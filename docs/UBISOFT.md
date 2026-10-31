# Ubisoft Connect

Madeira can sign in to Ubisoft, list owned PC games, show the games Ubisoft
Connect has installed in the prefix, and start them through Wine and FEX. It
does not download games itself: Ubisoft serves game files only to its own
client, so installs, updates and uninstalls are handed to the Ubisoft Connect
client in the prefix through its `uplay://` protocol — the same handoff GOG
Galaxy uses on Windows. The protocol work follows the GOG Galaxy Uplay
integration (FriendsOfGalaxy/galaxy-integration-uplay) and the unofficial
ubi-services reference (wnc-replay.github.io/ubi-docs).

## Source

- `app/Madeira/SwiftUbisoft/UbisoftAPI.swift`: web-login ticket capture, the
  device-only Keychain ticket item, ticket and remember-me refresh, and the
  owned-games GraphQL query.
- `app/Madeira/UbisoftLibrary.swift`: the account, owned cache, the prefix
  install scan (registry Installs keys + Connect's configurations), library
  entries, and the Connect handoff.
- `app/Madeira/UbisoftGames.swift`: sign-in, library, game sheet and
  game-detail views, and Settings › Ubisoft Connect.
- `app/Madeira/LauncherSupport.swift`: the Connect client itself — silent
  install, the legacy Uplay.exe aliases and registry both registry views need,
  and the `uplay://` / `ubisoft-connect://` protocol handlers in the prefix.

## Account and game files

Sign in under Settings > Ubisoft Connect, with the account's email and
password. Madeira sends them to Ubisoft's session service in one HTTPS
call — `POST /v3/profiles/sessions`, the login Ubisoft's own mobile app
makes — and keeps only the ticket it buys. The password builds the
request and is never stored or logged. If the club app id refuses a
password login, the same credentials go in under the mobile app id and
the session is exchanged for a club-bound one, because tickets are bound
to the app id that issued them. An account with 2-Step Verification
answers the login with a two-factor ticket instead of a session; the
sheet then asks for the 6-digit code and completes the same call
(`Ubi_2fa_v1` + `ubi-2facode`). The ticket lives in one Keychain item
for this device only; refresh is a ticket exchange
(`PUT /v3/profiles/sessions`), with the remember-me ticket (`rm_v1`)
as the fallback.

The sheet also offers the older route, Ubisoft's own login page in a web
view, for accounts the direct sign-in refuses. Device reports
(2026-10-30/31) showed why it is the fallback and not the front door:
with a phone user agent the page serves an app interstitial whose button
deep-links to the Connect app instead of showing the form; dressed as
desktop Chrome, Ubisoft's anti-bot filter blocked the sheet while the
same login in the phone's real browser went through; dressed as desktop
Safari (the presentation it keeps — desktop page variant, WebKit family,
persistent website data store) the login completed, but the heavy
post-login page stalled blank more than once, its wedged script context
never answering the session read — Madeira then moves the view to
Ubisoft's `change_domain` relay page, a light document on the same
origin where the same storage answers, the handoff the GOG integration
performs. In that flow the password stays inside Ubisoft's page and is
never seen by Madeira at all.

Ubisoft checks ownership when it serves the owned
list: `POST /v1/profiles/me/uplay/graphql`, the club `AllGames` query, filtered
to games whose owned platform groups include PC.

Installed games are found in the prefix, not downloaded: Wine's `system.reg`
`Software\Ubisoft\Launcher\Installs\<product id>` keys name each install
folder, and Connect's `cache/configuration/configurations` (read as the YAML
text it embeds) names each game's space id, title and program. A scan that
cannot read either source degrades to fewer matches, never to wrong ones.
Each installed game gets a normal library entry; Play starts its own program,
and `LauncherSupport.prepare` repairs the legacy Uplay surface before the
launch, as for any other game.

Install and uninstall start Connect in the Wine desktop with
`uplay://install/<product id>` or `uplay://uninstall/<product id>` as its
argument (the product id is the GraphQL game id when it is numeric, else the
install's registry id; when neither is known Connect simply opens). Connect
needs its own sign-in inside Wine the first time, as on Windows.

## Legacy games

Older Uplay games (Assassin's Creed II and its era) only run as their current
Ubisoft Connect edition: their original Uplay stub updates from servers that
no longer answer. Installing the game from Madeira's Ubisoft section makes
Connect lay down the current edition. The Game details page and
Settings › PC game launchers offer Repair Uplay, which recreates the
`Uplay.exe` / `UbisoftGameLauncher.exe` aliases and both registry views those
games look for.

## Checks and limits

`python3 tests/host/check-ubisoft.py` is static: licence headers, every
Ubisoft source registered in the Xcode project (build file, file reference,
group and Sources phase), the Keychain item is device-only, no ticket or
remember-me value in a log line, and the library keeping Ubisoft games out of
Other games. The parsers (`UbisoftAPI.parseOwnedGames`,
`UbisoftInstallScanner.parseInstallsRegistry` / `parseConfigurations`) are
pure and written to be driven by fixtures, but no host fixture run exists
yet — the first one needs a captured configurations file from a real prefix.

Live Ubisoft sign-in, a real `uplay://install`, Connect's behaviour under
Wine/FEX and gameplay still need device checks. Ubisoft's endpoints are
unofficial and may change without notice; the app ids in particular have
rotated before (the GOG integration has had to update them), and a rotation
shows up as sign-in failing until `UbisoftAPI.appId` / `genomeId` are updated.
Covers are not fetched: Ubisoft's services give Madeira no artwork for these
games, so cards use the library entry's chosen cover or a placeholder.
Cloud saves stay Connect's job, in the prefix.
