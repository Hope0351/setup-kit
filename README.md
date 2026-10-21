# setup-kit

One-command environment bootstrap: **QEMU (full x86_64 setup) + universal VPN
manager + network tooling**, installable in under 60 seconds — with or without
root.

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
| `vpn`, `net-check`                     | universal VPN manager + diagnostics |
| `curl`, `dig`, `ping`, `jq`            | network diagnostics              |

## The `vpn` command — connect to ANY VPN

Works with HackTheBox, TryHackMe-style, self-made configs, providers — any
OpenVPN `.ovpn` or WireGuard `.conf`, content-detected (extension doesn't
matter), never interactive, never hangs:

```bash
vpn up ~/vpn-config/config.ovpn          # HTB-style (cert-only)
vpn up config.ovpn --auth ~/vpn-config/auth.txt   # THM-style (user/pass, 2 lines)
vpn up ~/vpn-config/my-wg.conf           # WireGuard (direct OR gateway, auto)
vpn up                                   # auto-picks the config in ~/vpn-config
vpn plan <config>                        # dry-run: what was detected, what will happen
vpn status                               # tunnels, IPs, lab routes, gateway VM, proxy
vpn test [target-ip]                     # through-tunnel check (ping + RX counters)
vpn down                                 # full teardown (tunnels + gateway VM)
```

Mode selection is automatic:

- `/dev/net/tun` usable + root or passwordless sudo -> **DIRECT** (tunnel on host)
- otherwise (locked-down sandbox/CI) -> **GATEWAY**: a QEMU Alpine VM owns the
  tunnel; the host reaches it through `127.0.0.1:11080` proxy
  (`curl -x http://127.0.0.1:11080 <url>`). WireGuard, user/pass auth and
  pushed DNS are all handled inside the guest automatically.

Safety rails built in: stale same-config sessions are killed before every
connect (one-session rule), every connect attempt is bounded
(`--server-poll-timeout` + poll loop), and all subcommands are safe to re-run.

## Optional lab toolkit

```bash
bash scripts/tools.sh    # nmap, socat, netcat, tcpdump, file, ssh (same 3-tier install)
```

Deliberately NOT part of `setup.sh` — the core setup contract stays <60s.

## How the rootless mode works

On locked-down machines (no sudo), `scripts/portable-install.sh` downloads
the distro's own `.deb` packages with `apt-get download`, extracts them into
`~/.local/qemu-kit/root` with `dpkg -x`, and generates wrapper scripts with a
correct, auto-discovered `LD_LIBRARY_PATH`. No system files are touched.
`.debs` are cached in `~/.cache/setup-kit/debs`, so a wiped install rebuilds
in seconds without the network.

## Connection check

```bash
net-check before-vpn    # or: bash scripts/network-check.sh before-vpn
# ... vpn up ...
net-check after-vpn     # compare: exit IP, org, DNS, latency, speed
```

## The `htb` command — HackTheBox in one shot

```bash
htb ready <JWT-token>     # -> active machine, VPN pack, workbench VM, >> READY <<
htb active                # what machine is up now (name/IP/expiry)
htb submit 'HTB{...}'     # submit a flag
pentest --batch b1.sh     # run a batch of commands inside the VM (nmap etc.)
```

On locked-down boxes the tunnel lives inside the workbench VM (rootless:
no /dev/net/tun needed anywhere). The guest ships nmap, nmap-scripts,
openssl, curl and socat preinstalled — the first `htb ready` builds the VM
once (~3-6 min), every later session boots in ~25s and connects in ~5s.
Batch outputs land in `~/vm/share/results.txt`; see AGENT.md §8 for the
full protocol and verified API details.

## Agent contract

AI agents: read [`AGENT.md`](AGENT.md) before touching anything — it defines
the setup protocol, readiness criteria, the VPN handover protocol and
environment gotchas.

## Version

See [`VERSION`](VERSION). Changelog discipline: bump, prove with a fresh
clone, then push.
