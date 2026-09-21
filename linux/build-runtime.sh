#!/usr/bin/env bash
# Madeira — self-contained Linux runtime builder.
#
# Produces dist/madeira-runtime-<arch>.tar.gz containing:
#   bin/      madeira launcher + wine/wineboot/wineserver/winecfg
#   lib/      madeira libs (common/detect/prefix/doctor) + wine's lib/wine tree
#   share/    dxvk/, vkd3d-proton/, fex/ (aarch64), prefix-template.tar.gz,
#             game/ (optional), applications/, icons/, metainfo/
#   packaging/ desktop + metainfo + icon for the packagers
#   VERSION
#
# Stages (each skippable, see env vars below):
#   1. Wine fork — "new WoW64" single build (--enable-archs=x86_64,i386):
#      64-bit unix side + BOTH PE sets ⇒ the bundle needs NO 32-bit host
#      libraries at all. Built inside an ubuntu:24.04 container with mingw-w64
#      (x86_64) or pinned llvm-mingw (aarch64). iOS-specific fork patches are
#      intentionally NOT applied — they are Apple-only.
#   2. DXVK + VKD3D-Proton — pinned upstream release tarballs (sha256 gate).
#   3. FEX-Emu — aarch64 hosts only (x86→ARM translation + RootFS). Experimental.
#   4. Prefix template — wineboot --init in a container + username normalization
#      (GNU port of scripts/build-prefix-snapshot.sh).
#   5. Game staging + final reproducible tarball.
#
# Env switches:
#   JOBS=N                          parallelism (default: nproc)
#   MADEIRA_LINUX_WINE_ARCHS=...    wine --enable-archs (default: x86_64,i386)
#   MADEIRA_WINE_PREBUILT=DIR       reuse an existing wine install tree (stage 1 skip)
#   DXVK_VERSION / DXVK_SHA256      pin (default 2.6.1)
#   VKD3D_PROTON_VERSION / _SHA256  pin (default 2.14.1)
#   MADEIRA_BUILD_FEX=1             build/fetch FEX (aarch64 targets)
#   MADEIRA_GAME_DIR=/path/game     stage a game into share/madeira/game
#   MADEIRA_SKIP_WINE_BUILD=1       alias for MADEIRA_WINE_PREBUILT reuse check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ARCH="$(uname -m)"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
BUILD="${MADEIRA_BUILD_DIR:-$REPO_ROOT/build/linux-runtime}"
DIST="${MADEIRA_DIST_DIR:-$REPO_ROOT/dist}"
STAGE="$BUILD/stage"                      # assembles into the final tree
DXVK_VERSION="${DXVK_VERSION:-2.6.1}"
DXVK_SHA256="${DXVK_SHA256:-}"
VKD3D_PROTON_VERSION="${VKD3D_PROTON_VERSION:-2.14.1}"
VKD3D_PROTON_SHA256="${VKD3D_PROTON_SHA256:-}"
FEX_VERSION="${FEX_VERSION:-2407}"
WINE_ARCHS="${MADEIRA_LINUX_WINE_ARCHS:-x86_64,i386}"
GAME_DIR="${MADEIRA_GAME_DIR:-}"

msg()  { printf '[runtime] %s\n' "$*"; }
fail() { printf '[runtime] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD" "$DIST" "$STAGE"

# -------------------------------------------------------------- stage 1: wine
build_wine() {
    local dest="$STAGE"
    if [ -n "${MADEIRA_WINE_PREBUILT:-}" ]; then
        msg "stage1: reusing prebuilt Wine tree: $MADEIRA_WINE_PREBUILT"
        cp -a "$MADEIRA_WINE_PREBUILT/." "$dest/"
        return 0
    fi
    if [ "${MADEIRA_SKIP_WINE_BUILD:-0}" = "1" ]; then
        fail "stage1: MADEIRA_SKIP_WINE_BUILD=1 but no MADEIRA_WINE_PREBUILT given"
    fi
    command -v docker >/dev/null 2>&1 || \
        fail "stage1 needs docker (or set MADEIRA_WINE_PREBUILT to a wine install tree)"
    [ -d "$REPO_ROOT/wine" ] && [ -f "$REPO_ROOT/wine/configure" ] || \
        fail "wine submodule missing — run: git submodule update --init wine"

    msg "stage1: building Wine ($WINE_ARCHS) in ubuntu:24.04 container — this takes a while"
    mkdir -p "$BUILD/wine-out"
    # -i: feed the script on stdin. /src = repo, /out = install tree.
    docker run --rm -i \
        -e WINE_ARCHS="$WINE_ARCHS" \
        -v "$REPO_ROOT":/src:ro \
        -v "$BUILD/wine-out":/out \
        ubuntu:24.04 bash -s <<'WINE_BUILD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential flex bison gettext pkg-config file curl ca-certificates \
    gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
    libx11-dev libxext-dev libxrender-dev libxrandr-dev libxi-dev \
    libxcursor-dev libxfixes-dev libxcomposite-dev libxxf86vm-dev \
    libglib2.0-dev libfreetype-dev libfontconfig-dev libgnutls28-dev \
    libasound2-dev libpulse-dev libudev-dev libvulkan-dev \
    libwayland-dev libxkbcommon-dev libfaudio-dev libopus-dev libmpg123-dev

mkdir -p /out/build && cd /out/build
/src/wine/configure \
    --enable-archs="$WINE_ARCHS" \
    --with-mingw \
    --disable-tests \
    --prefix=/madeira
make -j"$(nproc)"
make install DESTDIR=/out
# Strip unix-side ELFs; PE files are already stripped by winebuild.
find /out/madeira -name '*.so' -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
WINE_BUILD

    # Copy the DESTDIR tree (madeira/bin, madeira/lib, madeira/share) into stage.
    cp -a "$BUILD/wine-out/madeira/." "$dest/"
    msg "stage1: wine installed into stage (bin/, lib/wine, share/)"
}
# ------------------------------------------------- stage 2: dxvk + vkd3d -----
fetch_extract() {
    # fetch_extract <url> <sha256|''> <archive>
    local url="$1" sha="$2" archive="$3"
    msg "fetching $url"
    curl -fL --retry 3 --connect-timeout 20 -o "$archive" "$url" \
        || fail "download failed: $url"
    if [ -n "$sha" ]; then
        echo "$sha  $archive" | sha256sum -c - || fail "checksum mismatch: $archive"
    else
        msg "warn: no sha256 pinned for $archive — set the env var for production builds"
    fi
}

fetch_dxvk_vkd3d() {
    local dest="$STAGE/share/madeira"
    mkdir -p "$dest/dxvk" "$dest/vkd3d-proton"
    local tmp
    tmp="$(mktemp -d "$BUILD/dl.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN

    fetch_extract \
        "https://github.com/doitsujin/dxvk/releases/download/v$DXVK_VERSION/dxvk-$DXVK_VERSION.tar.gz" \
        "$DXVK_SHA256" "$tmp/dxvk.tar.gz"
    tar -xzf "$tmp/dxvk.tar.gz" -C "$tmp"
    cp -a "$tmp/dxvk-$DXVK_VERSION/x64" "$dest/dxvk/x64"
    cp -a "$tmp/dxvk-$DXVK_VERSION/x86" "$dest/dxvk/x86"

    fetch_extract \
        "https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v$VKD3D_PROTON_VERSION/vkd3d-proton-$VKD3D_PROTON_VERSION.tar.zst" \
        "$VKD3D_PROTON_SHA256" "$tmp/vkd3d.tar.zst"
    tar --zstd -xf "$tmp/vkd3d.tar.zst" -C "$tmp"
    cp -a "$tmp/vkd3d-proton-$VKD3D_PROTON_VERSION/x64" "$dest/vkd3d-proton/x64"
    cp -a "$tmp/vkd3d-proton-$VKD3D_PROTON_VERSION/x86" "$dest/vkd3d-proton/x86"

    msg "stage2: DXVK $DXVK_VERSION + VKD3D-Proton $VKD3D_PROTON_VERSION staged"
}

# ---------------------------------------------------- stage 3: FEX (ARM64) ---
fetch_fex() {
    # Only meaningful for aarch64 targets. FEX release asset names have moved
    # between releases — check https://github.com/FEX-Emu/FEX/releases and pin
    # exact asset URLs + sha256 here before a production ARM64 build.
    if [ "$ARCH" != "aarch64" ] && [ "${MADEIRA_BUILD_FEX:-0}" != "1" ]; then
        msg "stage3: skipping FEX (not an aarch64 host)"
        return 0
    fi
    local dest="$STAGE/share/madeira/fex"
    mkdir -p "$dest"
    local tmp
    tmp="$(mktemp -d "$BUILD/fex.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    fetch_extract \
        "https://github.com/FEX-Emu/FEX/releases/download/FEX-$FEX_VERSION/RootFS_$FEX_VERSION.tar.xz" \
        "${FEX_ROOTFS_SHA256:-}" "$tmp/rootfs.tar.xz"
    tar -xJf "$tmp/rootfs.tar.xz" -C "$dest"
    mv "$dest"/RootFS* "$dest/RootFS" 2>/dev/null || true
    fetch_extract \
        "https://github.com/FEX-Emu/FEX/releases/download/FEX-$FEX_VERSION/FEX-$FEX_VERSION-aarch64.tar.xz" \
        "${FEX_BIN_SHA256:-}" "$tmp/fex.tar.xz"
    tar -xJf "$tmp/fex.tar.xz" -C "$dest"
    msg "stage3: FEX $FEX_VERSION staged (experimental — pin exact assets for production)"
}

# ------------------------------------------- stage 4: prefix template --------
build_prefix_template() {
    local template="$STAGE/share/madeira/prefix-template.tar.gz"
    [ -f "$template" ] && { msg "stage4: template exists — regenerating"; }
    mkdir -p "$STAGE/share/madeira"
    command -v docker >/dev/null 2>&1 || fail "stage4 needs docker"
    msg "stage4: generating prefix template via wineboot in a container"
    docker run --rm -i \
        -v "$STAGE":/rt \
        ubuntu:24.04 bash -s <<'PREFIX_BUILD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends xvfb ca-certificates libx11-6 \
    libxext6 libxrender1 libxrandr2 libxi6 libxcursor6 libglib2.0-0 \
    libfreetype6 libfontconfig1 libgnutls30 libasound2 libpulse0 libudev1 \
    libvulkan1 libwayland-client0 libxkbcommon0

export WINEPREFIX=/tmp/prefix
export WINEDEBUG=-all
export WINEDLLOVERRIDES=mscoree=d,mshtml=d
xvfb-run -a /rt/bin/wineboot --init
sleep 2

# Normalize the build-host username to 'madeira' (portable prefix), then
# strip what the bundle already ships — GNU port of scripts/build-prefix-snapshot.sh.
BUILD_USER="$(id -un 2>/dev/null || echo root)"
if [ -d "$WINEPREFIX/drive_c/users/$BUILD_USER" ] && [ "$BUILD_USER" != "madeira" ]; then
    mv "$WINEPREFIX/drive_c/users/$BUILD_USER" "$WINEPREFIX/drive_c/users/madeira"
fi
for reg in "$WINEPREFIX/system.reg" "$WINEPREFIX/user.reg" "$WINEPREFIX/userdef.reg"; do
    [ -f "$reg" ] || continue
    # '.' wildcards absorb the registry path separators regardless of how many
    # backslashes each layer (bash → sed -E) consumes.
    sed -i -E "s|users.$BUILD_USER.|users.madeira.|g" "$reg"
    sed -i -E "s|users.$BUILD_USER\"|users.madeira\"|g" "$reg"
    sed -i -E "s|=\"$BUILD_USER\"|=\"madeira\"|g" "$reg"
done
find "$WINEPREFIX/drive_c" -type f \( \
    -name '*.dll' -o -name '*.exe' -o -name '*.drv' -o -name '*.sys' \
    -o -name '*.acm' -o -name '*.cpl' -o -name '*.tlb' -o -name '*.ax' \
    -o -name '*.ocx' -o -name '*.mui' -o -name '*.rll' -o -name '*.nls' \) -delete
rm -rf "$WINEPREFIX/drive_c/windows/winsxs" \
       "$WINEPREFIX/drive_c/windows/Microsoft.NET" \
       "$WINEPREFIX/drive_c/windows/resources" \
       "$WINEPREFIX/drive_c/windows/globalization" \
       "$WINEPREFIX/drive_c/windows/system32/catroot" \
       "$WINEPREFIX/drive_c/windows/system32/driverstore" \
       "$WINEPREFIX/drive_c/windows/system32/gecko" \
       "$WINEPREFIX/drive_c/windows/system32/mui" \
       "$WINEPREFIX/drive_c/windows/system32/Speech" \
       "$WINEPREFIX/drive_c/windows/system32/winmetadata" \
       "$WINEPREFIX/drive_c/windows/system32/WindowsPowerShell"
rm -rf "$WINEPREFIX/dosdevices" "$WINEPREFIX/drive_c/users/$BUILD_USER"

tar -C /tmp -czf /rt/share/madeira/prefix-template.tar.gz prefix
PREFIX_BUILD
    msg "stage4: template written: $template ($(du -h "$template" | cut -f1))"
}
# ------------------------------------------------ stage 5: assemble pack -----
assemble_runtime() {
    # Launcher + libraries from the repo.
    mkdir -p "$STAGE/bin" "$STAGE/lib"
    install -m755 "$SCRIPT_DIR/app/madeira" "$STAGE/bin/madeira"
    install -m644 "$SCRIPT_DIR/lib/common.sh"  "$STAGE/lib/common.sh"
    install -m644 "$SCRIPT_DIR/lib/detect.sh"  "$STAGE/lib/detect.sh"
    install -m644 "$SCRIPT_DIR/lib/prefix.sh"  "$STAGE/lib/prefix.sh"
    install -m644 "$SCRIPT_DIR/lib/doctor.sh"  "$STAGE/lib/doctor.sh"

    # Packaging assets (desktop entry, metainfo, icon).
    mkdir -p "$STAGE/packaging" \
             "$STAGE/share/applications" "$STAGE/share/metainfo" \
             "$STAGE/share/icons/hicolor/1024x1024/apps"
    install -m644 "$SCRIPT_DIR/appimage/com.madeira.Madeira.desktop" "$STAGE/packaging/com.madeira.Madeira.desktop"
    install -m644 "$SCRIPT_DIR/flatpak/com.madeira.Madeira.metainfo.xml" "$STAGE/packaging/com.madeira.Madeira.metainfo.xml"
    install -m644 "$REPO_ROOT/app/Madeira/Assets.xcassets/AppIcon.appiconset/icon_1024.png" "$STAGE/packaging/madeira.png"
    install -m644 "$STAGE/packaging/madeira.png" "$STAGE/share/icons/hicolor/1024x1024/apps/madeira.png"
    install -m644 "$STAGE/packaging/com.madeira.Madeira.desktop" "$STAGE/share/applications/com.madeira.Madeira.desktop"
    install -m644 "$STAGE/packaging/com.madeira.Madeira.metainfo.xml" "$STAGE/share/metainfo/com.madeira.Madeira.metainfo.xml"

    # Optional game payload.
    if [ -n "$GAME_DIR" ]; then
        [ -d "$GAME_DIR" ] || fail "MADEIRA_GAME_DIR not found: $GAME_DIR"
        rm -rf "$STAGE/share/madeira/game"
        cp -a "$GAME_DIR" "$STAGE/share/madeira/game"
        msg "stage5: game staged from $GAME_DIR"
    fi

    # Version + reproducible tarball.
    local version
    version="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo 0.1.0)"
    printf '%s\n' "$version" > "$STAGE/VERSION"
    msg "stage5: packing dist/madeira-runtime-$ARCH.tar.gz (v$version)"
    tar -C "$STAGE" \
        --sort=name --owner=0 --group=0 --numeric-owner \
        -czf "$DIST/madeira-runtime-$ARCH.tar.gz" \
        bin lib share packaging VERSION
    msg "stage5: $(du -h "$DIST/madeira-runtime-$ARCH.tar.gz" | cut -f1) → $DIST/madeira-runtime-$ARCH.tar.gz"
}

# ------------------------------------------------------------ orchestration --
msg "Madeira Linux runtime builder — arch=$ARCH jobs=$JOBS wine-archs=$WINE_ARCHS"
build_wine
fetch_dxvk_vkd3d
fetch_fex
build_prefix_template
assemble_runtime

cat <<'NEXT'

[runtime] Done. Next steps:
  AppImage:  linux/appimage/build-appimage.sh
             → dist/Madeira-<version>-<arch>.AppImage
  Flatpak:   linux/flatpak/build-flatpak.sh
             → dist/com.madeira.Madeira-<arch>.flatpak
  Smoke test (no packaging): ./build/linux-runtime/stage/bin/madeira --doctor
Notes:
  * Rebuilds reuse the stage dir; delete build/linux-runtime/stage for a clean pass.
  * Wine rebuild: rm -rf build/linux-runtime/wine-out (or set MADEIRA_WINE_PREBUILT).
  * CI: run stages on a ubuntu-24.04 runner; x86_64 covers most users, run a
    second matrix leg on an arm64 runner with MADEIRA_BUILD_FEX=1.
NEXT
