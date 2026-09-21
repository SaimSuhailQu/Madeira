#!/usr/bin/env bash
# Madeira — AppImage builder.
#
# Consumes the self-contained runtime tarball produced by linux/build-runtime.sh
# (bin/ lib/ share/ VERSION packaging/) and produces a single-file,
# distro-agnostic AppImage. Users need NO system Wine, NO 32-bit multilib, and
# NO root — the image is extracted and run from $APPDIR/files at runtime.
#
# Usage: linux/appimage/build-appimage.sh [--tarball PATH] [--icon PATH]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$LINUX_ROOT")"
ARCH="$(uname -m)"
DIST="${MADEIRA_DIST_DIR:-$REPO_ROOT/dist}"
BUILD="${MADEIRA_BUILD_DIR:-$REPO_ROOT/build/appimage}"
TARBALL=""
ICON="$REPO_ROOT/app/Madeira/Assets.xcassets/AppIcon.appiconset/icon_1024.png"

while [ $# -gt 0 ]; do
    case "$1" in
        --tarball) TARBALL="$2"; shift 2 ;;
        --icon)    ICON="$2"; shift 2 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -f "$TARBALL" ] || TARBALL="$DIST/madeira-runtime-$ARCH.tar.gz"
if [ ! -f "$TARBALL" ]; then
    printf 'runtime tarball not found: %s\nrun linux/build-runtime.sh first\n' "$TARBALL" >&2
    exit 1
fi
[ -f "$ICON" ] || { printf 'icon not found: %s\n' "$ICON" >&2; exit 1; }

VERSION="$(tar -xOzf "$TARBALL" VERSION 2>/dev/null || printf '0.1.0')"
VERSION="${VERSION%%[[:space:]]*}"
[ -n "$VERSION" ] || VERSION="0.1.0"

APPDIR="$BUILD/Madeira.AppDir"
printf '==> assembling AppDir: %s (v%s, %s)\n' "$APPDIR" "$VERSION" "$ARCH"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/files" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/metainfo" \
         "$APPDIR/usr/share/icons/hicolor/1024x1024/apps"

# 1. Payload: everything from the runtime tarball → files/
tar -xzf "$TARBALL" -C "$APPDIR/files"

# 2. Launcher sanity + exec bits (tar may drop them depending on the builder).
chmod +x "$APPDIR/files/bin/madeira" 2>/dev/null || true
chmod +x "$APPDIR/files/bin/wine" "$APPDIR/files/bin/wineboot" \
         "$APPDIR/files/bin/wineserver" 2>/dev/null || true

# 3. Desktop entry, metainfo, icon.
cp "$LINUX_ROOT/appimage/com.madeira.Madeira.desktop" "$APPDIR/"
cp "$LINUX_ROOT/appimage/com.madeira.Madeira.desktop" \
   "$APPDIR/usr/share/applications/com.madeira.Madeira.desktop"
if [ -f "$APPDIR/files/packaging/com.madeira.Madeira.metainfo.xml" ]; then
    cp "$APPDIR/files/packaging/com.madeira.Madeira.metainfo.xml" \
       "$APPDIR/usr/share/metainfo/com.madeira.Madeira.metainfo.xml"
fi
cp "$ICON" "$APPDIR/usr/share/icons/hicolor/1024x1024/apps/madeira.png"
ln -sf usr/share/icons/hicolor/1024x1024/apps/madeira.png "$APPDIR/.DirIcon"

# 4. AppRun — resolves the AppDir and hands off to the launcher.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
# Madeira AppRun — exec the bundled launcher with the AppDir exported.
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export APPDIR="$HERE"
exec "$HERE/files/bin/madeira" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# 5. Validate what we can (both tools are optional).
if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$APPDIR/com.madeira.Madeira.desktop" \
        || printf 'warn: desktop file validation reported issues\n' >&2
fi

# 6. Fetch (pinned) appimagetool if not provided.
APPIMAGETOOL="${APPIMAGETOOL:-}"
if [ -z "$APPIMAGETOOL" ]; then
    TOOL="$BUILD/tools/appimagetool-$ARCH.AppImage"
    mkdir -p "$(dirname "$TOOL")"
    if [ ! -f "$TOOL" ]; then
        URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
        printf '==> fetching %s\n' "$URL"
        curl -fL --retry 3 --connect-timeout 20 -o "$TOOL" "$URL"
        chmod +x "$TOOL"
    fi
    if [ -n "${APPIMAGETOOL_SHA256:-}" ]; then
        echo "$APPIMAGETOOL_SHA256  $TOOL" | sha256sum -c - \
            || { printf 'appimagetool checksum mismatch\n' >&2; exit 1; }
    else
        printf 'warn: APPIMAGETOOL_SHA256 not set — skipping checksum verification\n' >&2
    fi
    APPIMAGETOOL="$TOOL"
fi

# 7. Build. Releases of appimagetool are AppImages themselves; the
#    --appimage-extract-and-run flag works everywhere (incl. containers).
TOOLRUN=(--appimage-extract-and-run)
if [ "${APPIMAGETOOL_FORCE_NATIVE:-0}" = "1" ]; then
    TOOLRUN=()
fi
mkdir -p "$DIST"
export VERSION
printf '==> building AppImage\n'
"$APPIMAGETOOL" ${TOOLRUN[@]+"${TOOLRUN[@]}"} "$APPDIR" \
    "$DIST/Madeira-$VERSION-$ARCH.AppImage"

printf '==> done: %s\n' "$DIST/Madeira-$VERSION-$ARCH.AppImage"
