// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation

// The Ubisoft account's games in Madeira (docs/UBISOFT.md).
//
// Ubisoft decides ownership: the list is the account's owned PC games from
// ubi-services. Unlike Epic, Ubisoft serves no game downloads to anything but
// its own client: installs, updates and uninstalls are handed to Ubisoft
// Connect in the Wine prefix through its uplay:// protocol (the same handoff
// GOG Galaxy uses on Windows), and installed games start as their own program
// in Wine with the Connect client Madeira keeps repaired beside them. There
// is no second launcher UI to open: the library here is the front end.
// `env.MADEIRA_UBISOFT = 0` turns the whole thing off.
// Log tags: [ubisoft-library], [ubisoft-install], [ubisoft-launch] (game
// names, counts and short reason codes; never account data).

/// A game the account owns on PC.
struct UbisoftOwnedGame: Codable, Identifiable, Hashable, Sendable {
    /// The Uplay product id, as text; not every game has a numeric one.
    var productId: String
    var spaceId: String
    var name: String
    var id: String { spaceId }
    /// The product id as a number, for uplay:// calls; nil when Ubisoft's id
    /// for this game is not numeric, in which case Connect opens instead.
    var productNumber: Int? { Int(productId) }
}

/// A game Ubisoft Connect installed in the prefix: where, and how it starts.
struct UbisoftInstalledGame: Codable, Sendable, Identifiable {
    var spaceId: String?
    var launchId: Int?
    var title: String
    /// The install folder, relative to drive_c.
    var folder: String
    /// The program, relative to the install folder, with "/" separators.
    var launchExe: String
    var installBytes: Int64
    var programPath: String { folder + "/" + launchExe }
    var id: String { spaceId ?? "launch-\(launchId ?? 0)-\(folder)" }
}

@MainActor final class UbisoftLibrary: ObservableObject {
    static let shared = UbisoftLibrary()

    /// Off with `env.MADEIRA_UBISOFT = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_UBISOFT", default: true) }

    @Published private(set) var signedIn = false
    private(set) var accountID: String?
    @Published private(set) var accountName: String?
    @Published private(set) var owned: [UbisoftOwnedGame] = []
    @Published private(set) var installed: [String: UbisoftInstalledGame] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    @Published var error: String?

    private var started = false
    private let api = UbisoftAPI.shared

    private init() {}

    func game(_ spaceId: String) -> UbisoftOwnedGame? { owned.first { $0.spaceId == spaceId } }
    func installedGame(_ spaceId: String) -> UbisoftInstalledGame? { installed.values.first { $0.spaceId == spaceId } }

    // MARK: Files

    static var drive: URL { LibraryModel.drive }
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { support.appendingPathComponent("ubisoft-library.json") }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [UbisoftOwnedGame] }
    private static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Called when the library shows the Ubisoft section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        Task {
            let account = await api.account()
            signedIn = account != nil
            accountID = account?.id
            accountName = account?.name
            if let account { loadCache(account: account.id) }
            refreshInstalled()
            UbisoftLog.event("[ubisoft-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count) installed=\(installed.count)")
            if signedIn, Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
                await refreshLibrary(interactive: false)
            }
        }
    }

    private func loadCache(account: String) {
        guard let data = try? Data(contentsOf: Self.cacheURL), data.count <= 32 << 20,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1,
              cache.account == Self.accountKey(account) else { return }
        owned = cache.games; libraryUpdated = cache.updated
    }

    private func writeCache(account: String) {
        guard let updated = libraryUpdated else { return }
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(version: 1, updated: updated, account: Self.accountKey(account), games: owned))
            .write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: Account

    /// A session captured from Ubisoft's login page (UbisoftSignInView).
    func signIn(capture: UbisoftSession) async throws {
        let session = try await api.signIn(capture: capture)
        signedIn = true
        accountName = session.username
        accountID = session.userId
        owned = []; libraryUpdated = nil
        refreshInstalled()
        await refreshLibrary(interactive: true)
    }

    /// Removes the tokens and the cached list. Installed games stay.
    func signOut() {
        Task { await api.signOut() }
        try? FileManager.default.removeItem(at: Self.cacheURL)
        signedIn = false; accountName = nil; accountID = nil; owned = []; libraryUpdated = nil
    }

    private func handle(_ error: Error, context: String, report: Bool) {
        if case UbisoftAPIError.signedOut = error {
            signedIn = false; accountName = nil; accountID = nil
        }
        let reason = (error as? UbisoftAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        UbisoftLog.event("[ubisoft-library] \(context) failed reason=\(reason)")
        if report { self.error = error.localizedDescription }
    }

    // MARK: Library

    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let games = try await api.ownedGames()
                .filter { $0.isPC }
                .map { UbisoftOwnedGame(productId: $0.productId, spaceId: $0.spaceId, name: $0.name) }
            owned = games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            libraryUpdated = Date()
            if let account = await api.account() { writeCache(account: account.id); accountName = account.name }
            UbisoftLog.event("[ubisoft-library] owned games=\(owned.count)")
            refreshInstalled()
        } catch {
            handle(error, context: "library", report: interactive)
        }
    }

    // MARK: Installed games

    /// Rescans the prefix for Connect installs and gives each one its library
    /// entry (or updates the entry's program and size).
    func refreshInstalled() {
        guard Self.enabled else { return }
        let drive = Self.drive
        let prefix = LibraryModel.documents.appendingPathComponent("wine", isDirectory: true)
        let connect = LauncherSupport.resolve(.ubisoft, drive: drive)
        Task {
            let records = await Task.detached(priority: .utility) {
                UbisoftInstallScanner.scan(drive: drive, prefix: prefix, connectFolder: connect?.deletingLastPathComponent())
            }.value
            var byKey: [String: UbisoftInstalledGame] = [:]
            for record in records { byKey[record.id] = record }
            installed = byKey
            for record in records {
                // A record matched to an owned game carries its real title.
                var record = record
                if let spaceId = record.spaceId, let owned = game(spaceId) { record.title = owned.name }
                LibraryModel.shared.upsertUbisoft(record)
            }
            UbisoftLog.event("[ubisoft-library] installed=\(records.count)")
        }
    }

    // MARK: Connect handoff (install / uninstall / open)

    /// Whether Ubisoft Connect is installed in the prefix.
    var connectInstalled: Bool { LauncherSupport.resolve(.ubisoft) != nil }

    /// Starts Ubisoft Connect in the Wine desktop, optionally with a uplay://
    /// address for it to act on (install, launch or uninstall a game). This
    /// is the handoff GOG Galaxy uses on Windows: Connect does the download
    /// and the ownership check; Madeira is the front end.
    func openConnect(uri: String?) {
        guard let executable = LauncherSupport.resolve(.ubisoft) else {
            error = "Install Ubisoft Connect first: Settings › PC game launchers › Ubisoft Connect › Download, then Install silently. Then try again."
            return
        }
        guard wine_process_is_running() == 0 else {
            error = "A Wine session is already running. End it, then try again."
            return
        }
        do {
            _ = try LauncherSupport.repair(.ubisoft, executable: executable)
            var entry = try LauncherSupport.entry(for: .ubisoft, executable: executable)
            entry.arguments = uri ?? ""
            if let old = LibraryModel.shared.entries.first(where: { $0.launcherID == LauncherID.ubisoft.rawValue }) { entry.id = old.id }
            LibraryModel.shared.save(entry)
            UbisoftLog.event("[ubisoft-install] connect handoff uri=\(uri == nil ? "home" : String(uri!.prefix(24)))")
            ShortcutRouter.shared.pendingExe = nil
            ShortcutRouter.shared.pendingExe = entry.launchWindowsPath
        } catch {
            self.error = "Ubisoft Connect could not start: \(error.localizedDescription)"
        }
    }

    /// Install in Connect: `uplay://install/<product id>` when the account's
    /// id for the game is numeric, else Connect opens on its own library.
    func install(_ game: UbisoftOwnedGame) {
        if let number = game.productNumber ?? installedGame(game.spaceId)?.launchId {
            openConnect(uri: "uplay://install/\(number)")
        } else {
            openConnect(uri: nil)
        }
    }

    /// Uninstall in Connect: `uplay://uninstall/<launch id>`.
    func uninstall(_ game: UbisoftInstalledGame) {
        if let number = game.launchId ?? game.spaceId.flatMap({ self.game($0)?.productNumber }) {
            openConnect(uri: "uplay://uninstall/\(number)")
        } else {
            openConnect(uri: nil)
        }
    }
}

// MARK: - Prefix scan

/// One game in Connect's `cache/configuration/configurations`, read from its
/// embedded YAML text: the space id, name and first program, when present.
struct UbisoftConfigGame: Equatable, Sendable {
    var spaceId: String?
    var name: String?
    var exeRelative: String?
    var launchId: Int?
}

enum UbisoftInstallScanner {
    /// Connect's installed games: the registry's Launcher\Installs keys give
    /// each product's folder; the configurations give names, space ids and
    /// programs. Anything unreadable is skipped, never fatal: a game the scan
    /// cannot name still appears, titled by its folder.
    static func scan(drive: URL, prefix: URL, connectFolder: URL?) -> [UbisoftInstalledGame] {
        let manager = FileManager.default
        var configs: [UbisoftConfigGame] = []
        if let folder = connectFolder {
            let url = folder.appendingPathComponent("cache/configuration/configurations")
            if let data = try? Data(contentsOf: url), data.count <= 256 << 20 {
                configs = parseConfigurations(String(decoding: data, as: UTF8.self))
            }
        }
        var records: [UbisoftInstalledGame] = []
        for (launchId, windowsDir) in installs(prefix: prefix) {
            guard let folderURL = hostURL(ofWindowsPath: windowsDir, drive: drive) else { continue }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let config = configs.first { $0.launchId == launchId }
                ?? configs.first { candidate in
                    guard let exe = candidate.exeRelative else { return false }
                    return manager.fileExists(atPath: folderURL.appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/")).path)
                }
            guard let exe = program(in: folderURL, preferred: config?.exeRelative) else { continue }
            let relative = relativePath(of: folderURL, drive: drive)
            guard !relative.isEmpty else { continue }
            records.append(UbisoftInstalledGame(
                spaceId: config?.spaceId, launchId: launchId,
                title: config?.name ?? folderURL.lastPathComponent,
                folder: relative, launchExe: exe,
                installBytes: folderSize(folderURL)))
        }
        return records.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `Software\Ubisoft\Launcher\Installs\<id>` → InstallDir, from Wine's
    /// system.reg (both registry views). Pure, so the host checks can drive it.
    static func installs(prefix: URL) -> [Int: String] {
        guard let data = try? Data(contentsOf: prefix.appendingPathComponent("system.reg")), !data.isEmpty else { return [:] }
        return parseInstallsRegistry(String(decoding: data, as: UTF8.self))
    }

    static func parseInstallsRegistry(_ text: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var currentId: Int?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                currentId = nil
                // [Software\\Ubisoft\\Launcher\\Installs\\4] 1699999999
                let section = line.dropFirst().prefix { $0 != "]" }
                    .replacingOccurrences(of: "\\\\", with: "\\")
                let parts = section.split(separator: "\\").map { $0.lowercased() }
                if parts.count >= 4, parts[parts.count - 4] == "ubisoft", parts[parts.count - 3] == "launcher",
                   parts[parts.count - 2] == "installs", let id = Int(parts[parts.count - 1]) {
                    currentId = id
                }
                continue
            }
            guard let id = currentId, line.lowercased().hasPrefix("\"installdir\"=") else { continue }
            let value = String(line.dropFirst("\"installdir\"=".count))
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { continue }
            let unescaped = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"")
            if !unescaped.isEmpty { result[id] = unescaped }
        }
        return result
    }

    /// The configurations file is a binary container whose payloads are YAML
    /// text; the scan reads the text blocks (a block starts at a `root:` line)
    /// and takes each game's space id, name, first online program and any
    /// Installs\<id> its registry references name. Framing bytes between
    /// blocks are ignored, so a format change degrades to fewer matches, not
    /// to wrong ones. Pure, so the host checks can drive it.
    static func parseConfigurations(_ text: String) -> [UbisoftConfigGame] {
        var games: [UbisoftConfigGame] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            let game = configGame(from: current)
            if game.spaceId != nil || game.name != nil || game.exeRelative != nil { games.append(game) }
            current = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "root:" || trimmed.hasPrefix("root:") && trimmed.count <= 6 { flush() }
            // YAML lines are printable text; a line full of replacement
            // characters is framing, which ends the block.
            if trimmed.count > 0, trimmed.unicodeScalars.filter({ $0 == "\u{FFFD}" }).count > trimmed.count / 2 { flush(); continue }
            current.append(line)
        }
        flush()
        return games
    }

    private static func configGame(from lines: [String]) -> UbisoftConfigGame {
        var game = UbisoftConfigGame()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func value(_ key: String) -> String? {
                guard trimmed.lowercased().hasPrefix(key) else { return nil }
                var rest = String(trimmed.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("'"), rest.hasSuffix("'"), rest.count >= 2 { rest = String(rest.dropFirst().dropLast()) }
                if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 { rest = String(rest.dropFirst().dropLast()) }
                return rest.isEmpty ? nil : rest
            }
            if game.spaceId == nil, let space = value("space_id:") { game.spaceId = space }
            if game.name == nil, let name = value("name:") { game.name = name }
            if let relative = value("relative:"), relative.lowercased().hasSuffix(".exe"), game.exeRelative == nil {
                game.exeRelative = relative.replacingOccurrences(of: "\\", with: "/")
            }
            if game.launchId == nil,
               let range = trimmed.range(of: "Installs\\", options: .caseInsensitive) {
                let digits = trimmed[range.upperBound...].prefix { $0.isNumber }
                if let id = Int(digits) { game.launchId = id }
            }
        }
        return game
    }

    /// The game's program inside its folder: the configuration's program when
    /// it is there, else a search that skips uninstallers, the Connect client
    /// and helper programs, preferring a shallow, large executable.
    static func program(in folder: URL, preferred: String?) -> String? {
        let manager = FileManager.default
        if let preferred {
            let relative = preferred.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !relative.isEmpty, manager.fileExists(atPath: folder.appendingPathComponent(relative).path) { return relative }
        }
        let skipped = ["uninstall", "upc", "ubisoft", "uplay", "crash", "helper", "service", "redist", "setup", "support"]
        var best: (relative: String, depth: Int, size: Int64)?
        guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(folder.path.count + 1))
            let depth = relative.split(separator: "/").count
            guard depth <= 3, url.pathExtension.lowercased() == "exe",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let name = url.lastPathComponent.lowercased()
            if skipped.contains(where: { name.contains($0) }) { continue }
            let size = Int64(values.fileSize ?? 0)
            if let current = best, !(depth < current.depth || (depth == current.depth && size > current.size)) { continue }
            best = (relative, depth, size)
        }
        return best?.relative
    }

    /// C:\a\b -> <drive>/a/b; nil for another drive or a ".." element.
    static func hostURL(ofWindowsPath path: String, drive: URL) -> URL? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.count >= 3, p.prefix(3).uppercased() == "C:\\" else { return nil }
        let parts = p.dropFirst(3).split(separator: "\\").map(String.init)
        guard !parts.contains("..") else { return nil }
        return parts.reduce(drive) { $0.appendingPathComponent($1) }
    }

    static func relativePath(of folder: URL, drive: URL) -> String {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let root = drive.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return "" }
        return String(path.dropFirst(root.count + 1))
    }

    static func folderSize(_ folder: URL) -> Int64 {
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in walker {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
