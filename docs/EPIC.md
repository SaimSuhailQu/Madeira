# Epic Games integration

Native Epic Games support in Madeira, modeled on Legendary's protocol work
(https://github.com/derrod/legendary). Milestone 1 (this change): sign in and
list owned games. Milestone 2: download and install games.

## Milestone 1 — sign in + library (done)

**Files** (`app/Madeira/Epic/`):

- `EpicAuth.swift` — OAuth through Epic's site. The user logs in in an embedded
  `WKWebView`; Madeira captures the `authorizationCode` from Epic's redirect
  page (`/id/api/redirect`, JSON body) and exchanges it at
  `account-public-service-prod03.ol.epicgames.com/account/api/oauth/token`
  (grant `authorization_code`, HTTP Basic with Epic's public launcher client
  credentials — the same ones Legendary uses). A manual paste fallback takes
  the raw code or the whole JSON, like Legendary's CLI. Tokens are refreshed
  with `grant_type=refresh_token` and kept in the Keychain
  (`madeira.epic.tokens`); the password never touches the app.
- `EpicAPI.swift` — owned games via
  `library-service.live.use1a.on.epicgames.com/library/api/public/items`
  (the endpoint Legendary's `get_library_items` uses), with cursor pagination.
  DLC (records with `mainGameItem`) and the `ue` namespace are filtered out;
  artwork prefers `DieselGameBoxTall` → `DieselGameBox` → `Thumbnail`.
- `EpicSignInView.swift` — sign-in sheet wired into `SettingsSheet.epicSignIn`
  with an "Epic sign-in" button next to Steam's. Signed-in users see their
  account and their games list (artwork + title).

**Why not a full Legendary port for milestone 1:** auth and the library
listing are the stable, thin parts of Epic's API (OAuth + one paginated GET).
The churny, complex part is the download engine — that is where riding
Legendary's maintenance pays off, and it is scoped for milestone 2.

## Milestone 2 — downloads (planned)

Port Legendary's manifest/chunk pipeline (`legendary/downloader/`):

1. **Manifests**: for each owned game, fetch the artifact/manifest list
   (`artifact-public-service-prod.beee.live.use1a.on.epicgames.com`), pick the
   Windows build, download its chunk manifest.
2. **Chunks**: download from Epic's CDN with resume, verify per-chunk hashes,
   assemble into `drive_c/Program Files/Epic Games/<game>/`. Reuse Madeira's
   existing background-download UI patterns (`SteamDownloadBackground`).
3. **Launch**: most Epic games are DRM-free once downloaded — register the
   installed exe as a `LibraryEntry` (with the per-game FEX/GPU settings the
   library already supports). Games that insist on EOS/overlay stay
   launch-through-Epic-Games-Launcher (see below).

**Decision point:** whether to vendor Legendary's Python downloader behind an
embedded interpreter (inherits upstream fixes for free) or port the
manifest/chunk logic to Swift (no runtime dependency, but we own every future
Epic API change). The manifest format is the part most likely to move —
vendoring is the robust default.

## Ubisoft

No native path: no open protocol reference exists (nothing like Legendary),
and Ubisoft's DRM requires the Connect client running. The realistic
integration is installing Ubisoft Connect's Windows client in the Wine prefix
as a guided launcher entry — same approach as the Epic Games Launcher
fallback. Not started.

## Sekiro (FEX preset)

`LibraryEntry` already supports per-game `FEX_X87REDUCEDPRECISION` and
`MADEIRA_CPU_COUNT`; `WineProcessBridge.m` exports any `FEX_*` env var, so a
general per-game FEX overrides map is a small addition. Ship a researched
Sekiro preset (TSO/multiblock/SMC) on top. Not started.
