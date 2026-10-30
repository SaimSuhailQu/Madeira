// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import WebKit

// The library's Ubisoft Connect section, a game's sheet, its Game details
// section, Settings › Ubisoft Connect and the sign-in sheet (docs/UBISOFT.md).

/// One game in the section: owned, installed by Ubisoft Connect, or both.
struct UbisoftItem: Identifiable {
    let id: String
    var title: String
    var owned: UbisoftOwnedGame?
    var installed: UbisoftInstalledGame?
}

enum UbisoftGamesRules {
    /// Installed games and the account's other games, by title, filtered by the search.
    @MainActor static func items(_ ubisoft: UbisoftLibrary, search: String) -> [UbisoftItem] {
        var items: [String: UbisoftItem] = [:]
        for game in ubisoft.owned {
            items[game.spaceId] = UbisoftItem(id: game.spaceId, title: game.name, owned: game)
        }
        for record in ubisoft.installed.values {
            if let spaceId = record.spaceId, items[spaceId] != nil {
                items[spaceId]?.installed = record
                items[spaceId]?.title = record.title
            } else {
                items[record.id] = UbisoftItem(id: record.id, title: record.title, installed: record)
            }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.values
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension LibraryModel {
    /// An installed Ubisoft game's library entry (its Game details page and
    /// settings); a game without one gets a new entry, saved when its details
    /// page closes.
    func ubisoftEntry(_ game: UbisoftInstalledGame) -> LibraryEntry {
        if var entry = entries.first(where: {
            (game.spaceId != nil && $0.ubisoftSpaceId == game.spaceId) ||
                (game.launchId != nil && $0.ubisoftLaunchId == game.launchId)
        }) {
            entry.relativePath = game.programPath
            return entry
        }
        var entry = LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.ubisoftSpaceId = game.spaceId
        entry.ubisoftLaunchId = game.launchId
        entry.folderBytes = game.installBytes
        return entry
    }
}

// MARK: - Library section

struct UbisoftGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var ubisoft = UbisoftLibrary.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideUbisoft") private var hidden = false
    @AppStorage("madeiraUbisoftShowUninstalled") private var showUninstalled = true
    @State private var selected: UbisoftSelection?
    @State private var showSignIn = false

    private struct UbisoftSelection: Identifiable { let id: String }

    var body: some View {
        let items = UbisoftGamesRules.items(ubisoft, search: search)
        let mine = items.filter { $0.installed != nil }
        let others = items.filter { $0.installed == nil }
        let collapsible = SteamGamesSection.collapsible
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "Ubisoft Connect", count: mine.count, collapsed: collapsible ? $hidden : nil) {
                if ubisoft.refreshing { ProgressView().accessibilityLabel("Refreshing Ubisoft library") }
            }
            if !(hidden && collapsible) {
                if !ubisoft.signedIn {
                    UbisoftSignInCard { showSignIn = true }
                }
                if !mine.isEmpty {
                    LibraryCells(items: mine, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                } else if ubisoft.signedIn && !ubisoft.refreshing && others.isEmpty && search.isEmpty {
                    Text(ubisoft.libraryUpdated == nil ? "Pull down to load your Ubisoft library."
                         : "No PC games were found in this Ubisoft library.").foregroundStyle(.secondary)
                }
                if ubisoft.signedIn && !others.isEmpty {
                    Button {
                        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { showUninstalled.toggle() }
                    } label: {
                        HStack {
                            Text("Not installed").font(.headline)
                            Text("\(others.count)").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showUninstalled ? 90 : 0)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle()).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                        .accessibilityValue(showUninstalled ? "Shown" : "Hidden")
                    if showUninstalled {
                        LibraryCells(items: others, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                    }
                }
            }
        }
        .onAppear { ubisoft.start() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { ubisoft.refreshInstalled() } }
        .sheet(item: $selected) { selection in
            UbisoftGameSheet(itemId: selection.id) { entry in
                // Let the game sheet finish dismissing before presenting the details page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .sheet(isPresented: $showSignIn) { UbisoftSignInView() }
        .alert("Ubisoft Connect", isPresented: Binding(get: { ubisoft.error != nil }, set: { if !$0 { ubisoft.error = nil } })) {
            Button("OK", role: .cancel) { ubisoft.error = nil }
        } message: { Text(ubisoft.error ?? "") }
    }

    private func cell(_ item: UbisoftItem, list: Bool, dense: Bool) -> some View {
        Button {
            if let installed = item.installed {
                open(library.ubisoftEntry(installed))
            } else {
                selected = UbisoftSelection(id: item.id)
            }
        } label: { UbisoftGameCell(item: item, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }
}

/// The signed-out section's invitation to sign in.
struct UbisoftSignInCard: View {
    var signIn: () -> Void
    var body: some View {
        Button(action: signIn) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Ubisoft Connect").font(.headline)
                    Text("See your Ubisoft games here and install them without opening the Connect app yourself.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

/// A game's artwork: the library entry's cover once one is chosen, else a
/// placeholder (Ubisoft's services give Madeira no cover art for these games).
struct UbisoftGameArtwork: View {
    let item: UbisoftItem
    @ObservedObject private var library = LibraryModel.shared
    var body: some View {
        if let entry = library.entries.first(where: {
            $0.ubisoftSpaceId == item.id || (item.installed != nil && $0.ubisoftLaunchId == item.installed?.launchId)
        }), entry.coverFile != nil {
            LibraryArtwork(entry: entry)
        } else {
            GeometryReader { geometry in
                ZStack {
                    Color(uiColor: .secondarySystemFill)
                    Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.accessibilityHidden(true)
        }
    }
}

struct UbisoftGameCell: View {
    let item: UbisoftItem
    var list = false
    var dense = false
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let entry = library.entries.first {
            $0.ubisoftSpaceId == item.id || (item.installed != nil && $0.ubisoftLaunchId == item.installed?.launchId && item.installed?.launchId != nil)
        }
        Group {
            if list && dense {
                HStack(spacing: 10) {
                    UbisoftGameArtwork(item: item).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    pills(entry).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    UbisoftGameArtwork(item: item).frame(width: 48, height: 72)
                        .overlay { if item.installed == nil { notDownloaded } }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline).lineLimit(2)
                        pills(entry)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    UbisoftGameArtwork(item: item).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { if item.installed == nil { notDownloaded } }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    pills(entry)
                }.padding(4)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .task(id: entry?.id, priority: .utility) { if let id = entry?.id { await library.refreshMetadata(id) } }
    }

    @ViewBuilder private func pills(_ entry: LibraryEntry?) -> some View {
        if item.installed != nil, let entry {
            LibraryBadges(entry: entry).foregroundStyle(.secondary)
        } else if item.installed == nil {
            badge("Not installed")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.secondary)
    }

    private var notDownloaded: some View {
        ZStack {
            Color.black.opacity(0.4)
            Image(systemName: "icloud.and.arrow.down").font(.largeTitle.weight(.medium)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Game sheet

struct UbisoftGameSheet: View {
    let itemId: String
    /// Opens the installed game's Game details page (after this sheet closes).
    var open: (LibraryEntry) -> Void
    @ObservedObject private var ubisoft = UbisoftLibrary.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let item = UbisoftGamesRules.items(ubisoft, search: "").first { $0.id == itemId }
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            UbisoftGameArtwork(item: item).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.title).font(.title2.bold())
                                primaryAction(item)
                            }
                        }.padding(.vertical, 24)
                    }
                    if let installed = item.installed {
                        Section {
                            Button { ubisoft.uninstall(installed) } label: { Label("Uninstall in Ubisoft Connect", systemImage: "trash") }
                            Button { ubisoft.openConnect(uri: nil) } label: { Label("Open Ubisoft Connect", systemImage: "arrow.up.forward.app") }
                        } footer: {
                            Text("Connect removes the game's files; Madeira's entry for it is cleaned up the next time the library is scanned without it.")
                        }
                    }
                    Section {
                        Text("Installs and updates run in Ubisoft Connect inside the Wine desktop — Ubisoft serves game files only to its own client, which also checks ownership when a game starts. Madeira hands Connect the game to install, so you do not have to find it in Connect's own screens.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Older Uplay games — Assassin's Creed II and its era — only run as their current Ubisoft Connect edition. If a copy installed from an old disc or backup folder reports Uplay missing or fails to start, install the game from here instead: Connect replaces it with the current edition. If it still complains, Settings › PC game launchers › Ubisoft Connect › Repair Uplay fixes the legacy names and registry it looks for.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your Ubisoft library and try again."))
                }
            }
            .navigationTitle("Ubisoft Connect").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private func primaryAction(_ item: UbisoftItem) -> some View {
        if let installed = item.installed {
            Button {
                let entry = LibraryModel.shared.ubisoftEntry(installed)
                dismiss(); open(entry)
            } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if let owned = item.owned {
            Button { ubisoft.install(owned); dismiss() } label: {
                steamActionLabel("Install in Ubisoft Connect", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!ubisoft.signedIn)
        }
    }
}

// MARK: - Game details

/// The Ubisoft Connect section of a Ubisoft game's Game details page.
struct UbisoftEntrySection: View {
    @Binding var entry: LibraryEntry
    @ObservedObject private var ubisoft = UbisoftLibrary.shared
    @ObservedObject private var support = LauncherSupportModel.shared

    var body: some View {
        let record = ubisoft.installed.values.first {
            (entry.ubisoftSpaceId != nil && $0.spaceId == entry.ubisoftSpaceId) ||
                (entry.ubisoftLaunchId != nil && $0.launchId == entry.ubisoftLaunchId)
        }
        Section {
            if !ubisoft.signedIn {
                Text("Sign in to Ubisoft Connect in Settings › Ubisoft Connect to see this game in your account library and install updates.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let spaceId = entry.ubisoftSpaceId { LabeledContent("Space ID", value: spaceId) }
            if let launchId = entry.ubisoftLaunchId { LabeledContent("Product ID", value: String(launchId)) }
            Button { support.repair(.ubisoft) } label: { Label("Repair Uplay compatibility", systemImage: "wrench.and.screwdriver") }
            Text("Recreates the legacy Uplay.exe names and registry older games (Assassin's Creed II and its era) look for. Safe to run any time Connect is installed.")
                .font(.caption).foregroundStyle(.secondary)
            if let record {
                Button { ubisoft.uninstall(record) } label: { Label("Uninstall in Ubisoft Connect", systemImage: "trash") }
            }
        } header: {
            Text("Ubisoft Connect")
        } footer: {
            Text("The game starts its own program in Wine. Ubisoft Connect, installed beside it in the prefix, answers its ownership check, as it does on Windows. There is no Ubisoft sign-in code for Madeira to pass, unlike Epic.")
        }
        .onAppear { support.refresh(); ubisoft.start() }
    }
}

// MARK: - Settings

struct UbisoftSettingsSection: View {
    let open: (SettingsSheet) -> Void
    @ObservedObject private var ubisoft = UbisoftLibrary.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if ubisoft.signedIn {
                LabeledContent("Signed in as", value: ubisoft.accountName ?? "Ubisoft account")
                Button("Sign out of Ubisoft Connect", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.ubisoftSignIn) } label: { Label("Sign in to Ubisoft Connect", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("Ubisoft Connect")
        } footer: {
            Text("Madeira keeps a Ubisoft sign-in ticket in this device's Keychain, for this device only — never your password. Signing out removes it; installed games stay. Game installs run in the Ubisoft Connect client under Settings › PC game launchers.")
        }
        .onAppear { ubisoft.start() }
        .confirmationDialog("Sign out of Ubisoft Connect?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { ubisoft.signOut() }
        }
    }
}

// MARK: - Sign-in

/// Ubisoft's own login page in a web view. When the login finishes, the page's
/// local storage holds the session ticket; Madeira reads it and signs in. The
/// password and any two-factor step stay inside Ubisoft's page.
struct UbisoftSignInView: View {
    @ObservedObject private var ubisoft = UbisoftLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if ubisoft.signedIn {
                    Form {
                        LabeledContent("Signed in as", value: ubisoft.accountName ?? "Ubisoft account")
                        Button("Sign out", role: .destructive) { ubisoft.signOut() }
                    }
                } else {
                    UbisoftLoginWebView(reload: reload) { capture in submit(capture) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if busy {
                                ProgressView("Signing in…").padding(20)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                }
            }
            .navigationTitle("Ubisoft Connect").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !ubisoft.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Reload", systemImage: "arrow.clockwise") { reload += 1 }
                    }
                }
            }
            .alert("Ubisoft Connect", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil; reload += 1 }
            } message: { Text(failure ?? "") }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let capture = UbisoftAPI.session(fromCapture: text) else {
            failure = "Ubisoft's login did not leave a session Madeira can use. Finish signing in, wait for the Connect home page, then try again."
            return
        }
        busy = true
        Task {
            do {
                try await ubisoft.signIn(capture: capture)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

/// WKWebView with Ubisoft's login page, in a private (non-persistent) data
/// store. The coordinator polls the page's local storage after each load and
/// on a timer, because the login finishes with in-page redirects.
///
/// The view presents a desktop Chrome user agent: with a phone user agent
/// connect.ubisoft.com serves an app interstitial ("Sign in to Ubisoft
/// Connect to continue") whose button deep-links to the Connect app instead
/// of showing the login form — in a web view that tap goes nowhere and the
/// prompt loops (device report, 2026-10-30). The GOG Galaxy integration,
/// whose flow this mirrors, likewise runs the page in a desktop browser.
struct UbisoftLoginWebView: UIViewRepresentable {
    var reload: Int
    var onCapture: (String) -> Void

    /// Desktop Chrome on Windows — the user agent the GOG integration's
    /// browser presents to Ubisoft's web auth.
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.127 Safari/537.36"

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.desktopUserAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: UbisoftAPI.loginURL))
        context.coordinator.loadedReload = reload
        context.coordinator.startPolling(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCapture = onCapture
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: UbisoftAPI.loginURL))
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCapture: (String) -> Void
        var loadedReload = 0
        var delivered = false
        private var timer: Timer?
        private weak var view: WKWebView?
        init(onCapture: @escaping (String) -> Void) { self.onCapture = onCapture }

        func startPolling(_ view: WKWebView) {
            self.view = view
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.check()
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            check()
        }

        private func check() {
            guard !delivered, let view, view.url?.host?.lowercased() == "connect.ubisoft.com" else { return }
            view.evaluateJavaScript(UbisoftAPI.captureScript) { [weak self] result, _ in
                guard let self, !self.delivered, let text = result as? String, !text.isEmpty,
                      UbisoftAPI.session(fromCapture: text) != nil else { return }
                self.delivered = true
                self.stopPolling()
                self.onCapture(text)
            }
        }

        /// Links that open a new window (some sign-in providers) load in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // JavaScript panels: without a delegate implementation WebKit drops
        // the page's dialogs and its script waits on an answer that never
        // comes, which reads on screen as a button that does nothing.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(webView, message: message, buttons: [("OK", true)], prompt: nil) { _, _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(webView, message: message, buttons: [("Cancel", false), ("OK", true)], prompt: nil) { accepted, _ in
                completionHandler(accepted)
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            present(webView, message: prompt, buttons: [("Cancel", false), ("OK", true)], prompt: defaultText ?? "") { accepted, text in
                completionHandler(accepted ? (text ?? defaultText) : nil)
            }
        }

        /// Shows one alert for a JavaScript panel. The completion always runs
        /// exactly once — WebKit suspends the page's script until it does.
        private func present(_ webView: WKWebView, message: String, buttons: [(String, Bool)],
                             prompt: String?, completion: @escaping (Bool, String?) -> Void) {
            guard let presenter = Self.topPresenter(from: webView) else { completion(false, nil); return }
            let alert = UIAlertController(title: "Ubisoft Connect", message: message, preferredStyle: .alert)
            if prompt != nil { alert.addTextField { $0.text = prompt } }
            for (title, accepted) in buttons {
                alert.addAction(UIAlertAction(title: title, style: accepted ? .default : .cancel) { _ in
                    completion(accepted, alert.textFields?.first?.text)
                })
            }
            presenter.present(alert, animated: true)
        }

        private static func topPresenter(from view: UIView) -> UIViewController? {
            var top = view.window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }
    }
}
