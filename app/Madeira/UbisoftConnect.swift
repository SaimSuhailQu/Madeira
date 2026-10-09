// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Guided installer and launcher integration for Ubisoft Connect in Madeira.
// Downloads official UbisoftConnectInstaller.exe into the Wine prefix drive_c/Installers,
// registers Ubisoft Connect into the Madeira Library, and configures recommended defaults
// (Desktop environment, Windows services enabled, and proper working directory).

import Foundation
import SwiftUI

// MARK: - Ubisoft Connect Model

@MainActor
final class UbisoftConnectModel: ObservableObject {
    static let shared = UbisoftConnectModel()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var progressFraction: Double = 0.0
    @Published var error: String?

    static let installerURL = URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
    static let relativeInstallerPath = "Installers/UbisoftConnectInstaller.exe"
    static let relativeInstalledExePath = "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"

    var installerFile: URL {
        LibraryModel.drive.appendingPathComponent(Self.relativeInstallerPath)
    }

    var installedFile: URL {
        LibraryModel.drive.appendingPathComponent(Self.relativeInstalledExePath)
    }

    var isInstallerPresent: Bool {
        FileManager.default.fileExists(atPath: installerFile.path)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedFile.path)
    }

    var statusDescription: String {
        if isInstalled {
            return "Installed in Wine prefix"
        } else if isInstallerPresent {
            return "Installer ready to run"
        } else {
            return "Not installed"
        }
    }

    func downloadAndRegister(autoLaunch: ((LibraryEntry) -> Void)? = nil) {
        guard case .idle = phase else { return }
        error = nil
        phase = .downloading(0.0)
        progressFraction = 0.0

        let destination = installerFile
        let downloadURL = Self.installerURL

        Task.detached {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "UbisoftConnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download installer from Ubisoft CDN."])
                }
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tempURL, to: destination)

                await MainActor.run {
                    self.phase = .ready
                    let entry = self.registerInstallerEntry()
                    autoLaunch?(entry)
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func registerInstallerEntry() -> LibraryEntry {
        let title = "Install Ubisoft Connect"
        var entry: LibraryEntry
        if let existing = LibraryModel.shared.entries.first(where: { $0.relativePath == Self.relativeInstallerPath }) {
            entry = existing
        } else {
            entry = LibraryEntry(title: title, relativePath: Self.relativeInstallerPath, bits: 32)
        }
        entry.desktop = true
        entry.startServices = true
        LibraryModel.shared.save(entry)
        return entry
    }

    @discardableResult
    func registerInstalledLauncherEntry() -> LibraryEntry {
        let title = "Ubisoft Connect"
        var entry: LibraryEntry
        if let existing = LibraryModel.shared.entries.first(where: { $0.relativePath == Self.relativeInstalledExePath }) {
            entry = existing
        } else {
            entry = LibraryEntry(title: title, relativePath: Self.relativeInstalledExePath, bits: 32)
        }
        entry.desktop = true
        entry.startServices = true
        LibraryModel.shared.save(entry)
        return entry
    }
}

// MARK: - Settings Section View

struct UbisoftConnectSettingsSection: View {
    @ObservedObject private var ubi = UbisoftConnectModel.shared
    @State private var notice: String?

    var body: some View {
        Section {
            LabeledContent("Ubisoft Connect", value: ubi.statusDescription)

            if case .downloading = ubi.phase {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                    Text("Downloading UbisoftConnectInstaller.exe (~250 MB)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = ubi.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if ubi.isInstalled {
                Button {
                    let entry = ubi.registerInstalledLauncherEntry()
                    notice = "Ubisoft Connect added to library. Start it from your Library screen."
                } label: {
                    Label("Add Ubisoft Connect to Library", systemImage: "plus.circle")
                }
            } else if ubi.isInstallerPresent {
                Button {
                    let entry = ubi.registerInstallerEntry()
                    notice = "Installer added to library. Tap Play on 'Install Ubisoft Connect' to run setup."
                } label: {
                    Label("Add Installer to Library", systemImage: "arrow.up.forward.app")
                }
            } else {
                Button {
                    ubi.downloadAndRegister()
                } label: {
                    Label("Download Ubisoft Connect Installer", systemImage: "arrow.down.circle")
                }
            }
        } header: {
            Text("Ubisoft Connect")
        } footer: {
            Text("Downloads official Ubisoft Connect installer into Wine prefix (C:\\Installers). Because Ubisoft requires its desktop client and background services, it launches inside the Wine desktop with services enabled.")
        }
        .alert("Ubisoft Connect", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }
}
