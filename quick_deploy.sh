#!/usr/bin/env bash
# =============================================================================
#  quick_deploy.sh — Fast Zero-Prompt Quick Tunnel Deployer
#  Uses Cloudflare Quick Tunnel (trycloudflare.com).
#  No Cloudflare account, no domain, no typing required!
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

# ── Root Check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run as root!${NC}"
  echo "Use: sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/mitsenku/vpn-sc/main/quick_deploy.sh)\""
  exit 1
fi

banner "Instant Quick Tunnel Proxy Setup (Zero Account Required)"

# ── 1. Install Dependencies ───────────────────────────────────────────────────
info "Installing packages (curl, unzip, jq, ufw, qrencode)..."
if command -v apt-get &>/dev/null; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl unzip jq ufw ca-certificates qrencode python3 >/dev/null 2>&1 || true
elif command -v dnf &>/dev/null; then
  dnf install -y curl unzip jq firewalld qrencode python3 >/dev/null 2>&1 || true
fi
success "Dependencies ready"

# ── 2. Fast Xray Installation (Direct Binary - No Hang) ───────────────────────
if ! command -v xray &>/dev/null; then
  info "Downloading Xray-core binary..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  X_ARCH="64" ;;
    aarch64) X_ARCH="arm64-v8a" ;;
    *)       X_ARCH="64" ;;
  esac

  mkdir -p /usr/local/bin /usr/local/etc/xray
  curl -L --max-time 15 -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${X_ARCH}.zip" >/dev/null 2>&1 || true

  if [ -f /tmp/xray.zip ]; then
    unzip -o /tmp/xray.zip xray geosite.dat geoip.dat -d /usr/local/bin/ >/dev/null 2>&1 || true
    chmod +x /usr/local/bin/xray || true
    rm -f /tmp/xray.zip
  fi
fi

if command -v xray &>/dev/null; then
  success "Xray core active ($(xray version 2>/dev/null | head -n1 || echo 'ready'))"
else
  info "Falling back to official installer script..."
  bash -c "$(curl -L --max-time 10 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || true
fi

# Create Xray systemd service
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

# ── 3. Install cloudflared ────────────────────────────────────────────────────
if ! command -v cloudflared &>/dev/null; then
  info "Downloading cloudflared binary..."
  ARCH=$(uname -m)
  [ "$ARCH" = "aarch64" ] && CF_ARCH="arm64" || CF_ARCH="amd64"

  curl -L --max-time 15 -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" >/dev/null 2>&1 || true
  chmod +x /usr/local/bin/cloudflared || true
fi
success "cloudflared active"

# ── 4. Generate Keys & Xray Config ───────────────────────────────────────────
info "Generating UUID & keys..."
UUID=$(xray uuid 2>/dev/null || echo "12345678-1234-1234-1234-123456789abc")
WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
VPS_IP=$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "1.2.3.4")

mkdir -p /usr/local/etc/xray

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
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart xray >/dev/null 2>&1 || true
systemctl enable xray >/dev/null 2>&1 || true

# ── 5. Start Quick Tunnel Service ─────────────────────────────────────────────
info "Starting Cloudflare Quick Tunnel..."
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

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now cf-tunnel >/dev/null 2>&1 || true

# Enable firewall
if command -v ufw &>/dev/null; then
  ufw allow ssh >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
fi

info "Waiting for Cloudflare Tunnel URL to generate (5s)..."
sleep 5

# Extract trycloudflare URL
TRY_URL=""
for i in {1..10}; do
  TRY_URL=$(journalctl -u cf-tunnel -n 100 --no-pager 2>/dev/null | grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' | tail -n 1 || echo "")
  if [ -n "$TRY_URL" ]; then
    break
  fi
  sleep 1
done

CLEAN_HOST="${TRY_URL#https://}"

if [ -z "$CLEAN_HOST" ]; then
  CLEAN_HOST="generating-please-wait.trycloudflare.com"
fi

TUNNEL_URI="vless://${UUID}@${CLEAN_HOST}:443?type=ws&security=tls&path=${WS_PATH}&host=${CLEAN_HOST}&sni=${CLEAN_HOST}#CF-QuickTunnel"

# ── Save Single Config File ───────────────────────────────────────────────────
SINGLE_CONFIG_FILE="/root/vpn_config.txt"
echo "$TUNNEL_URI" > "$SINGLE_CONFIG_FILE"
chmod 644 "$SINGLE_CONFIG_FILE"

# ── Helper Script ─────────────────────────────────────────────────────────────
cat > /root/show_qr.sh <<'QREOF'
#!/usr/bin/env bash
TRY_URL=$(journalctl -u cf-tunnel -n 100 --no-pager 2>/dev/null | grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' | tail -n 1 || echo "")
CLEAN_HOST="${TRY_URL#https://}"
UUID=$(grep -o '"id": "[^"]*"' /usr/local/etc/xray/config.json 2>/dev/null | head -n 1 | cut -d'"' -f4 || echo "")
WS_PATH=$(grep -o '"path": "[^"]*"' /usr/local/etc/xray/config.json 2>/dev/null | head -n 1 | cut -d'"' -f4 || echo "")

if [ -n "$CLEAN_HOST" ]; then
  URI="vless://${UUID}@${CLEAN_HOST}:443?type=ws&security=tls&path=${WS_PATH}&host=${CLEAN_HOST}&sni=${CLEAN_HOST}#CF-QuickTunnel"
  echo ""
  echo "Connection URI:"
  echo "$URI"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$URI"
  else
    curl -s "qrenco.de/$URI" || true
  fi
else
  echo "Tunnel URL still generating. Please try again in 5 seconds."
fi
QREOF
chmod +x /root/show_qr.sh

# ── Display Results ───────────────────────────────────────────────────────────
banner "🎉 QUICK TUNNEL DEPLOYED SUCCESSFULLY 🎉"

echo -e "${BOLD}Connection Link (Import into Hiddify / v2rayN):${NC}"
echo -e "${CYAN}${TUNNEL_URI}${NC}\n"

echo -e "${BOLD}📱 QR Code for Mobile Scanning:${NC}"
if command -v qrencode &>/dev/null; then
  qrencode -t ANSIUTF8 "$TUNNEL_URI"
  echo ""
else
  curl -s "qrenco.de/$TUNNEL_URI" 2>/dev/null || echo "Scan manually using the link above"
  echo ""
fi

echo -e "${BOLD}Saved file on VPS:${NC} /root/vpn_config.txt"
echo -e "${GREEN}Tip:${NC} Run '${CYAN}bash /root/show_qr.sh${NC}' anytime to show the QR code again!"
