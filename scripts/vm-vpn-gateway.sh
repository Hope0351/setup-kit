#!/usr/bin/env bash
# =============================================================================
# vm-vpn-gateway.sh — Rootless VPN gateway inside a QEMU VM
#
# Use when the machine has NO /dev/net/tun (locked-down sandboxes, some CI):
# the HOST cannot create a tunnel, but a QEMU guest can (own kernel).
# Host traffic reaches the guest through slirp and comes back via a proxy
# bridged with hostfwd:  host -> 127.0.0.1:<FWD> -> guest tinyproxy -> VPN.
#
# Usage:
#   bash scripts/vm-vpn-gateway.sh up <config> [--auth <userpass-file>]
#                                                # OpenVPN .ovpn OR WireGuard .conf
#   bash scripts/vm-vpn-gateway.sh down          # terminate the VM
#
# Then on the host:   curl -x http://127.0.0.1:11080 <url>
# (or just use: vpn up <config> — vpn.sh picks this gateway automatically)
#
# Lessons encoded here (do NOT remove):
#   * modloop= MUST be passed at boot: stable apk repos receive kernel bumps,
#     so repo linux-virt NEVER matches the netboot kernel version; only the
#     release's own modloop squashfs has the exact modules (tun!).
#   * ONE VPN session per config: connecting twice (e.g. host + guest) makes
#     the server starve the older session's return traffic.
#   * Split-tunnel VPNs (e.g. HackTheBox) route ONLY the lab subnets through
#     the tunnel; exit-IP checks against general internet will NOT change.
# =============================================================================
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALPINE_VER="${ALPINE_VER:-3.23}"
ALPINE_NB="${ALPINE_NB:-3.23.6}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"
NB_BASE="$MIRROR/v$ALPINE_VER/releases/x86_64/netboot-$ALPINE_NB"
ASSET_DIR="${ASSET_DIR:-$HOME/.local/vpn-gateway}"
FWD="${FWD:-11080}"
PY="${PYTHON:-python3}"

OP="${1:-}"
CFG="${2:-}"
AUTH=""
if [ "${3:-}" = "--auth" ]; then AUTH="${4:-}"; fi

die() { echo "[vm-gateway] ERROR: $*" >&2; exit 1; }

# --- python3 available? (serial automation needs it) --------------------------
command -v "$PY" >/dev/null 2>&1 || die "python3 not found (required for serial automation)"
PY="$(command -v "$PY")"

# --- QEMU available? ----------------------------------------------------------
QEMU_BIN="$(command -v qemu-system-x86_64 || echo "$HOME/.local/qemu-kit/bin/qemu-system-x86_64")"
[ -x "$QEMU_BIN" ] || die "qemu-system-x86_64 not found; run setup.sh first"
export QEMU_BIN

if [ "$OP" = "down" ]; then
    "$PY" "$KIT_DIR/scripts/vm_console.py" kill
    exit 0
fi

[ "$OP" = "up" ] || { echo "usage: $0 up <config.ovpn|.conf> [--auth <file>] | down"; exit 1; }
[ -f "$CFG" ] || die "config not found: $CFG"

# --- config type (content-based) ------------------------------------------------
CFG_TYPE=openvpn
if grep -qE '^[[:space:]]*\[Interface\]' "$CFG" 2>/dev/null \
   && grep -qE '^[[:space:]]*PrivateKey[[:space:]]*=' "$CFG" 2>/dev/null; then
    CFG_TYPE=wireguard
fi
echo "[vm-gateway] config type: $CFG_TYPE"

# --- fetch netboot assets (cached) --------------------------------------------
mkdir -p "$ASSET_DIR"
for f in vmlinuz-virt initramfs-virt; do
    if [ ! -s "$ASSET_DIR/$f" ]; then
        echo "[vm-gateway] fetching $f from $NB_BASE ..."
        curl -fsSL --retry 3 -o "$ASSET_DIR/$f" "$NB_BASE/$f"
    fi
done

# --- boot + connect ------------------------------------------------------------
"$PY" "$KIT_DIR/scripts/vm_console.py" boot \
    "$ASSET_DIR/vmlinuz-virt" "$ASSET_DIR/initramfs-virt" \
    "$NB_BASE/modloop-virt" "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VER/main" \
    "$FWD"

"$PY" "$KIT_DIR/scripts/vm_console.py" exec \
    "echo 'http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VER/main' > /etc/apk/repositories" \
    "echo 'http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VER/community' >> /etc/apk/repositories" \
    "apk update" \
    "apk add openvpn wireguard-tools iproute2 tinyproxy curl"

"$PY" "$KIT_DIR/scripts/vm_console.py" push "$CFG" /root/vpn.cfg

if [ "$CFG_TYPE" = "wireguard" ]; then
    "$PY" "$KIT_DIR/scripts/vm_console.py" connect-wg /root/vpn.cfg
else
    if [ -n "$AUTH" ]; then
        [ -f "$AUTH" ] || die "auth file not found: $AUTH"
        "$PY" "$KIT_DIR/scripts/vm_console.py" push "$AUTH" /root/auth.txt
        "$PY" "$KIT_DIR/scripts/vm_console.py" connect-ovpn /root/vpn.cfg /root/auth.txt
    else
        "$PY" "$KIT_DIR/scripts/vm_console.py" connect-ovpn /root/vpn.cfg
    fi
fi
"$PY" "$KIT_DIR/scripts/vm_console.py" proxy 1080

echo
echo "[vm-gateway] VPN GATEWAY LIVE"
echo "[vm-gateway] host usage:  curl -x http://127.0.0.1:$FWD <url>"
echo "[vm-gateway] tunnel ops:  $0 down"
