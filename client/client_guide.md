# Client Setup Guide

This guide covers importing the proxy configuration into Hiddify, v2rayN (Windows), and v2rayNG (Android).

---

## Before You Start

> **Important — Captive Portal First**
> On campus WiFi, you must **authenticate through the captive portal in your browser first**, then start the proxy. The proxy cannot work until your MAC address is granted network access.

---

## Step 1 — Get Your Config Files

Run the config generator on any machine (or on your VPS):
```bash
cd client
pip3 install qrcode[pil] Pillow   # first time only
python3 generate_config.py
```

This creates the `client/output/` directory with:
- `all-connections.txt` — raw `vless://` URIs
- `hiddify-subscription.txt` — Hiddify import file
- `v2ray-share-links.txt` — v2rayN / v2rayNG links
- `qr-tunnel.png` — QR code for the tunnel profile
- `qr-reality.png` — QR code for the REALITY profile

---

## Windows — Hiddify Next (Recommended)

**Why Hiddify?** Supports TUN mode (routes all apps), has a clean GUI, and handles profile switching automatically.

### Setup
1. Download **Hiddify Next** from GitHub:
   → https://github.com/hiddify/hiddify-app/releases/latest
   Download: `Hiddify-Windows-Setup-x64.exe`

2. Install and open Hiddify

3. Add the CF-Tunnel profile:
   - Click **"+"** → **"Add from File"**
   - Select `client/output/hiddify-subscription.txt`
   - Both profiles (Tunnel + REALITY) will be imported

   *Alternative:* Click **"+"** → **"Add from Clipboard"** → paste the `vless://` URI from `all-connections.txt`

4. Enable **TUN Mode**:
   - Settings → **VPN** tab → toggle on **System Proxy / TUN**
   - This routes *all* applications through the proxy (Discord, games, etc.)

5. Click **Connect** on the CF-Tunnel profile

6. Verify: open https://ip.gs in your browser → should show your VPS IP

### Switching Profiles
- **Slow connection?** Switch to the REALITY profile (direct, lower latency)
- **REALITY blocked?** Switch back to CF-Tunnel (hidden behind Cloudflare)

---

## Windows — v2rayN (Advanced Users)

v2rayN offers more fine-grained control but requires manual TUN setup.

### Setup
1. Download **v2rayN** from GitHub:
   → https://github.com/2dust/v2rayN/releases/latest
   Download: `v2rayN-windows-64.zip`

2. Extract and run `v2rayN.exe`

3. Add server:
   - **Servers** → **Import bulk URL from clipboard**
   - Open `client/output/v2ray-share-links.txt`, copy a `vless://` line, paste

4. Enable TUN mode:
   - Settings → **Core** → select **Xray-core**
   - Settings → **TUN** → enable TUN
   - Accept UAC prompt (requires admin)

5. Right-click system tray icon → **Select Server** → choose your server

6. Verify at https://ip.gs

---

## Android — Hiddify Next (Recommended)

### Setup
1. Download **Hiddify** from:
   - Google Play: https://play.google.com/store/apps/details?id=app.hiddify.com
   - GitHub APK: https://github.com/hiddify/hiddify-app/releases/latest

2. Tap **"+"** → **"Add from QR Code"**
   - Scan `qr-tunnel.png` with your phone camera
   - Or scan `qr-reality.png` for the REALITY profile

   *Alternative:* Share `all-connections.txt` to your phone → Hiddify → **"+"** → **"Add from File"**

3. Enable VPN:
   - Toggle the VPN switch at the top
   - Accept the VPN permission dialog

4. Verify: open https://ip.gs in Chrome → should show VPS IP

### Per-App Routing (Optional)
- Settings → **Routing** → enable **Per-app proxy**
- Choose which apps use the proxy (e.g., only browser + Discord)

---

## Android — v2rayNG (Lightweight Alternative)

v2rayNG does not support TUN mode — it works as a SOCKS/HTTP proxy or via per-app VPN.

### Setup
1. Download from Google Play:
   → https://play.google.com/store/apps/details?id=com.v2ray.ang

2. Tap **"+"** (top right) → **"Import config from QRcode"**
   - Scan `qr-tunnel.png`

3. Tap the **▶** button to connect

4. Browser traffic and apps that support proxy settings will be routed.
   For full system routing, use Hiddify instead.

---

## iOS — Hiddify

1. Download from the App Store:
   → https://apps.apple.com/app/hiddify/id6596777532

2. Tap **"+"** → **"Add from QR Code"** (scan `qr-tunnel.png`)
   or **"Add from URL"** (paste the `vless://` URI)

3. Enable the VPN toggle → allow VPN configuration

4. Verify at https://ip.gs

---

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| Can't connect — "No network" | Authenticate campus captive portal first, then connect |
| Connected but slow | Switch to REALITY profile (lower latency, no CDN hop) |
| REALITY not connecting | Your VPS IP may be blocked — use CF-Tunnel instead |
| Error 1101 in Cloudflare | Cloudflare can't reach your origin → check `docker compose ps` on VPS |
| Error 522 | Xray container is down → `docker compose restart xray` |
| WebSocket disconnect after ~100s | Enable keepalive in client (Hiddify does this automatically) |
| IP shows college network at ip.gs | TUN mode is off — enable VPN/TUN in client settings |
| ChatGPT / Netflix blocked | WARP outbound should handle this — verify with `docker logs xray-proxy` |

---

## Updating Your Config

If you rotate your WebSocket path or generate a new UUID:
```bash
# On VPS:
nano server/.env          # edit values
bash server/scripts/generate-xray-config.sh
docker compose restart xray

# Then regenerate client configs:
python3 client/generate_config.py
```
