
#!/bin/bash
# ============================================
# VLESS VPN Setup — FREE, No Domain, No WARP
# Uses Cloudflare Quick Tunnel (trycloudflare.com)
# Run this on your Ubuntu VPS
# ============================================

set -e

echo "============================================"
echo "  VLESS VPN — VPS Setup"
echo "  FREE: No Domain, No WARP"
echo "  Uses trycloudflare.com"
echo "============================================"
echo ""

# ----- Step 1: Update System -----
echo "[1/5] Updating system..."
sudo apt update && sudo apt upgrade -y
echo "✅ System updated"
echo ""

# ----- Step 2: Install Xray -----
echo "[2/5] Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
echo "✅ Xray installed: $(xray version | head -1)"
echo ""

# ----- Step 3: Install cloudflared -----
echo "[3/5] Installing cloudflared..."
curl -L --output /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i /tmp/cloudflared.deb
rm /tmp/cloudflared.deb
echo "✅ cloudflared installed: $(cloudflared --version)"
echo ""

# ----- Step 4: Generate UUID and Configure Xray -----
echo "[4/5] Configuring Xray VLESS + WebSocket..."
UUID=$(xray uuid)
echo "   Your UUID: $UUID"
echo "   ⚠️  SAVE THIS! You need it for the client."
echo ""

# Save UUID to file for easy reference
echo "$UUID" > /root/vpn_uuid.txt

sudo bash -c "cat > /usr/local/etc/xray/config.json << XRAYEOF
{
    \"log\": {
        \"loglevel\": \"warning\"
    },
    \"inbounds\": [
        {
            \"port\": 8080,
            \"listen\": \"127.0.0.1\",
            \"protocol\": \"vless\",
            \"settings\": {
                \"clients\": [
                    {
                        \"id\": \"$UUID\",
                        \"level\": 0
                    }
                ],
                \"decryption\": \"none\"
            },
            \"streamSettings\": {
                \"network\": \"ws\",
                \"wsSettings\": {
                    \"path\": \"/ws-tunnel\"
                }
            }
        }
    ],
    \"outbounds\": [
        {
            \"protocol\": \"freedom\",
            \"settings\": {}
        }
    ]
}
XRAYEOF"

sudo systemctl restart xray
sudo systemctl enable xray
echo "✅ Xray configured and running on localhost:8080"
echo ""

# ----- Step 5: Install Nginx -----
echo "[5/5] Installing Nginx..."
sudo apt install -y nginx

# Configure Nginx as reverse proxy
sudo bash -c 'cat > /etc/nginx/sites-available/vless << NGINXEOF
server {
    listen 8888;

    # Cover page — looks like a real website
    location / {
        default_type text/html;
        return 200 "<html><body><h1>Welcome</h1><p>Page under construction.</p></body></html>";
    }

    # Secret VLESS WebSocket endpoint
    location /ws-tunnel {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINXEOF'

sudo ln -sf /etc/nginx/sites-available/vless /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
sudo systemctl enable nginx
echo "✅ Nginx configured on port 8888"
echo ""

# ----- Create the tunnel start script -----
cat > /root/start_tunnel.sh << 'TUNNELEOF'
#!/bin/bash
# Start Cloudflare Quick Tunnel
# This gives you a FREE trycloudflare.com URL
# No domain, no account, no signup needed!

echo "Starting Cloudflare Quick Tunnel..."
echo "Wait for the URL to appear below..."
echo ""
echo "============================================"
echo "  Copy the URL that appears and use it"
echo "  as the 'Address' in v2rayN client"
echo "============================================"
echo ""

cloudflared tunnel --url http://localhost:8888

# The output will show something like:
# https://some-random-words.trycloudflare.com
#
# Use that as your server address in v2rayN!
TUNNELEOF

chmod +x /root/start_tunnel.sh

# ----- Create systemd service for persistent tunnel -----
sudo bash -c 'cat > /etc/systemd/system/cf-tunnel.service << SVCEOF
[Unit]
Description=Cloudflare Quick Tunnel
After=network.target nginx.service xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:8888
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF'

# Enable IP Forwarding
sudo sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

echo ""
echo "============================================"
echo "  ✅ VPS SETUP COMPLETE!"
echo "============================================"
echo ""
echo "  UUID: $UUID"
echo "  (Also saved to /root/vpn_uuid.txt)"
echo ""
echo "============================================"
echo "  NOW RUN THIS TO GET YOUR FREE URL:"
echo "============================================"
echo ""
echo "  sudo bash /root/start_tunnel.sh"
echo ""
echo "  It will output a URL like:"
echo "  https://random-words.trycloudflare.com"
echo ""
echo "  Use that URL in v2rayN on your Windows PC!"
echo ""
echo "============================================"
echo ""
echo "  CLIENT CONFIG (for v2rayN):"
echo "  Address:    (the trycloudflare.com URL)"
echo "  Port:       443"
echo "  UUID:       $UUID"
echo "  Protocol:   VLESS"
echo "  Network:    ws (WebSocket)"
echo "  Path:       /ws-tunnel"
echo "  TLS:        tls"
echo "  Encryption: none"
echo "============================================"
echo ""
echo "  TO RUN TUNNEL AS A PERMANENT SERVICE:"
echo "  sudo systemctl enable cf-tunnel"
echo "  sudo systemctl start cf-tunnel"
echo "  sudo journalctl -u cf-tunnel -f  (to see the URL)"
echo ""
echo "============================================"
