# Building Madeira

Madeira is intended to be buildable from a clean clone with one command.

## Prerequisites

- macOS with a current Xcode installation and the iOS SDK
- Xcode command-line tools selected with `xcode-select`
- Homebrew
- Git

The build script installs the remaining Homebrew packages, initializes all
submodules (including DXMT's nested header submodules), downloads the pinned compiler toolchains, builds the native iOS
libraries, downloads the official Microsoft Visual C++ x64 Redistributable,
extracts the required runtime DLLs locally, builds the Xcode project, and
packages the result. Microsoft runtime DLLs are never added to Git.

Expect the first run to take several hours on a typical Mac: LLVM 15 is
compiled twice (macOS host tools, then the iOS target libraries), and FEX is
a large C++ codebase. Later runs reuse cached outputs and finish in minutes.

## Build an IPA

```sh
git clone --recurse-submodules https://github.com/willfaust/Madeira.git
cd Madeira
./scripts/build-ipa.sh
```

The output is:

```text
dist/Madeira.ipa
```

The IPA is ad-hoc signed with Madeira's requested entitlements so that a
sideloading tool such as SideStore can re-sign it with the contributor's own
development identity.

The current native DXMT build targets iOS 17.0, so the packaged application
also uses iOS 17.0 as its effective deployment target.

## Re-running the build

Toolchains and expensive native build outputs are cached under their existing
ignored build directories. Re-running `./scripts/build-ipa.sh` reuses them when
they are already present. Delete an individual ignored build directory to force
that component to rebuild.

You can override parallelism with, for example:

```sh
JOBS=4 ./scripts/build-ipa.sh
```

If you already have an official `vc_redist.x64.exe`, avoid the download with:

```sh
VC_REDIST_X64="$HOME/Downloads/vc_redist.x64.exe" ./scripts/build-ipa.sh
```

## 32-bit (WoW64) support — x86 32-bit games and apps

32-bit (x86) Windows games and apps — including Valve's real 32-bit
`steam.exe` — run through a WoW64-style session. At launch the app reads the
target's PE header (`IMAGE_FILE_MACHINE_I386` vs `AMD64`/`ARM64*`) in
`WineProcessBridge.m` and selects the matching session architecture:

| Target PE machine | Session |
|---|---|
| `0x014c` i386 | WoW64: `i386-windows` PE set, `MADEIRA_WOW64=1` |
| `0x8664` / ARM64EC | `arm64ec-windows` (FEX x86-64 path) |
| ARM64 | `aarch64-windows` |
| unreadable | legacy `"x64" in filename` heuristic |

The 32-bit PE set is **optional and off by default** (normal builds are
unaffected). Build it with:

```sh
MADEIRA_BUILD_I386=1 ./scripts/build/build-wine.sh
```

This configures `wine/build-i386` (`--enable-archs=i386`) against the
llvm-mingw toolchain, builds the 32-bit PE DLLs/EXEs, strips their debug
sections, and collects them into `app/Madeira/i386-windows`.
`package-ipa.sh` bundles that folder into the IPA when present; at runtime
the app links it into both `C:\windows\syswow64` (the canonical path
Wine's loader probes for i386 modules) and the `sysx86` farm (the
per-arch farm used by cross-arch children, matching `sysx64`/`sysaa64`).

**Status / known limits.** The app-side plumbing (PE detection, WoW64
session selection, farms, Steam launch gating, Settings toggle) is in
place and degrades gracefully — a 32-bit launch without the i386 set logs
a clear reason and falls back rather than crashing. Actual execution of
32-bit x86 code additionally requires the 32-bit guest engine in the FEX
fork (the counterpart of the `xtajit64.dll` 64-bit path) plus the Wine
fork's i386 loader wiring; until that lands, treat WoW64 as
experimental. A 64-bit Steam archive continues to work without any of
this.

## iPhone XS / 4 GB-class devices

The Steam/CEF JIT pool sizes (512–1024 MB) were tuned against the jetsam
budget of 6 GB-class devices. On 4 GB phones (iPhone XS / XR / 11) iOS
kills the app ("closes the application") long before those budgets are
reached. `runWineFullSequence` now auto-clamps the JIT pool to 384 MB on
<4.6 GB devices, `Phone Hardware Optimization` stays on by default, and
the Steam launch path prints the device's situation before a run instead
of after a kill. If a 4 GB-device run still dies, set the JIT pool to
256 MB in Phone & Display Settings (⚙️).
