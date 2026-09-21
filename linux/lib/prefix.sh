# shellcheck shell=bash
# Madeira — lib/prefix.sh
# First-run WINEPREFIX initialization from the shipped prefix-template
# (the same app/Madeira/prefix-template.tar.gz the iOS PrefixExtractor
# consumes), plus registry tweaks, DXVK/VKD3D install & removal.
# Never touches ~/.wine — WINEPREFIX is always exported by the caller.

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
ensure_prefix() {
    local prefix
    prefix="$(madeira_prefix_dir)"
    local template="$MADEIRA_RUNTIME_ROOT/share/madeira/prefix-template.tar.gz"
    local marker="$prefix/.madeira-template-stamp"

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
        if ! tar -xzf "$template" -C "$prefix" 2>/dev/null; then
            log_warn "template extraction failed; falling back to wineboot --init"
        fi
    else
        log_warn "prefix-template.tar.gz missing from bundle; falling back to wineboot --init"
    fi

    # dosdevices were stripped from the template; recreate with correct links.
    mkdir -p "$prefix/dosdevices"
    ln -sfn ../drive_c "$prefix/dosdevices/c:"
    [ -e "$prefix/dosdevices/z:" ] || ln -sfn / "$prefix/dosdevices/z:"

    # Finish/update quietly (no mono/gecko download prompts) so the prefix is
    # complete even though the template predates this Wine build.
    if [ ! -f "$prefix/.update-timestamp" ]; then
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
            printf '"d3d9"="builtin"\n"d3d10core"="builtin"\n"d3d11"="builtin"\n"dxgi"="builtin"\n"d3d12"="builtin"\n'
        else
            printf '"d3d9"="native,builtin"\n"d3d10core"="native,builtin"\n"d3d11"="native,builtin"\n"dxgi"="native,builtin"\n"d3d12"="native,builtin"\n'
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
# DXVK replaces d3d9/d3d10core/d3d11/dxgi; VKD3D-Proton replaces d3d12.
# Only 64-bit DLLs are mandatory; 32-bit are copied when a syswow64 exists
# (new-WoW64 prefixes). Removing the DLLs restores builtin wined3d/vkd3d.
install_dxvk() {
    local prefix src dll dst
    prefix="$(madeira_prefix_dir)"
    src="$MADEIRA_RUNTIME_ROOT/share/madeira/dxvk"
    dst="$prefix/drive_c/windows/system32"
    [ -d "$src" ] || { log_dbg "no bundled DXVK — skipping"; return 1; }
    for dll in d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
        if [ -f "$src/x64/$dll" ]; then
            cp -f "$src/x64/$dll" "$dst/$dll" || return 1
        fi
    done
    if [ -d "$prefix/drive_c/windows/syswow64" ] && [ -d "$src/x86" ]; then
        for dll in d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
            [ -f "$src/x86/$dll" ] && cp -f "$src/x86/$dll" "$prefix/drive_c/windows/syswow64/$dll"
        done
    fi
    log_info "DXVK installed into prefix"
    return 0
}

remove_dxvk() {
    local prefix dll
    prefix="$(madeira_prefix_dir)"
    for dll in d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
        rm -f "$prefix/drive_c/windows/system32/$dll"
        rm -f "$prefix/drive_c/windows/syswow64/$dll" 2>/dev/null || true
    done
    log_info "DXVK removed — builtin WineD3D (OpenGL) will be used"
}

install_vkd3d() {
    local prefix src
    prefix="$(madeira_prefix_dir)"
    src="$MADEIRA_RUNTIME_ROOT/share/madeira/vkd3d-proton"
    [ -d "$src" ] || { log_dbg "no bundled VKD3D-Proton — skipping"; return 1; }
    if [ -f "$src/x64/d3d12.dll" ]; then
        cp -f "$src/x64/d3d12.dll" "$prefix/drive_c/windows/system32/d3d12.dll" || return 1
    fi
    if [ -d "$prefix/drive_c/windows/syswow64" ] && [ -f "$src/x86/d3d12.dll" ]; then
        cp -f "$src/x86/d3d12.dll" "$prefix/drive_c/windows/syswow64/d3d12.dll"
    fi
    log_info "VKD3D-Proton installed into prefix"
    return 0
}

remove_vkd3d() {
    local prefix
    prefix="$(madeira_prefix_dir)"
    rm -f "$prefix/drive_c/windows/system32/d3d12.dll"
    rm -f "$prefix/drive_c/windows/syswow64/d3d12.dll" 2>/dev/null || true
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
