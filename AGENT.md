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

## 4. VPN handover protocol

When the user supplies the VPN:

1. Save the config to `~/vpn-config/` — **NEVER commit VPN configs, creds,
   tokens or .ovpn/.conf files to this repo.** This repo stays secret-free.
2. Baseline first: `bash scripts/network-check.sh before-vpn`
3. Connect:
   - OpenVPN: `openvpn --config ~/vpn-config/<file>.ovpn --daemon` (needs
     root/tun; if the box has no root, report that limitation and use the
     user-provided proxy/socks endpoint instead if any)
   - WireGuard: `wg-quick up ~/vpn-config/<name>.conf` (needs root)
4. Re-check: `bash scripts/network-check.sh after-vpn`
5. Report to the user in one compact block: tunnel present? exit IP, country,
   org, DNS ok, latency, throughput. Compare against the baseline.

## 5. Environment notes (learned the hard way — trust these)

- Debian 13 "trixie" sandbox, user `z`, NO passwordless sudo. The rootless
  portable installer is the path that works there.
- `dpkg --print-architecture` returns `amd64`, but Debian's multiarch lib dir
  is `x86_64-linux-gnu`. Never hand-construct the lib path — the portable
  installer auto-discovers every dir containing `*.so*`. Do not "simplify"
  this back to a hardcoded triplet.
- Wrappers in `~/.local/qemu-kit/bin/` embed their own `LD_LIBRARY_PATH`; run
  the wrappers, not the raw binaries under `root/usr/bin/`.
- `apt-get download` + `dpkg -x` works without root; `/dev/kvm` is usually
  absent in sandboxes -> QEMU falls back to TCG emulation automatically.
- Keep the kit dependency-light: bash, coreutils, curl, jq, dpkg/apt. Nothing
  else. Do not add frameworks, do not containerize, do not add CI.

## 6. Repo map

```
setup-kit/
├── setup.sh                  <- entry point ("setup" = run this)
├── verify.sh                 <- READY/NOT-READY gate
├── AGENT.md                  <- this file
├── README.md                 <- human quickstart
├── VERSION                   <- kit version
└── scripts/
    ├── portable-install.sh   <- rootless QEMU/VPN tools installer (deb extraction)
    └── network-check.sh      <- VPN/connection diagnostics (before/after)
```

## 7. Upgrade discipline

If you must change the kit: bump `VERSION`, re-run `bash setup.sh` from a
**fresh clone** to prove a new machine still reaches READY, then push. The
under-60-second guarantee is part of the contract — measure before pushing.
