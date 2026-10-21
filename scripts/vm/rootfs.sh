#!/usr/bin/env bash
# =============================================================================
# vm/rootfs.sh — build Alpine rootfs entirely on the host (userns chroot, no root)
#
# Proven pipeline (do not simplify — each step fixes a real failure):
#   * apk signing keys pulled from alpine-keys package (static apk TLS breaks
#     signature verification on some sandbox networks -> --allow-untrusted)
#   * userns chroot (unshare -Ur) so apk scripts can run host-side
#   * package set includes nmap/curl/socat so the workbench is pentest-ready
#     the moment it boots (no per-session apk add)
# =============================================================================
set -e
VM_DIR="${VM_DIR:-$HOME/vm}"
BUILD="$VM_DIR/build"
LIBEXEC="${APK_STATIC_DIR:-$HOME/.local/libexec/apk-tools}"
ALPINE_VER="${ALPINE_VER:-3.22}"
BASE="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VER"

# locate or fetch apk.static (host-side package installer)
APK_STATIC="$LIBEXEC/apk.static"
if [ ! -x "$APK_STATIC" ]; then
    echo "[vm/rootfs] fetching apk-tools-static..."
    mkdir -p "$LIBEXEC"
    AURL=$(curl -sL "$BASE/main/x86_64/" | grep -oE 'apk-tools-static-[0-9][^"]*\.apk' | sort -u | tail -1)
    [ -n "$AURL" ] || { echo "cannot find apk-tools-static"; exit 1; }
    curl -sL -o "$LIBEXEC/apk-tools.apk" "$BASE/main/x86_64/$AURL"
    tar -xzf "$LIBEXEC/apk-tools.apk" -C "$LIBEXEC" sbin/apk.static 2>/dev/null \
        || tar -xzf "$LIBEXEC/apk-tools.apk" -C "$LIBEXEC" 2>/dev/null
    APK="$(find "$LIBEXEC" -name apk.static -type f | head -1)"
    [ -n "$APK" ] && mv "$APK" "$APK_STATIC" && chmod +x "$APK_STATIC"
fi
[ -x "$APK_STATIC" ] || { echo "apk.static unavailable"; exit 1; }

mkdir -p "$BUILD/rootfs" "$BUILD/keys"
cd "$BUILD"

# --- 1. apk signing keys (from alpine-keys package) ---
if [ ! -f keys/alpine-keys.apk ]; then
  KURL=$(curl -sL "$BASE/main/x86_64/" | grep -oE 'alpine-keys-[0-9][^"]*\.apk' | sort -u | tail -1)
  curl -sL -o keys/alpine-keys.apk "$BASE/main/x86_64/$KURL"
fi
rm -rf keys/extract && mkdir -p keys/extract
tar -xzf keys/alpine-keys.apk -C keys/extract 2>/dev/null || true
mkdir -p rootfs/etc/apk/keys
cp keys/extract/etc/apk/keys/*.pub rootfs/etc/apk/keys/ 2>/dev/null \
  || cp keys/extract/usr/share/apk/keys/*/* rootfs/etc/apk/keys/

# --- 2. repositories ---
cat > rootfs/etc/apk/repositories <<EOF
$BASE/main
$BASE/community
EOF

# --- 3. install base system + pentest/VPN tools inside userns ---
unshare -Ur bash -exc "
  cd '$BUILD'
  '$APK_STATIC' \
    --root rootfs --initdb --arch x86_64 --allow-untrusted \
    --keys-dir rootfs/etc/apk/keys \
    --repositories-file rootfs/etc/apk/repositories \
    add alpine-base openvpn wireguard-tools iproute2 ifupdown-ng linux-virt nmap nmap-scripts openssl curl bash socat 2>&1 | tail -4
  ls rootfs/bin/sh rootfs/bin/busybox rootfs/sbin/openrc 2>/dev/null
"

echo "=== rootfs size: $(du -sh rootfs | cut -f1)"
echo "=== key binaries:"
ls rootfs/usr/sbin/openvpn rootfs/usr/bin/wg rootfs/sbin/nmap \
   rootfs/usr/bin/nmap rootfs/lib/modules/ 2>/dev/null
echo "ROOTFS_OK"
