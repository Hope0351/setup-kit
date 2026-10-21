# AGENT.md — READ THIS FIRST (AI agent context)

You are an AI agent that has just been given this repository link plus the word
**"setup"**. This file is your complete context. Follow it exactly. Do not
re-derive anything: the kit is already engineered, tested and versioned.

---

## 1. Mission (persistent across sessions)

The user's workflow is:

1. **Setup** — bootstrap a full working environment from this repo (QEMU +
   VPN/network tooling). Target: under 60 seconds.
2. **VPN handover** — the user hands over a VPN configuration (OpenVPN
   `.ovpn`, WireGuard `.conf`, or credentials/proxy).
3. **Connection check** — you verify the connection through that VPN and
   report: exit IP/location, provider org, tunnel status, DNS, latency,
   throughput.

## 2. "Setup" protocol — execute in this exact order

```bash
git clone <REPO-URL> setup-kit && cd setup-kit   # fresh copy, no stale state
bash setup.sh                                     # installs everything (idempotent)
bash verify.sh                                    # must end with ">> READY <<"
```

Rules:

- If `verify.sh` exits 0 and prints `>> READY <<`, reply to the user that you
  are ready and ask for the VPN config. **Nothing else is required.**
- If setup fails, read the failing line, fix locally, re-run. Do NOT rewrite
  the kit on a whim — the scripts are battle-tested; failures are usually
  environmental (no network, restricted egress).
- If the machine is locked down (no root/sudo), `setup.sh` automatically falls
  back to the rootless portable installer — that is expected and correct.

## 3. What "ready" means

`verify.sh` confirms all of the following before printing `>> READY <<`:

| Component            | Requirement                                            |
|----------------------|--------------------------------------------------------|
| qemu-system-x86_64   | runs and prints a version                              |
| qemu-img             | runs (disk image create/convert/inspect)               |
| machine types        | at least the standard PC machine present               |
| accelerators         | TCG (always) and/or KVM (when /dev/kvm is writable)    |
| VPN tools            | openvpn / wg present (or noted as non-blocking absent) |
| outbound internet    | public IP retrievable                                  |

## 4. VPN handover protocol — the `vpn` command handles EVERYTHING

The kit ships a universal VPN manager. It auto-detects the config type by
content (OpenVPN vs WireGuard — extension irrelevant), resolves credentials,
picks the connection mode for the machine, and never runs interactively.

```bash
mkdir -p ~/vpn-config          # user hands over config -> save it here
                               # NEVER commit VPN configs/creds to this repo!

vpn plan ~/vpn-config/<file>   # optional dry-run: shows type/auth/mode
vpn up ~/vpn-config/<file>     # connect — that's it
vpn up <file> --auth ~/vpn-config/auth.txt   # when the config needs user/pass
vpn status                     # tunnels, IPs, lab routes, gateway VM, proxy
vpn test                       # through-tunnel check (ping + RX counters)
vpn down                       # full teardown (host tunnels + gateway VM)
```

Auth file format (THM-style `auth-user-pass` configs): line 1 = username,
line 2 = password:

```bash
printf '%s\n%s\n' 'myuser' 'mypass' > ~/vpn-config/auth.txt
vpn up ~/vpn-config/config.ovpn --auth ~/vpn-config/auth.txt
```

### How vpn.sh picks the mode (trust it — do not override by hand)

1. `/dev/net/tun` writable AND (root OR passwordless sudo) -> **DIRECT**:
   tunnel is created on the host (`openvpn --daemon` or `wg-quick up`).
2. Anything else (sandbox, CI, no tun) -> **GATEWAY**: boots a QEMU Alpine
   VM that owns the tunnel and exposes a proxy on `127.0.0.1:11080`:
   `curl -x http://127.0.0.1:11080 <url>`. Inside the guest it handles
   WireGuard (wg-quick, DNS stripped + set manually), auth-user-pass, and
   pushed `dhcp-option DNS` automatically.

First gateway boot downloads netboot assets (~2-4 min); cached boots are
~1 min. All connects are bounded by timeouts — if it fails it FAILS FAST
with the log tail, it does not hang.

### Baseline + reporting

```bash
net-check before-vpn     # baseline (or: bash scripts/network-check.sh before-vpn)
vpn up ~/vpn-config/<file> [ --auth file ]
net-check after-vpn
vpn test                 # prove lab reachability
```

Report: tunnel present? exit IP/country/org, DNS, latency, throughput.

### VPN debugging truths (learned by packet forensics — trust these)

- **ONE session per config.** Two simultaneous openvpn sessions with the same
  cert (e.g. host + guest) make the server starve the older session's return
  traffic: handshakes keep succeeding while ZERO data returns. If a session
  seems dead-but-healthy, kill every other session using the same config and
  reconnect once.
- **Split-tunnel VPNs** (HackTheBox free servers included) push routes for
  lab subnets only (10.10.0.0/16, 10.129.0.0/16, ...). Exit-IP services on
  the general internet will NOT show the VPN exit — test against lab
  addresses instead.
- Symptom `Cannot open TUN/TAP dev /dev/net/tun: No such file or directory`
  = missing device node (fix: `mkdir -p /dev/net && mknod /dev/net/tun c 10 200`).
  `... No such device (errno=19)` = tun kernel module not loaded (needs
  matching modules — see the modloop lesson below).
- Diagnose tunnel data paths with counters, not guesses:
  `grep tun0 /proc/net/dev` (RX>0 = something returns) and tcpdump both
  interfaces with direction counts (`grep -c 'server.ip >'` vs `' > server.ip'`).

## 5. Environment notes (learned the hard way — trust these)

- Debian 13 "trixie" sandbox, user `z`, NO passwordless sudo. The rootless
  portable installer is the path that works there.
- `dpkg --print-architecture` returns `amd64`, but Debian's multiarch lib dir
  is `x86_64-linux-gnu`. Never hand-construct the lib path — the portable
  installer auto-discovers every dir containing `*.so*`. Do not "simplify"
  this back to a hardcoded triplet.
- Wrappers in `~/.local/qemu-kit/bin/` embed their own `LD_LIBRARY_PATH` and
  (for qemu-system-*) the `-L` BIOS/rom data dirs; run the wrappers, not the
  raw binaries under `root/usr/bin/`.
- `apt-get download` + `dpkg -x` works without root; `/dev/kvm` is usually
  absent in sandboxes -> QEMU falls back to TCG emulation automatically.
- Alpine netboot VMs: ALWAYS pass `modloop=<netboot-dir>/modloop-virt` on the
  kernel cmdline. Stable apk repos get kernel security bumps, so `apk add
  linux-virt` installs modules that do NOT match the netboot kernel version
  (`modprobe tun: not found`); the release's modloop is the exact match.
- jq 1.7 chokes on `"... \(.x // "?") ..."` string-in-string interpolation in
  some quoting contexts (exit 3, INVALID_CHARACTER). Use field-by-field
  extraction: `jq -r --arg k "$k" '.[$k] // "?"'`.
- `vpn.sh` must stay non-interactive and hang-proof: never remove
  `--server-poll-timeout`, the tun-poll loop, or the stale-session kill
  (one-session rule). If a tunnel looks dead-but-healthy, it is almost always
  a duplicate session starved by the server — `vpn down && vpn up`.
- Keep the kit dependency-light: bash, coreutils, curl, jq, dpkg/apt,
  python3 (serial-console automation only). Nothing else. Do not add
  frameworks, do not containerize, do not add CI.

## 6. Repo map

```
setup-kit/
├── setup.sh                  <- entry point ("setup" = run this)
├── verify.sh                 <- READY/NOT-READY gate
├── AGENT.md                  <- this file
├── README.md                 <- human quickstart
├── VERSION                   <- kit version
└── scripts/
    ├── vpn.sh                <- universal VPN manager (vpn command: ANY .ovpn/.conf)
    ├── portable-install.sh   <- rootless QEMU/VPN tools installer (deb extraction + cache)
    ├── network-check.sh      <- VPN/connection diagnostics (before/after)
    ├── tools.sh              <- optional lab toolkit (nmap, socat, ...) — NOT in core setup
    ├── vm-vpn-gateway.sh     <- rootless VPN gateway inside a QEMU VM (OpenVPN + WireGuard)
    └── vm_console.py         <- VM serial-console automation driver
```

## 7. Upgrade discipline

If you must change the kit: bump `VERSION`, re-run `bash setup.sh` from a
**fresh clone** to prove a new machine still reaches READY, then push. The
under-60-second guarantee is part of the contract — measure before pushing.
