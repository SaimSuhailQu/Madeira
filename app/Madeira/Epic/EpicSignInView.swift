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
                        Text("Madeira lists your Epic library so you can see your games. Installing them arrives in the next update.")
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
                Button("Sign out", role: .destructive) {
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
                                Text("Installs in a later update")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Refresh") { library.refresh() }
                }
            }
        }
    }
}
