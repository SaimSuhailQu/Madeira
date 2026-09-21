# Madeira for Linux — Engineering Blueprint

Covers the four pillars requested: packaging/runtime isolation, launch wrappe
hardening, low-end optimization, and distribution artifacts. File map is in
[README.md](README.md).

---

## 1. Packaging & Runtime Isolation

### 1.1 Why AppImage (primary) + Flatpak (secondary)

| Criterion                          | AppImage                    | Flatpak (fd 24.08)         |
|------------------------------------|-----------------------------|----------------------------|
| Zero system deps (Wine, multilib)  | ✅ everything in one file   | ✅ runtime + GL extensions |
| GPU driver freshness               | ⚠️ host Mesa/NVIDIA must exist | ✅ `org.freedesktop.Platform.GL.*` injected per host |
| Sandbox isolation                  | ❌ none                     | ✅ allow-listed portals     |
| Install friction                   | none (chmod +x, run)        | needs flatpak + runtime pull|
| ARM64 story                        | same image pipeline         | runtime is arch-tagged      |

Both consume the **same** self-contained runtime tarball
(`dist/madeira-runtime-<arch>.tar.gz`) from `linux/build-runtime.sh`, so there
is exactly one artifact pipeline to verify.

### 1.2 The isolation trick: "new WoW64" single Wine build

The classic reason Linux Wine users need 32-bit multilib is the *old* WoW
model: separate 32-bit `wineserver` + 32-bit unix `.so`s. Wine 8+ supports the
**new WoW64**: one 64-bit build configured with
`--enable-archs=x86_64,i386`. All unix-side code is 64-bit; 32-bit PE code runs
through the 64-bit ntdll. Consequences:

- **No i386 ELF libraries required on the host or in the sandbox.**
- One `bin/wine` serves both PE architectures — the launcher's PE-header probe
  (same `IMAGE_FILE_MACHINE` table as `WineProcessBridge.m`) needs no arch
  switching.
- Known tradeoff: new-WoW64 32-bit graphics can lag native; that is why the
  WineD3D/GL fallback path exists (§2.2).

Build stage 1 compiles this in a pinned `ubuntu:24.04` container, so the bundle
behaves identically regardless of the packager's distro. The repo's Wine fork
is used unpatched on Linux — the iOS patches (`wine-bitblt-winios-guard`,
`wine-ntdll-xlate-jit-aarch64`) are Apple-only and deliberately skipped.

### 1.3 First-run sequence (no `~/.wine` pollution)

`WINEPREFIX` is exported **before any Wine binary executes** — there is no code
path that can create `~/.wine`:

1. `madeira_ensure_dirs` — creates `${XDG_DATA_HOME:-~/.local/share}/madeira/{logs,cache}`.
2. `madeira_lock_prefix` — `flock` on `$XDG_RUNTIME_DIR/madeira-<uid>/prefix-<hash>.lock`
   guards against two wrappers corrupting one prefix. Games inherit fd 9
   closed so a crashed wrapper cannot wedge the lock.
3. `ensure_prefix`:
   - Extracts `share/madeira/prefix-template.tar.gz` (built in stage 4 by
     `wineboot --init` in a container, usernames normalized to `madeira`,
     bundle-shipped PE/NLS stripped, `dosdevices` removed) — the identical
     artifact the iOS `PrefixExtractor` consumes.
   - Recreates `dosdevices/c:` → `../drive_c` and `z:` → `/`.
   - Runs `wineboot -u` (timeout 300, `mscoree`/`mshtml` disabled so no Mono/
     Gecko download prompts) only if the template lacks `.update-timestamp`.
   - Writes `.madeira-template-stamp` (template cksum + date + host arch) so
     re-init happens only when the template changes.
4. `select_renderer` + `apply_prefix_tweaks` — DXVK/VKD3D DLL copies and a
   `regedit /S` of the tweak file (DPI, renderer overrides, audio driver,
   crash-dialog suppression).
5. On Flatpak, `XDG_DATA_HOME` is automatically `~/.var/app/com.madeira.Madeira/data`,
   so the prefix lands at `~/.var/app/com.madeira.Madeira/data/madeira/prefix`
   with zero special-casing.

### 1.4 Runtime contents (per-arch tarball)

```
bin/         madeira  wine  wineboot  wineserver  winecfg  regedit  msiexec
lib/         common.sh detect.sh prefix.sh doctor.sh
lib/wine/    x86_64-unix/ x86_64-windows/ i386-windows/  (new-WoW64 tree)
share/madeira/  dxvk/{x64,x86}  vkd3d-proton/{x64,x86}  fex/  (aarch64 only)
               prefix-template.tar.gz  game/  (optional payload)
packaging/   .desktop  metainfo  icon
VERSION
```
---

## 2. Launch Wrapper & Environment Hardening

### 2.1 Architecture handling
- `uname -m` → x86_64 / aarch64 / armv7l (unsupported → clear error).
- PE header probe (`od`-based, mirrors `WineProcessBridge.m`): `i386`,
  `x86_64`, `aarch64`, `arm64ec`, `arm64x`.
- aarch64 hosts: x86/x86_64 targets are wrapped with the bundled
  `FEXInterpreter` (`FEX_ROOTFS` pointed at the shipped RootFS); missing FEX
  fails loudly with build instructions instead of a cryptic Wine error.
- i386 PE on a runtime built without `i386-windows` logs the exact
  `MADEIRA_LINUX_WINE_ARCHS` rebuild instruction (parity with the iOS app's
  graceful WoW64 degradation).

### 2.2 Graphics fallback ladde
```
MADEIRA_RENDERER=auto (default):
  Vulkan 1.3 ICD + /dev/dri/renderD128 readable?
    ├─ yes → DXVK (d3d9/10/11/dxgi) + VKD3D-Proton (d3d12) copied into prefix
    │        WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d12=n,b;..."
    └─ no  → remove_dxvk/remove_vkd3d (builtins restored)
             WINEDLLOVERRIDES="mscoree=d;mshtml=d" only → WineD3D/OpenGL
  DXVK install itself failing also degrades to WineD3D (logged).
```
`detect_vulkan` handles: no `/dev/dri`, unreadable render node (render-group
hint), missing `vulkaninfo` (ICD-directory scan fallback), and containers.
NVIDIA gets `DXVK_ENABLE_NVAPI=1`; `--renderer=wined3d` forces the GL path;
`MADEIRA_SOFTWARE_GL=1` sets `LIBGL_ALWAYS_SOFTWARE=1` (llvmpipe escape hatch).

### 2.3 Wayland / X11, scaling, resolution restore
- `WAYLAND_DISPLAY` + `DISPLAY` → XWayland + Wine **x11** driver (stable
  default). `MADEIRA_ENABLE_WAYLAND=1` (or no XWayland) switches to the
  `wayland` driver, with a warning if the bundled Wine lacks it.
- Scale from GNOME `scaling-factor`/`text-scaling-factor`, KDE
  `kscreen-doctor`, or `Xft.dpi`; written as `LogPixels` + `FontSmoothing`
  registry tweaks.
- Pre-launch `xrandr --current` snapshot (output/mode/rate/gamma/origin);
  restored in teardown even on SIGINT/SIGTERM/crash (`trap ... EXIT` +
  `INT TERM HUP`). Disable with `MADEIRA_RESTORE_RESOLUTION=0`.
- `--virtual-desktop=WxH|1` runs games in `explorer /desktop=` to contain
  fullscreen resolution switches.

### 2.4 Audio
- Backend probe: PipeWire (env/pid) → PulseAudio (`PULSE_SERVER`/pid) → ALSA
  (`/dev/snd/pcmC0D0p`) → none (warning).
- PipeWire is consumed through `pipewire-pulse`, so the Wine **pulse** drive
  covers both; `PULSE_LATENCY_MSEC=60` (90 on `--preset=low`) fixes crackle;
  `PIPEWIRE_LATENCY=128/48000` (1024/48000 on low) for the native quantum.
- Registry `HKCU\Software\Wine\Drivers` `Audio` set per backend; silent mode
  (`Audio=""`) when no server exists.

### 2.5 Process-tree teardown (orphan prevention)
On any exit path (`wait` completion, `SIGINT/TERM/HUP`, crash of the wrapper):
1. `SIGTERM` the game's **process group** (`setsid` made wine a PG leader;
   explorer/virtual-desktop children inherit it) — 10 s grace.
2. `wineserver -k` with our `WINEPREFIX` (polite service shutdown).
3. Hard sweep, scoped to *this* prefix only: `pgrep -x wineserver` whose
   `/proc/<pid>/cwd` equals our prefix → `SIGKILL`; `pgrep -f
   <prefix>/drive_c` stragglers → `SIGKILL`. Never a blanket
   `killall wineserver` (that would murder other apps' prefixes).
4. Resolution/gamma restore.
The teardown handler is idempotent (`MADEIRA_TEARDOWN_DONE`).
---

## 3. Low-End / Older Hardware Optimization

| Concern | Mechanism |
|---|---|
| Debug spam | `WINEDEBUG=-all` always; `--debug` re-enables `warn+seh,+loaddll` |
| Sync prims | `WINE_NTSYNC=1` (kernel ntsync) → `WINEFSYNC=1` (futex2 ≥5.16) → `WINEESYNC=1`; detected, not assumed |
| Memory | `MALLOC_ARENA_MAX=2` on `--preset=low`; shader caches (DXVK/VKD3D/NVIDIA) pinned to XDG cache dir, not the prefix |
| FPS cap | `MADEIRA_MAX_FPS` → `DXVK_FRAME_RATE`; `vblank_mode=0` unlocks GL (wined3d) |
| Latency | audio flags above; `--preset=low` raises latency instead of risking underruns on slow disks/CPUs |
| Thread count | Wine threads scale with cores automatically; per-game MT tuning goes in `dxvk.conf` (`DXVK_CONFIG_FILE` auto-exported when placed next to the exe) |

### 3.1 `--doctor` / `--debug`
`--doctor` writes `~/.local/share/madeira/logs/doctor-<ts>.log` (Flatpak: unde
`~/.var/app/...`): OS, CPU/mem (+cgroup limits), PCI GPU list, `vulkaninfo`
summary, `glxinfo`, session/scaling, audio backends, kernel feature bits,
fd limits, bundled Wine `--version` + WoW64 set presence, DXVK/VKD3D/FEX
bundle state, prefix state + template stamp, all `MADEIRA_/WINE_/DXVK/VKD3D`
env, disk space, and the tail of the last `wine-*.log`. `--debug` tees Wine
output to `wine-<ts>.log` and prints the last 40 lines on non-zero exit.
Support workflow: "run `madeira --doctor` and attach the printed log path".

---

## 4. Distribution Artifacts & Permissions Checklist

### 4.1 Complete file tree (as created in this repo)
```
linux/
├── README.md                                  user-facing overview
├── BLUEPRINT.md                               this document
├── build-runtime.sh                           wine+dxvk+vkd3d+fex+template → tarball
├── app/madeira                                hardened entrypoint
├── lib/{common,detect,prefix,doctor}.sh       launcher libraries
├── appimage/
│   ├── build-appimage.sh                      AppDir + appimagetool → .AppImage
│   └── com.madeira.Madeira.desktop            desktop entry (+ doctor/debug actions)
├── flatpak/
│   ├── com.madeira.Madeira.yml                fd-24.08 manifest
│   ├── build-flatpak.sh                       flatpak-builder → single-file bundle
│   ├── com.madeira.Madeira.desktop
│   └── com.madeira.Madeira.metainfo.xml       AppStream (Flathub-ready)
└── tools/
    └── validate.sh                            syntax + smoke + integrity checks
```

### 4.2 `.desktop` launcher specification
`Exec=madeira %f`, `Icon=madeira` (Flatpak icon renamed by `rename-icon`),
`Categories=Game;Emulator;`, `StartupWMClass=madeira`, `Actions=doctor;debug`,
and `X-AppImage-Integrate=true` so AppImage desktop-integration tools pick it
up. Validation: `desktop-file-validate` (run by the AppImage builder).

### 4.3 Permissions checklist
**AppImage (no sandbox):** document that the app exercises GPU, audio, network
and home — same trust model as any natively-run binary. Ship only from HTTPS
release URLs with `APPIMAGETOOL_SHA256` + `DXVK_SHA256` + `VKD3D_PROTON_SHA256`
pinned (unset pins emit loud warnings). Sign release tarballs with minisign.

**Flatpak `finish-args` justification (Flathub review):**

| Permission | Why |
|---|---|
| `--device=dri` | Vulkan/GL rendering (DXVK, WineD3D) |
| `--device=input` | gamepad/HOTAS via evdev+SDL |
| `--socket=x11` / `wayland` / `--share=ipc` | windowing incl. XWayland |
| `--socket=pulseaudio` | audio via PulseAudio/PipeWire-pulse |
| `--share=network` | Steam client, multiplayer, CDNs |
| `--filesystem=home:ro` | run games from existing dirs; writes go to the app's own data dir |
| `--talk-name=org.freedesktop.Notifications` | toast notifications |

Deliberately **not** granted: `--filesystem=home` (rw), `--allow=multiarch`
(unnecessary for new-WoW64), `--socket=system-bus`, `--device=all`,
`--allow=devel`. If a title needs more (e.g. rw game-dir for saves), prefe
`MADEIRA_PREFIX` + a targeted `--filesystem=xdg-data/...` override in use
docs over widening the default manifest.

**Release hygiene:**
- [ ] no Microsoft VC runtime DLLs shipped (same policy as the IPA — `tools/fetch-vcruntime.md`)
- [ ] license compliance: Wine LGPL-2.1, DXVK Zlib, VKD3D-Proton LGPL-2.1, FEX MIT → update `THIRD-PARTY-NOTICES.md` for the Linux bundle
- [ ] reproducible tarball (`--sort=name --owner=0`) + published sha256
- [ ] AppImage `--appimage-extract` smoke test on a clean distro containe
- [ ] `flatpak-builder --run … --doctor` smoke test in CI
- [ ] log dir rotation (files are timestamped; prune >30 days in a future release)

### 4.4 Known limitations
- Native Wayland driver requires Wine ≥ 9.x with the wayland driver built in;
  otherwise XWayland is mandatory (`xserver-xorg-xwayland`).
- DXVK/VKD3D versions are pinned; bump via env (`DXVK_VERSION=…`) and re-pin
  the sha256 in the same commit.
- FEX-on-Linux is experimental (the fork's iOS FEX work differs from upstream
  Linux builds); treat aarch64 builds as beta until validated.
