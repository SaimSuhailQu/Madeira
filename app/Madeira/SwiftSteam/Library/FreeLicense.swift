// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Saim Suhail
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Free-license grants over the app's own Steam connection. ClientRequestFreeLicense
// (EMsg 5012) is the message Valve's own client sends when a player takes a
// free-to-play game: Steam grants the license server-side, and their client
// still enforces it at launch. Nothing here bypasses a price, a regional
// restriction or the client's own checks — a game the account cannot have for
// free stays unowned, and eresult says so.
extension SteamSession {
    /// Asks Steam for the app's free license. Returns whether Steam granted a
    /// new license (false: the account already had one, which is fine).
    /// Throws SteamError.freeLicenseDenied when Steam refuses.
    func requestFreeLicense(appID: UInt32) async throws -> Bool {
        let request = CMsgClientRequestFreeLicense(appID: appID)
        let response = try await sendAndWait(eMsg: .clientRequestFreeLicense,
                                             body: request.serialize(),
                                             responseEMsg: .clientRequestFreeLicenseResponse)
        let parsed = try CMsgClientRequestFreeLicenseResponse.deserialize(from: response.body)
        guard parsed.eresult == 1 else {
            throw SteamError.freeLicenseDenied(appID: Int(appID), result: UInt32(bitPattern: parsed.eresult))
        }
        return parsed.grantedAppIDs.contains(appID)
    }
}
