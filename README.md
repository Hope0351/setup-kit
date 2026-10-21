# setup-kit

One-command environment bootstrap: **QEMU (full x86_64 setup) + VPN/network
tooling**, installable in under 60 seconds — with or without root.

## Quickstart

```bash
bash setup.sh     # installs everything (native apt if root, rootless fallback otherwise)
bash verify.sh    # must print: >> READY <<
```

That's it. Idempotent — re-running skips whatever is already installed.

## What gets installed

| Tool                                   | Purpose                          |
|----------------------------------------|----------------------------------|
| `qemu-system-x86_64` 10.x              | x86_64 VM emulator/virtualizer   |
| `qemu-img`, `qemu-io`, `qemu-nbd`, ... | disk image tooling               |
| `openvpn`, `wg`, `wg-quick`            | VPN client tooling               |
| `curl`, `dig`, `ping`, `jq`            | network diagnostics              |

## How the rootless mode works

On locked-down machines (no sudo), `scripts/portable-install.sh` downloads
the distro's own `.deb` packages with `apt-get download`, extracts them into
`~/.local/qemu-kit/root` with `dpkg -x`, and generates wrapper scripts with a
correct, auto-discovered `LD_LIBRARY_PATH`. No system files are touched.

## VPN connection check

```bash
bash scripts/network-check.sh before-vpn   # baseline
# ... connect your VPN (openvpn/wg-quick) ...
bash scripts/network-check.sh after-vpn    # compare: exit IP, org, DNS, latency, speed
```

## Agent contract

AI agents: read [`AGENT.md`](AGENT.md) before touching anything — it defines
the setup protocol, readiness criteria and environment gotchas.

## Version

See [`VERSION`](VERSION). Changelog discipline: bump, prove with a fresh
clone, then push.
