#!/usr/bin/env bash
# Madeira — Flatpak build script.
#
# Requires: flatpak, flatpak-builder, and the runtime tarball from
# linux/build-runtime.sh. Produces dist/com.madeira.Madeira-<arch>.flatpak
# (a single-file bundle installable with `flatpak install --bundle`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$LINUX_ROOT")"
ARCH="$(uname -m)"
APP_ID="com.madeira.Madeira"
RUNTIME_VER="24.08"
DIST="${MADEIRA_DIST_DIR:-$REPO_ROOT/dist}"
BUILD="${MADEIRA_BUILD_DIR:-$REPO_ROOT/build/flatpak}"
TARBALL="${1:-$DIST/madeira-runtime-$ARCH.tar.gz}"

if ! command -v flatpak >/dev/null 2>&1 || ! command -v flatpak-builder >/dev/null 2>&1; then
    printf 'error: flatpak and flatpak-builder are required\n' >&2
    printf '  Debian/Ubuntu: apt install flatpak flatpak-builder\n' >&2
    printf '  Fedora:        dnf install flatpak flatpak-builder\n' >&2
    printf '  Arch:          pacman -S flatpak flatpak-builder\n' >&2
    exit 1
fi
if [ ! -f "$TARBALL" ]; then
    printf 'runtime tarball not found: %s\nrun linux/build-runtime.sh first\n' "$TARBALL" >&2
    exit 1
fi

# Ensure the freedesktop runtime + sdk exist (skippable in CI with the env).
if [ "${MADEIRA_SKIP_RUNTIME_INSTALL:-0}" != "1" ]; then
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    flatpak install --user --noninteractive --or-update -y flathub \
        "org.freedesktop.Platform//$RUNTIME_VER" \
        "org.freedesktop.Sdk//$RUNTIME_VER"
fi

mkdir -p "$BUILD" "$DIST"
rm -rf "$BUILD/repo" "$BUILD/build"

printf '==> building %s\n' "$APP_ID"
# Pull the runtime tarball path from the manifest's relative source; the dev
# manifest expects it at ../../dist/madeira-runtime-<arch>.tar.gz, which is
# exactly where build-runtime.sh puts it. For a custom path, copy/symlink it.
flatpak-builder --user --force-clean \
    --repo="$BUILD/repo" \
    --state-dir="$BUILD/state" \
    "$BUILD/build" \
    "$LINUX_ROOT/flatpak/$APP_ID.yml"

printf '==> exporting single-file bundle\n'
flatpak build-bundle \
    --compression=zstd \
    "$BUILD/repo" \
    "$DIST/$APP_ID-$ARCH.flatpak" \
    "$APP_ID"

printf '==> done: %s\n' "$DIST/$APP_ID-$ARCH.flatpak"
printf '    install: flatpak install --bundle %s\n' "$DIST/$APP_ID-$ARCH.flatpak"
printf '    run:     flatpak run %s\n' "$APP_ID"
printf '    test:    flatpak-builder --run $PWD/%s %s --doctor\n' "$BUILD/build" "$APP_ID"
