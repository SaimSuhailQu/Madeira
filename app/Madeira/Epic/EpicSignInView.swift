// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games sign-in sheet: log in on Epic's site in an embedded web view
// (the authorizationCode is captured automatically), or paste one manually.
// When signed in it shows the account and the owned-games list.

import SwiftUI

struct EpicSignInView: View {
    @ObservedObject private var auth = EpicAuth.shared
    @ObservedObject private var library = EpicLibrary.shared
    @ObservedObject private var installs = EpicInstallModel.shared
    /// Opens a game's Game details page after its install (LibraryView passes it).
    var openEntry: ((LibraryEntry) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var showPaste = false
    @State private var pastedCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Sign in to Epic Games", systemImage: "person.crop.circle.fill").font(.title2.bold())
                        Text("Madeira lists your Epic library, installs the Windows build of a game into the Wine prefix, and starts it like any library game.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if let name = auth.accountName {
                    signedInSection(name)
                } else {
                    Section {
                        Button("Sign in with Epic") { showLogin = true }
                            .disabled(auth.isBusy)
                        Button("Paste an authorization code instead") { showPaste.toggle() }
                            .font(.footnote)
                    }
                    if showPaste { pasteSection }
                }
                if let error = auth.signInError ?? library.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Text("Madeira signs in with Epic directly. Your password is entered on Epic's site and is never stored. Tokens are kept in this device's Keychain until you sign out.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Epic Games").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(auth.signedIn ? "Done" : "Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                NavigationStack {
                    EpicLoginWebView { code in
                        showLogin = false
                        auth.exchange(authorizationCode: code)
                    }
                    .navigationTitle("Epic sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showLogin = false }
                        }
                    }
                }
            }
            .onAppear {
                auth.refresh()
                if auth.signedIn { library.refresh() }
            }
            .onChange(of: auth.accountName) { _, name in
                if name != nil { library.refresh() } else { library.clear() }
            }
        }
    }

    private var pasteSection: some View {
        Section("Authorization code") {
            Text("Log in at epicgames.com in your browser, open the redirect page, and paste the authorizationCode value (or the whole JSON).")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("authorizationCode", text: $pastedCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Sign in") {
                auth.exchange(authorizationCode: EpicAuth.extractCode(from: pastedCode))
                pastedCode = ""
                showPaste = false
            }
            .disabled(pastedCode.isEmpty || auth.isBusy)
        }
    }

    private func signedInSection(_ name: String) -> some View {
        Group {
            Section("Account") {
                Label(name, systemImage: "person.crop.circle.fill")
                Button("Refresh library") { library.refresh() }
                Button("Sign out", role: .destructive) {
                    installs.cancelAll()
                    auth.signOut()
                    library.clear()
                }
            }
            Section("Your games (\(library.games.count))") {
                if library.isLoading {
                    ProgressView()
                } else if library.games.isEmpty {
                    Text("No games found.").foregroundStyle(.secondary)
                    Button("Refresh") { library.refresh() }
                } else {
                    ForEach(library.games) { game in
                        EpicGameRow(game: game,
                                    install: installs.state[game.appName],
                                    installed: installs.record(appName: game.appName)) {
                            installs.install(game: game, drive: LibraryModel.drive)
                        } onOpen: {
                            openInstalled(game)
                        }
                    }
                }
            }
        }
    }

    /// Opens an installed Epic game's library entry (its Game details page).
    private func openInstalled(_ game: EpicGame) {
        guard let record = installs.record(appName: game.appName) else { return }
        let entry = LibraryModel.shared.epicEntry(record)
        dismiss()
        // After the sheet finishes dismissing, as SteamGameSheet does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openEntry?(entry) }
    }
}

/// One game's row: artwork, title, and its install state — Install, a progress
/// bar while downloading, Play once installed (the entry opens Game details,
/// whose Play starts the game as for any library game).
private struct EpicGameRow: View {
    let game: EpicGame
    let install: EpicInstallModel.GameState?
    let installed: EpicInstallRecord?
    let onInstall: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let url = game.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 44, height: 44)
                .cornerRadius(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.headline)
                switch install?.phase {
                case .preparing:
                    Text("Preparing...").font(.caption).foregroundStyle(.secondary)
                case .downloading:
                    if let install {
                        Text("Downloading \(Int(install.fraction * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: install.fraction)
                    }
                case .failed(let reason):
                    Text("Download failed: \(reason)").font(.caption).foregroundStyle(.red)
                    Button("Try again") { onInstall() }.font(.caption)
                case .none:
                    if installed != nil {
                        Button("Play") { onOpen() }
                            .font(.caption).buttonStyle(.borderedProminent)
                    } else {
                        Button("Install") { onInstall() }
                            .font(.caption).buttonStyle(.bordered)
                    }
                default:
                    Text("Finishing...").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .disabled(install != nil && install.phase != .failed)
    }
}
