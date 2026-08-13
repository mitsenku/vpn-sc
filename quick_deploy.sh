#!/usr/bin/env bash
# =============================================================================
#  quick_deploy.sh — 100% Zero-Prompt Quick Tunnel Deployer
#  Uses Cloudflare Quick Tunnel (trycloudflare.com).
#  No Cloudflare account, no domain, no typing required!
#
#  Usage (on Ubuntu/Debian VPS as root):
#    sudo bash quick_deploy.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash quick_deploy.sh"

banner "Instant Quick Tunnel Proxy Setup (Zero Account Required)"

# ── 1. Install Dependencies ───────────────────────────────────────────────────
info "Installing packages (curl, jq, ufw, qrencode)..."
if command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq curl jq ufw ca-certificates qrencode 2>/dev/null || true
elif command -v dnf &>/dev/null; then
  dnf install -y -q curl jq firewalld qrencode 2>/dev/null || true
fi

# ── 2. Install Xray ───────────────────────────────────────────────────────────
if ! command -v xray &>/dev/null; then
  info "Installing Xray core..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
fi
success "Xray core active"

# ── 3. Install cloudflared ────────────────────────────────────────────────────
if ! command -v cloudflared &>/dev/null; then
  info "Installing cloudflared..."
  ARCH=$(uname -m)
  [[ "$ARCH" == "aarch64" ]] && CF_ARCH="arm64" || CF_ARCH="amd64"
  if command -v apt-get &>/dev/null; then
    curl -L -o /tmp/cf.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb" >/dev/null 2>&1
    dpkg -i /tmp/cf.deb >/dev/null 2>&1
    rm -f /tmp/cf.deb
  else
    curl -L -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" >/dev/null 2>&1
    chmod +x /usr/local/bin/cloudflared
  fi
fi
success "cloudflared active"

# ── 4. Generate Keys & Xray Config ───────────────────────────────────────────
UUID=$(xray uuid)
WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
KEYS=$(xray x25519)
REALITY_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $NF}')
REALITY_PUBLIC_KEY=$(echo "$KEYS"  | grep "Public key"  | awk '{print $NF}')
REALITY_SHORT_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)
VPS_IP=$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || echo "1.2.3.4")

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "inbound-ws",
      "port": 8080,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "level": 0 } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "inbound-reality",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision", "level": 0 } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com", "microsoft.com"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}", ""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "direct", "network": "tcp,udp" }
    ]
  }
}
EOF

systemctl restart xray
systemctl enable xray

# ── 5. Start Quick Tunnel Service ─────────────────────────────────────────────
cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=Cloudflare Quick Tunnel
After=network.target xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8080
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cf-tunnel

# Enable firewall
if command -v ufw &>/dev/null; then
  ufw allow ssh >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
fi

info "Waiting for Cloudflare Quick Tunnel URL to generate..."
sleep 5

# Extract trycloudflare URL
TRY_URL=""
for i in {1..10}; do
  TRY_URL=$(journalctl -u cf-tunnel -n 100 --no-pager 2>/dev/null | grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' | tail -n 1 || echo "")
  if [[ -n "$TRY_URL" ]]; then
    break
  fi
  sleep 2
done

CLEAN_HOST="${TRY_URL#https://}"

if [[ -z "$CLEAN_HOST" ]]; then
  CLEAN_HOST="check-journalctl.trycloudflare.com"
fi

TUNNEL_URI="vless://${UUID}@${CLEAN_HOST}:443?type=ws&security=tls&path=${WS_PATH}&host=${CLEAN_HOST}&sni=${CLEAN_HOST}#CF-QuickTunnel"
REALITY_URI="vless://${UUID}@${VPS_IP}:443?type=tcp&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}#Direct-REALITY"

# ── Create Single Importable Config File ─────────────────────────────────────
SINGLE_CONFIG_FILE="/root/vpn_config.txt"
cat > "$SINGLE_CONFIG_FILE" <<EOF
# ============================================================
# SINGLE CLIENT CONFIG FILE — Import directly into Hiddify / v2rayN / v2rayNG
# Saved at: /root/vpn_config.txt
# ============================================================

${TUNNEL_URI}
${REALITY_URI}
EOF
chmod 644 "$SINGLE_CONFIG_FILE"

# ── Create v2rayN Client JSON Config File ────────────────────────────────────
V2RAYN_JSON_FILE="/root/v2rayN_client.json"
cat > "$V2RAYN_JSON_FILE" <<EOF
{
  "v": "2",
  "ps": "CF-QuickTunnel",
  "add": "${CLEAN_HOST}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "scy": "none",
  "net": "ws",
  "type": "none",
  "host": "${CLEAN_HOST}",
  "path": "${WS_PATH}",
  "tls": "tls",
  "sni": "${CLEAN_HOST}",
  "alpn": ""
}
EOF
chmod 644 "$V2RAYN_JSON_FILE"

# ── 6. Display Connection Details & QR Code ───────────────────────────────────
banner "🎉 QUICK TUNNEL DEPLOYED SUCCESSFULLY 🎉"

echo -e "${BOLD}1. SINGLE CONFIG FILE FOR YOUR CLIENT APP:${NC}"
echo -e "   File saved on VPS at: ${GREEN}/root/vpn_config.txt${NC}"
echo -e "   v2rayN JSON saved at: ${GREEN}/root/v2rayN_client.json${NC}\n"

echo -e "${BOLD}File Contents (Copy everything between lines below & save as config.txt):${NC}"
echo -e "${YELLOW}------------------- BEGIN CONFIG FILE -------------------${NC}"
cat "$SINGLE_CONFIG_FILE"
echo -e "${YELLOW}-------------------- END CONFIG FILE --------------------${NC}\n"

if command -v qrencode &>/dev/null && [[ "$CLEAN_HOST" != "check-journalctl.trycloudflare.com" ]]; then
  echo -e "${BOLD}Scan with Hiddify / v2rayNG on Phone:${NC}"
  qrencode -t ANSIUTF8 "$TUNNEL_URI"
  echo ""
fi

if [[ "$CLEAN_HOST" == "check-journalctl.trycloudflare.com" ]]; then
  echo -e "${YELLOW}URL still generating. Run this command to view your link:${NC}"
  echo "  sudo journalctl -u cf-tunnel -n 20 --no-pager | grep trycloudflare"
fi
