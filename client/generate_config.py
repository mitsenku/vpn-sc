#!/usr/bin/env python3
"""
generate_config.py — Client configuration generator
Generates VLESS connection URIs, QR codes, and client-specific configs
for Hiddify, v2rayN (Windows), and v2rayNG (Android).

Usage:
    python3 generate_config.py [--creds ../server/.credentials]
    python3 generate_config.py --tunnel-url YOUR_TUNNEL.trycloudflare.com \
        --uuid YOUR_UUID --ws-path /yourpath \
        [--vps-ip 1.2.3.4] [--reality-pubkey KEY] [--reality-shortid ID]
"""

import argparse
import base64
import json
import os
import sys
import urllib.parse
from pathlib import Path
from datetime import datetime

# ── Try importing QR code lib ─────────────────────────────────────────────────
try:
    import qrcode
    from PIL import Image
    QR_AVAILABLE = True
except ImportError:
    QR_AVAILABLE = False

OUTPUT_DIR = Path(__file__).parent / "output"

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

CYAN   = "\033[0;36m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
BOLD   = "\033[1m"
NC     = "\033[0m"


def info(msg):   print(f"{CYAN}[INFO]{NC}  {msg}")
def ok(msg):     print(f"{GREEN}[OK]{NC}    {msg}")
def warn(msg):   print(f"{YELLOW}[WARN]{NC}  {msg}")
def banner(msg): print(f"\n{BOLD}{CYAN}━━━  {msg}  ━━━{NC}\n")


def load_credentials(creds_path: Path) -> dict:
    """Parse key=value pairs from .credentials file."""
    creds = {}
    if not creds_path.exists():
        return creds
    with open(creds_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            creds[key.strip()] = val.strip()
    return creds


def build_tunnel_uri(uuid: str, tunnel_host: str, ws_path: str) -> str:
    """Build VLESS+WS+TLS URI for Cloudflare Tunnel mode."""
    params = urllib.parse.urlencode({
        "type":     "ws",
        "security": "tls",
        "path":     ws_path,
        "host":     tunnel_host,
        "sni":      tunnel_host,
    })
    name = urllib.parse.quote("CF-Tunnel (Primary)")
    return f"vless://{uuid}@{tunnel_host}:443?{params}#{name}"


def build_reality_uri(
    uuid: str, vps_ip: str,
    pubkey: str, shortid: str,
    sni: str = "www.microsoft.com"
) -> str:
    """Build VLESS+TCP+REALITY URI for direct fallback."""
    params = urllib.parse.urlencode({
        "type":       "tcp",
        "flow":       "xtls-rprx-vision",
        "security":   "reality",
        "sni":        sni,
        "fp":         "chrome",
        "pbk":        pubkey,
        "sid":        shortid,
    })
    name = urllib.parse.quote("Direct-REALITY (Fallback)")
    return f"vless://{uuid}@{vps_ip}:443?{params}#{name}"


# ═══════════════════════════════════════════════════════════════════════════════
# QR Code generation
# ═══════════════════════════════════════════════════════════════════════════════

def generate_qr_terminal(uri: str, label: str):
    """Print QR code to terminal using ANSI blocks."""
    if not QR_AVAILABLE:
        warn("qrcode/Pillow not installed. Install with: pip3 install qrcode[pil] Pillow")
        print(f"  URI: {uri}\n")
        return

    qr = qrcode.QRCode(border=1, error_correction=qrcode.constants.ERROR_CORRECT_M)
    qr.add_data(uri)
    qr.make(fit=True)
    print(f"\n{BOLD}QR Code — {label}{NC}")
    qr.print_ascii(invert=True)


def generate_qr_png(uri: str, filename: str) -> Path:
    """Save QR code as PNG file."""
    if not QR_AVAILABLE:
        return None
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    qr = qrcode.make(uri)
    path = OUTPUT_DIR / filename
    qr.save(str(path))
    return path


# ═══════════════════════════════════════════════════════════════════════════════
# Client-specific output formats
# ═══════════════════════════════════════════════════════════════════════════════

def build_hiddify_subscription(uris: list[str]) -> str:
    """
    Build a Hiddify-compatible subscription: base64-encoded newline-joined URIs.
    Can be imported directly via 'Add from URL' in Hiddify.
    """
    combined = "\n".join(uris)
    encoded = base64.b64encode(combined.encode()).decode()
    return encoded


def build_v2rayn_share(uri: str) -> str:
    """v2rayN share format is simply the vless:// URI, base64-encoded."""
    return base64.b64encode(uri.encode()).decode()


def build_v2rayng_share(uri: str) -> str:
    """v2rayNG uses the same format as v2rayN for VLESS."""
    return uri  # v2rayNG can import vless:// URIs directly


def save_hiddify_subscription(uris: list[str], tunnel_host: str) -> Path:
    """Save Hiddify subscription as a base64 file importable by URL."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    content = build_hiddify_subscription(uris)
    path = OUTPUT_DIR / "hiddify-subscription.txt"
    path.write_text(content)
    return path


def save_all_uris(uris: list[str]) -> Path:
    """Save all connection URIs in a plain text file."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUTPUT_DIR / "all-connections.txt"
    lines = [
        f"# Generated by generate_config.py on {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}",
        "# Import any of these URIs into Hiddify, v2rayN, or v2rayNG",
        "",
    ] + uris
    path.write_text("\n".join(lines))
    return path


# ═══════════════════════════════════════════════════════════════════════════════
# Main output
# ═══════════════════════════════════════════════════════════════════════════════

def print_client_instructions():
    print(f"""
{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CLIENT SETUP GUIDE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{NC}

{BOLD}WINDOWS — Hiddify Next (Recommended){NC}
  1. Download: https://github.com/hiddify/hiddify-app/releases/latest
  2. Open Hiddify → "+" button → Add from Clipboard or scan QR
  3. Paste the CF-Tunnel URI (primary), then add REALITY URI (fallback)
  4. Settings → VPN Mode → enable TUN (routes ALL apps, not just browser)
  5. Click Connect
  6. Verify at https://ip.gs — should show VPS/Cloudflare IP

{BOLD}WINDOWS — v2rayN (Power Users){NC}
  1. Download: https://github.com/2dust/v2rayN/releases/latest
  2. Servers → Add [VLESS] server → Paste URI
  3. Settings → Core: v2fly/xray → enable TUN mode
  4. Click ▶ (Connect)

{BOLD}ANDROID — Hiddify Next (Recommended){NC}
  1. Download: https://play.google.com/store/apps/details?id=app.hiddify.com
     or from: https://github.com/hiddify/hiddify-app/releases/latest
  2. Tap "+" → Add from QR code (scan QR below) or paste URI
  3. Add both profiles (Tunnel + REALITY)
  4. Tap VPN toggle → enable TUN mode
  5. Verify at https://ip.gs

{BOLD}ANDROID — v2rayNG (Lightweight){NC}
  1. Download: https://play.google.com/store/apps/details?id=com.v2ray.ang
  2. "+" → Import config from QRcode or clipboard
  3. Tap ▶ (runs as SOCKS proxy only — no TUN mode)
  4. Enable "Per-app proxy" in settings for specific apps

{BOLD}iOS — Hiddify{NC}
  1. App Store: https://apps.apple.com/app/hiddify/id6596777532
  2. Tap "+" → Add from URL or scan QR
  3. Enable VPN toggle

{BOLD}⚠  CAPTIVE PORTAL TIP:{NC}
  On campus WiFi — FIRST authenticate in your browser (sign in to the
  portal), THEN start the proxy. The proxy works only after the firewall
  grants your MAC address internet access.

{BOLD}🔄  SWITCHING PROFILES:{NC}
  • Slow/unstable? → Switch to REALITY (direct, lower latency)
  • REALITY blocked? → Switch to CF-Tunnel (hides VPS IP)
""")


def main():
    parser = argparse.ArgumentParser(
        description="Generate VLESS client configs for Hiddify, v2rayN, v2rayNG"
    )
    parser.add_argument("--creds", default="../server/.credentials",
                        help="Path to .credentials file (default: ../server/.credentials)")
    parser.add_argument("--tunnel-url",  help="Cloudflare Tunnel public hostname (e.g. abc.trycloudflare.com)")
    parser.add_argument("--uuid",        help="Xray client UUID")
    parser.add_argument("--ws-path",     help="WebSocket path (e.g. /abc123)")
    parser.add_argument("--vps-ip",      help="VPS public IP (for REALITY URI)")
    parser.add_argument("--reality-pubkey",  help="REALITY public key")
    parser.add_argument("--reality-shortid", help="REALITY short ID")
    parser.add_argument("--no-qr",       action="store_true", help="Skip QR code output")
    args = parser.parse_args()

    banner("VLESS Client Config Generator")

    # ── Load credentials ──────────────────────────────────────────────────────
    creds_path = Path(args.creds).resolve()
    creds = load_credentials(creds_path)

    if creds:
        info(f"Loaded credentials from: {creds_path}")
    else:
        warn(f"Credentials file not found at: {creds_path}")
        info("Using command-line arguments only.")

    def get(arg_val, cred_key, prompt=None):
        if arg_val:
            return arg_val
        if cred_key in creds and creds[cred_key]:
            return creds[cred_key]
        if prompt:
            return input(f"  Enter {prompt}: ").strip()
        return None

    # ── Gather values ─────────────────────────────────────────────────────────
    uuid       = get(args.uuid,        "XRAY_UUID",       "Xray UUID")
    ws_path    = get(args.ws_path,     "WS_PATH",         "WebSocket path")
    vps_ip     = get(args.vps_ip,      "VPS_IP")
    pubkey     = get(args.reality_pubkey,  "REALITY_PUBLIC_KEY")
    shortid    = get(args.reality_shortid, "REALITY_SHORT_ID")
    tunnel_url = get(args.tunnel_url,  "TUNNEL_HOSTNAME")

    if not tunnel_url:
        tunnel_url = input(
            "\n  Enter your Cloudflare Tunnel public hostname\n"
            "  (from Zero Trust dashboard → Networks → Tunnels → [tunnel] → Public Hostname)\n"
            "  Example: abc-def.trycloudflare.com  or  proxy.yourdomain.com\n"
            "  Tunnel hostname: "
        ).strip()

    if not uuid:
        print("\n  ERROR: UUID not found. Run install.sh first or pass --uuid.")
        sys.exit(1)

    # ── Build URIs ────────────────────────────────────────────────────────────
    uris = []
    banner("Generated Connection URIs")

    # Tunnel URI (always generated)
    tunnel_uri = build_tunnel_uri(uuid, tunnel_url, ws_path or "/")
    uris.append(tunnel_uri)
    print(f"{BOLD}[1] Cloudflare Tunnel — Primary (recommended){NC}")
    print(f"    {tunnel_uri}\n")

    # REALITY URI (optional)
    reality_uri = None
    enable_reality = creds.get("ENABLE_REALITY", "false").lower() == "true"
    if enable_reality and vps_ip and pubkey and shortid:
        reality_uri = build_reality_uri(uuid, vps_ip, pubkey, shortid)
        uris.append(reality_uri)
        print(f"{BOLD}[2] REALITY Direct — Fallback (lower latency){NC}")
        print(f"    {reality_uri}\n")
    elif pubkey and shortid and vps_ip:
        reality_uri = build_reality_uri(uuid, vps_ip, pubkey, shortid)
        uris.append(reality_uri)
        print(f"{BOLD}[2] REALITY Direct — Fallback{NC}")
        print(f"    {reality_uri}\n")

    # ── Save output files ─────────────────────────────────────────────────────
    banner("Saving Output Files")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # All URIs plain text
    uris_file = save_all_uris(uris)
    ok(f"All URIs saved: {uris_file}")

    # Hiddify subscription
    sub_file = save_hiddify_subscription(uris, tunnel_url)
    ok(f"Hiddify subscription: {sub_file}")
    info("  Import in Hiddify: '+' → Add from File → select hiddify-subscription.txt")

    # v2rayN / v2rayNG share file
    share_file = OUTPUT_DIR / "v2ray-share-links.txt"
    share_lines = []
    for uri in uris:
        share_lines.append(f"# Direct import (paste into v2rayN / v2rayNG)")
        share_lines.append(uri)
        share_lines.append(f"# Base64 (v2rayN legacy share format)")
        share_lines.append(build_v2rayn_share(uri))
        share_lines.append("")
    share_file.write_text("\n".join(share_lines))
    ok(f"v2rayN/v2rayNG shares: {share_file}")

    # ── QR codes ──────────────────────────────────────────────────────────────
    if not args.no_qr:
        banner("QR Codes")

        qr_path = generate_qr_png(tunnel_uri, "qr-tunnel.png")
        if qr_path:
            ok(f"Tunnel QR code saved: {qr_path}")
        generate_qr_terminal(tunnel_uri, "CF-Tunnel (scan in Hiddify/v2rayNG)")

        if reality_uri:
            qr_path_r = generate_qr_png(reality_uri, "qr-reality.png")
            if qr_path_r:
                ok(f"REALITY QR code saved: {qr_path_r}")
            generate_qr_terminal(reality_uri, "REALITY Direct")

    # ── Client instructions ───────────────────────────────────────────────────
    print_client_instructions()

    print(f"{BOLD}Output directory:{NC} {OUTPUT_DIR}/")
    print(f"  ├── all-connections.txt        (all URIs)")
    print(f"  ├── hiddify-subscription.txt  (Hiddify import)")
    print(f"  ├── v2ray-share-links.txt      (v2rayN/v2rayNG)")
    print(f"  ├── qr-tunnel.png             (scan with phone)")
    if reality_uri:
        print(f"  └── qr-reality.png           (REALITY fallback QR)")
    print()


if __name__ == "__main__":
    main()
