# shellcheck shell=bash
# Madeira — lib/detect.sh
# Host capability detection: architecture, PE headers, session, scaling, GPU,
# Vulkan stack, audio backend, kernel sync support, X11 display snapshot.
# Every function sets globals and returns 0 unless noted.

# ------------------------------------------------------------ architecture ---
detect_host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  MADEIRA_HOST_ARCH=x86_64  ;;
        aarch64|arm64) MADEIRA_HOST_ARCH=aarch64 ;;
        armv7l|armv8l) MADEIRA_HOST_ARCH=armv7l  ;;
                *)     MADEIRA_HOST_ARCH=unknown ;;
    esac
}

# Read the PE header machine type of a Windows executable.
# Mirrors WineProcessBridge.m's IMAGE_FILE_MACHINE probe (iOS contract):
#   0x014c i386 | 0x8664 AMD64 | 0xAA64 ARM64 | 0xA641 ARM64EC | 0xA64E ARM64X
read_pe_machine() {
    local f="$1" off sig machine
    [ -r "$f" ] || { printf 'unreadable'; return 0; }
    off="$(od -An -j60 -N4 -tu4 "$f" 2>/dev/null | tr -d ' \n')"
    case "$off" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
    [ "$off" -ge 4 ] && [ "$off" -le 10485760 ] || { printf 'unreadable'; return 0; }
    sig="$(od -An -j"$off" -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')"
    [ "$sig" = "50450000" ] || { printf 'non-pe'; return 0; }   # "PE\0\0"
    machine="$(od -An -j"$((off + 4))" -N2 -tx1 "$f" 2>/dev/null | tr -d ' \n')"
    case "$machine" in
        4c01) printf 'i386'    ;;
        8664) printf 'x86_64'  ;;
        64aa) printf 'aarch64' ;;
        41a6) printf 'arm64ec' ;;
        4ea6) printf 'arm64x'  ;;
        *)    printf 'unknown' ;;
    esac
}

# ---------------------------------------------------------------- session ----
# MADEIRA_SESSION:            x11 | wayland | headless
# MADEIRA_WINE_GRAPHICS_DRIVER: x11 (default, incl. XWayland) | wayland (opt-in)
detect_session() {
    MADEIRA_SESSION=x11
    MADEIRA_WINE_GRAPHICS_DRIVER=x11
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if [ -n "${DISPLAY:-}" ]; then
            # XWayland available — the stable default is Wine's X11 driver.
            if [ "${MADEIRA_ENABLE_WAYLAND:-0}" = "1" ]; then
                MADEIRA_SESSION=wayland
                MADEIRA_WINE_GRAPHICS_DRIVER=wayland
            else
                MADEIRA_SESSION=x11
            fi
        else
            MADEIRA_SESSION=wayland
            MADEIRA_WINE_GRAPHICS_DRIVER=wayland
        fi
    elif [ -z "${DISPLAY:-}" ]; then
        MADEIRA_SESSION=headless
    fi
    # Warn when a wayland-only session meets a Wine build without the driver.
    if [ "$MADEIRA_WINE_GRAPHICS_DRIVER" = "wayland" ]; then
        if ! ls "${MADEIRA_WINE_DIR:-/nonexistent}"/lib/wine/*/wayland* >/dev/null 2>&1 \
           && ! ls "${MADEIRA_WINE_DIR:-/nonexistent}"/lib/wine/*/*wayland* >/dev/null 2>&1; then
            log_warn "wayland-only session but bundled Wine lacks the Wayland driver — install XWayland (xserver-xorg-xwayland)"
        fi
    fi
}

# --------------------------------------------------------- display scaling ---
# MADEIRA_SCALE     desktop scale factor (e.g. 1, 1.25, 2)
# MADEIRA_LOGPIXELS Windows logical DPI to write into the prefix (96 default)
detect_scale() {
    local override="${MADEIRA_SCALE:-}"
    MADEIRA_SCALE=1
    MADEIRA_LOGPIXELS=96
    local v=""
    if [ -n "$override" ] && [ "$override" != "1" ]; then
        v="$override"
    elif require_cmd gsettings; then
        v="$(gsettings get org.gnome.desktop.interface scaling-factor 2>/dev/null | awk '{print $NF}')"
        case "$v" in ''|0|1) v="$(gsettings get org.gnome.desktop.interface text-scaling-factor 2>/dev/null | awk '{print $NF}')" ;; esac
    elif require_cmd kscreen-doctor; then
        v="$(kscreen-doctor -o 2>/dev/null | grep -m1 -oE 'scale: ?[0-9.]+' | awk '{print $2}')"
    fi
    if [ -z "$v" ] && require_cmd xrdb && [ -n "${DISPLAY:-}" ]; then
        v="$(xrdb -query 2>/dev/null | awk '/Xft\.dpi/{print $2; exit}')"
        [ -n "$v" ] && v="$(awk -v d="$v" 'BEGIN{printf "%.2f", d/96}')"
    fi
    case "$v" in ''|*[!0-9.]*) v=1 ;; esac
    case "$v" in ''|0) v=1 ;; esac
    MADEIRA_SCALE="$v"
    MADEIRA_LOGPIXELS="$(awk -v s="$v" 'BEGIN{printf "%d", 96 * s + 0.5}')"
}

# --------------------------------------------------------------------- GPU ---
# MADEIRA_GPU_VENDOR: nvidia | amd | intel | virtual | other | none
detect_gpu() {
    MADEIRA_GPU_VENDOR=none
    local d class vendor v rank crank=9
    [ -d /sys/bus/pci/devices ] || return 0
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] || continue
        class="$(cat "$d/class" 2>/dev/null)" || continue
        case "$class" in
            0x030000|0x030200) ;;          # VGA | 3D controller
            *) continue ;;
        esac
        vendor="$(cat "$d/vendor" 2>/dev/null)"
        case "$vendor" in
            0x10de)                       v=nvidia;  rank=0 ;;
            0x1002)                       v=amd;     rank=1 ;;
            0x8086)                       v=intel;   rank=3 ;;
            0x15ad|0x1af4|0x1234|0x1b36)  v=virtual; rank=4 ;;
            *)                            v=other;   rank=2 ;;
        esac
        # A 3D controller (discrete GPU) outranks a VGA controller of the same vendor class
        if [ "$class" = "0x030200" ] && [ "$rank" -gt 0 ]; then
            rank=$((rank - 2))
        fi
        if [ "$rank" -lt "$crank" ]; then
            crank=$rank
            MADEIRA_GPU_VENDOR=$v
        fi
    done
}
# -------------------------------------------------- Vulkan / DXVK gating ----
# Madeira needs Vulkan 1.3 (DXVK 2.x / VKD3D-Proton 2.12+ requirement).
# Sets MADEIRA_VULKAN_OK=1|0 and MADEIRA_VULKAN_REASON="...".
detect_vulkan() {
    MADEIRA_VULKAN_OK=0
    MADEIRA_VULKAN_REASON="unknown"
    if is_container; then
        MADEIRA_VULKAN_REASON="container without /dev/dri (no GPU access)"
        return 0
    fi
    if ! [ -e /dev/dri ]; then
        MADEIRA_VULKAN_REASON="/dev/dri missing (no GPU driver loaded)"
        return 0
    fi
    [ -r /dev/dri/renderD128 ] || {
        MADEIRA_VULKAN_REASON="/dev/dri/renderD128 not readable (user not in 'render' group?)"
        return 0
    }
    if ! require_cmd vulkaninfo; then
        # No client-side checker inside the sandbox: fall back to ICD scanning.
        if ls /usr/share/vulkan/icd.d/*.json \
              /etc/vulkan/icd.d/*.json \
              "${MADEIRA_APPDIR:-/nonexistent}"/usr/share/vulkan/icd.d/*.json >/dev/null 2>&1; then
            MADEIRA_VULKAN_OK=1
            MADEIRA_VULKAN_REASON="Vulkan ICDs present (vulkaninfo unavailable)"
        else
            MADEIRA_VULKAN_REASON="no Vulkan ICD found (install mesa-vulkan-drivers or nvidia-driver)"
        fi
        return 0
    fi
    # vulkaninfo summarizes cleanly; --summary avoids JSON-parsing tool churn.
    if vulkaninfo --summary >/dev/null 2>&1; then
        local ver
        ver="$(vulkaninfo --summary 2>/dev/null | grep -m1 -oE 'apiVersion[^0-9]*1\.3')"
        if [ -n "$ver" ]; then
            MADEIRA_VULKAN_OK=1
            MADEIRA_VULKAN_REASON="Vulkan >= 1.3 available"
        else
            MADEIRA_VULKAN_OK=1
            MADEIRA_VULKAN_REASON="Vulkan available (1.3 not confirmed; DXVK will verify)"
        fi
    else
        # Some older vulkaninfo builds fail with --summary but still enumerate.
        if vulkaninfo 2>/dev/null | grep -q 'GPU id'; then
            MADEIRA_VULKAN_OK=1
            MADEIRA_VULKAN_REASON="Vulkan available (legacy vulkaninfo)"
        else
            MADEIRA_VULKAN_REASON="vulkaninfo failed (driver too old, or no ICD matches the GPU)"
        fi
    fi
}

# --------------------------------------------------------------- audio -------
# MADEIRA_AUDIO_BACKEND: pipewire | pulseaudio | alsa | none
detect_audio() {
    MADEIRA_AUDIO_BACKEND=none
    if [ -n "${PIPEWIRE_LATENCY:-}" ] || [ -n "${PIPEWIRE_NODE:-}" ] || [ -n "${PIPEWIRE_PROPS:-}" ]; then
        MADEIRA_AUDIO_BACKEND=pipewire
    elif pgrep -x pipewire >/dev/null 2>&1 || pgrep -x pipewire-pulse >/dev/null 2>&1; then
        MADEIRA_AUDIO_BACKEND=pipewire
    elif pgrep -x pulseaudio >/dev/null 2>&1; then
        MADEIRA_AUDIO_BACKEND=pulseaudio
    elif [ -n "${PULSE_SERVER:-}" ]; then
        MADEIRA_AUDIO_BACKEND=pulseaudio
    elif [ -e /dev/snd/pcmC0D0p ]; then
        MADEIRA_AUDIO_BACKEND=alsa
    fi
}

# ------------------------------------------------------- kernel features -----
detect_kernel_features() {
    MADEIRA_FUTEX2=0
    MADEIRA_ESYNC=0
    if grep -qsE '(^|\s)futex2(\s|$)' /proc/cmdline; then
        MADEIRA_FUTEX2=1
    fi
    # fsync/esync only help when wineserver is a separate process (always true on Linux).
    [ -r /proc/sys/kernel/threads_max ] && MADEIRA_ESYNC=1
    # ntsync detection: look for the character device introduced with the
    # upstream ntsync driver (Wine 9.x+); guarded so old kernels stay quiet.
    MADEIRA_NTSYNC=0
    [ -c /dev/ntsync ] && MADEIRA_NTSYNC=1
}

# --------------------------------------------------------- X11 snapshot ------
# Snapshot current video mode + gamma for restoration on exit.
# MADEIRA_X11_RANDR_OUTPUT / _MODE / _RATE / _GAMMA / _ORIGIN
snapshot_x11_display() {
    MADEIRA_X11_RANDR_OUTPUT=""
    MADEIRA_X11_RANDR_MODE=""
    MADEIRA_X11_RANDR_RATE=""
    MADEIRA_X11_RANDR_GAMMA=""
    MADEIRA_X11_RANDR_ORIGIN=""
    [ -n "${DISPLAY:-}" ] || return 0
    require_cmd xrandr || return 0
    local out line
    out="$(xrandr --current 2>/dev/null)" || return 0
    line="$(printf '%s\n' "$out" | grep -m1 -E '\*')" || return 0
    MADEIRA_X11_RANDR_OUTPUT="$(printf '%s' "$line" | awk '{print $1}')"
    MADEIRA_X11_RANDR_MODE="$(printf '%s'   "$line" | awk '{print $2}')"
    MADEIRA_X11_RANDR_RATE="$(printf '%s' "$line" | awk '{print $NF}' | tr -d '*+')"
    # gamma: xrandr shows "gamma: 1.0:1.0:1.0" per connected output; take the current output's.
    local gam
    gam="$(printf '%s\n' "$out" | awk -v o="$MADEIRA_X11_RANDR_OUTPUT" '$1==o && /gamma:/ {for(i=1;i<=NF;i++) if($i=="gamma:"){print $(i+1); exit}}')"
    MADEIRA_X11_RANDR_GAMMA="$gam"
    # origin: "NAME connected primary 1920x1080+0+0"
    MADEIRA_X11_RANDR_ORIGIN="$(printf '%s\n' "$out" | awk -v o="$MADEIRA_X11_RANDR_OUTPUT" '$1==o {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {print $i; exit}}')"
    log_dbg "display snapshot: out=$MADEIRA_X11_RANDR_OUTPUT mode=$MADEIRA_X11_RANDR_MODE rate=$MADEIRA_X11_RANDR_RATE gamma=$MADEIRA_X11_RANDR_GAMMA origin=$MADEIRA_X11_RANDR_ORIGIN"
}

# Restore whatever snapshot_x11_display captured (idempotent; safe on crash).
restore_x11_display() {
    [ -n "${DISPLAY:-}" ] || return 0
    require_cmd xrandr || return 0
    if [ -n "$MADEIRA_X11_RANDR_OUTPUT" ] && [ -n "$MADEIRA_X11_RANDR_MODE" ]; then
        local rate=""
        [ -n "${MADEIRA_X11_RANDR_RATE:-}" ] && [ "$MADEIRA_X11_RANDR_RATE" != "0" ] && rate="--rate $MADEIRA_X11_RANDR_RATE"
        # shellcheck disable=SC2086
        xrandr --output "$MADEIRA_X11_RANDR_OUTPUT" --mode "$MADEIRA_X11_RANDR_MODE" $rate 2>/dev/null \
            && log_dbg "display mode restored" \
            || log_warn "could not restore display mode via xrandr"
    fi
    if [ -n "${MADEIRA_X11_RANDR_GAMMA:-}" ]; then
        case "$MADEIRA_X11_RANDR_GAMMA" in
            *:*) xrandr --output "$MADEIRA_X11_RANDR_OUTPUT" --gamma "$MADEIRA_X11_RANDR_GAMMA" 2>/dev/null || true ;;
            0|0.0) ;;
            *) xrandr --output "$MADEIRA_X11_RANDR_OUTPUT" --gamma "$MADEIRA_X11_RANDR_GAMMA:$MADEIRA_X11_RANDR_GAMMA:$MADEIRA_X11_RANDR_GAMMA" 2>/dev/null || true ;;
        esac
    fi
}

# -------------------------------------------------------- combined probe -----
# One call to run everything the wrapper needs; results are globals.
detect_all() {
    detect_host_arch
    detect_session
    detect_scale
    detect_gpu
    detect_vulkan
    detect_audio
    detect_kernel_features
}
