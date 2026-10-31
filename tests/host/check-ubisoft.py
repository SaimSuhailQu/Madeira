#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Static host checks for the Ubisoft Connect library (docs/UBISOFT.md).

Never contacts Ubisoft. Checks, in the style of check-epic-games.py Part A:

* every Ubisoft source file exists, carries the licence header, and is
  registered in the Xcode project (build file, file reference, group child
  and Sources build phase) — the check whose absence let a pbxproj merge
  silently drop files in October 2026;
* the Keychain item is device-only and non-synchronizable;
* no log line carries a ticket, remember-me ticket or session id value;
* the wiring is present: the library section, Settings section and sign-in
  sheet case, the Game details section, the kill switch, and Ubisoft games
  kept out of Other games.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
app = root / "app/Madeira"
sources = [app / "UbisoftLibrary.swift", app / "UbisoftGames.swift",
           app / "SwiftUbisoft/UbisoftAPI.swift"]
project = (app.parent / "Madeira.xcodeproj/project.pbxproj").read_text()
library = (app / "Library.swift").read_text()
content = (app / "ContentView.swift").read_text()
failures = 0


def require(condition, label):
    global failures
    print(("PASS: " if condition else "FAIL: ") + label)
    if not condition:
        failures += 1


for path in sources:
    require(path.exists(), f"{path.name} exists")
    if not path.exists():
        continue
    text = path.read_text()
    require("SPDX-License-Identifier: GPL-3.0-or-later" in text,
            f"{path.name} carries the licence header")
    # Registration: file reference path, group child, build file, Sources phase.
    rel = str(path.relative_to(app))
    require(f'path = "{rel}"' in project, f"{path.name} has a file reference")
    ref = re.search(r'(A[0-9A-F]+) /\* ' + re.escape(path.name) + r' \*/ = \{isa = PBXFileReference', project)
    require(ref is not None, f"{path.name} file reference id found")
    if ref:
        require(f"{ref.group(1)} /* {path.name} */," in project,
                f"{path.name} is a group child")
        build = re.search(r'(A[0-9A-F]+) /\* ' + re.escape(rel) + r' in Sources \*/ = \{isa = PBXBuildFile; fileRef = '
                          + ref.group(1), project)
    require(build is not None, f"{path.name} has a build file")
    if build:
        require(f"{build.group(1)} /* {rel} in Sources */," in project,
                f"{path.name} is in the Sources build phase")
    # No credential values in log lines.
    for line in text.splitlines():
        if "Log.event" in line or ".log(" in line:
            require("ticket" not in line.lower() and "rememberme" not in line.lower()
                    and "sessionId" not in line,
                    f"{path.name}: log line carries no credential: {line.strip()[:60]}")

api = (app / "SwiftUbisoft/UbisoftAPI.swift").read_text()
require("kSecAttrAccessibleWhenUnlockedThisDeviceOnly" in api, "Keychain item is device-only")
require("kSecAttrSynchronizable as String: false" in api, "Keychain item is not synchronizable")
require('"madeira.ubisoft.tokens"' in api, "Keychain service is madeira.ubisoft.tokens")
require("MADEIRA_UBISOFT" in (app / "UbisoftLibrary.swift").read_text(), "kill switch MADEIRA_UBISOFT present")
require("UbisoftGamesSection" in library, "library shows the Ubisoft section")
require("UbisoftSettingsSection" in library, "Settings shows the Ubisoft section")
require("case allSettings, steamSignIn, epicSignIn, ubisoftSignIn, dock" in library,
        "SettingsSheet has the ubisoftSignIn case")
require("UbisoftSignInView()" in library and "UbisoftSignInView()" in content,
        "both settings sheets present the Ubisoft sign-in")
require("UbisoftEntrySection" in library, "Game details shows the Ubisoft section")
require("$0.ubisoftSpaceId == nil" in library, "Other games keeps Ubisoft games out")
require("var ubisoftSpaceId: String?" in library and "var ubisoftLaunchId: Int?" in library,
        "LibraryEntry carries the Ubisoft fields")
games = (app / "UbisoftGames.swift").read_text()
require("customUserAgent" in games and "desktopUserAgent" in games and "Macintosh" in games,
        "sign-in web view presents a desktop Safari user agent (desktop page, engine-consistent)")
require("websiteDataStore = .default()" in games,
        "sign-in web view keeps a persistent data store (the anti-bot check's cookies must survive)")
require("runJavaScriptAlertPanelWithMessage" in games and "runJavaScriptConfirmPanelWithMessage" in games,
        "sign-in web view answers JavaScript dialogs")
require("change_domain" in games and "handedOff" in games,
        "sign-in capture falls back to the relay page when the post-login page stalls")
require("deepValue" in api and "captureParts" in api,
        "session parsing searches nested payloads and reports storage parts by label only")

print("FAILURES:", failures)
sys.exit(1 if failures else 0)
