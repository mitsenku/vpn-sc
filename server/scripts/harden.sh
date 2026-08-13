#!/usr/bin/env bash
# =============================================================================
#  harden.sh — Post-install VPS security hardening
#  Run once after install.sh completes.
#  Usage: sudo bash scripts/harden.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash scripts/harden.sh"; exit 1; }

# ── SSH Hardening ─────────────────────────────────────────────────────────────
harden_ssh() {
  banner "Hardening SSH"
  SSHD_CONF="/etc/ssh/sshd_config"

  # Only disable password auth if we can verify a key is set up
  if [[ -f ~/.ssh/authorized_keys ]] && [[ -s ~/.ssh/authorized_keys ]]; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONF"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONF"
    success "Password auth disabled (key found in authorized_keys)"
  else
    warn "No SSH key found in authorized_keys — skipping password auth disable."
    warn "Add your public key first: ssh-copy-id user@$HOSTNAME"
  fi

  # Harden other settings
  grep -q "^MaxAuthTries"       "$SSHD_CONF" || echo "MaxAuthTries 3"       >> "$SSHD_CONF"
  grep -q "^ClientAliveInterval" "$SSHD_CONF" || echo "ClientAliveInterval 120" >> "$SSHD_CONF"
  grep -q "^ClientAliveCountMax" "$SSHD_CONF" || echo "ClientAliveCountMax 2"  >> "$SSHD_CONF"
  grep -q "^X11Forwarding"     "$SSHD_CONF" || echo "X11Forwarding no"     >> "$SSHD_CONF"
  grep -q "^AllowTcpForwarding" "$SSHD_CONF" || echo "AllowTcpForwarding yes" >> "$SSHD_CONF"

  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  success "SSH hardened"
}

# ── Fail2Ban ──────────────────────────────────────────────────────────────────
install_fail2ban() {
  banner "Installing Fail2Ban"
  if ! command -v fail2ban-server &>/dev/null; then
    if command -v apt-get &>/dev/null; then
      apt-get install -y -q fail2ban
    elif command -v dnf &>/dev/null; then
      dnf install -y -q fail2ban
    fi
  fi

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 86400
EOF

  systemctl enable --now fail2ban
  success "Fail2Ban installed and enabled (SSH brute-force protection)"
}

# ── Kernel tuning for throughput (BBR + FQ) ───────────────────────────────────
tune_kernel() {
  banner "Kernel Tuning (BBR congestion control)"
  SYSCTL_CONF="/etc/sysctl.d/99-proxy-tuning.conf"

  cat > "$SYSCTL_CONF" <<'EOF'
# TCP BBR for improved throughput on lossy/congested networks
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Increase socket buffer sizes
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.ipv4.tcp_rmem = 4096 87380 26214400
net.ipv4.tcp_wmem = 4096 65536 26214400

# Reduce TIME_WAIT overhead
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Harden against SYN floods
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
EOF

  sysctl -p "$SYSCTL_CONF" > /dev/null
  success "Kernel parameters applied (BBR enabled)"
}

# ── Docker daemon log limits ───────────────────────────────────────────────────
harden_docker() {
  banner "Hardening Docker Daemon"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "live-restore": true
}
EOF
  systemctl reload docker 2>/dev/null || systemctl restart docker
  success "Docker daemon: log limits and live-restore configured"
}

# ── Unattended security upgrades ──────────────────────────────────────────────
enable_auto_updates() {
  banner "Enabling Unattended Security Upgrades"
  if command -v apt-get &>/dev/null; then
    apt-get install -y -q unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    systemctl enable --now unattended-upgrades
    success "Automatic security updates enabled"
  else
    warn "Non-Debian OS: enable automatic updates manually."
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}Hardening complete!${NC}"
  echo ""
  echo "  ✅  SSH: MaxAuthTries=3, key-only (if key present)"
  echo "  ✅  Fail2Ban: SSH brute-force protection (24h ban after 3 failures)"
  echo "  ✅  Kernel: BBR congestion control, anti-spoofing, SYN flood protection"
  echo "  ✅  Docker: log size limits, live-restore"
  echo "  ✅  Unattended security upgrades (Debian/Ubuntu)"
  echo ""
  echo -e "${YELLOW}Reminder:${NC} Schedule health-check.sh in cron:"
  echo "  crontab -e"
  echo "  */5 * * * * bash $(dirname "$0")/health-check.sh >> /var/log/proxy-health.log 2>&1"
}

# ── Main ──────────────────────────────────────────────────────────────────────
harden_ssh
install_fail2ban
tune_kernel
harden_docker
enable_auto_updates
print_summary
