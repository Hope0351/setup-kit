#!/usr/bin/env bash
# =============================================================================
# vpn.sh — universal VPN manager: works with ANY OpenVPN or WireGuard config
#
#   vpn up <config> [--auth <userpass-file>]   connect (auto mode selection)
#   vpn up                                     auto-pick config from ~/vpn-config
#   vpn plan <config>                          dry-run: what would happen, no changes
#   vpn status                                 tunnels, IPs, routes, gateway VM, proxy
#   vpn test [target-ip]                       through-tunnel connectivity check
#   vpn down                                   full teardown (tunnels + gateway VM)
#   vpn gateway up <config> [--auth <file>]    force VM-gateway mode
#   vpn gateway down                           stop the gateway VM
#
# Proven compatible with:
#   * HackTheBox      .ovpn  (cert-only, split-tunnel, UDP 1337)
#   * TryHackMe-style .ovpn  (auth-user-pass -> use --auth file, 2 lines: user/pass)
#   * Self-made OpenVPN configs (inline <ca>/<cert>/<key>, any proto/port)
#   * WireGuard configs (.conf with [Interface]) - direct OR gateway mode
#
# Mode selection (automatic, non-interactive, cannot hang):
#   /dev/net/tun usable AND (root OR passwordless sudo) -> DIRECT mode
#   otherwise (locked-down sandbox / CI)                -> GATEWAY mode
#       QEMU Alpine VM owns the tunnel; host reaches it via 127.0.0.1:11080 proxy
#
# Anti-stuck guarantees: every long operation is bounded (polls + server-poll
# timeouts); stale same-config sessions are killed first (one-session rule).
# =============================================================================
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_DIR="${VPN_DIR:-$HOME/vpn-config}"
GW_FWD="${GW_FWD:-11080}"
CONNECT_WAIT="${CONNECT_WAIT:-45}"

c()    { printf '\033[1;35m[vpn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() { grep -E '^#   vpn ' "${BASH_SOURCE[0]}" | sed 's/^# *//'; }

# --- config type detection (content-based, extension-agnostic) ----------------
detect_type() {
    local f="$1"
    if grep -qE '^[[:space:]]*\[Interface\]' "$f" 2>/dev/null \
       && grep -qE '^[[:space:]]*PrivateKey[[:space:]]*=' "$f" 2>/dev/null; then
        echo wireguard
    elif grep -qiE '^[[:space:]]*(remote[[:space:]]|proto[[:space:]]|client[[:space:]]*$|<ca>|<connection>|tls-client|dev[[:space:]]+tun)' "$f" 2>/dev/null \
       || grep -qi 'openvpn' "$f" 2>/dev/null; then
        echo openvpn
    else
        echo unknown
    fi
}

needs_auth() { grep -qE '^[[:space:]]*auth-user-pass' "$1" 2>/dev/null; }

# auth file path written inside the config (auth-user-pass /path/file.txt)
inline_auth_path() {
    local line
    line="$(grep -E '^[[:space:]]*auth-user-pass' "$1" | head -1 \
            | sed 's/^[[:space:]]*auth-user-pass[[:space:]]*//')"
    [ -n "$line" ] && { echo "$line"; return 0; } || return 1
}

# --- mode selection ------------------------------------------------------------
pick_mode() {
    if { [ -e /dev/net/tun ] && [ -w /dev/net/tun ]; } || [ "$(id -u)" -eq 0 ]; then
        if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
            echo direct; return
        fi
    fi
    echo gateway
}

# --- auth resolution (sets global AUTH_FILE; returns 1 on fatal) ----------------
AUTH_FILE=""
resolve_auth() {  # $1=config $2=--auth value
    local cfg="$1" auth="${2:-}" inline
    AUTH_FILE=""
    if [ -n "$auth" ]; then
        [ -f "$auth" ] || { err "auth file not found: $auth"; return 1; }
        AUTH_FILE="$auth"; return 0
    fi
    if inline="$(inline_auth_path "$cfg")"; then
        case "$inline" in /*) ;; *) inline="$(dirname "$cfg")/$inline" ;; esac
        if [ -f "$inline" ]; then AUTH_FILE="$inline"; return 0; fi
        err "config wants auth file '$inline' but it is missing"
        err "create it (line1=username, line2=password) and rerun:"
        err "  printf '%s\\n%s\\n' USER PASS > ~/vpn-config/auth.txt"
        err "  vpn up $cfg --auth ~/vpn-config/auth.txt"
        return 1
    fi
    if needs_auth "$cfg"; then
        err "config needs user/pass (THM-style auth-user-pass) but none supplied"
        err "create a 2-line credentials file (line1=username, line2=password):"
        err "  printf '%s\\n%s\\n' myuser mypass > ~/vpn-config/auth.txt"
        err "then connect:  vpn up $cfg --auth ~/vpn-config/auth.txt"
        return 1
    fi
    return 0
}

# --- one-session rule (server starves older duplicate sessions) ----------------
enforce_single_session() {
    local cfg="$1" pids p cmdline
    pids="$(pgrep -x openvpn 2>/dev/null || true)"
    [ -z "$pids" ] && return 0
    for p in $pids; do
        cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
        if [[ "$cmdline" == *"$cfg"* ]]; then
            warn "killing stale session pid=$p (same config - one-session rule)"
            kill "$p" 2>/dev/null || true
        else
            warn "unrelated openvpn session alive pid=$p"
            warn "  double sessions with the same cert get starved by servers;"
            warn "  run 'vpn status' and 'vpn down' if the tunnel looks dead-but-up"
        fi
    done
    sleep 1
    return 0
}

wait_tun() {  # $1 = max seconds
    local end=$(( SECONDS + ${1:-$CONNECT_WAIT} ))
    while [ "$SECONDS" -lt "$end" ]; do
        local addr
        addr="$(ip -o -4 addr show 2>/dev/null | grep -E ':(tun|wg)[0-9]+' | head -1)"
        [ -n "$addr" ] && { echo "$addr"; return 0; }
        sleep 2
    done
    return 1
}

# --- DIRECT mode launchers ------------------------------------------------------
start_openvpn_direct() {  # $1=config $2=auth(may be empty)
    local cfg="$1" auth="${2:-}" base pidf
    base="$(basename "$cfg")"; base="${base%.*}"
    pidf="$VPN_DIR/$base.pid"
    local -a pre=() authargs=()
    [ "$(id -u)" -eq 0 ] || pre=(sudo -n)
    [ -n "$auth" ] && authargs=(--auth-user-pass "$auth")
    "${pre[@]}" openvpn --config "$cfg" \
        --daemon --log "$VPN_DIR/$base.log" --writepid "$pidf" \
        --connect-retry 2 --connect-retry-max 5 --server-poll-timeout 15 \
        --resolv-retry 10 "${authargs[@]+"${authargs[@]}"}"
    local addr
    if addr="$(wait_tun "$CONNECT_WAIT")"; then
        ok "TUNNEL UP: $addr"
        return 0
    fi
    err "tunnel did not come up within ${CONNECT_WAIT}s; log tail:"
    tail -15 "$VPN_DIR/$base.log" 2>/dev/null | sed 's/^/    /'
    return 4
}

start_wg_direct() {  # $1=config
    local cfg="$1" out rc
    if out="$( { [ "$(id -u)" -eq 0 ] && wg-quick up "$cfg" \
                 || sudo -n wg-quick up "$cfg"; } 2>&1 )"; then
        ok "wireguard up: $out"
        return 0
    fi
    rc=$?
    err "wg-quick failed (rc=$rc): $out"
    return 4
}

start_gateway() {  # $1=config $2=auth(may be empty)
    local cfg="$1" auth="${2:-}"
    local -a args=(up "$cfg")
    [ -n "$auth" ] && args+=(--auth "$auth")
    bash "$KIT_DIR/scripts/vm-vpn-gateway.sh" "${args[@]}"
}

# --- commands --------------------------------------------------------------------
cmd_up() {
    local cfg="" autharg="" a1="${1:-}" a2="${2:-}" a3="${3:-}"
    # accept: vpn up CFG [--auth F]  |  vpn up --auth F CFG  |  vpn up
    while [ $# -gt 0 ]; do
        case "$1" in
            --auth) autharg="${2:-}"; shift 2 ;;
            *) [ -z "$cfg" ] && cfg="$1"; shift ;;
        esac
    done
    mkdir -p "$VPN_DIR"
    if [ -z "$cfg" ]; then
        local -a found=()
        shopt -s nullglob
        found=("$VPN_DIR"/*.ovpn "$VPN_DIR"/*.conf)
        shopt -u nullglob
        [ "${#found[@]}" -gt 0 ] || die "no config given and nothing found in $VPN_DIR"
        cfg="${found[0]}"
        c "auto-selected config: $cfg"
    fi
    [ -f "$cfg" ] || die "config not found: $cfg"
    local type; type="$(detect_type "$cfg")"
    [ "$type" = "unknown" ] && die "unrecognized VPN config format: $cfg"
    resolve_auth "$cfg" "$autharg" || exit 1
    enforce_single_session "$cfg"
    local mode; mode="$(pick_mode)"
    c "type=$type  mode=$mode  auth=${AUTH_FILE:+file}$( [ -z "$AUTH_FILE" ] && echo none )"
    case "$mode:$type" in
        gateway:*)   start_gateway "$cfg" "$AUTH_FILE" ;;
        direct:openvpn) start_openvpn_direct "$cfg" "$AUTH_FILE" ;;
        direct:wireguard) start_wg_direct "$cfg" ;;
    esac
}

cmd_plan() {
    [ -n "${1:-}" ] || die "usage: vpn plan <config>"
    [ -f "$1" ] || die "config not found: $1"
    local type; type="$(detect_type "$1")"
    [ "$type" = "unknown" ] && die "unrecognized VPN config format: $1"
    echo "config:        $1"
    echo "type:          $type"
    if [ "$type" = openvpn ]; then
        echo "auth:          $(needs_auth "$1" && echo 'required (auth-user-pass)' || echo 'not required (cert-only)')"
        grep -E '^[[:space:]]*remote ' "$1" | head -3 | sed 's/^/server:         /'
    else
        grep -E '^[[:space:]]*(Endpoint|Address|DNS)[[:space:]]*=' "$1" | sed 's/^/wg:             /'
    fi
    echo "auth resolved: ${AUTH_FILE:-none}"
    echo "mode:          $(pick_mode)  $( [ "$(pick_mode)" = gateway ] \
        && echo "(tunnel owned by QEMU guest; host proxy 127.0.0.1:$GW_FWD)" \
        || echo "(tunnel created directly on this host)" )"
}

cmd_status() {
    echo "== vpn status =="
    local ovpn_pids; ovpn_pids="$(pgrep -x openvpn 2>/dev/null || true)"
    if [ -n "$ovpn_pids" ]; then
        for p in $ovpn_pids; do
            echo "  openvpn pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null \
                | grep -oE '\-\-config [^ ]+' || echo '(config unknown)')"
        done
    else
        echo "  openvpn: no host sessions"
    fi
    if have wg; then
        local wgout; wgout="$(wg show 2>/dev/null | head -5)"
        echo "  wireguard: ${wgout:-none}"
    fi
    local tun; tun="$(ip -o -4 addr show 2>/dev/null | grep -E ':(tun|wg)[0-9]+' | tr '\n' ' ')"
    echo "  tunnel ifaces: ${tun:-none}"
    echo "  lab routes: $(ip route 2>/dev/null | grep -E '^(10\.[0-9]+\.){2}' | tr '\n' ' ' || echo none)"
    if pgrep -f qemu-system-x86_64 >/dev/null 2>&1; then
        echo "  gateway VM: RUNNING"
        if curl -s --max-time 4 -o /dev/null -x "http://127.0.0.1:$GW_FWD" http://api.ipify.org 2>/dev/null; then
            echo "  gateway proxy: UP on 127.0.0.1:$GW_FWD (use: curl -x http://127.0.0.1:$GW_FWD <url>)"
        else
            echo "  gateway proxy: not responding yet on $GW_FWD"
        fi
    else
        echo "  gateway VM: not running"
    fi
    local newest
    newest="$(ls -t "$VPN_DIR"/*.log 2>/dev/null | head -1 || true)"
    if [ -n "$newest" ]; then
        echo "  last log ($newest):"
        tail -3 "$newest" | sed 's/^/    /'
    fi
    return 0
}

cmd_test() {
    local target="${1:-}"
    local tun; tun="$(ip -o link show 2>/dev/null | awk -F': ' '/(tun|wg)[0-9]+/{sub(/@.*/,"",$2); print $2; exit}')"
    if [ -z "$tun" ]; then
        if curl -s --max-time 6 -x "http://127.0.0.1:$GW_FWD" "https://api.ipify.org" >/dev/null 2>&1; then
            local ip; ip="$(curl -s --max-time 8 -x "http://127.0.0.1:$GW_FWD" "https://api.ipify.org" 2>/dev/null)"
            ok "gateway proxy path alive (exit IP via proxy: ${ip:-unknown})"
            return 0
        fi
        die "no tunnel interface and no gateway proxy on $GW_FWD - nothing to test (vpn up first)"
    fi
    if [ -z "$target" ]; then
        target="$(ip route show dev "$tun" 2>/dev/null | awk '/via/{print $3; exit}')"
        [ -n "$target" ] || target="10.10.14.1"   # HTB default gateway
        c "auto-selected target: $target (via $tun)"
    fi
    local rx_before rx_after
    rx_before="$(awk -v d="$tun:" '$1==d{print $2}' /proc/net/dev 2>/dev/null || echo 0)"
    if timeout 15 ping -c 3 -I "$tun" -W 4 "$target" >/tmp/vpn-ping.out 2>&1; then
        ok "ping $target via $tun: $(grep -oE '[0-9]+ received' /tmp/vpn-ping.out | head -1), $(grep -oE 'rtt min/avg[^=]*= .*' /tmp/vpn-ping.out | head -1)"
    else
        warn "ping to $target failed (server may block ICMP)"
    fi
    rx_after="$(awk -v d="$tun:" '$1==d{print $2}' /proc/net/dev 2>/dev/null || echo 0)"
    if [ "${rx_after:-0}" -gt "${rx_before:-0}" ]; then
        ok "data returning through $tun (RX $rx_before -> $rx_after)"
    else
        warn "no RX growth on $tun - if handshake was OK but data dead, apply the one-session rule (vpn down && vpn up)"
    fi
}

cmd_down() {
    c "tearing down all tunnels and the gateway VM..."
    if pgrep -x openvpn >/dev/null 2>&1; then
        pkill -x openvpn 2>/dev/null && ok "openvpn sessions killed" || true
    else
        echo "  no openvpn sessions"
    fi
    local wg_ifaces; wg_ifaces="$(ip -o link show 2>/dev/null | awk -F': ' '/wg[0-9]+/{sub(/@.*/,"",$2); print $2}')"
    for i in $wg_ifaces; do
        have wg-quick && wg-quick down "$i" 2>/dev/null \
            || { [ "$(id -u)" -eq 0 ] && ip link del "$i" 2>/dev/null; } \
            || warn "could not remove wg iface $i (needs root)"
    done
    [ -n "$wg_ifaces" ] || echo "  no wireguard ifaces"
    if pgrep -f qemu-system-x86_64 >/dev/null 2>&1; then
        bash "$KIT_DIR/scripts/vm-vpn-gateway.sh" down
    else
        echo "  gateway VM: not running"
    fi
    ok "teardown complete"
}

# --- entry ----------------------------------------------------------------------
cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 1; }
shift || true

case "$cmd" in
    up)      cmd_up "$@" ;;
    plan)    AUTH_FILE=""; cmd_plan "$@" ;;
    status)  cmd_status ;;
    test)    cmd_test "$@" ;;
    down)    cmd_down ;;
    gateway)
        sub="${1:-}"; shift || true
        case "$sub" in
            up)   cfg=""; autharg=""
                  while [ $# -gt 0 ]; do
                      case "$1" in --auth) autharg="${2:-}"; shift 2 ;;
                                   *) [ -z "$cfg" ] && cfg="$1"; shift ;; esac
                  done
                  [ -f "$cfg" ] || die "gateway up: config not found: $cfg"
                  resolve_auth "$cfg" "$autharg" || exit 1
                  bash "$KIT_DIR/scripts/vm-vpn-gateway.sh" up "$cfg" \
                      ${AUTH_FILE:+--auth "$AUTH_FILE"} ;;
            down) bash "$KIT_DIR/scripts/vm-vpn-gateway.sh" down ;;
            *)    die "usage: vpn gateway up <cfg> [--auth F] | vpn gateway down" ;;
        esac ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
esac
