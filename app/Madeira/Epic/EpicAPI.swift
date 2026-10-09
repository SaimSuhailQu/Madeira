// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games library: the owned-games list via the library-service API —
// the same endpoint Legendary's get_library_items uses — with cursor
// pagination. DLC and the Unreal Engine itself are filtered out.

import Foundation
import Combine

struct EpicGame: Identifiable, Codable {
    var appName: String
    var title: String
    var namespace: String
    var artworkURL: URL?
    /// The library record's catalog item id (the manifest API names it).
    var catalogItemID: String?

    var id: String { appName }
}

private struct EpicLibraryResponse: Codable {
    var records: [EpicLibraryRecord]?
    var responseMetadata: EpicResponseMetadata?
}

private struct EpicResponseMetadata: Codable {
    var nextCursor: String?
}

private struct EpicLibraryRecord: Codable {
    var appName: String?
    var title: String?
    var namespace: String?
    var id: String?
    var metadata: EpicRecordMetadata?
}

private struct EpicRecordMetadata: Codable {
    var keyImages: [EpicKeyImage]?
    var mainGameItem: EpicMainGameItem?
}

private struct EpicKeyImage: Codable {
    var type: String?
    var url: String?
}

private struct EpicMainGameItem: Codable {
    var id: String?
}

final class EpicLibrary: ObservableObject {
    static let shared = EpicLibrary()

    @Published private(set) var games: [EpicGame] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let host = "library-service.live.use1a.on.epicgames.com"
    private let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    /// Preferred artwork, tallest box art first.
    private let artworkPreference = ["DieselGameBoxTall", "DieselGameBox", "Thumbnail",
                                     "DieselStoreFrontTall", "DieselStoreFrontWide"]

    func clear() {
        games = []
        error = nil
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        Task {
            do {
                let games = try await refreshAsync()
                await MainActor.run {
                    self.games = games
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = (error as? EpicAuthError)?.message ?? error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// The owned list, fetched now (refresh() wraps it for the sheet; an install
    /// calls it when the library was never read this run).
    func refreshAsync() async throws -> [EpicGame] {
        let token = try await EpicAuth.shared.validAccessToken()
        return try await fetchAll(token: token)
    }

    private func fetchAll(token: String) async throws -> [EpicGame] {
        var records: [EpicLibraryRecord] = []
        var cursor: String? = nil
        repeat {
            let (page, next) = try await fetchPage(token: token, cursor: cursor)
            records.append(contentsOf: page)
            cursor = next
        } while cursor != nil

        return records.compactMap { record -> EpicGame? in
            guard let appName = record.appName, !appName.isEmpty,
                  let title = record.title, !title.isEmpty else { return nil }
            // DLC rides on a main game item; the 'ue' namespace is the engine itself.
            if record.metadata?.mainGameItem != nil { return nil }
            if record.namespace == "ue" { return nil }
            return EpicGame(
                appName: appName,
                title: title,
                namespace: record.namespace ?? "",
                artworkURL: Self.artwork(from: record.metadata?.keyImages, preferring: artworkPreference),
                catalogItemID: record.id
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func artwork(from images: [EpicKeyImage]?, preferring order: [String]) -> URL? {
        guard let images = images else { return nil }
        for type in order {
            if let urlString = images.first(where: { $0.type == type })?.url,
               !urlString.isEmpty, let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    /// What an install needs for a game (EpicInstall.swift): its namespace and
    /// catalog item id, from the library records already fetched. nil while the
    /// library has not listed the game.
    func meta(for game: EpicGame) async throws -> (namespace: String, catalogItemID: String)? {
        if let known = games.first(where: { $0.appName == game.appName }),
           let catalogItemID = known.catalogItemID, !catalogItemID.isEmpty {
            return (known.namespace, catalogItemID)
        }
        // The library was never fetched this run (an install without the sheet).
        let fetched = try await refreshAsync()
        await MainActor.run { self.games = fetched }
        guard let known = fetched.first(where: { $0.appName == game.appName }),
              let catalogItemID = known.catalogItemID, !catalogItemID.isEmpty else { return nil }
        return (known.namespace, catalogItemID)
    }

    private func fetchPage(token: String, cursor: String?) async throws -> ([EpicLibraryRecord], String?) {
        var components = URLComponents(string: "https://\(host)/library/api/public/items")!
        var items = [URLQueryItem(name: "includeMetadata", value: "true")]
        if let cursor = cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EpicAuthError.network }
        let decoded = try JSONDecoder().decode(EpicLibraryResponse.self, from: data)
        return (decoded.records ?? [], decoded.responseMetadata?.nextCursor)
    }
}
