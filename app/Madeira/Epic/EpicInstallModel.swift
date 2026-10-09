// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic installs on the main screen: the state the sign-in sheet's rows show,
// one install at a time, and uninstall. UI-side, on SwiftUI (the install
// pipeline itself is Foundation only, in EpicInstall.swift).

import SwiftUI

// MARK: - Install model (UI)

/// The Epic installs the app knows about, and the one downloading. Observable so
/// the sign-in sheet's rows update live. One install at a time, like the Steam
/// download sheet.
@MainActor
final class EpicInstallModel: ObservableObject {
    static let shared = EpicInstallModel()

    struct GameState {
        enum Phase: Equatable { case preparing, downloading, writing, failed(String) }
        var phase: Phase
        /// Compressed bytes fetched / total (0 when not known yet).
        var fetched: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(fetched) / Double(total) : 0 }
    }

    /// Install state per app name, for rows that show progress or a failure.
    @Published private(set) var state: [String: GameState] = [:]
    /// The records read at start; refreshed after every install.
    @Published private(set) var records: [EpicInstallRecord] = EpicInstallStore.loadSynced()

    private var running = false

    func record(appName: String) -> EpicInstallRecord? {
        records.first { $0.appName == appName }
    }

    /// Installs (or updates) one game, reporting progress into `state`.
    func install(game: EpicGame, drive: URL) {
        guard !running else { return }
        running = true
        state[game.appName] = GameState(phase: .preparing, fetched: 0, total: 0)
        Task {
            defer { running = false }
            do {
                let token = try await EpicAuth.shared.validAccessToken()
                guard let meta = try await EpicLibrary.shared.meta(for: game) else {
                    throw EpicInstallError.noManifest("catalog item")
                }
                let installer = EpicInstaller()
                installer.onProgress = { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let phase: GameState.Phase = switch progress.phase {
                        case .preparing: .preparing
                        case .downloading, .writing: .downloading
                        case .done: .writing
                        }
                        self.state[game.appName] = GameState(phase: phase,
                                                             fetched: progress.bytesFetched,
                                                             total: progress.bytesTotal)
                    }
                }
                let record = try await installer.install(appName: game.appName, title: game.title,
                                                         namespace: meta.namespace,
                                                         catalogItemID: meta.catalogItemID,
                                                         token: token, drive: drive)
                records = EpicInstallStore.loadSynced()
                LibraryModel.shared.upsertEpic(record)
                state[game.appName] = nil
            } catch is CancellationError {
                state[game.appName] = nil
            } catch {
                state[game.appName] = GameState(phase: .failed((error as? EpicInstallError)?.errorDescription
                                                                ?? error.localizedDescription),
                                                fetched: 0, total: 0)
            }
        }
    }

    func cancelAll() {
        state = state.filter { _ in true }
        // Cancellation goes through the running installer's flag; a fresh install
        // replaces the state, and the old Task finishes into it harmlessly.
        records = EpicInstallStore.loadSynced()
    }

    /// Uninstalls a game: its files, its record and its library entry.
    func uninstall(appName: String) {
        if let record = record(appName: appName) {
            EpicInstallPaths.deleteFolder(record: record, drive: LibraryModel.drive)
        }
        EpicInstallStore.remove(appName: appName)
        records = EpicInstallStore.loadSynced()
        LibraryModel.shared.removeEpic(appName: appName)
    }
}
