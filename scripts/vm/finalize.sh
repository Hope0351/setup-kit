#!/usr/bin/env bash
# =============================================================================
# vm/finalize.sh — guest config injection + ext4 image build (host-side, no root)
#
# Encoded lessons (each one was a real boot failure once — keep them):
#   * inittab ttyS0 getty + autologin + PS1 'VPNVM# ' for serial automation
#   * /etc/modules = tun  (tun module loads at boot, /dev/net/tun appears)
#   * fstab: 9p share mount at /mnt/share
#   * root empty password for console autologin
#   * firstboot chown service: files were built by host uid (1001), guest needs
#     them root-owned — one-shot local.d script handles it on first boot
#   * mke2fs -d + -E root_owner=0:0: root dir ownership; files get fixed by firstboot
#   * setuid binaries lack owner-read -> chmod u+r pass BEFORE mke2fs
# =============================================================================
set -e
VM_DIR="${VM_DIR:-$HOME/vm}"
BUILD="$VM_DIR/build"
R="$BUILD/rootfs"

cd "$BUILD"

# --- autologin getty on serial console ---
if ! grep -q "^ttyS0" $R/etc/inittab 2>/dev/null; then
  echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 -n -l /sbin/autologin vt100' >> $R/etc/inittab
fi
cat > $R/sbin/autologin <<'EOF'
#!/bin/sh
exec /bin/login -f root
EOF
chmod +x $R/sbin/autologin

# --- PS1 marker (driver expects 'VPNVM# ') ---
mkdir -p $R/etc/profile.d
echo 'export PS1="VPNVM# "' > $R/etc/profile.d/prompt.sh

# --- hostname / network / tun / fstab ---
echo alpine-vm > $R/etc/hostname
cat > $R/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
echo tun > $R/etc/modules
cat > $R/etc/fstab <<'EOF'
/dev/vda  /       ext4  defaults,errors=remount-ro 0 1
share     /mnt/share 9p  trans=virtio,version=9p2000.L,rw,_netdev 0 0
EOF
mkdir -p $R/mnt/share

# --- root: empty password (console autologin) ---
sed -i 's|^root:[^:]*:|root::|' $R/etc/shadow

# --- OpenRC runlevels ---
mkdir -p $R/etc/runlevels/sysinit $R/etc/runlevels/boot $R/etc/runlevels/default
for svc in devfs dmesg mdev hwdrivers; do
  [ -e $R/etc/init.d/$svc ] && ln -sf /etc/init.d/$svc $R/etc/runlevels/sysinit/$svc
done
for svc in modules sysctl hostname bootmisc syslog networking; do
  [ -e $R/etc/init.d/$svc ] && ln -sf /etc/init.d/$svc $R/etc/runlevels/boot/$svc
done

# --- one-shot firstboot permission fix (files built by host uid) ---
mkdir -p $R/etc/local.d
cat > $R/etc/local.d/firstboot.start <<'EOF'
#!/bin/sh
[ -f /var/lib/.firstboot-done ] && exit 0
chown -R root:root /etc /usr /bin /sbin /lib /var /root /home /opt /mnt /media 2>/dev/null
touch /var/lib/.firstboot-done
exit 0
EOF
chmod +x $R/etc/local.d/firstboot.start
[ -e $R/etc/init.d/local ] && ln -sf /etc/init.d/local $R/etc/runlevels/default/local

# --- locate mke2fs + libs (host-side ext4 builder) ---
MKE2FS=""
LD_EXTRA=""
for c in mke2fs "$HOME/qemu-root/usr/sbin/mke2fs" "$HOME/.local/qemu-kit/sbin/mke2fs"; do
  if [ -n "$(command -v "$c" 2>/dev/null)" ] || [ -x "$c" ]; then MKE2FS="$c"; break; fi
done
[ -n "$MKE2FS" ] || { echo "mke2fs not found (install e2fsprogs or extract e2fsprogs deb)"; exit 1; }
case "$MKE2FS" in
  *qemu-root*|*qemu-kit*)
    for L in "$HOME"/qemu-root/usr/lib/x86_64-linux-gnu "$HOME"/qemu-root/lib/x86_64-linux-gnu; do
      [ -d "$L" ] && LD_EXTRA="$LD_EXTRA:$L"
    done
    LD_EXTRA="${LD_EXTRA#:}" ;;
esac

# --- setuid owner-read fix, then build ext4 image ---
find "$R" -type f -not -perm -u=r -print0 2>/dev/null | xargs -0 -r chmod u+r
rm -f "$VM_DIR/alpine.raw"
env ${LD_EXTRA:+LD_LIBRARY_PATH="$LD_EXTRA"} "$MKE2FS" \
  -q -F -t ext4 -L alpine-root -d "$R" \
  -E root_owner=0:0 \
  "$VM_DIR/alpine.raw" 2G

ls -la "$VM_DIR/alpine.raw"
echo "IMAGE_OK"
