#!/usr/bin/env bash
# =============================================================================
# portable-install.sh — Rootless QEMU + VPN-tools installer
#
# Installs QEMU (system emulator + utils) and VPN client tools WITHOUT root
# by downloading the distro's own .deb packages and extracting them into a
# local prefix. Works on locked-down machines, containers and CI sandboxes.
#
# Usage:   bash scripts/portable-install.sh [PREFIX]
# Default: PREFIX=$HOME/.local/qemu-kit
#
# Result:  $PREFIX/bin/<tool> wrappers for: qemu-system-x86_64, qemu-img,
#          openvpn, wg, and every other binary shipped by the packages.
# =============================================================================
set -euo pipefail

PREFIX="${1:-$HOME/.local/qemu-kit}"
ARCH="$(dpkg --print-architecture)"
ROOT="$PREFIX/root"

# What we install (extend this list to grow the kit)
PKGS=(qemu-system-x86 qemu-utils openvpn wireguard-tools)

log()  { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# --- 0. Already installed? ---------------------------------------------------
if [ -x "$PREFIX/bin/qemu-system-x86_64" ] && "$PREFIX/bin/qemu-system-x86_64" --version >/dev/null 2>&1; then
    ok "QEMU already portable-installed at $PREFIX (skipping)"
    exit 0
fi

command -v apt-get >/dev/null 2>&1 || { echo "ERROR: apt-get not found (Debian/Ubuntu only)"; exit 1; }
command -v dpkg     >/dev/null 2>&1 || { echo "ERROR: dpkg not found"; exit 1; }

mkdir -p "$PREFIX/debs" "$PREFIX/bin" "$ROOT"
cd "$PREFIX/debs"

# --- 1. Resolve the full recursive dependency closure ------------------------
log "Resolving dependency closure for: ${PKGS[*]}"
ALL_DEPS="$(apt-cache depends --recurse --no-recommends --no-suggests \
              --no-conflicts --no-breaks --no-replaces --no-enhances \
              "${PKGS[@]}" 2>/dev/null | grep -E '^[a-zA-Z0-9]' | sort -u || true)"

# --- 2. Keep only packages NOT already installed on the host -----------------
TODO=""
for p in $ALL_DEPS; do
    status="$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)"
    if [[ "$status" != *"install ok installed"* ]]; then
        TODO="$TODO $p"
    fi
done
log "$(wc -w <<< "$TODO") packages to fetch (rest already on host)"

# --- 3. Download them (parallel, per-package failure tolerant) ---------------
if [ -n "${TODO// /}" ]; then
    log "Downloading .debs (this is the slow part, cached afterwards)..."
    printf '%s\n' $TODO | xargs -P8 -I{} bash -c \
        'apt-get download "$1" >/dev/null 2>&1 || echo "warn: could not fetch $1" >&2' _ {} || true
fi

# --- 4. Extract everything into the local prefix ------------------------------
log "Extracting packages into $ROOT"
shopt -s nullglob
for deb in ./*.deb; do
    dpkg -x "$deb" "$ROOT" 2>/dev/null || warn "extract failed: $deb"
done

# --- 5. Generate wrapper scripts with correct LD_LIBRARY_PATH ----------------
# Auto-discover every directory that actually contains shared libraries
# (robust against multiarch triplets: x86_64-linux-gnu vs amd64, etc.)
LIBDIRS="$(find "$ROOT" -type f -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')"
make_wrapper() {
    local name="$1" target="$2"
    cat > "$PREFIX/bin/$name" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$LIBDIRS:\${LD_LIBRARY_PATH:-}"
exec "$target" "\$@"
EOF
    chmod +x "$PREFIX/bin/$name"
}

shopt -s nullglob
count=0
for bin in "$ROOT"/usr/bin/* "$ROOT"/bin/* "$ROOT"/usr/sbin/*; do
    [ -f "$bin" ] && [ -x "$bin" ] || continue
    base="$(basename "$bin")"
    make_wrapper "$base" "$bin"
    count=$((count+1))
done
log "Created $count wrappers in $PREFIX/bin"

# --- 6. Sanity check ----------------------------------------------------------
export LD_LIBRARY_PATH="${LIBDIRS%:}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
MISSING="$(ldd "$ROOT/usr/bin/qemu-system-x86_64" 2>/dev/null | grep 'not found' || true)"
if [ -n "$MISSING" ]; then
    warn "Some libraries unresolved:"
    echo "$MISSING" | sed 's/^/        /'
else
    ok "All QEMU libraries resolved"
fi

"$PREFIX/bin/qemu-system-x86_64" --version >/dev/null 2>&1 && \
    ok "QEMU functional: $("$PREFIX/bin/qemu-system-x86_64" --version | head -1)" || {
    echo "ERROR: qemu-system-x86_64 failed to run"; exit 1; }

ok "Portable install complete -> $PREFIX/bin"
