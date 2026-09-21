# shellcheck shell=bash
# Madeira — lib/common.sh
# Shared helpers: logging, XDG paths, prefix locking.
# Sourced by linux/app/madeira and linux/lib/doctor.sh. Never executed directly.
# GNU/Linux only (readlink -f, flock, cksum, od).

MADEIRA_LIB_VERSION="1.0.0"

# ---------------------------------------------------------------- logging ----
log_info()  { printf '[madeira][info ] %s\n' "$*" >&2; }
log_warn()  { printf '[madeira][warn ] %s\n' "$*" >&2; }
log_error() { printf '[madeira][error] %s\n' "$*" >&2; }
log_dbg() {
    [ "${MADEIRA_DEBUG:-0}" = "1" ] || return 0
    printf '[madeira][debug] %s\n' "$*" >&2
}
die() { log_error "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

madeira_stamp() { date '+%Y%m%d-%H%M%S'; }

# ------------------------------------------------------------ XDG paths ------
# AppImage / tarball: ${XDG_DATA_HOME:-~/.local/share}/madeira/...
# Flatpak:            XDG_DATA_HOME is redirected to ~/.var/app/com.madeira.Madeira/data
#                     by the Flatpak session, so the same expressions hold.
madeira_data_dir()   { printf '%s/madeira' "${XDG_DATA_HOME:-$HOME/.local/share}"; }
madeira_prefix_dir() { printf '%s' "${MADEIRA_PREFIX:-$(madeira_data_dir)/prefix}"; }
madeira_logs_dir()   { printf '%s/logs' "$(madeira_data_dir)"; }
madeira_cache_dir()  { printf '%s/cache' "$(madeira_data_dir)"; }

madeira_ensure_dirs() {
    local base
    base="$(madeira_data_dir)"
    mkdir -p "$base" "$(madeira_logs_dir)" "$(madeira_cache_dir)" \
        || die "cannot create XDG data directories under $base"
    chmod 700 "$base" 2>/dev/null || true
}

# ------------------------------------------------- single-instance lock ------
# Prevents two wrappers from driving the same prefix simultaneously (a second
# wineserver on one prefix causes lock and registry corruption).
madeira_lock_prefix() {
    local rundir lock hash
    rundir="${XDG_RUNTIME_DIR:-/tmp}/madeira-$(id -u)"
    if ! mkdir -p "$rundir" 2>/dev/null; then
        rundir="/tmp"
    fi
    hash="$(printf '%s' "$(madeira_prefix_dir)" | cksum | tr -d ' \t')"
    lock="$rundir/prefix-$hash.lock"
    exec 9>"$lock" || die "cannot open lock file: $lock"
    if ! flock -n 9; then
        log_error "another Madeira instance is already running this prefix:"
        log_error "  $(madeira_prefix_dir)"
        exit 1
    fi
    MADEIRA_LOCK_FILE="$lock"
    log_dbg "prefix lock acquired: $lock"
}

# --------------------------------------------------------- misc helpers ------
is_flatpak() {
    [ -n "${FLATPAK_ID:-}" ] || [ -f /.flatpak-info ]
}

is_container() {
    [ -f /.dockerenv ] && return 0
    grep -qaE 'docker|kubepods|containerd|lxc' /proc/1/cgroup 2>/dev/null
}

# Wait for a PID to exit, up to $2 seconds (0.2s polling). Returns 0 on exit.
wait_pid_dead() {
    local pid="$1" timeout="${2:-10}" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
             41 42 43 44 45 46 47 48 49 50; do
        [ "$i" -gt "$((timeout * 5))" ] && return 1
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
    done
    return 1
}
