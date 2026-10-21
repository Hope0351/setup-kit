#!/usr/bin/env bash
# =============================================================================
# setup.sh — ONE-COMMAND environment bootstrap
#
# Installs QEMU (system emulator + utils) and VPN/network tooling.
# Works everywhere:
#   * root / sudo available  -> native apt install (fastest)
#   * locked-down box        -> rootless portable install (deb extraction)
#
# Idempotent: re-running skips what is already installed.
# Typical time: ~20-40s cold, ~2s warm.
#
# Usage:  bash setup.sh
# =============================================================================
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_PREFIX="$HOME/.local/qemu-kit"

c() { printf '\033[1;35m[setup-kit]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
SECONDS=0

c "Starting environment setup..."

# -----------------------------------------------------------------------------
# 1. Ensure the tooling is installed
# -----------------------------------------------------------------------------
NEED_INSTALL=1

# Already functional via current PATH?
if command -v qemu-system-x86_64 >/dev/null 2>&1 \
   && qemu-system-x86_64 --version >/dev/null 2>&1; then
    ok "QEMU already on PATH: $(qemu-system-x86_64 --version | head -1)"
    NEED_INSTALL=0
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        # --- native path: real root ------------------------------------------
        c "Running as root -> native apt install"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq qemu-system-x86 qemu-utils openvpn \
            wireguard-tools curl wget dnsutils net-tools jq git \
            iputils-ping seabios e2fsprogs >/dev/null
        ok "Native apt install complete"
    elif sudo -n true 2>/dev/null; then
        # --- native path: passwordless sudo ----------------------------------
        c "Passwordless sudo available -> native apt install"
        export DEBIAN_FRONTEND=noninteractive
        sudo -n apt-get update -qq || true
        sudo -n apt-get install -y -qq qemu-system-x86 qemu-utils openvpn \
            wireguard-tools curl wget dnsutils net-tools jq git \
            iputils-ping seabios e2fsprogs >/dev/null
        ok "Native apt install complete"
    else
        # --- rootless portable path ------------------------------------------
        c "No root -> using rootless portable install (deb extraction)"
        bash "$KIT_DIR/scripts/portable-install.sh" "$QEMU_PREFIX"
    fi
fi

# -----------------------------------------------------------------------------
# 2. Wire the portable binaries into PATH (persistently)
# -----------------------------------------------------------------------------
mkdir -p "$QEMU_PREFIX/bin"   # exists even on native installs (vpn/net-check live here)
case ":$PATH:" in
    *":$QEMU_PREFIX/bin:"*) ;;
    *) export PATH="$QEMU_PREFIX/bin:$PATH" ;;
esac
# Persist for future shells (once)
if ! grep -q 'qemu-kit/bin' "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ''
        echo '# added by setup-kit (QEMU + VPN tools)'
        echo 'export PATH="$HOME/.local/qemu-kit/bin:$PATH"'
    } >> "$HOME/.bashrc"
    ok "PATH wiring added to ~/.bashrc"
fi

# -----------------------------------------------------------------------------
# 2b. Install universal command launchers (vpn, net-check) ---------------------
#     'vpn' handles ANY OpenVPN/WireGuard config: direct mode when /dev/net/tun
#     is usable, QEMU-VM gateway mode on locked-down boxes. Never interactive.
# -----------------------------------------------------------------------------
BIN_DIR="$QEMU_PREFIX/bin"
mkdir -p "$BIN_DIR"
install_launcher() {
    local name="$1" target="$2"
    cat > "$BIN_DIR/$name" <<EOF
#!/usr/bin/env bash
KIT="$KIT_DIR"
if [ ! -f "\$KIT/$target" ]; then
    echo "$name: kit not found at \$KIT - re-run setup.sh from a fresh clone" >&2
    exit 1
fi
exec bash "\$KIT/$target" "\$@"
EOF
    chmod +x "$BIN_DIR/$name"
}
install_launcher vpn       scripts/vpn.sh
install_launcher net-check scripts/network-check.sh
install_launcher htb       scripts/htb.sh

# pentest launcher (needs python3 + pexpect; pexpect auto-installed on first use)
cat > "$BIN_DIR/pentest" <<EOF
#!/usr/bin/env bash
KIT="$KIT_DIR"
python3 -c 'import pexpect' 2>/dev/null || pip3 install --quiet --user pexpect || \
    { echo 'pentest: pexpect missing and pip install failed'; exit 1; }
exec python3 "\$KIT/scripts/pentest.py" "\$@"
EOF
chmod +x "$BIN_DIR/pentest"
ok "commands installed: vpn (any VPN), htb (HackTheBox), pentest (VM workbench), net-check"

# -----------------------------------------------------------------------------
# 3. Verify
# -----------------------------------------------------------------------------
c "Running verification..."
bash "$KIT_DIR/verify.sh"
STATUS=$?

echo
if [ "$STATUS" -eq 0 ]; then
    ok "ENVIRONMENT READY in ${SECONDS}s"
    echo    '        VPN:   vpn up ~/vpn-config/<config.ovpn|.conf>   (any VPN, auto mode)'
    echo    '        Check: net-check before-vpn / after-vpn | vpn status | vpn test'
else
    echo    '\033[1;31m[fail]\033[0m Environment NOT ready (see errors above)'
    exit 1
fi
