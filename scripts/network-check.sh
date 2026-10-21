#!/usr/bin/env bash
# =============================================================================
# network-check.sh — connection / VPN diagnostics
#
# Run BEFORE and AFTER connecting a VPN to compare:
#     bash scripts/network-check.sh            (label auto: "check")
#     bash scripts/network-check.sh before-vpn
#     bash scripts/network-check.sh after-vpn
# =============================================================================
set -uo pipefail

LABEL="${1:-check}"
LINE="------------------------------------------------------------"

hdr()  { echo; echo "$LINE"; echo "[$LABEL] $*"; echo "$LINE"; }

# --- 1. VPN interface detection ------------------------------------------------
hdr "TUNNEL INTERFACES"
TUN="$(ip -o link show 2>/dev/null | grep -Ei 'tun[0-9]|tap[0-9]|wg[0-9]|ppp[0-9]' || true)"
if [ -n "$TUN" ]; then
    echo "$TUN"
    echo ">> VPN tunnel interface: PRESENT"
else
    echo "(no tun/tap/wg/ppp interfaces found)"
    echo ">> VPN tunnel interface: ABSENT"
fi

# --- 2. Public IP + network operator -------------------------------------------
hdr "PUBLIC IP / EXIT NODE"
JSON="$(curl -s --max-time 10 https://ipinfo.io/json 2>/dev/null || true)"
if [ -n "$JSON" ]; then
    echo "$JSON" | jq -r \
        '"  IP:       \(.ip // "?)"\n  City:     \(.city // "?")\n  Region:   \(.region // "?")\n  Country:  \(.country // "?")\n  Org:      \(.org // "?")"' 2>/dev/null \
        || echo "$JSON"
    ORG="$(echo "$JSON" | jq -r '.org // empty' 2>/dev/null || true)"
    if echo "$ORG" | grep -qiE 'vpn|nord|express|mullvad|proton|surfshark|tunnel|hosting|data ?center|cloud'; then
        echo ">> Exit node looks like a VPN/hosting provider: $ORG"
    else
        echo ">> Exit node org does not obviously look like a consumer VPN (verify yourself)"
    fi
else
    echo "  could not reach ipinfo.io"
fi

# --- 3. DNS ---------------------------------------------------------------------
hdr "DNS RESOLUTION"
if command -v dig >/dev/null 2>&1; then
    echo "  resolvers: $(grep -hs '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
    if dig +short +time=3 +tries=1 example.com >/dev/null 2>&1; then
        echo "  DNS lookup: OK (example.com -> $(dig +short +time=3 +tries=1 example.com | head -1))"
    else
        echo "  DNS lookup: FAILED"
    fi
else
    getent hosts example.com >/dev/null 2>&1 && echo "  DNS lookup: OK" || echo "  DNS lookup: FAILED"
fi

# --- 4. Latency ------------------------------------------------------------------
hdr "LATENCY"
for host in 1.1.1.1 8.8.8.8; do
    if command -v ping >/dev/null 2>&1; then
        OUT="$(ping -c 3 -W 2 "$host" 2>/dev/null | tail -1 || true)"
        if echo "$OUT" | grep -q 'rtt\|round-trip'; then
            echo "  $host: $(echo "$OUT" | sed 's/.*= //')"
        else
            echo "  $host: unreachable (ICMP may be blocked - not fatal)"
        fi
    fi
done

# --- 5. Throughput (rough) --------------------------------------------------------
hdr "THROUGHPUT (25 MB pull from Cloudflare)"
BYTES="$(curl -s -o /dev/null -w '%{speed_download}' --max-time 20 \
    'https://speed.cloudflare.com/__down?bytes=25000000' 2>/dev/null || echo 0)"
if [ "${BYTES%.*}" -gt 0 ] 2>/dev/null; then
    MBPS="$(awk -v b="$BYTES" 'BEGIN{printf "%.1f", b*8/1000000}')"
    echo "  download: ~${MBPS} Mbit/s"
else
    echo "  speed test endpoint unreachable"
fi

echo
echo "[$LABEL] done."
