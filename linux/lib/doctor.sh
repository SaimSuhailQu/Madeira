# shellcheck shell=bash
# Madeira — lib/doctor.sh — --doctor diagnostics report writer.
# Requires common.sh + detect.sh sourced first (MADEIRA_* globals set).

doctor_put()  { printf '%s\n' "$*" >> "$MADEIRA_DOCTOR_LOG"; }
doctor_run()  { doctor_put "\$ $*"; eval "$*" >> "$MADEIRA_DOCTOR_LOG" 2>&1 || true; }
doctor_section() { doctor_put ""; doctor_put "================================================================== $*"; }

run_doctor() {
    local prefix logdir
    prefix="$(madeira_prefix_dir)"
    logdir="$(madeira_logs_dir)"
    mkdir -p "$logdir" 2>/dev/null || true
    MADEIRA_DOCTOR_LOG="$logdir/doctor-$(madeira_stamp).log"
    : > "$MADEIRA_DOCTOR_LOG"

    log_info "writing diagnostics report: $MADEIRA_DOCTOR_LOG"

    doctor_section "Madeira"
    doctor_put "version:      $MADEIRA_VERSION (lib $MADEIRA_LIB_VERSION)"
    doctor_put "generated:    $(date '+%Y-%m-%d %H:%M:%S %z')"
    doctor_put "runtime root: $MADEIRA_RUNTIME_ROOT"
    doctor_put "appdir:       ${MADEIRA_APPDIR:-none}  flatpak: $(is_flatpak && echo yes || echo no)  container: $(is_container && echo yes || echo no)"

    doctor_section "Operating system"
    doctor_run "uname -a"
    doctor_run "grep PRETTY_NAME /etc/os-release 2>/dev/null"
    doctor_run "cat /etc/debian_version /etc/fedora-release /etc/arch-release 2>/dev/null | head -3"

    doctor_section "CPU / memory"
    doctor_run "grep -m1 'model name' /proc/cpuinfo"
    doctor_run "nproc; grep -c ^processor /proc/cpuinfo 2>/dev/null"
    doctor_run "grep -E 'MemTotal|SwapTotal' /proc/meminfo"
    doctor_run "cat /sys/fs/cgroup/memory.max 2>/dev/null"

    doctor_section "GPU (PCI)"
    doctor_run "lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || echo 'lspci not available'"
    doctor_run "for d in /sys/bus/pci/devices/*; do c=\$(cat \"\$d/class\" 2>/dev/null); case \"\$c\" in 0x030000|0x030200) echo \"\$d vendor=\$(cat \"\$d/vendor\" 2>/dev/null)\";; esac; done"

    doctor_section "Vulkan"
    doctor_put "probe:    $MADEIRA_VULKAN_OK ($MADEIRA_VULKAN_REASON)"
    doctor_run "vulkaninfo --summary 2>/dev/null | head -60 || echo 'vulkaninfo unavailable — install vulkan-tools for deeper detail'"

    doctor_section "OpenGL"
    doctor_run "glxinfo -B 2>/dev/null | head -25 || echo 'glxinfo unavailable (mesa-utils)'"

    doctor_section "Session / display"
    doctor_put "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}  XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>}"
    doctor_put "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}  DISPLAY=${DISPLAY:-<unset>}"
    doctor_put "detected session: $MADEIRA_SESSION   wine graphics driver: $MADEIRA_WINE_GRAPHICS_DRIVER"
    doctor_put "scale: $MADEIRA_SCALE   LogPixels: $MADEIRA_LOGPIXELS"
    doctor_put "gpu vendor: $MADEIRA_GPU_VENDOR"
    [ -n "${DISPLAY:-}" ] && doctor_run "xrandr --query 2>/dev/null | head -40"

    doctor_section "Audio"
    doctor_put "backend: $MADEIRA_AUDIO_BACKEND"
    doctor_run "pactl info 2>/dev/null | head -15 || echo 'pactl unavailable'"
    doctor_run "pgrep -a pipewire 2>/dev/null | head -5; pgrep -a pulseaudio 2>/dev/null | head -5; true"

    doctor_section "Kernel features"
    doctor_put "futex2(fsync): $MADEIRA_FUTEX2   esync-capable: $MADEIRA_ESYNC   ntsync: $MADEIRA_NTSYNC"
    doctor_run "ulimit -Hn; ulimit -Sn"

    doctor_section "Wine runtime"
    doctor_run "\"$MADEIRA_RUNTIME_ROOT/bin/wine\" --version 2>&1 || echo 'bundled wine missing'"
    doctor_run "\"$MADEIRA_RUNTIME_ROOT/bin/wineserver\" --version 2>&1 || true"
    doctor_put "wow64 i386 PE set: $([ -d "$MADEIRA_RUNTIME_ROOT/lib/wine/i386-windows" ] && echo present || echo ABSENT)"
    doctor_put "dxvk bundle:   $(ls "$MADEIRA_RUNTIME_ROOT/share/madeira/dxvk" 2>/dev/null || echo none)"
    doctor_put "vkd3d bundle:  $(ls "$MADEIRA_RUNTIME_ROOT/share/madeira/vkd3d-proton" 2>/dev/null || echo none)"
    doctor_put "fex bundle:    $(ls "$MADEIRA_RUNTIME_ROOT/share/madeira/fex" 2>/dev/null | head -3 || echo none)"

    doctor_section "Wine prefix"
    doctor_put "prefix: $prefix"
    doctor_put "renderer state: dxvk=${MADEIRA_USE_DXVK:-n/a} vkd3d=${MADEIRA_USE_VKD3D:-n/a}"
    doctor_run "ls -la \"$prefix\" 2>/dev/null | head -20"
    doctor_run "cat \"$prefix/.madeira-template-stamp\" 2>/dev/null"
    doctor_run "ls -la \"$prefix/dosdevices\" 2>/dev/null"

    doctor_section "Madeira environment"
    doctor_run "env | grep -E '^(MADEIRA|WINE|WINEDLLOVERRIDES|DXVK|VKD3D|PULSE|PIPEWIRE|LIBGL|GALLIUM|__GL|FEX)' | sort"

    doctor_section "Disk space"
    doctor_run "df -h \"$prefix\" /tmp 2>/dev/null | head -8"

    doctor_section "Last wine log (tail)"
    local last
    last="$(ls -1t "$logdir"/wine-*.log 2>/dev/null | head -n 1)"
    if [ -n "$last" ]; then
        doctor_put "file: $last"
        doctor_run "tail -n 80 \"$last\""
    else
        doctor_put "no wine-*.log files yet"
    fi

    printf '%s\n' "$MADEIRA_DOCTOR_LOG"
}
