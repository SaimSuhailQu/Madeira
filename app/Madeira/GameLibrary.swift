//
// GameLibrary.swift
// Madeira
//
// Manages local games, tools, and Steam manifest (.acf) / .lua launch metadata.
// Scans Documents/wine/drive_c for installed executables, steamapps manifests,
// and custom .lua / .json launch descriptors.
//

import Foundation
import SwiftUI

public struct LibraryItem: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var exePath: String         // e.g. "C:\\Program Files\\Thumper\\THUMPER_win10.exe" or relative to drive_c
    public var args: String
    public var iconName: String        // SF Symbol name or asset name
    public var isTool: Bool
    public var is64Bit: Bool
    public var workingDir: String?
    public var appId: String?

    public init(
        id: String,
        name: String,
        exePath: String,
        args: String = "",
        iconName: String = "gamecontroller.fill",
        isTool: Bool = false,
        is64Bit: Bool = true,
        workingDir: String? = nil,
        appId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.exePath = exePath
        self.args = args
        self.iconName = iconName
        self.isTool = isTool
        self.is64Bit = is64Bit
        self.workingDir = workingDir
        self.appId = appId
    }
}

public final class GameLibraryManager: ObservableObject {
    public static let shared = GameLibraryManager()

    @Published public var items: [LibraryItem] = []

    private init() {
        reloadLibrary()
    }

    /// Primary scan that discovers default tools, manifest-defined Steam games, .lua descriptors, and custom library.json
    public func reloadLibrary() {
        var discovered: [LibraryItem] = []

        // 1. Built-in system tools & defaults
        discovered.append(contentsOf: defaultTools())

        // 2. Scan Steam appmanifest_*.acf files in steamapps/
        discovered.append(contentsOf: scanSteamManifests())

        // 3. Scan .lua game/tool launch scripts in Documents/Launchers/ or Documents/
        discovered.append(contentsOf: scanLuaLaunchers())

        // 4. Scan custom library.json if user created one
        discovered.append(contentsOf: loadCustomLibraryJson())

        // Deduplicate by ID
        var seen = Set<String>()
        var unique: [LibraryItem] = []
        for item in discovered {
            if !seen.contains(item.id) {
                seen.insert(item.id)
                unique.append(item)
            }
        }

        DispatchQueue.main.async {
            self.items = unique
        }
    }

    private func winePrefixURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("wine")
    }

    private func defaultTools() -> [LibraryItem] {
        [
            LibraryItem(
                id: "wine-desktop",
                name: "Desktop",
                exePath: "explorer.exe",
                args: "/desktop=shell,1024x768 C:\\windows\\system32\\services.exe",
                iconName: "display",
                isTool: true,
                is64Bit: false
            ),
            LibraryItem(
                id: "wine-cmd",
                name: "Command Prompt",
                exePath: "cmd.exe",
                args: "",
                iconName: "terminal.fill",
                isTool: true,
                is64Bit: true
            ),
            LibraryItem(
                id: "wine-taskmgr",
                name: "Taskmgr",
                exePath: "taskmgr.exe",
                args: "",
                iconName: "chart.bar.xaxis",
                isTool: true,
                is64Bit: false
            ),
            LibraryItem(
                id: "wine-regedit",
                name: "Regedit",
                exePath: "regedit.exe",
                args: "",
                iconName: "slider.horizontal.3",
                isTool: true,
                is64Bit: false
            ),
            LibraryItem(
                id: "cube-x64",
                name: "x64 Cube",
                exePath: "cube-x64.exe",
                args: "",
                iconName: "cube.fill",
                isTool: true,
                is64Bit: true
            )
        ]
    }

    /// Parse Steam Valve KeyValues format (appmanifest_<appid>.acf)
    /// Example snippet:
    /// "AppState" { "appid" "356400" "name" "Thumper" "installdir" "Thumper" }
    private func scanSteamManifests() -> [LibraryItem] {
        guard let prefix = winePrefixURL() else { return [] }
        let fm = FileManager.default

        // Common Steamapps paths in prefix
        let steamAppsPaths = [
            prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps"),
            prefix.appendingPathComponent("drive_c/Program Files/Steam/steamapps"),
            prefix.appendingPathComponent("drive_c/steamapps")
        ]

        var results: [LibraryItem] = []

        for appsDir in steamAppsPaths {
            guard let files = try? fm.contentsOfDirectory(atPath: appsDir.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                let manifestURL = appsDir.appendingPathComponent(file)
                guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else { continue }

                let appId = extractKey(content, key: "appid") ?? extractKey(content, key: "AppId") ?? ""
                let name = extractKey(content, key: "name") ?? "Steam Game \(appId)"
                let installDir = extractKey(content, key: "installdir") ?? ""

                if !appId.isEmpty && !installDir.isEmpty {
                    // Check common directory for game exe
                    let commonDir = appsDir.appendingPathComponent("common").appendingPathComponent(installDir)
                    if let gameExe = findPrimaryExe(in: commonDir) {
                        let winPath = "C:\\" + gameExe.path
                            .replacingOccurrences(of: prefix.appendingPathComponent("drive_c").path + "/", with: "")
                            .replacingOccurrences(of: "/", with: "\\")

                        results.append(
                            LibraryItem(
                                id: "steam-\(appId)",
                                name: name,
                                exePath: winPath,
                                args: "",
                                iconName: "gamecontroller.fill",
                                isTool: false,
                                is64Bit: true,
                                workingDir: nil,
                                appId: appId
                            )
                        )
                    }
                }
            }
        }

        return results
    }

    /// Simple KeyValues extractor
    private func extractKey(_ text: String, key: String) -> String? {
        // Look for "key"\s+"value"
        let pattern = #""\#(key)"\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
              let valRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valRange])
    }

    /// Heuristic to find candidate executable in a game's common folder
    private func findPrimaryExe(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "exe" {
                let name = fileURL.lastPathComponent.lowercased()
                // Avoid uninstaller or crash reporters
                if name.contains("unins") || name.contains("crash") || name.contains("setup") || name.contains("redist") {
                    continue
                }
                candidates.append(fileURL)
            }
        }

        // Return candidate with smallest directory depth or largest file size
        return candidates.sorted {
            let s1 = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let s2 = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return s1 > s2
        }.first
    }

    /// Parse .lua files in Documents/ or Documents/Launchers/
    /// Example Lua launcher format:
    /// -- game.lua
    /// name = "Sekiro: Shadows Die Twice"
    /// exe = "C:\\Games\\Sekiro\\sekiro.exe"
    /// args = "-windowed"
    /// appid = "814380"
    /// icon = "flame.fill"
    /// is_64bit = true
    private func scanLuaLaunchers() -> [LibraryItem] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let fm = FileManager.default
        var results: [LibraryItem] = []

        let dirsToScan = [
            docs,
            docs.appendingPathComponent("Launchers"),
            docs.appendingPathComponent("Games")
        ]

        for dir in dirsToScan {
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasSuffix(".lua") {
                let luaURL = dir.appendingPathComponent(file)
                guard let content = try? String(contentsOf: luaURL, encoding: .utf8) else { continue }

                let id = file.replacingOccurrences(of: ".lua", with: "")
                let name = extractLuaVar(content, varName: "name") ?? id
                guard let exe = extractLuaVar(content, varName: "exe") else { continue }
                let args = extractLuaVar(content, varName: "args") ?? ""
                let icon = extractLuaVar(content, varName: "icon") ?? "gamecontroller.fill"
                let appId = extractLuaVar(content, varName: "appid")
                let isTool = (extractLuaVar(content, varName: "is_tool")?.lowercased() == "true")
                let is64 = !(extractLuaVar(content, varName: "is_64bit")?.lowercased() == "false")

                results.append(
                    LibraryItem(
                        id: "lua-\(id)",
                        name: name,
                        exePath: exe,
                        args: args,
                        iconName: icon,
                        isTool: isTool,
                        is64Bit: is64,
                        appId: appId
                    )
                )
            }
        }
        return results
    }

    private func extractLuaVar(_ text: String, varName: String) -> String? {
        // match varName = "value" or varName = 'value' or varName = value
        let pattern = #"\b\#(varName)\s*=\s*["']?([^"'\n\r]+)["']?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
              let valRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadCustomLibraryJson() -> [LibraryItem] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let jsonURL = docs.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else {
            return []
        }
        return items
    }

    /// Add a game directly by writing a .lua descriptor
    public func addLuaGame(id: String, name: String, exePath: String, args: String, appId: String?, is64Bit: Bool) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let launchersDir = docs.appendingPathComponent("Launchers")
        try? FileManager.default.createDirectory(at: launchersDir, withIntermediateDirectories: true)

        let safeId = id.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
        let fileURL = launchersDir.appendingPathComponent("\(safeId).lua")

        let escapedExe = exePath.replacingOccurrences(of: "\\", with: "\\\\")
        let escapedArgs = args.replacingOccurrences(of: "\\", with: "\\\\")

        let luaContent = """
        -- Madeira Auto-Generated Launcher
        name = "\(name)"
        exe = "\(escapedExe)"
        args = "\(escapedArgs)"
        appid = "\(appId ?? "")"
        is_64bit = \(is64Bit ? "true" : "false")
        icon = "gamecontroller.fill"
        """

        try? luaContent.write(to: fileURL, atomically: true, encoding: .utf8)
        reloadLibrary()
    }

    /// Add a game directly from an appmanifest (.acf) file content
    public func importManifestContent(_ content: String) {
        guard let prefix = winePrefixURL() else { return }
        let appId = extractKey(content, key: "appid") ?? extractKey(content, key: "AppId") ?? "\(Int(Date().timeIntervalSince1970))"
        let name = extractKey(content, key: "name") ?? "Steam Game \(appId)"
        let installDir = extractKey(content, key: "installdir") ?? name

        // Write to steamapps
        let steamAppsDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try? FileManager.default.createDirectory(at: steamAppsDir, withIntermediateDirectories: true)
        let manifestFile = steamAppsDir.appendingPathComponent("appmanifest_\(appId).acf")
        try? content.write(to: manifestFile, atomically: true, encoding: .utf8)

        // Also create a quick .lua launcher fallback in Launchers/
        let exeGuess = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\\(installDir)\\\(installDir).exe"
        addLuaGame(id: "steam_\(appId)", name: name, exePath: exeGuess, args: "", appId: appId, is64Bit: true)
        reloadLibrary()
    }
}

// =============================================================================
// Background Steam Game Download Manager
// =============================================================================

public struct DownloadProgress: Identifiable {
    public let id: String
    public var title: String
    public var progress: Double // 0.0 ... 1.0
    public var downloadedBytes: Int64
    public var totalBytes: Int64
    public var status: String
    public var isComplete: Bool
}

public final class GameDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = GameDownloadManager()

    @Published public var activeDownloads: [String: DownloadProgress] = [:]
    private var session: URLSession!
    private var taskMap: [URLSessionDownloadTask: (id: String, destination: URL)] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.madeira.background-downloader")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldUseExtendedBackgroundIdleMode = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Download game assets or zip packages directly to Wine prefix in background
    public func startDownload(
        id: String,
        title: String,
        from url: URL,
        destinationFolder: String = "Games"
    ) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let destDir = docs.appendingPathComponent("wine/drive_c").appendingPathComponent(destinationFolder)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let finalDestination = destDir.appendingPathComponent(url.lastPathComponent)

        let task = session.downloadTask(with: url)
        taskMap[task] = (id, finalDestination)

        DispatchQueue.main.async {
            self.activeDownloads[id] = DownloadProgress(
                id: id,
                title: title,
                progress: 0.0,
                downloadedBytes: 0,
                totalBytes: 0,
                status: "Starting background download...",
                isComplete: false
            )
        }
        task.resume()
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let (id, _) = taskMap[downloadTask] else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0

        DispatchQueue.main.async {
            if var item = self.activeDownloads[id] {
                item.progress = progress
                item.downloadedBytes = totalBytesWritten
                item.totalBytes = totalBytesExpectedToWrite
                let mbDownloaded = Double(totalBytesWritten) / 1024.0 / 1024.0
                let mbTotal = Double(totalBytesExpectedToWrite) / 1024.0 / 1024.0
                item.status = String(format: "%.1f MB / %.1f MB (%.0f%%)", mbDownloaded, mbTotal, progress * 100)
                self.activeDownloads[id] = item
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let (id, destination) = taskMap[downloadTask] else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                if var item = self.activeDownloads[id] {
                    item.progress = 1.0
                    item.status = "Complete: saved to \(destination.lastPathComponent)"
                    item.isComplete = true
                    self.activeDownloads[id] = item
                }
                GameLibraryManager.shared.reloadLibrary()
            }
        } catch {
            DispatchQueue.main.async {
                if var item = self.activeDownloads[id] {
                    item.status = "Failed: \(error.localizedDescription)"
                    self.activeDownloads[id] = item
                }
            }
        }
        taskMap.removeValue(forKey: downloadTask)
    }
}

