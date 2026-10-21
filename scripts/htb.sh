#!/usr/bin/env bash
# =============================================================================
# htb.sh — HackTheBox zero-struggle client (API + VPN + workbench)
#
#   htb active  [token]        show currently active machine (name/IP/time)
#   htb ready   [token]        token -> active machine -> ovpn -> workbench VM
#                              -> prints READY summary. ONE command, no struggle.
#   htb ovpn    [token]        (re)download the VPN pack for the active machine
#   htb submit  <flag> [token] submit a flag for the active machine
#   htb where                  where things live (token, ovpn, image, results)
#
# Token resolution order: arg > $HTB_TOKEN > ~/vpn-config/htb.token
#
# API truths (verified 2026-10, do NOT "fix" these back):
#   * API base is  https://labs.hackthebox.com/api/v4
#     (www.hackthebox.com/api/v4 is served by HubSpot marketing -> 404/406)
#   * GET  /machine/active                     -> active machine JSON
#   * GET  /access/ovpnfile/{serverId}/{mode}/{proto}
#         mode/proto: tcp/443 works; udp/1337 legacy. Response = .ovpn text.
#   * POST /machine/submit  {"flag": "..."}    -> flag submission
#   * Auth header: "Authorization: Bearer <JWT>"  (JWT from HTB profile settings)
#   * If scopes are empty the JWT may still work for lab endpoints (tested).
#
# Exit codes: 0 ready/success, 1 API/auth error, 2 usage/env error
# =============================================================================
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_DIR="${VPN_DIR:-$HOME/vpn-config}"
VM_DIR="${VM_DIR:-$HOME/vm}"
API_HOSTS=("https://labs.hackthebox.com/api/v4" "https://www.hackthebox.com/api/v4")
mkdir -p "$VPN_DIR"

ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*"; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
have curl || die "curl not found — run setup.sh first"

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# *//'; }

# --- token ---------------------------------------------------------------------
resolve_token() {
    local t="${1:-${HTB_TOKEN:-}}"
    if [ -z "$t" ] && [ -f "$VPN_DIR/htb.token" ]; then
        t="$(tr -d '[:space:]' < "$VPN_DIR/htb.token")"
    fi
    [ -n "$t" ] || { usage; die "no API token (arg, \$HTB_TOKEN, or $VPN_DIR/htb.token)"; }
    printf '%s' "$t"
}

save_token() {
    local t="$1"; printf '%s' "$t" > "$VPN_DIR/htb.token"; chmod 600 "$VPN_DIR/htb.token"
}

# --- API core: call <endpoint> [method] [json-body] -----------------------------
# Tries each known API host once; remembers which one worked (api.host file).
api() {
    local ep="$1" method="${2:-GET}" body="${3:-}"
    local token; token="$(resolve_token)" || return 2
    local host_file="$VPN_DIR/.api-host"
    local hosts=()
    if [ -f "$host_file" ]; then
        local h; h="$(cat "$host_file")"
        hosts=("$h"); [ "$h" = "${API_HOSTS[0]}" ] || hosts+=("${API_HOSTS[@]}")
    else
        hosts=("${API_HOSTS[@]}")
    fi
    local args=(-s --max-time 25 -H "Authorization: Bearer $token" -H "Accept: application/json"
                -H "User-Agent: setup-kit-htb/2.0" -w '\n%{http_code}')
    [ "$method" = "POST" ] && args+=(-X POST -H "Content-Type: application/json" ${body:+-d "$body"})
    local out code h
    for h in "${hosts[@]}"; do
        out="$(curl "${args[@]}" "$h$ep" 2>/dev/null)" || continue
        code="$(printf '%s' "$out" | tail -n1)"
        out="$(printf '%s' "$out" | sed '$d')"
        if [ "$code" = "200" ]; then
            printf '%s' "$h" > "$host_file"
            printf '%s' "$out"
            return 0
        fi
        # 404/406 on labs means wrong endpoint, not wrong host — try next endpoint host anyway
    done
    printf '%s' "$out"
    return 1
}

jsonget() { # jsonget <json> <python-expr over d>
    printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>/dev/null
}

# --- commands -------------------------------------------------------------------
cmd_active() {
    local resp; resp="$(api /machine/active)" || die "API failed (bad token? expired? see htb where)"
    [ -z "$resp" ] && die "empty API response"
    local name ip id srv exp
    name="$(jsonget "$resp" "d['info']['name']")"
    ip="$(jsonget "$resp" "d['info']['ip']")"
    id="$(jsonget "$resp" "d['info']['id']")"
    srv="$(jsonget "$resp" "d['info']['vpn_server_id']")"
    exp="$(jsonget "$resp" "d['info']['expires_at']")"
    [ -z "$name" ] || [ "$name" = "None" ] && die "no active machine (spawn one first)"
    printf 'ACTIVE  %s  (id %s)\nTARGET  %s\nSERVER  vpn %s\nEXPIRES %s\n' "$name" "$id" "$ip" "$srv" "$exp"
    printf '%s' "$resp" > "$VPN_DIR/active-machine.json"
}

cmd_ovpn() {
    local resp srv
    [ -f "$VPN_DIR/active-machine.json" ] || cmd_active >/dev/null || true
    srv="$(jsonget "$(cat "$VPN_DIR/active-machine.json" 2>/dev/null || echo '{}')" "d['info']['vpn_server_id']")"
    [ -n "$srv" ] && [ "$srv" != "None" ] || die "no active machine — run: htb active"
    local token; token="$(resolve_token)" || return 2
    local host_file="$VPN_DIR/.api-host" out="" h
    [ -f "$host_file" ] && h="$(cat "$host_file")" || h="${API_HOSTS[0]}"
    local out_f="$VPN_DIR/htb-$srv.ovpn"
    for variant in "tcp/443" "udp/1337"; do
        for cand in "$h" "${API_HOSTS[@]}"; do
            out="$(curl -s --max-time 30 -H "Authorization: Bearer $token" "$cand/access/ovpnfile/$srv/$variant" 2>/dev/null)" || continue
            if printf '%s' "$out" | head -3 | grep -q "^client"; then
                printf '%s\n' "$out" > "$out_f"; chmod 600 "$out_f"
                ok "VPN pack saved: $out_f ($variant)"
                # latest config is the one the workbench uses
                cp "$out_f" "$VM_DIR/share/htb.ovpn" 2>/dev/null || { mkdir -p "$VM_DIR/share"; cp "$out_f" "$VM_DIR/share/htb.ovpn"; }
                return 0
            fi
        done
    done
    die "could not download a valid .ovpn (token lacks lab scope?)"
}

ensure_workbench() {
    if [ -f "$VM_DIR/alpine.raw" ] && [ -f "$VM_DIR/initramfs.gz" ]; then
        ok "workbench VM present: $VM_DIR/alpine.raw"
        return 0
    fi
    warn "workbench VM missing — building (one-time, ~3-6 min)..."
    bash "$KIT_DIR/scripts/vm-build.sh" || die "workbench build failed"
    ok "workbench VM built"
}

cmd_ready() {
    local t0=$(date +%s)
    local token; token="$(resolve_token "$1")" || return 2
    save_token "$token"
    echo "== HTB READY CHECK =="
    cmd_active || return 1
    cmd_ovpn  || return 1
    ensure_workbench || return 1
    local ip; ip="$(jsonget "$(cat "$VPN_DIR/active-machine.json")" "d['info']['ip']")"
    local name; name="$(jsonget "$(cat "$VPN_DIR/active-machine.json")" "d['info']['name']")"
    local dt=$(( $(date +%s) - t0 ))
    echo
    echo ">> READY <<  machine=$name target=$ip  (prep ${dt}s)"
    echo "  pentest session : python3 $KIT_DIR/scripts/pentest.py --batch <batchfile>"
    echo "  quick flag submit: htb submit 'HTB{...}'"
}

cmd_submit() {
    local flag="${1:-}"; [ -n "$flag" ] || die "usage: htb submit '<flag>'"
    shift || true
    [ -f "$VPN_DIR/active-machine.json" ] || cmd_active >/dev/null || die "no active machine"
    local resp code name
    name="$(jsonget "$(cat "$VPN_DIR/active-machine.json")" "d['info']['name']")"
    resp="$(api /machine/submit POST "{\"flag\": \"$flag\"}")" || { err "submit failed"; printf '%s\n' "$resp"; exit 1; }
    if printf '%s' "$resp" | grep -qi '"success": *true\|"message": *"[^"]*orrect'; then
        ok "FLAG ACCEPTED for $name: $flag"
    else
        warn "API response:"; printf '%s\n' "$resp"
    fi
}

cmd_where() {
    cat <<EOF
token   : $VPN_DIR/htb.token
active  : $VPN_DIR/active-machine.json
ovpn    : $VPN_DIR/htb-*.ovpn  (copy used by workbench: $VM_DIR/share/htb.ovpn)
workbench: $VM_DIR/alpine.raw (+ $VM_DIR/initramfs.gz)
results : $VM_DIR/share/results.txt
api host: $(cat "$VPN_DIR/.api-host" 2>/dev/null || echo "auto (first call)")
EOF
}

case "${1:-}" in
    active)  shift; cmd_active "$@" ;;
    ready)   shift; cmd_ready "$@" ;;
    ovpn)    shift; cmd_ovpn "$@" ;;
    submit)  shift; cmd_submit "$@" ;;
    where)   shift; cmd_where ;;
    help|-h|--help|"") usage ;;
    *) usage; die "unknown subcommand: $1" ;;
esac
