#!/usr/bin/env python3
"""Build minimal initramfs for the Alpine workbench VM.

Contents: busybox, /init (mounts, modprobe storage/net closure, switch_root),
virtio+ext4 module closure from the rootfs modules.dep.
Output: $VM_DIR/initramfs.gz (newc cpio, root-owned entries)

Lessons encoded (do not simplify — each fixes a real boot failure):
  * /sysroot MUST exist in the cpio or mount fails with ENOENT
  * rootfstype=ext4 kernel arg needed: typeless mount cannot auto-load ext4
  * busybox modprobe lacks zlib -> modules decompressed, modules.dep rewritten
  * cpio must be repacked with --uid 0 (root-owned entries)
  * modules.alias subset shipped for kernel request_module resolution
"""
import os, re, subprocess, gzip, sys, glob

VM_DIR = os.environ.get("VM_DIR", os.path.expanduser("~/vm"))
ROOTFS = f"{VM_DIR}/build/rootfs"
KVER = os.environ.get("KVER") or (glob.glob(f"{ROOTFS}/lib/modules/*-virt") + [None])[0] and \
       os.path.basename(glob.glob(f"{ROOTFS}/lib/modules/*-virt")[0])
MODDIR = f"{ROOTFS}/lib/modules/{KVER}"
OUT = f"{VM_DIR}/initramfs.gz"
STAGE = f"{VM_DIR}/build/initramfs-stage"

WANT = ["virtio_pci", "virtio_blk", "ext4", "crc32c_generic", "crc32c-intel",
        "virtio_net", "net_failover", "failover"]

dep_map = {}
for line in open(f"{MODDIR}/modules.dep"):
    line = line.strip()
    if not line:
        continue
    mod, _, deps = line.partition(":")
    dep_map[mod] = [d for d in deps.split() if d]

def resolve(name):
    matches = [m for m in dep_map if m.endswith(f"/{name}.ko") or m.endswith(f"/{name}.ko.gz")]
    if not matches:
        print(f"WARN: module {name} not found"); return []
    out, stack = set(), list(dep_map[matches[0]])
    out.add(matches[0])
    while stack:
        d = stack.pop()
        if d in out: continue
        out.add(d)
        stack.extend(dep_map.get(d, []))
    return sorted(out)

paths = set()
for w in WANT:
    paths.update(resolve(w))
print("modules in closure:", len(paths))

subprocess.run(["rm", "-rf", STAGE], check=True)
for d in ("bin", f"lib/modules/{KVER}", "proc", "sys", "dev", "tmp", "sysroot"):
    os.makedirs(f"{STAGE}/{d}", exist_ok=True)

bb = f"{ROOTFS}/bin/busybox"
assert os.path.exists(bb), "busybox missing in rootfs"
subprocess.run(["cp", bb, f"{STAGE}/bin/busybox"], check=True)
os.chmod(f"{STAGE}/bin/busybox", 0o755)

ldso = f"{ROOTFS}/lib/ld-musl-x86_64.so.1"
if os.path.exists(ldso):
    subprocess.run(["cp", ldso, f"{STAGE}/lib/ld-musl-x86_64.so.1"], check=True)
    os.chmod(f"{STAGE}/lib/ld-musl-x86_64.so.1", 0o755)

for p in paths:
    src, dst = f"{MODDIR}/{p}", f"{STAGE}/lib/modules/{KVER}/{p}"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if p.endswith(".gz"):
        raw = gzip.open(src, "rb").read()
        with open(dst[:-3], "wb") as f:
            f.write(raw)
        os.chmod(dst[:-3], 0o644)
    else:
        subprocess.run(["cp", src, dst], check=True)

def strip_gz(path): return path[:-3] if path.endswith(".gz") else path

with open(f"{STAGE}/lib/modules/{KVER}/modules.dep", "w") as f:
    for p in paths:
        deps = [strip_gz(d) for d in dep_map.get(p, [])]
        f.write(strip_gz(p) + (": " + " ".join(deps) if deps else ":") + "\n")

names = {os.path.basename(strip_gz(p)).replace('-', '_') for p in paths}
alias_lines = []
for line in open(f"{MODDIR}/modules.alias"):
    line = line.strip()
    if not line.startswith("alias "):
        continue
    _, alias, mod = line.split(None, 2)
    if mod.replace('-', '_') in names:
        alias_lines.append(f"alias {alias} {strip_gz(mod)}")
with open(f"{STAGE}/lib/modules/{KVER}/modules.alias", "w") as f:
    f.write("\n".join(alias_lines) + "\n")
print("alias lines:", len(alias_lines))

INIT = """#!/bin/busybox sh
/bin/busybox --install -s /bin 2>/dev/null
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mkdir -p /proc /sys /dev /tmp /sysroot /sbin /usr/sbin /usr/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
echo "[initramfs] loading modules"
for m in virtio_pci virtio_blk crc32c_generic crc32c-intel virtio_net ext4; do
  modprobe $m 2>/dev/null
done
n=0
while [ ! -b /dev/vda ] && [ $n -lt 40 ]; do
  sleep 0.25; n=$((n+1)); mdev -s 2>/dev/null
done
echo "[initramfs] /dev/vda present after $n tries; mounting root"
mount -t ext4 -o rw /dev/vda /sysroot || rescue=1
if [ "$rescue" = "1" ]; then
  echo "ROOT MOUNT FAILED - dropping to shell"
  exec /bin/sh
fi
echo "[initramfs] switch_root"
exec switch_root /sysroot /sbin/init
"""
with open(f"{STAGE}/init", "w") as f:
    f.write(INIT)
os.chmod(f"{STAGE}/init", 0o755)

# cpio newc (root-owned) via bsdtar (fallback: python cpio writer)
os.chdir(STAGE)
bsdtar = None
for c in ("bsdtar", os.path.expanduser("~/qemu-root/usr/bin/bsdtar")):
    if subprocess.run(["sh", "-c", f"command -v {c} >/dev/null 2>&1"], capture_output=True).returncode == 0 \
       or os.path.exists(c):
        bsdtar = c; break
if bsdtar:
    subprocess.run([bsdtar, "--format", "newc", "--uid", "0", "--gid", "0",
                    "-cf", "/tmp/initramfs.cpio", "."], check=True)
    with open(OUT, "wb") as fo, open("/tmp/initramfs.cpio", "rb") as fi:
        with gzip.GzipFile(fileobj=fo, mode="wb", mtime=0) as gz:
            while True:
                chunk = fi.read(1 << 20)
                if not chunk: break
                gz.write(chunk)
    os.remove("/tmp/initramfs.cpio")
else:
    sys.exit("bsdtar not found (needed for root-owned cpio)")
print("OK ->", OUT, os.path.getsize(OUT), "bytes")
