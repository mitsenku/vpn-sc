#!/usr/bin/env bash
# =============================================================================
#  generate-xray-config.sh
#  Called by install.sh to template xray-config.json from .env values.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$INSTALL_DIR/.env"
OUTPUT="$INSTALL_DIR/config/xray-config.json"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }
source "$ENV_FILE"

# ── Build inbounds array ──────────────────────────────────────────────────────
WS_INBOUND=$(cat <<EOF
    {
      "tag": "inbound-ws",
      "port": 8080,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}",
          "headers": {
            "Host": ""
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
EOF
)

if [[ "${ENABLE_REALITY}" == "true" ]]; then
  REALITY_INBOUND=$(cat <<EOF
,
    {
      "tag": "inbound-reality",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
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
        },
        "tcpSettings": {
          "acceptProxyProtocol": false
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
EOF
)
else
  REALITY_INBOUND=""
fi

# ── Build outbounds array ─────────────────────────────────────────────────────
FREEDOM_OUTBOUND=$(cat <<'EOF'
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
EOF
)

if [[ "${ENABLE_WARP}" == "true" ]]; then
  WARP_OUTBOUND=$(cat <<EOF
    {
      "tag": "warp",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${WARP_PRIVATE_KEY}",
        "address": ["${WARP_ADDRESS}", "2606:4700:110:8a36:df92:102a:9602:fa18/128"],
        "peers": [
          {
            "publicKey": "${WARP_PUBLIC_KEY}",
            "endpoint": "${WARP_ENDPOINT}",
            "allowedIPs": ["0.0.0.0/0", "::/0"]
          }
        ],
        "reserved": [0, 0, 0],
        "mtu": 1280
      }
    },
EOF
)
  WARP_ROUTING=$(cat <<'EOF'
      {
        "type": "field",
        "outboundTag": "warp",
        "domain": [
          "geosite:openai",
          "domain:openai.com",
          "domain:chatgpt.com",
          "domain:claude.ai",
          "domain:anthropic.com",
          "geosite:netflix",
          "geosite:disney",
          "domain:disneyplus.com",
          "domain:spotify.com"
        ]
      },
EOF
)
else
  WARP_OUTBOUND=""
  WARP_ROUTING=""
fi

# ── Write final JSON ──────────────────────────────────────────────────────────
cat > "$OUTPUT" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/dev/null",
    "error": ""
  },
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "domains": ["geosite:geolocation-!cn"],
        "queryStrategy": "UseIPv4v6"
      },
      {
        "address": "8.8.8.8",
        "port": 53
      },
      "localhost"
    ],
    "disableFallbackIfMatch": true
  },
  "inbounds": [
    ${WS_INBOUND}${REALITY_INBOUND}
  ],
  "outbounds": [
    ${WARP_OUTBOUND}${FREEDOM_OUTBOUND}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "ip": ["geoip:private"]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": ["geosite:category-ads-all"]
      },
      ${WARP_ROUTING}{
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 10,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": false,
        "statsUserDownlink": false,
        "bufferSize": 512
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
EOF

echo "  Written: $OUTPUT"

# Validate JSON
if command -v python3 &>/dev/null; then
  python3 -m json.tool "$OUTPUT" > /dev/null && echo "  JSON validation: OK"
fi
