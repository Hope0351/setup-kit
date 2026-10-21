#!/usr/bin/env python3
"""
vm_console.py — QEMU Alpine VM serial-console driver (rootless VPN gateway).

General-purpose automation over the QEMU serial unix socket. Used by
vm-vpn-gateway.sh but usable standalone.

Subcommands:
  boot <kernel> <initrd> <modloop-url> <repo-url> [hostfwd-port]
      Launch QEMU (TCG, 1GB RAM, slirp + hostfwd TCP <port>->guest:1080),
      wait for login, log in as root. Leaves the VM running.
  exec '<shell command>' ['<more>' ...]
      Run commands in the guest, print output + rc.
  push <local-file> <remote-path>
      Transfer a file into the guest (base64 over serial, md5-verified).
  connect-ovpn <remote-config-path>
      modprobe tun, mknod /dev/net/tun, start openvpn, wait for tun0 IP.
  proxy <port>
      Write tinyproxy config, start tinyproxy on 0.0.0.0:<port>.
  kill
      Terminate the VM.

Environment:
  VM_SOCK (default /tmp/vm-serial.sock), VM_LOG (/tmp/vm-console.log)
"""
import base64
import hashlib
import os
import socket
import subprocess
import sys
import time

SOCK = os.environ.get("VM_SOCK", "/tmp/vm-serial.sock")
LOG = os.environ.get("VM_LOG", "/tmp/vm-console.log")
QEMU = os.environ.get("QEMU_BIN",
                      os.path.expanduser("~/.local/qemu-kit/bin/qemu-system-x86_64"))
MARK = [0]


def log(msg):
    print(f"[vm] {msg}", flush=True)


class Serial:
    def __init__(self, path, wait=90):
        end = time.time() + wait
        last = None
        while time.time() < end:
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(path)
                break
            except OSError as e:
                last = e
                time.sleep(0.5)
        else:
            raise RuntimeError(f"cannot connect {path}: {last}")
        self.s.settimeout(0.4)
        self.buf = b""

    def _drain(self):
        try:
            d = self.s.recv(65536)
            if d:
                self.buf += d
                with open(LOG, "ab") as f:
                    f.write(d)
        except socket.timeout:
            pass

    def wait_for(self, pat, timeout=180):
        end = time.time() + timeout
        while time.time() < end:
            self._drain()
            if pat.encode() in self.buf:
                out, self.buf = self.buf, b""
                return out.decode(errors="replace")
            time.sleep(0.05)
        raise TimeoutError(f"'{pat}' not seen in {timeout}s")

    def send(self, line, delay=0.05):
        self.s.sendall((line + "\n").encode())
        time.sleep(delay)

    def run(self, cmd, timeout=120):
        MARK[0] += 1
        uniq = f"MK{MARK[0]}X{int(time.time()*1000)%10000}"
        a, b = uniq[:5], uniq[5:]
        self.buf = b""
        self.send(cmd)
        self.send(f'echo "{a}""{b}=$?"')
        out = self.wait_for(uniq + "=", timeout)
        rc = "?"
        for ln in out.splitlines():
            if uniq + "=" in ln:
                rc = ln.split("=")[-1].strip() or "?"
        return out, rc

    def push(self, local_path, remote_path):
        raw = open(local_path, "rb").read()
        b64 = base64.b64encode(raw).decode()
        md5 = hashlib.md5(raw).hexdigest()
        self.send(f"rm -f {remote_path}.b64 {remote_path}")
        for i in range(0, len(b64), 96):
            self.send(f"echo '{b64[i:i+96]}' >> {remote_path}.b64", delay=0.06)
        out, _ = self.run(f"base64 -d {remote_path}.b64 > {remote_path} && "
                          f"md5sum {remote_path}", timeout=90)
        if md5 not in out:
            raise RuntimeError(f"transfer md5 mismatch, expected {md5}")
        log(f"pushed {local_path} -> {remote_path} (md5 {md5})")


def boot(kernel, initrd, modloop, repo, fwdport):
    subprocess.run(["pkill", "-f", f"hostfwd=tcp:127.0.0.1:{fwdport}"],
                   capture_output=True)
    time.sleep(1)
    if os.path.exists(LOG):
        os.unlink(LOG)
    cmd = [
        QEMU, "-accel", "tcg,thread=multi", "-machine", "pc", "-cpu", "qemu64",
        "-m", "1024", "-smp", "2",
        "-kernel", kernel, "-initrd", initrd,
        "-append", (f"console=ttyS0,115200 ip=dhcp alpine_repo={repo} "
                    f"modloop={modloop}"),
        "-display", "none", "-monitor", "none",
        "-serial", f"unix:{SOCK},server,nowait",
        "-nic", f"user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:{fwdport}-:1080",
    ]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                     stderr=open("/tmp/qemu-stderr.log", "w"),
                     start_new_session=True)
    log(f"QEMU launched (kernel={kernel})")
    ser = Serial(SOCK, wait=120)
    ser.wait_for("login:", timeout=420)
    ser.send("root")
    ser.wait_for("#", timeout=60)
    log("logged in as root")
    out, rc = ser.run("ip -4 addr show eth0 | grep -q inet || "
                      "(ip link set eth0 up && udhcpc -i eth0 -t 10 -n)",
                      timeout=90)
    if rc != "0":
        log(f"WARNING: network bring-up rc={rc}")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    op = args[0]

    if op == "boot":
        boot(args[1], args[2], args[3], args[4],
             args[5] if len(args) > 5 else "11080")
    elif op == "exec":
        ser = Serial(SOCK)
        ser.send("")
        time.sleep(0.5)
        for c in args[1:]:
            out, rc = ser.run(c, timeout=600)
            print(f"$ {c}\n{out}\n[rc={rc}]", flush=True)
    elif op == "push":
        ser = Serial(SOCK)
        ser.push(args[1], args[2])
    elif op == "connect-ovpn":
        ser = Serial(SOCK)
        ser.run("modprobe tun", timeout=120)
        ser.run("mkdir -p /dev/net && "
                "[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200", timeout=30)
        log("starting openvpn in guest...")
        ser.run(f"openvpn --config {args[1]} --daemon "
                f"--log /root/ovpn.log", timeout=60)
        got = None
        for i in range(20):
            time.sleep(3)
            out, _ = ser.run(
                'T="$(ip -4 addr show tun0 2>/dev/null | grep -w inet | '
                'head -1)"; echo "TUN""RES=$T"', timeout=30)
            for ln in out.splitlines():
                if ln.startswith("TUNRES=") and "inet" in ln:
                    got = ln.split("=", 1)[1].strip()
            if got:
                break
        if not got:
            out, _ = ser.run("tail -15 /root/ovpn.log", timeout=30)
            print(out)
            sys.exit(4)
        log(f"TUNNEL UP: {got}")
    elif op == "proxy":
        ser = Serial(SOCK)
        conf = base64.b64encode(
            f"Port {args[1]}\nListen 0.0.0.0\nTimeout 600\nLogLevel Info\n"
            f"MaxClients 60\nAllow 0.0.0.0/0\n".encode()).decode()
        ser.run(f"echo '{conf}' | base64 -d > /etc/tinyproxy.conf", timeout=30)
        ser.run("tinyproxy -c /etc/tinyproxy.conf", timeout=30)
        out, _ = ser.run(f"netstat -tln | grep {args[1]}", timeout=30)
        if str(args[1]) not in out:
            sys.exit(5)
        log(f"tinyproxy listening (guest:{args[1]})")
    elif op == "kill":
        subprocess.run(["pkill", "-f", "qemu-system-x86_64"], capture_output=True)
        log("VM terminated")
    else:
        print(f"unknown op {op}")
        sys.exit(1)


if __name__ == "__main__":
    main()
