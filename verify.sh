#!/usr/bin/env bash
# =============================================================================
# verify.sh — prints a READY / NOT-READY report for the environment
# Exit code 0 = ready, 1 = not ready
# =============================================================================
set -uo pipefail

PASS=0; FAIL=0
ok()   { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '  \033[1;36m[info]\033[0m %s\n' "$*"; }

echo "== setup-kit environment verification =="

# --- QEMU ---------------------------------------------------------------------
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    V="$(qemu-system-x86_64 --version 2>/dev/null | head -1)"
    [ -n "$V" ] && ok "qemu-system-x86_64: $V" || fail "qemu-system-x86_64 present but broken"
else
    fail "qemu-system-x86_64 not found on PATH"
fi

if command -v qemu-img >/dev/null 2>&1; then
    ok "qemu-img: $(qemu-img --version 2>/dev/null | head -1)"
else
    fail "qemu-img not found"
fi

# machine types sanity (need at least the default pc machine)
if command -v qemu-system-x86_64 >/dev/null 2>&1 \
   && qemu-system-x86_64 -machine help 2>/dev/null | grep -q 'Standard PC'; then
    ok "x86_64 machine types available"
else
    fail "qemu machine list unavailable"
fi

# accelerators
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    ACC="$(qemu-system-x86_64 -accel help 2>/dev/null | grep -cE '^(tcg|kvm)$')"
    [ "$ACC" -ge 1 ] && ok "accelerators available: $(qemu-system-x86_64 -accel help 2>/dev/null | grep -E '^(tcg|kvm)$' | tr '\n' ' ')" \
                     || fail "no usable accelerator"
fi

# --- VPN / network tools --------------------------------------------------------
for tool in openvpn wg wg-quick curl dig ping; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool available"
    else
        info "$tool missing (non-blocking)"   # wg/wg-quick may legitimately be absent
    fi
done

# --- universal vpn command ------------------------------------------------------
if command -v vpn >/dev/null 2>&1; then
    ok "vpn command available ($(command -v vpn)) — handles any OpenVPN/WireGuard config"
else
    info "vpn command not on PATH (setup.sh wires it into ~/.local/qemu-kit/bin)"
fi

# --- VPN mode preview -----------------------------------------------------------
if [ -w /dev/net/tun ]; then
    ok "/dev/net/tun writable -> vpn will use DIRECT mode"
elif [ -e /dev/net/tun ]; then
    info "/dev/net/tun present but not writable -> vpn uses DIRECT via root/sudo, else GATEWAY"
else
    info "/dev/net/tun absent -> vpn will use GATEWAY mode (QEMU VM owns the tunnel)"
fi

# --- network connectivity ------------------------------------------------------
IP="$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [ -n "$IP" ]; then
    ok "outbound internet OK (public IP: $IP)"
else
    fail "no outbound internet access"
fi

# --- KVM note -------------------------------------------------------------------
if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "KVM acceleration available (/dev/kvm writable)"
else
    info "/dev/kvm not writable -> QEMU will use TCG software emulation (slower but works)"
fi

# --- QEMU BIOS files (boot fails without bios-256k.bin) --------------------------
BIOS_FOUND=0
for d in "$HOME/qemu-root/usr/share/qemu" "$HOME/qemu-root/usr/share/seabios" \
         "$HOME/.local/qemu-kit/root/usr/share/qemu" "$HOME/.local/qemu-kit/root/usr/share/seabios" \
         /usr/share/qemu /usr/share/seabios; do
    if [ -f "$d/bios-256k.bin" ]; then
        ok "SeaBIOS present: $d/bios-256k.bin"
        BIOS_FOUND=1
        break
    fi
done
[ "$BIOS_FOUND" -eq 1 ] || fail "bios-256k.bin not found (install seabios / re-run setup.sh)"

# --- HTB tooling -----------------------------------------------------------------
if command -v htb >/dev/null 2>&1; then
    ok "htb command available (HackTheBox: active/ready/ovpn/submit)"
else
    info "htb command not on PATH (setup.sh wires it into ~/.local/qemu-kit/bin)"
fi
if command -v pentest >/dev/null 2>&1; then
    ok "pentest command available (VM workbench batch driver)"
else
    info "pentest command not on PATH (setup.sh wires it)"
fi
python3 -c 'import pexpect' 2>/dev/null \
    && ok "python3+pexpect available (serial console driver)" \
    || info "pexpect missing (pentest launcher auto-installs on first use)"

# --- workbench VM image -----------------------------------------------------------
VM_DIR="${VM_DIR:-$HOME/vm}"
if [ -f "$VM_DIR/alpine.raw" ] && [ -f "$VM_DIR/initramfs.gz" ]; then
    ok "workbench VM present ($VM_DIR/alpine.raw) — pentest sessions available"
else
    info "workbench VM not built yet — first 'htb ready' will build it (~3-6 min, one-time)"
fi

echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] && { printf '\033[1;32m>> READY <<\033[0m\n'; exit 0; }
printf '\033[1;31m>> NOT READY <<\033[0m\n'
exit 1
