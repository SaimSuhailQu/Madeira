#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
WINE="$ROOT/wine"
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
BISON_PATH="$(brew --prefix bison 2>/dev/null || true)/bin"
LLVM_PATH="$(brew --prefix llvm 2>/dev/null || true)/bin"
if [[ -d "$BISON_PATH" ]]; then export PATH="$BISON_PATH:$PATH"; fi
if [[ -d "$LLVM_PATH" ]]; then export PATH="$LLVM_PATH:$PATH"; fi
export PATH="$MINGW:$PATH"

[[ -x "$WINE/configure" ]] || { echo "ERROR: wine submodule is missing" >&2; exit 1; }

# Apply patches to Wine submodule if not already applied
if git -C "$WINE" apply --reverse --check "$ROOT/patches/wine-bitblt-winios-guard.patch" >/dev/null 2>&1; then
  echo "Wine bitblt patch: already applied"
else
  echo "Applying Wine bitblt patch..."
  git -C "$WINE" apply "$ROOT/patches/wine-bitblt-winios-guard.patch"
fi

if git -C "$WINE" apply --reverse --check "$ROOT/patches/wine-ntdll-xlate-jit-aarch64.patch" >/dev/null 2>&1; then
  echo "Wine ntdll xlate_jit patch: already applied"
else
  echo "Applying Wine ntdll xlate_jit patch..."
  git -C "$WINE" apply "$ROOT/patches/wine-ntdll-xlate-jit-aarch64.patch"
fi

# Ensure wine/server/fd.c includes socket headers on Apple
WINE_FD="$WINE/server/fd.c"
if [[ -f "$WINE_FD" ]] && ! grep -q "sys/socket.h" "$WINE_FD"; then
  echo "Patching $WINE_FD for socket headers..."
  python3 -c "
with open('$WINE_FD', 'r') as f:
    c = f.read()
target = '#include <sys/types.h>'
replacement = '''#include <sys/types.h>
#ifdef __APPLE__
#include <sys/socket.h>
#include <netinet/in.h>
#endif'''
if target in c:
    c = c.replace(target, replacement, 1)
    with open('$WINE_FD', 'w') as f:
        f.write(c)
" 2>/dev/null || true
fi

# Native macOS build tree. Madeira's iOS unix-side libraries consume config.h,
# generated headers, and host build outputs from here. aarch64 is the native
# PE architecture used by the tracked Wine/DXMT side.
if [[ ! -f "$WINE/build-macos/Makefile" ]]; then
  echo "Configuring Wine (macOS/aarch64)..."
  mkdir -p "$WINE/build-macos"
  (
    cd "$WINE/build-macos"
    ../configure --enable-archs=aarch64 --disable-tests
  )
fi

if [[ ! -f "$WINE/build-macos/include/dwrite.h" || ! -x "$WINE/build-macos/tools/winebuild/winebuild" ]]; then
  echo "Building Wine host tree..."
  make -C "$WINE/build-macos" -j"$JOBS"
else
  echo "Wine host tree: cached"
fi

# Madeira's ntdll iOS build currently includes generated dwrite headers from a
# directory named build-arm64ec. Configure that tree reproducibly and build only
# the generated headers required by the iOS static libraries; PE binaries are
# already versioned by Madeira and are not rebuilt during onboarding.
if [[ ! -f "$WINE/build-arm64ec/Makefile" ]]; then
  echo "Configuring Wine (ARM64EC headers)..."
  mkdir -p "$WINE/build-arm64ec"
  (
    cd "$WINE/build-arm64ec"
    ../configure --enable-archs=arm64ec --disable-tests
  )
fi

if [[ ! -f "$WINE/build-arm64ec/include/dwrite.h" || ! -f "$WINE/build-arm64ec/include/dwrite_3.h" ]]; then
  echo "Generating Wine ARM64EC headers..."
  make -C "$WINE/build-arm64ec" -j"$JOBS" include/dwrite.h include/dwrite_3.h
else
  echo "Wine ARM64EC headers: cached"
fi

# ---------------------------------------------------------------------------
# ml777: OPTIONAL 32-bit (WoW64) PE set — i386 games, apps and the real
# 32-bit Steam client.
#
# The app detects a target's PE machine type at launch (WineProcessBridge.m
# madeira_pe_machine_*) and runs an i386 session (MADEIRA_WOW64=1) with the
# 32-bit set from app/Madeira/i386-windows when it is present.
#
# This build is OFF by default: it needs the FEX fork's 32-bit (x86) engine
# for actual execution, so building it alone produces a bundle that degrades
# gracefully (clear log, arm64ec fallback) rather than a working WoW64 path.
# Opt in explicitly with:
#
#   MADEIRA_BUILD_I386=1 ./scripts/build/build-wine.sh
#
# The set is built the same way the ARM64EC PEs are: a dedicated Wine build
# tree configured for the i386 PE arch, driven by the llvm-mingw toolchain
# (llvm-mingw ships the i386-w64-mingw32 target), then stripped and collected
# into app/Madeira/i386-windows for package-ipa.sh to bundle.
# ---------------------------------------------------------------------------
I386_DIR="$WINE/build-i386"
I386_OUT="$ROOT/app/Madeira/i386-windows"
if [[ "${MADEIRA_BUILD_I386:-0}" == "1" ]]; then
  echo "Configuring Wine (i386 PE set for WoW64)..."
  rm -rf "$I386_DIR" "$I386_OUT"
  mkdir -p "$I386_DIR"
  (
    cd "$I386_DIR"
    "$WINE/configure" \
      --prefix="$I386_DIR/install" \
      --with-wine-tools="$WINE/build-macos" \
      --enable-archs=i386 \
      --disable-tests \
      --disable-winemenubuilder \
      --without-x \
      --without-wayland \
      --without-xinerama \
      --without-alsa \
      --without-pulse \
      --without-gstreamer \
      --without-sdl \
      --without-oss \
      --without-cups
  )
  [[ -f "$I386_DIR/Makefile" ]] || {
    echo "ERROR: i386 Wine configure produced no Makefile" >&2
    find "$I386_DIR" -maxdepth 2 -name config.log -print
    exit 1
  }
  (
    cd "$I386_DIR"
    echo "i386 Wine build directory: $PWD"
    grep -E '^(host|host_cpu|enable_win64|DLL|PROGRAM)' config.status config.log 2>/dev/null || true
    find dlls programs -type f -name Makefile -print | head -30 || true
  )
  echo "Building Wine i386 PE set (this is a full PE build; expect a long run)..."
  (
    cd "$I386_DIR"
    make -j"$JOBS" dlls programs
    # The directory targets can be no-ops in a partially generated tree;
    # follow them with Wine's complete default target to build all PE rules.
    make -j"$JOBS"
  )
  pe_count="$(find "$I386_DIR/dlls" "$I386_DIR/programs" \
    -type f \( -name '*.dll' -o -name '*.exe' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$pe_count" -lt 50 ]]; then
    echo "ERROR: i386 build completed without producing PE images" >&2
    find "$I386_DIR" -maxdepth 2 -type f -name config.log -print
    find "$I386_DIR/dlls" "$I386_DIR/programs" -type f \( -name '*.dll' -o -name '*.exe' \) 2>/dev/null | head -20 || true
    exit 1
  fi
  mkdir -p "$I386_OUT"
  count=0
  while IFS= read -r pe; do
    base="$(basename "$pe")"
    # Only ship built PE images: skip import libs (.a), fake DLLs (.fake)
    # and any cross-compiled static artifacts.
    case "$base" in
      *.dll|*.exe) ;;
      *) continue ;;
    esac
    llvm-strip --strip-debug "$pe" 2>/dev/null || true
    cp -f "$pe" "$I386_OUT/$base"
    count=$((count + 1))
  done < <(find "$I386_DIR/dlls" "$I386_DIR/programs" -type f \( -name '*.dll' -o -name '*.exe' \) 2>/dev/null)
  echo "i386-windows: collected $count PE images into $I386_OUT"
  # A zero-image collection must fail loudly. package-ipa.sh bundles whatever
  # sits in that directory, so an empty set used to yield a green build whose
  # IPA had no 32-bit support at all.
  if [[ "$count" -eq 0 ]]; then
    echo "ERROR: i386 build produced no PE images (searched $I386_DIR/dlls and $I386_DIR/programs)" >&2
    exit 1
  fi
  [[ -f "$I386_OUT/ntdll.dll" ]] || {
    echo "WARNING: i386 set collected but ntdll.dll is missing — WoW64 will not initialise" >&2
  }
else
  echo "Wine i386 (WoW64) PE set: skipped (MADEIRA_BUILD_I386=1 to build)"
fi
