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
