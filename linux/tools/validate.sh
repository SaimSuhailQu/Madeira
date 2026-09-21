#!/usr/bin/env bash
# Madeira — development validation helper.
# Syntax-checks every launcher/build script, smoke-tests the detection
# library, and exercises `madeira --help/--version/--doctor` with an isolated
# XDG data dir. Works on Linux and in Git Bash (MSYS) on Windows.
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0

echo "== bash version =="
bash --version | head -1

echo "== CRLF strip =="
find . -type f -exec sed -i 's/\r$//' {} +
echo "stripped"

echo "== bash -n =="
for f in app/madeira build-runtime.sh appimage/build-appimage.sh flatpak/build-flatpak.sh lib/*.sh; do
    if bash -n "$f" 2>&1; then
        echo "SYNTAX-OK   $f"
    else
        echo "SYNTAX-FAIL $f"
        rc=1
    fi
done

echo "== leftover chunk markers =="
if grep -rn --exclude=validate.sh '__CHUNK\|__RT2__\|__RT3__\|__MAIN' . 2>/dev/null; then
    echo "MARKERS-FOUND"
    rc=1
else
    echo "NO-MARKERS"
fi

echo "== smoke: detection library =="
(
    . ./lib/common.sh
    . ./lib/detect.sh
    detect_host_arch
    detect_session
    detect_scale
    detect_gpu
    detect_vulkan
    detect_audio
    echo "ARCH=$MADEIRA_HOST_ARCH SESSION=$MADEIRA_SESSION SCALE=$MADEIRA_SCALE LOGPIXELS=$MADEIRA_LOGPIXELS GPU=$MADEIRA_GPU_VENDOR VK_OK=$MADEIRA_VULKAN_OK AUDIO=$MADEIRA_AUDIO_BACKEND"
    printf 'PE-PROBE-ELF: '; read_pe_machine ../app/Madeira/hello_x86.elf; echo
) || rc=1

echo "== smoke: entrypoint --help/--version =="
if bash ./app/madeira --help >/dev/null 2>&1; then echo "HELP-OK"; else echo "HELP-FAIL"; rc=1; fi
bash ./app/madeira --version || rc=1

echo "== smoke: --doctor with isolated XDG data dir =="
TESTDATA="$(mktemp -d)"
XDG_DATA_HOME="$TESTDATA" bash ./app/madeira --doctor && echo "DOCTOR-OK" || { echo "DOCTOR-FAIL"; rc=1; }
echo "doctor artifacts:"; find "$TESTDATA" -type f | sort
rm -rf "$TESTDATA"

echo "== integrity sentinels =="
# Key identifiers that must exist per file — catches any mid-word clipping.
sentinel_fail=0
check_sentinel() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then
        echo "OK   $1 :: $2"
    else
        echo "MISS $1 :: $2"
        sentinel_fail=1
    fi
}
check_sentinel app/madeira 'find_runtime_root'
check_sentinel app/madeira 'select_renderer'
check_sentinel app/madeira 'MADEIRA_TEARDOWN_DONE'
check_sentinel app/madeira 'restore_x11_display'
check_sentinel app/madeira 'WINE_NTSYNC'
check_sentinel app/madeira 'DXVK_STATE_CACHE_PATH'
check_sentinel app/madeira 'DXVK_CONFIG_FILE'
check_sentinel app/madeira 'MALLOC_ARENA_MAX'
check_sentinel app/madeira 'setsid 9>&-'
check_sentinel lib/detect.sh 'read_pe_machine'
check_sentinel lib/detect.sh 'snapshot_x11_display'
check_sentinel lib/detect.sh 'detect_kernel_features'
check_sentinel lib/detect.sh 'restore_x11_display'
check_sentinel lib/prefix.sh 'PrefixExtractor'
check_sentinel lib/prefix.sh 'stamp_new'
check_sentinel lib/prefix.sh 'madeira-tweaks.reg'
check_sentinel lib/prefix.sh 'install_vkd3d'
check_sentinel lib/prefix.sh 'ShowCrashDialog'
check_sentinel lib/doctor.sh 'doctor_section'
check_sentinel lib/doctor.sh 'vulkaninfo'
check_sentinel build-runtime.sh 'WINE_ARCHS'
check_sentinel build-runtime.sh 'PREFIX_BUILD'
check_sentinel build-runtime.sh 'fetch_dxvk_vkd3d'
check_sentinel build-runtime.sh 'assemble_runtime'
[ "$sentinel_fail" = "1" ] && rc=1

echo "== result rc=$rc =="
exit $rc
