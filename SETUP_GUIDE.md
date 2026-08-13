# ============================================
# COMPLETE VPN SETUP GUIDE
# VLESS + Cloudflare Tunnel — FREE
# No Domain. No WARP. No Payment.
# ============================================


## HOW IT WORKS
## ============================================
##
##   v2rayN (Windows — TUN mode, ALL apps)
##       │
##       │  VLESS + WebSocket + TLS (looks like HTTPS)
##       ▼
##   Cloudflare CDN (trycloudflare.com — port 443)
##       │
##       │  Cloudflare Quick Tunnel
##       ▼
##   Your VPS (Nginx + Xray)
##       │
##       │  Decodes VLESS → Internet
##       ▼
##   Internet (sees VPS IP)
##
##   Cost:     $0 (only your VPS cost)
##   Domain:   Not needed (uses trycloudflare.com)
##   WARP:     Not needed
##   Account:  Not needed for tunnel


## PART 1 — RUN SETUP ON YOUR VPS
## ============================================

### Step 1.1 — Copy the script to your VPS

Open Command Prompt on your Windows PC:

    scp C:\Users\mithun\Downloads\vpn\vps_setup.sh root@YOUR_VPS_IP:/root/

(Replace YOUR_VPS_IP with your actual VPS IP address)

### Step 1.2 — SSH into your VPS

    ssh root@YOUR_VPS_IP

### Step 1.3 — Run the setup script

    chmod +x vps_setup.sh
    sudo bash vps_setup.sh

Wait for it to finish. It will print your UUID — SAVE IT!

### Step 1.4 — Start the Cloudflare Tunnel

    sudo bash /root/start_tunnel.sh

After a few seconds, you will see output like:

    2024-01-01 INF +-------------------------------------------+
    2024-01-01 INF | Your free tunnel URL is:                  |
    2024-01-01 INF | https://happy-green-fox.trycloudflare.com |
    2024-01-01 INF +-------------------------------------------+

COPY THAT URL! You need it for the client.

Example: happy-green-fox.trycloudflare.com
(yours will be different random words)

### Step 1.5 — Make tunnel permanent (optional)

If you want the tunnel to run 24/7 and survive reboots:

    sudo systemctl enable cf-tunnel
    sudo systemctl start cf-tunnel

To see the URL again:

    sudo journalctl -u cf-tunnel | grep "trycloudflare"


## PART 2 — WINDOWS CLIENT SETUP (v2rayN)
## ============================================

### Step 2.1 — Download v2rayN

1. Go to: https://github.com/2dust/v2rayN/releases
2. Download the file named: v2rayN-With-Core.zip
3. Extract the ZIP file to a folder (e.g., C:\v2rayN)
4. Open the folder → Run v2rayN.exe
5. If Windows Defender blocks it:
   → Click "More Info" → Click "Run Anyway"

### Step 2.2 — Add Your VLESS Server

1. In v2rayN, click the server menu or "+" button
2. Select: Add [VLESS] server
3. Fill in these settings:

   ┌─────────────────────────────────────────────────┐
   │  Remarks:       My VPN                          │
   │                                                 │
   │  Address:       happy-green-fox.trycloudflare.com│
   │                 (use YOUR trycloudflare URL)     │
   │                                                 │
   │  Port:          443                              │
   │                                                 │
   │  UUID:          (paste UUID from VPS setup)      │
   │                                                 │
   │  Flow:          (leave empty)                    │
   │                                                 │
   │  Encryption:    none                             │
   │                                                 │
   │  Network:       ws                               │
   │                                                 │
   │  Path:          /ws-tunnel                       │
   │                                                 │
   │  TLS:           tls                              │
   │                                                 │
   │  SNI:           happy-green-fox.trycloudflare.com│
   │                 (same as Address)                │
   │                                                 │
   │  Fingerprint:   chrome                           │
   │                                                 │
   │  AllowInsecure: true                             │
   └─────────────────────────────────────────────────┘

4. Click "Confirm" or "OK" to save

### Step 2.3 — Set Active Server

1. In the server list, right-click "My VPN"
2. Click "Set as active server"

### Step 2.4 — Enable TUN Mode (ALL Apps Through VPN)

1. Look at the bottom bar of v2rayN
2. Find the mode selector
3. Change to "TUN Mode"
4. If asked to install TUN adapter → Click Yes
5. If TUN mode doesn't appear:
   - Close v2rayN
   - Right-click v2rayN.exe → "Run as Administrator"
   - Try again

TUN Mode means: ALL traffic from ALL apps goes through the VPN.
(Games, Discord, Spotify, WhatsApp, browser — everything!)

### Step 2.5 — Connect!

1. Press the connect button (play ▶ button) or press Enter
2. Status bar shows connected (green indicator)
3. ALL your traffic now routes through Cloudflare → VPS!


## PART 3 — VERIFY IT WORKS
## ============================================

### Test 1 — Check IP

Open browser → Go to: https://whatismyipaddress.com
→ Should show your VPS IP and VPS location ✅
→ NOT your real home IP

### Test 2 — Check from Command Prompt

Open CMD and type:

    curl https://icanhazip.com

→ Should show VPS IP ✅

### Test 3 — Check all apps work

- Open Discord → Make a voice call → Works ✅
- Open Spotify → Play a song → Works ✅
- Open a game → Multiplayer → Works ✅
- Ping test: ping 8.8.8.8 → Works ✅


## WHAT THE FIREWALL SEES
## ============================================

    Your PC connects to: happy-green-fox.trycloudflare.com
    
    Firewall analysis:
    ✅ Protocol:     HTTPS (port 443)
    ✅ Destination:  Cloudflare IP (104.x.x.x)
    ✅ Traffic type:  Normal encrypted web traffic
    ✅ SNI:          trycloudflare.com (Cloudflare's own domain)
    ❌ VPN detected: NO
    ❌ Suspicious:   NO
    
    Verdict: Looks like someone browsing a Cloudflare-hosted website.


## DAILY USAGE
## ============================================

    VPN ON:   Open v2rayN → Connect
    VPN OFF:  v2rayN → Disconnect (or close the app)

    VPS runs automatically 24/7.
    Just control ON/OFF from your Windows PC.


## IMPORTANT NOTES
## ============================================

### The trycloudflare.com URL may change!

If your VPS reboots or the tunnel restarts, you get a NEW random URL.
When that happens:
1. SSH into VPS: ssh root@YOUR_VPS_IP
2. Check new URL: sudo journalctl -u cf-tunnel | grep "trycloudflare"
3. Update the Address and SNI in v2rayN with the new URL

### To avoid URL changes:
Run the tunnel as a systemd service (Step 1.5).
It auto-restarts but keeps the same URL as long as the process doesn't fully die.

### Want a permanent URL?
Buy a $1 domain (.xyz from Namecheap) and add it to Cloudflare.
Then the URL never changes.


## TROUBLESHOOTING
## ============================================

### v2rayN won't connect:
    - Check VPS: sudo systemctl status xray
    - Check tunnel: sudo systemctl status cf-tunnel
    - Make sure the trycloudflare URL is correct
    - Check UUID matches

### IP didn't change:
    - Enable TUN mode (not just Global)
    - Run v2rayN as Administrator
    - Check routing mode is not "Direct"

### TUN mode not working:
    - Right-click v2rayN → Run as Administrator
    - Install TUN driver when prompted
    - Restart v2rayN

### Tunnel URL changed:
    - SSH to VPS
    - Run: sudo journalctl -u cf-tunnel | grep "trycloudflare"
    - Update v2rayN with new URL

### Slow speeds:
    - Normal — free Cloudflare has no speed limit
    - Check your VPS bandwidth
    - Try VPS in a location closer to you
