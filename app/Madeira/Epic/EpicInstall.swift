// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games installs: the manifest the assets v2 API names, the chunks the
// manifest lists, and the files they build. Modeled on Legendary's
// get_game_manifest + prepare_download (legendary/core.py), without its
// multiprocess pool: one chunk at a time, cancellable, with progress.
//
// An install goes into C:\Epic Games\<app name> inside the prefix, and an
// install record into Documents (madeira-epic-installs.json) with the same
// role Steam's appmanifest has for Madeira Dock: the library lists games from
// it, and Game details' Program picker and launch profile work on the folder
// like any library game's. Foundation only, so
// tests/host/check-epic-launcher.py compiles this file as it is.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CommonCrypto

enum EpicInstallError: Error, LocalizedError {
    case notSignedIn
    case noManifest(String)
    case manifestHash
    case emptyFolderName
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to Epic Games first."
        case .noManifest(let what): return "Epic has no Windows build for this game (\(what))."
        case .manifestHash: return "The build manifest Epic served does not match its hash."
        case .emptyFolderName: return "The game's install folder could not be named."
        case .cancelled: return "The download was stopped."
        }
    }
}

// MARK: - Install record

/// One installed Epic game. Steam's appmanifest_*.acf role for the owned
/// library: the library lists games from these records, and a game's library
/// entry (LibraryEntry.epicAppName) is kept in step with them.
struct EpicInstallRecord: Codable, Equatable {
    var appName: String
    var title: String
    var namespace: String
    var catalogItemID: String
    var buildVersion: String
    /// The install folder, relative to drive_c ("Epic Games/Foo").
    var folder: String
    /// The program the manifest names, relative to the folder; may be empty.
    var launchExe: String
    /// Files on disk, from the manifest (bytes).
    var installSize: Int64
    var installedAt: Date
}

enum EpicInstallStore {
    /// The records file: beside the Documents folder (device). Where Documents
    /// does not exist (the host check on Linux), a scratch location is used so
    /// the store still round-trips.
    static var file: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if FileManager.default.fileExists(atPath: documents.path) {
            return documents.appendingPathComponent("madeira-epic-installs.json")
        }
        #if os(macOS) || os(Linux)
        return URL(fileURLWithPath: CommandLine.arguments.isEmpty ? "/tmp" : NSTemporaryDirectory(),
                    isDirectory: true).appendingPathComponent("madeira-epic-installs.json")
        #else
        return documents.appendingPathComponent("madeira-epic-installs.json")
        #endif
    }

    static func load() -> [EpicInstallRecord] {
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([EpicInstallRecord].self, from: data) else { return [] }
        return records
    }

    static func save(_ records: [EpicInstallRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Re-reads with the same date decoding save() used, so records survive.
    static func loadSynced() -> [EpicInstallRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let records = try? decoder.decode([EpicInstallRecord].self, from: data) else { return [] }
        return records
    }

    static func upsert(_ record: EpicInstallRecord) {
        var records = loadSynced()
        if let index = records.firstIndex(where: { $0.appName == record.appName }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save(records)
    }

    static func remove(appName: String) {
        var records = loadSynced()
        records.removeAll { $0.appName == appName }
        save(records)
    }
}

// MARK: - Paths

enum EpicInstallPaths {
    /// The install root, relative to drive_c — the folder a Windows Epic
    /// launcher would use ("Epic Games").
    static let rootRelative = "Epic Games"

    /// Install folders come from app names; keep them to one safe component,
    /// as SteamInstallFiles.safeFolderName does.
    static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "Game" }
        return trimmed
    }

    /// drive_c-relative install folder for an app name.
    static func folder(appName: String) -> String { rootRelative + "/" + safeFolderName(appName) }

    /// Removes an install's folder; only paths strictly inside the Epic root
    /// are removed. Returns whether anything was removed.
    static func deleteFolder(record: EpicInstallRecord, drive: URL) -> Bool {
        let root = drive.appendingPathComponent(rootRelative, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let folder = drive.appendingPathComponent(record.folder, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard folder.path.hasPrefix(root.path + "/"), folder.deletingLastPathComponent().path == root.path else { return false }
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        try? FileManager.default.removeItem(at: folder)
        return true
    }
}

// MARK: - Downloader

/// Downloads and installs one Epic game. One game at a time (the library's
/// download sheet starts one and shows its progress); cancel() stops it.
final class EpicInstaller {
    struct Progress: Equatable {
        enum Phase: Equatable { case preparing, downloading, writing, done }
        var phase: Phase = .preparing
        /// Compressed bytes fetched over the wire so far.
        var bytesFetched: Int64 = 0
        /// Compressed bytes the whole install fetches (all its unique chunks).
        var bytesTotal: Int64 = 0
        /// Uncompressed bytes written so far (files complete).
        var bytesWritten: Int64 = 0
        /// Files written so far / all files.
        var filesDone: Int = 0
        var filesTotal: Int = 0
    }

    /// The API response the assets v2 endpoint gives for one game.
    struct AssetManifestResponse {
        var hash: [UInt8]
        /// Full manifest URLs (query params folded in), in the order given.
        var urls: [String]
        var buildVersion: String
    }

    private(set) var progress = Progress()
    private let lock = NSLock()
    private var cancelled = false
    /// Called on the caller's queue as progress changes.
    var onProgress: ((Progress) -> Void)?

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func report(_ mutate: (inout Progress) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&progress)
        if let onProgress { onProgress(progress) }
    }

    // MARK: API

    /// The user agent the launcher API and CDN both expect.
    static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    private static let launcherHost = "launcher-public-service-prod06.ol.epicgames.com"

    /// Where the manifest response comes from: Epic's API (the app) or the
    /// check's fixture (tests/host/check-epic-launcher.py sets this).
    static var manifestProvider: (String, String, String, String) async throws -> AssetManifestResponse =
        manifestResponse(namespace:catalogItemID:appName:token:)

    /// The manifest URLs and expected hash for a game's Windows build.
    static func manifestResponse(namespace: String, catalogItemID: String, appName: String,
                                 token: String) async throws -> AssetManifestResponse {
        var components = URLComponents(string: "https://\(launcherHost)/launcher/api/public/assets/v2/platform/Windows" +
            "/namespace/\(namespace)/catalogItem/\(catalogItemID)/app/\(appName)/label/Live")!
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]],
              let element = elements.first else { throw EpicInstallError.noManifest("empty") }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EpicInstallError.noManifest("HTTP \(http.statusCode)")
        }
        guard let hashHex = element["hash"] as? String, hashHex.count == 40,
              let manifests = element["manifests"] as? [[String: Any]], !manifests.isEmpty else {
            throw EpicInstallError.noManifest("no manifest")
        }
        var hash = [UInt8](); hash.reserveCapacity(20)
        var index = hashHex.startIndex
        for _ in 0..<20 {
            let next = hashHex.index(index, offsetBy: 2)
            hash.append(UInt8(hashHex[index..<next], radix: 16) ?? 0)
            index = next
        }
        var urls: [String] = []
        for manifest in manifests {
            guard let uri = manifest["uri"] as? String, !uri.isEmpty else { continue }
            if let params = manifest["queryParams"] as? [[String: String]] {
                let query = params.compactMap { param -> String? in
                    guard let name = param["name"], let value = param["value"] else { return nil }
                    return "\(name)=\(value)"
                }.joined(separator: "&")
                urls.append(query.isEmpty ? uri : uri + "?" + query)
            } else {
                urls.append(uri)
            }
        }
        guard !urls.isEmpty else { throw EpicInstallError.noManifest("no CDN URL") }
        return AssetManifestResponse(hash: hash, urls: urls,
                                     buildVersion: element["buildVersion"] as? String ?? "")
    }

    // MARK: Install

    /// Installs (or updates) a game into drive_c. Returns the record written.
    /// `folderBytes` is what a fresh install occupies — the manifest's file
    /// sizes; an update reuses the existing folder.
    @discardableResult
    func install(appName: String, title: String, namespace: String, catalogItemID: String,
                 token: String, drive: URL) async throws -> EpicInstallRecord {
        let folder = EpicInstallPaths.folder(appName: appName)
        report { $0 = Progress(phase: .preparing, filesTotal: 0) }

        // The manifest: API names CDN URLs, we fetch one, check its SHA-1.
        let asset = try await Self.manifestProvider(namespace, catalogItemID, appName, token)
        guard !isCancelled else { throw EpicInstallError.cancelled }
        let manifestData = try await Self.fetchManifest(urls: asset.urls)
        guard EpicManifest.sha1(manifestData) == asset.hash else { throw EpicInstallError.manifestHash }
        let manifest = try EpicManifest.parse(manifestData)

        // Files we install: manifest names that stay inside the folder. Symlinks
        // are skipped (no Windows game install has needed them here).
        let files = manifest.files.compactMap { file -> EpicFileManifest? in
            guard file.safeRelativePath != nil, file.chunkParts.isEmpty == false else { return nil }
            return file
        }
        let emptyFiles = manifest.files.filter { $0.safeRelativePath != nil && $0.chunkParts.isEmpty }
        let installSize = manifest.files.reduce(Int64(0)) { $0 + $1.fileSize }
        let uniqueGUIDs = Set(files.flatMap { $0.chunkParts.map { $0.guidStringLower } })
        let chunkByGUID = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.guidLower, $0) })
        let bytesTotal = uniqueGUIDs.reduce(Int64(0)) { total, guid in total + (chunkByGUID[guid]?.fileSize ?? 0) }

        report {
            $0.phase = .downloading
            $0.bytesTotal = bytesTotal
            $0.filesTotal = files.count + emptyFiles.count
        }

        // The install folder: an update reuses it; a fresh install creates it.
        let root = drive.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Chunk cache for this run: a chunk shared by many files is fetched once.
        var payloads: [String: Data] = [:]
        var payloadSizes: [String: Int] = [:]

        for (fileIndex, file) in files.enumerated() {
            guard !isCancelled else { throw EpicInstallError.cancelled }
            // Fetch this file's chunks it does not have yet.
            var needed: Set<String> = []
            for part in file.chunkParts where payloads[part.guidStringLower] == nil {
                needed.insert(part.guidStringLower)
            }
            for guid in needed.sorted() {
                guard let chunkInfo = chunkByGUID[guid] else {
                    throw EpicInstallError.noManifest("chunk \(guid)")
                }
                let (header, payload) = try await Self.fetchChunk(chunkInfo, path: chunkInfo.path(featureLevel: manifest.meta.featureLevel), baseFrom: asset.urls)
                guard header.guidLower == guid else {
                    throw EpicInstallError.noManifest("chunk \(guid) came back as \(header.guidLower)")
                }
                payloads[guid] = payload
                payloadSizes[guid] = payload.count
                report { $0.bytesFetched += Int64(chunkInfo.fileSize) }
            }
            // Write the file.
            let relative = file.safeRelativePath!
            let target = root.appendingPathComponent(relative)
            let dir = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = EpicChunk.assemble(parts: file.chunkParts, payloads: payloads)
            guard data.count == Int(file.fileSize) else {
                throw EpicInstallError.noManifest("\(relative) built \(data.count) of \(file.fileSize) bytes")
            }
            try data.write(to: target, options: .atomic)
            report {
                $0.bytesWritten += Int64(file.fileSize)
                $0.filesDone = fileIndex + 1
            }
            // A window no later file needs can be dropped.
            let laterGUIDs = Set(files[(fileIndex + 1)...].flatMap { $0.chunkParts.map { $0.guidStringLower } })
            payloads = payloads.filter { laterGUIDs.contains($0.key) }
        }

        // Empty files (flags-only entries): create them.
        for file in emptyFiles {
            guard let relative = file.safeRelativePath else { continue }
            let target = root.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                _ = FileManager.default.createFile(atPath: target.path, contents: Data())
            }
            report { $0.filesDone += 1 }
        }

        let record = EpicInstallRecord(appName: appName, title: title, namespace: namespace,
                                       catalogItemID: catalogItemID, buildVersion: manifest.meta.buildVersion.isEmpty ? asset.buildVersion : manifest.meta.buildVersion,
                                       folder: folder, launchExe: manifest.meta.launchExe,
                                       installSize: installSize, installedAt: Date())
        EpicInstallStore.upsert(record)
        report { $0.phase = .done }
        return record
    }

    // MARK: Fetch helpers

    /// Fetches the manifest from the first URL that answers.
    static func fetchManifest(urls: [String]) async throws -> Data {
        var lastError: Error = EpicInstallError.noManifest("no URL tried")
        for url in urls {
            guard let requestURL = URL(string: url) else { continue }
            var request = URLRequest(url: requestURL)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { continue }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Fetches one chunk, trying the base URL of each manifest URL in order.
    static func fetchChunk(_ chunk: EpicChunkInfo, path: String, baseFrom urls: [String]) async throws -> (EpicChunk, Data) {
        var lastError: Error = EpicInstallError.noManifest("no CDN tried")
        let bases = urls.compactMap { $0.split(separator: "?").first.map(String.init) }
            .compactMap { URL(string: $0)?.deletingLastPathComponent() }
        var tried = Set<String>()
        for base in bases where !tried.contains(base.absoluteString) {
            tried.insert(base.absoluteString)
            guard let url = URL(string: base.absoluteString + path) else { continue }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { continue }
                let (header, payload) = try EpicChunk.parse(data)
                guard header.shaHash == chunk.shaHash || chunk.shaHash.isEmpty else {
                    throw EpicInstallError.noManifest("chunk hash mismatch")
                }
                return (header, payload)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

private extension EpicChunk {
    var guidLower: String {
        String(format: "%08x-%08x-%08x-%08x", guid.0, guid.1, guid.2, guid.3)
    }
}

