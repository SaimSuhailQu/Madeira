# Madeira for Linux — Bundled-Wine Game Runtime

Production-ready Linux distribution of the Madeira Wine host. It launches a
Windows PC game under the **self-built Wine fork** shipped in this repo —
**without system Wine, without 32-bit multilib libraries, and without touching
the user's `~/.wine`**.

The Linux stack maps 1:1 onto the iOS stack:

| Concern              | iOS (this repo, `app/`)          | Linux (this directory)                         |
|----------------------|----------------------------------|------------------------------------------------|
| Windows API          | Wine fork (ARM64EC)              | Same Wine fork, built `x86_64[,i386]` WoW64    |
| x86 → host CPU       | FEX-Emu (`xtajit64.dll`)         | Native on x86_64; FEX on aarch64 hosts         |
| D3D11                | DXMT → Metal                     | DXVK → Vulkan (WineD3D/GL fallback)            |
| D3D12                | VKD3D-Proton → MoltenVK          | VKD3D-Proton → Vulkan                          |
| wineserver           | Thread inside the Mach task      | Process, killed via `wineserver -k` + PGID     |
| Prefix               | `prefix-template.tar.gz` extracted by `PrefixExtractor` | Same template, extracted to `XDG_DATA_HOME/madeira/prefix` |
| Launch contract      | `MADEIRA_EXE` / `MADEIRA_ARGS`   | Same env vars + positional CLI args            |

## Quickstart

```sh
# 1. Build the self-contained runtime (Wine + DXVK + VKD3D + FEX + game)
./linux/build-runtime.sh                          # x86_64 host
#   optional stages: MADEIRA_BUILD_FEX=1 ./linux/build-runtime.sh

# 2. Package
./linux/appimage/build-appimage.sh                # → dist/Madeira-<ver>-<arch>.AppImage
./linux/flatpak/build-flatpak.sh                  # → dist/com.madeira.Madeira.flatpak

# 3. Run (users never need this — the AppImage is the entry point)
./dist/Madeira-1.0.0-x86_64.AppImage                # launch default game
./dist/Madeira-1.0.0-x86_64.AppImage game.exe --map # run a specific exe
./dist/Madeira-1.0.0-x86_64.AppImage --doctor       # write diagnostics report
./dist/Madeira-1.0.0-x86_64.AppImage --debug game   # wine debug log tee'd to file
```

## File tree

```
linux/
├── README.md                       ← this file
├── BLUEPRINT.md                    ← full engineering blueprint + permissions checklist
├── build-runtime.sh                ← orchestrator: builds Wine/DXVK/VKD3D/FEX + prefix template
├── app/
│   └── madeira                     ← hardened entrypoint (arch probe, renderer fallback,
│                                     display/audio handling, prefix init, teardown)
├── lib/
│   ├── common.sh                   ← logging, XDG paths, bundle-root resolution, locking
│   ├── detect.sh                   ← arch/PE header, GPU+Vulkan, session, audio, kernel caps
│   ├── prefix.sh                   ← first-run prefix init from prefix-template, tweaks,
│   │                                 DXVK/VKD3D install & clean removal
│   └── doctor.sh                   ← --doctor diagnostics report writer
├── appimage/
│   ├── build-appimage.sh           ← AppDir assembly + appimagetool
│   └── com.madeira.Madeira.desktop
├── flatpak/
│   ├── com.madeira.Madeira.yml     ← manifest on org.freedesktop.Platform 24.08
│   ├── build-flatpak.sh
│   ├── com.madeira.Madeira.desktop
│   └── com.madeira.Madeira.metainfo.xml
└── tools/
    └── validate.sh                 ← syntax + smoke + integrity validation
```

## User-facing behavior

- **Prefix** lives in standard XDG data: `~/.local/share/madeira/prefix`
  (AppImage / tarball) — or `~/.var/app/com.madeira.Madeira/data/madeira/prefix`
  (Flatpak; Flatpak redirects `XDG_DATA_HOME` automatically). `~/.wine` is
  **never** read or written: `WINEPREFIX` is always exported before any Wine
  binary runs.
- **Renderer**: DXVK + VKD3D-Proton when a Vulkan 1.3-capable driver is
  detected; automatic fallback to WineD3D/OpenGL otherwise. Override with
  `MADEIRA_RENDERER=auto|dxvk|wined3d`.
- **Wayland/X11**: XWayland preferred by default; opt-in native Wayland driver
  with `MADEIRA_ENABLE_WAYLAND=1`. Desktop resolution is snapshotted before
  launch and restored on exit, including after crashes.
- **Teardown**: on exit, crash or signal the wrapper terminates the game's
  process group, then `wineserver -k`s the exact prefix (wineserver is matched
  by its cwd), then escalates to `SIGKILL`. No orphaned `wineserver`/`svchost`
  processes remain.

## CLI

```
madeira [OPTIONS] [--] [GAME.EXE [ARGS...]]
  --doctor                write a diagnostics report and exit
  --debug                 verbose Wine + DXVK logging, tee'd to the log dir
  --renderer=MODE         auto | dxvk | wined3d   (default: auto)
  --preset=PRESET         default | low  (low: latency/footprint tuned for old hw)
  --prefix=PATH           use a custom WINEPREFIX instead of the XDG default
  --virtual-desktop=WxH   run inside a Wine virtual desktop
  --env=KEY=VAL           extra environment variable for the game
  --version | --help
  MADEIRA_EXE / MADEIRA_ARGS env vars are honored when no positional game is
  given (parity with the iOS host contract in WineProcessBridge.m).
```

Logs land in `XDG_DATA_HOME/madeira/logs/`. See `BLUEPRINT.md` for the
packaging design, runtime isolation, hardening matrix, low-end tuning and the
distribution permissions checklist.
