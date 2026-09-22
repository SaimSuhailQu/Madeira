# shellcheck shell=bash
# Madeira — lib/prefix.sh
# First-run WINEPREFIX initialization from the shipped prefix-template
# (the same app/Madeira/prefix-template.tar.gz the iOS PrefixExtractor
# consumes), plus registry tweaks, DXVK/VKD3D install & removal.
# Never touches ~/.wine — export_prefix_env() runs before any Wine binary.

# --------------------------------------------------- WINEPREFIX export -------
# Called from main() *before* the prefix work below, not just from
# setup_wine_env(): ensure_prefix (wineboot) and apply_prefix_tweaks (regedit)
# both execute Wine, and an unset WINEPREFIX silently targets ~/.wine.
export_prefix_env() {
    WINEPREFIX="$(madeira_prefix_dir)"
    export WINEPREFIX
    log_dbg "WINEPREFIX=$WINEPREFIX"
}

# Locate the runtime root (bin/, lib/wine, share/... of the bundled Wine).
find_runtime_root() {
    if [ -n "${MADEIRA_APPDIR:-}" ] && [ -d "$MADEIRA_APPDIR/files" ]; then
        MADEIRA_RUNTIME_ROOT="$MADEIRA_APPDIR/files"
        return 0
    fi
    if [ -d /app/files ] && is_flatpak; then
        MADEIRA_RUNTIME_ROOT=/app/files
        return 0
    fi
    local self="${BASH_SOURCE[1]:-}"
    if [ -n "$self" ]; then
        local d
        d="$(cd "$(dirname "$(readlink -f "$self")")/.." && pwd)"
        if [ -x "$d/bin/wine" ]; then
            MADEIRA_RUNTIME_ROOT="$d"
            return 0
        fi
    fi
    if [ -x "${MADEIRA_ROOT:-/nonexistent}/runtime/bin/wine" ]; then
        MADEIRA_RUNTIME_ROOT="$MADEIRA_ROOT/runtime"
        return 0
    fi
    log_warn "bundled Wine runtime not located (expected bin/wine inside AppDir/files)"
    MADEIRA_RUNTIME_ROOT="${MADEIRA_RUNTIME_ROOT:-/nonexistent}"
    return 1
}

# -------------------------------------------------- first-run prefix init ----
# Idempotent: a marker file records the template's cksum so the heavy work
# only happens once per (prefix, template) pair.

# The template is built as `tar -C <workdir> ... prefix`, i.e. every member is
# rooted one level above the prefix — exactly what the iOS PrefixExtractor
# strips before writing (see PrefixExtractor.c). Extracting without
# --strip-components would put drive_c at <prefix>/prefix/drive_c and leave the
# real WINEPREFIX empty, so Wine would silently rebuild a second, throwaway
# prefix next to the seeded one.
extract_prefix_template() {
    local template="$1" prefix="$2"
    tar --strip-components=1 -xzf "$template" -C "$prefix" 2>/dev/null
}

# Wine creates the shell folders as symlinks into the *build host's* home — in
# the shipped template those are container paths such as /root/Documents. They
# exist on no user machine, so My Documents silently fails to resolve and games
# that save or log there break (the iOS app carries the same repair, see the
# "ml719" note in WineProcessBridge.m). Replace only links whose target is
# actually absent: a real directory, or a link the user made themselves that
# resolves, is left alone. Real directories rather than absolute links, because
# the container/host path is not stable across installs either.
repair_shell_folders() {
    local prefix="$1" users_dir udir name repaired=0
    users_dir="$prefix/drive_c/users"
    [ -d "$users_dir" ] || return 0
    for udir in "$users_dir"/*; do
        [ -d "$udir" ] || continue
        for name in Desktop Documents Downloads Music Pictures Videos; do
            [ -L "$udir/$name" ] || continue
            [ -e "$udir/$name" ] && continue          # resolves — leave it alone
            rm -f "$udir/$name" || continue
            mkdir -p "$udir/$name" 2>/dev/null || continue
            repaired=$((repaired + 1))
        done
    done
    [ "$repaired" -gt 0 ] && log_info "repaired $repaired dangling shell-folder link(s) in the prefix"
    return 0
}

ensure_prefix() {
    local prefix template marker seeded=0
    prefix="$(madeira_prefix_dir)"
    template="$MADEIRA_RUNTIME_ROOT/share/madeira/prefix-template.tar.gz"
    marker="$prefix/.madeira-template-stamp"

    if [ -f "$marker" ] && [ -f "$prefix/.update-timestamp" ]; then
        log_dbg "prefix already initialized: $prefix"
        return 0
    fi

    log_info "initializing Wine prefix at $prefix (first run)…"
    mkdir -p "$prefix"

    if [ -f "$template" ]; then
        # Seed from the shipped template: fast (no wineserver round-trips),
        # matches the iOS app's PrefixExtractor flow, and produces a portable
        # prefix because build-prefix-snapshot.sh already normalized usernames
        # to 'madeira' and stripped bundle-shipped binaries.
        log_dbg "extracting template: $template"
        if extract_prefix_template "$template" "$prefix"; then
            seeded=1
        else
            log_warn "template extraction failed; falling back to wineboot --init"
        fi
    else
        log_warn "prefix-template.tar.gz missing from bundle; falling back to wineboot --init"
    fi

    # dosdevices were stripped from the template; recreate with correct links.
    mkdir -p "$prefix/dosdevices"
    ln -sfn ../drive_c "$prefix/dosdevices/c:"
    [ -e "$prefix/dosdevices/z:" ] || ln -sfn / "$prefix/dosdevices/z:"

    repair_shell_folders "$prefix"

    # Finish/update quietly (no mono/gecko download prompts) so the prefix is
    # complete even though the template predates this Wine build. Run it
    # unconditionally after a successful seed: the template's PE files are
    # stripped at build time yet it ships a .update-timestamp of its own, so
    # without this the fake-DLL skeleton in system32/syswow64 would never be
    # restored. The marker written below — not .update-timestamp — is what keeps
    # subsequent launches cheap.
    if [ "$seeded" = "1" ] || [ ! -f "$prefix/.update-timestamp" ]; then
        log_dbg "running wineboot -u on the seeded prefix"
        # shellcheck disable=SC2091
        WINEDEBUG="-all" WINEDLLOVERRIDES="mscoree=d,mshtml=d" \
            timeout 300 "$MADEIRA_RUNTIME_ROOT/bin/wineboot" -u >/dev/null 2>&1 || \
            log_warn "wineboot -u failed; prefix may be incomplete"
    fi

    local stamp_new
    stamp_new="$(cksum "$template" 2>/dev/null | awk '{print $1}')"
    printf 'template=%s\nstamp=%s\ncreated=%s\nhost=%s\n' \
        "$(basename "$template" 2>/dev/null || echo none)" \
        "${stamp_new:-manual}" "$(madeira_stamp)" "$(uname -m)" > "$marker"

    log_info "prefix initialized."
}

# ------------------------------------------------------ registry tweaks ------
# Applied after prefix init and after every renderer switch. Written as a
# .reg file and applied with regedit /S so it is atomic and loggable.
apply_prefix_tweaks() {
    local wine_bin="$MADEIRA_RUNTIME_ROOT/bin/wine" prefix reg
    prefix="$(madeira_prefix_dir)"
    reg="$prefix/madeira-tweaks.reg"
    local renderer="${MADEIRA_RENDERER:-auto}"
    {
        printf 'REGEDIT4\n\n'
        # Display scaling / DPI fix (MADEIRA_LOGPIXELS set by detect_scale)
        printf '[HKEY_CURRENT_USER\\Control Panel\\Desktop]\n'
        printf '"LogPixels"=dword:%08x\n' "$MADEIRA_LOGPIXELS"
        printf '"FontSmoothing"="2"\n\n'
        printf '[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]\n'
        printf '"UseTakeFocus"="Y"\n\n'
        printf '[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]\n'
        case "${MADEIRA_AUDIO_BACKEND:-none}" in
            pipewire|pulseaudio) printf '"Audio"="pulse"\n' ;;
            alsa)                printf '"Audio"="alsa"\n' ;;
            *)                   printf '"Audio"=""\n' ;;
        esac
        # Renderer: in wined3d mode force builtin; in dxvk mode native wins.
        printf '[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n'
        if [ "$renderer" = "wined3d" ]; then
            printf '"d3d8"="builtin"\n"d3d9"="builtin"\n"d3d10core"="builtin"\n"d3d11"="builtin"\n"dxgi"="builtin"\n"d3d12"="builtin"\n'
        else
            printf '"d3d8"="native,builtin"\n"d3d9"="native,builtin"\n"d3d10core"="native,builtin"\n"d3d11"="native,builtin"\n"dxgi"="native,builtin"\n"d3d12"="native,builtin"\n'
        fi
        printf '"mscoree"="disabled"\n"mshtml"="disabled"\n'
        # Never block on Wine crash dialogs; the wrapper owns teardown.
        printf '[HKEY_CURRENT_USER\\Software\\Wine\\WineDbg]\n'
        printf '"ShowCrashDialog"=dword:00000000\n'
    } > "$reg"

    log_dbg "applying registry tweaks: $reg"
    WINEDEBUG="-all" "$wine_bin" regedit /S "$reg" >/dev/null 2>&1 \
        || log_warn "regedit tweaks failed (non-fatal)"
    rm -f "$reg"
}
# --------------------------------------------------- renderer installers -----
# DXVK replaces d3d8/d3d9/d3d10core/d3d11/dxgi; VKD3D-Proton replaces d3d12.
# The lists below are the single source of truth for install *and* removal, so
# the two stay exact inverses.
#
# VKD3D-Proton needs both d3d12.dll (a thin forwarder) and d3d12core.dll (the
# implementation) — copying only the first leaves D3D12 unable to initialise.
# DXVK has shipped d3d8.dll since 2.4, so 32-bit and 64-bit D3D8 titles get the
# Vulkan path instead of WineD3D.
MADEIRA_DXVK_DLLS="d3d8.dll d3d9.dll d3d10core.dll d3d11.dll dxgi.dll"
MADEIRA_VKD3D_DLLS="d3d12.dll d3d12core.dll"

# Copy the named DLLs that the bundle actually ships. Returns non-zero when the
# source tree is missing or nothing was copied (an empty renderer pack must not
# be reported as a successful install).
renderer_copy_dlls() {
    local srcdir="$1" dstdir="$2" dll copied=0
    shift 2
    [ -d "$srcdir" ] || return 1
    mkdir -p "$dstdir" || return 1
    for dll in "$@"; do
        [ -f "$srcdir/$dll" ] || continue
        cp -f "$srcdir/$dll" "$dstdir/$dll" || return 1
        copied=$((copied + 1))
    done
    [ "$copied" -gt 0 ]
}

# Install a renderer's DLLs for every architecture this prefix can run: 64-bit
# into system32 (mandatory), 32-bit into syswow64. Wine only populates syswow64
# on new-WoW64 builds — wineserver creates it from supported_machines
# (server/registry.c) — so the 32-bit set is installed when the runtime carries
# the i386 PE set, or when a syswow64 directory already exists.
renderer_install() {
    local src="$1" what="$2" prefix sysdir wow64dir
    shift 2
    prefix="$(madeira_prefix_dir)"
    sysdir="$prefix/drive_c/windows/system32"
    wow64dir="$prefix/drive_c/windows/syswow64"
    renderer_copy_dlls "$src/x64" "$sysdir" "$@" || return 1
    if [ -d "$MADEIRA_RUNTIME_ROOT/lib/wine/i386-windows" ] || [ -d "$wow64dir" ]; then
        if renderer_copy_dlls "$src/x86" "$wow64dir" "$@"; then
            log_dbg "32-bit $what DLLs installed into syswow64"
        else
            log_warn "32-bit $what DLLs missing from the bundle — 32-bit games fall back to WineD3D"
        fi
    else
        log_dbg "runtime has no i386 PE set — skipping 32-bit $what DLLs"
    fi
    return 0
}

renderer_remove() {
    local prefix dir dll
    prefix="$(madeira_prefix_dir)"
    for dir in "$prefix/drive_c/windows/system32" "$prefix/drive_c/windows/syswow64"; do
        [ -d "$dir" ] || continue
        for dll in "$@"; do
            rm -f "$dir/$dll"
        done
    done
}

install_dxvk() {
    local src="$MADEIRA_RUNTIME_ROOT/share/madeira/dxvk"
    [ -d "$src" ] || { log_dbg "no bundled DXVK — skipping"; return 1; }
    # shellcheck disable=SC2086
    renderer_install "$src" "DXVK" $MADEIRA_DXVK_DLLS || return 1
    log_info "DXVK installed into prefix"
    return 0
}

remove_dxvk() {
    # shellcheck disable=SC2086
    renderer_remove $MADEIRA_DXVK_DLLS
    log_info "DXVK removed — builtin WineD3D (OpenGL) will be used"
}

install_vkd3d() {
    local src="$MADEIRA_RUNTIME_ROOT/share/madeira/vkd3d-proton"
    [ -d "$src" ] || { log_dbg "no bundled VKD3D-Proton — skipping"; return 1; }
    # shellcheck disable=SC2086
    renderer_install "$src" "VKD3D-Proton" $MADEIRA_VKD3D_DLLS || return 1
    log_info "VKD3D-Proton installed into prefix"
    return 0
}

remove_vkd3d() {
    # shellcheck disable=SC2086
    renderer_remove $MADEIRA_VKD3D_DLLS
}

# Decide the renderer once, then converge the prefix to that decision.
# Uses detect_vulkan results. Override: MADEIRA_RENDERER=dxvk|wined3d|auto.
select_renderer() {
    local want="${MADEIRA_RENDERER:-auto}"
    MADEIRA_USE_DXVK=0
    MADEIRA_USE_VKD3D=0
    case "$want" in
        dxvk)
            MADEIRA_USE_DXVK=1
            MADEIRA_USE_VKD3D=1
            ;;
        wined3d)
            MADEIRA_VULKAN_REASON="renderer forced to wined3d"
            ;;
        auto)
            if [ "$MADEIRA_VULKAN_OK" = "1" ]; then
                MADEIRA_USE_DXVK=1
                MADEIRA_USE_VKD3D=1
            fi
            ;;
        *)
            log_warn "unknown MADEIRA_RENDERER='$want' — using auto"
            [ "$MADEIRA_VULKAN_OK" = "1" ] && { MADEIRA_USE_DXVK=1; MADEIRA_USE_VKD3D=1; }
            ;;
    esac
    if [ "$MADEIRA_USE_DXVK" = "1" ]; then
        install_dxvk || log_warn "DXVK install failed; falling back to WineD3D"
        MADEIRA_USE_DXVK=$([ -f "$(madeira_prefix_dir)/drive_c/windows/system32/d3d11.dll" ] && echo 1 || echo 0)
        [ "$MADEIRA_USE_DXVK" = "0" ] && MADEIRA_VULKAN_REASON="DXVK DLLs unavailable — WineD3D fallback"
    else
        remove_dxvk
    fi
    if [ "$MADEIRA_USE_VKD3D" = "1" ] && [ "$MADEIRA_USE_DXVK" = "1" ]; then
        install_vkd3d || log_warn "VKD3D-Proton install failed; builtin vkd3d will serve D3D12"
    else
        remove_vkd3d
    fi
    if [ "$MADEIRA_USE_DXVK" = "1" ]; then
        log_info "renderer: DXVK/Vulkan ($MADEIRA_VULKAN_REASON)"
    else
        log_info "renderer: WineD3D/OpenGL ($MADEIRA_VULKAN_REASON)"
    fi
}
