#!/usr/bin/env bash
# =============================================================================
# tools.sh — OPTIONAL lab toolkit (run AFTER setup.sh; not part of <60s core)
#
# Installs common pentest/lab utilities using the same 3-tier strategy:
#   root / passwordless sudo -> native apt
#   locked-down box          -> rootless portable install (deb extraction)
#
# Usage:  bash scripts/tools.sh
# Env:    TOOLS="nmap socat ..."   override the default set
# =============================================================================
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local/qemu-kit}"
TOOLS="${TOOLS:-nmap netcat-openbsd socat tcpdump file openssh-client}"

log() { printf '\033[1;36m[tools]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

log "installing: $TOOLS"

if [ "$(id -u)" -eq 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq $TOOLS >/dev/null && ok "native apt install done"
elif sudo -n true 2>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    sudo -n apt-get update -qq || true
    sudo -n apt-get install -y -qq $TOOLS >/dev/null && ok "native apt install done"
else
    log "no root -> rootless portable install of extra tools"
    PKGS_EXTRA="$TOOLS" bash "$KIT_DIR/scripts/portable-install.sh" "$PREFIX"
fi

# Make sure the prefix bin is on PATH for this session
[ -d "$PREFIX/bin" ] && case ":$PATH:" in
    *":$PREFIX/bin:"*) ;; *) export PATH="$PREFIX/bin:$PATH" ;;
esac

echo
log "availability check:"
for t in $TOOLS nmap nc socat tcpdump file ssh; do
    command -v "$t" >/dev/null 2>&1 && ok "$t -> $(command -v "$t")"
done
