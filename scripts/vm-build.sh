#!/usr/bin/env bash
# =============================================================================
# vm-build.sh — ONE-COMMAND workbench VM builder (no root needed anywhere)
#
#   bash scripts/vm-build.sh          # build $VM_DIR/alpine.raw + initramfs.gz
#   VM_DIR=~/vm bash scripts/vm-build.sh
#
# Pipeline: rootfs (host-side apk) -> initramfs (module closure) -> ext4 image.
# Result: boots in ~25s via direct kernel boot; guest = Alpine with
# openvpn + wireguard + nmap + nmap-scripts + openssl + curl + socat,
# root autologin on serial console, tun available, 9p share at /mnt/share.
#
# Idempotent: re-running rebuilds the image from the cached rootfs in ~1 min.
# =============================================================================
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="${VM_DIR:-$HOME/vm}"
export VM_DIR
mkdir -p "$VM_DIR/share" "$VM_DIR/logs"

T0=$(date +%s)
echo "[vm-build] 1/3 rootfs (apk install host-side)..."
bash "$KIT_DIR/scripts/vm/rootfs.sh" | tail -3

echo "[vm-build] 2/3 initramfs (module closure)..."
python3 "$KIT_DIR/scripts/vm/initramfs.py" | tail -2

echo "[vm-build] 3/3 ext4 image..."
bash "$KIT_DIR/scripts/vm/finalize.sh" | tail -3

DT=$(( $(date +%s) - T0 ))
echo "[vm-build] >> VM_READY << in ${DT}s"
echo "[vm-build] next: python3 $KIT_DIR/scripts/pentest.py --batch <file>"
