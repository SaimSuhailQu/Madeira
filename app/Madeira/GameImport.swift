// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Saim Suhail
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import zlib

// The zip reader for in-app game import (Library, "Import game (.zip)…"). A
// streaming central-directory parser: entries are inflated one at a time from a
// mapped archive, so a multi-gigabyte game never sits in memory twice. Hardened
// the same way as SteamRuntime.swift's unpacker — no traversal, no absolute
// paths, no encryption, no symlinks, no duplicate or case-colliding names, no
// zip bombs — with caps sized for real game archives instead of Valve's
// component packages.
enum GameZip {
    struct Entry {
        let name: String        // normalized: forward slashes, no trailing slash
        let isDirectory: Bool
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let offset: UInt64      // local header offset
    }

    enum ImportError: LocalizedError {
        case notAZip, unsupportedEntry(String), tooManyEntries, tooLarge, duplicateEntry(String), empty
        var errorDescription: String? {
            switch self {
            case .notAZip: return "That file is not a zip archive."
            case .unsupportedEntry(let name): return "The archive entry cannot be imported: \(name)"
            case .tooManyEntries: return "The archive holds too many files."
            case .tooLarge: return "The uncompressed archive is too large for this device."
            case .duplicateEntry(let name): return "The archive contains two entries named \"\(name)\"."
            case .empty: return "The archive is empty."
            }
        }
    }

    // Caps: a game's uncompressed tree may be large, but bounded — a hostile or
    // mistaken archive cannot fill the container or hang the import.
    static let maxEntries = 60_000
    static let maxUncompressedBytes: UInt64 = 24 << 30

    static func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24)
    }
    static func u64(_ d: Data, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(d[o + i]) }
        return v
    }

    /// Parse the central directory (zip32 and zip64). Returns entries in archive
    /// order with names normalized; every hardening check happens here, before
    /// anything is written to disk.
    static func readDirectory(_ data: Data) throws -> [Entry] {
        // End of central directory: search the tail (comments may follow it).
        let tail = max(0, data.count - 66_000)
        var eocd = -1
        if data.count >= 22 {
            var p = data.count - 22
            while p >= tail {
                if u32(data, p) == 0x06054b50, p + 22 + u16(data, p + 20) == data.count { eocd = p; break }
                p -= 1
            }
        }
        guard eocd >= 0 else { throw ImportError.notAZip }
        guard u16(data, eocd + 4) == 0, u16(data, eocd + 6) == 0 else { throw ImportError.unsupportedEntry("a multi-disk archive") }

        var count = u16(data, eocd + 10)
        var central = UInt64(u32(data, eocd + 16))
        // zip64: a locator sits immediately before the EOCD when the classic
        // fields overflowed.
        if count == 0xFFFF || central == 0xFFFFFFFF, eocd >= 20, u32(data, eocd - 20) == 0x07064b50 {
            let eocd64 = u64(data, eocd - 20 + 8)
            guard eocd64 + 56 <= UInt64(data.count), u32(data, Int(eocd64)) == 0x06064b50 else { throw ImportError.notAZip }
            count = Int(u64(data, Int(eocd64) + 32))
            central = u64(data, Int(eocd64) + 48)
        }
        guard count > 0, count <= maxEntries, central > 0, central < UInt64(data.count) else { throw count == 0 ? ImportError.empty : ImportError.tooManyEntries }

        var entries: [Entry] = []
        var seen = Set<String>()
        var total: UInt64 = 0
        entries.reserveCapacity(count)
        var cursor = Int(central)
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x02014b50 else { throw ImportError.notAZip }
            let flags = u16(data, cursor + 8)
            let method = UInt16(u16(data, cursor + 10))
            let crc = u32(data, cursor + 16)
            var compressed = UInt64(u32(data, cursor + 20))
            var size = UInt64(u32(data, cursor + 24))
            let nameLength = u16(data, cursor + 28)
            let extraLength = u16(data, cursor + 30)
            let commentLength = u16(data, cursor + 32)
            let external = u32(data, cursor + 38)
            var offset = UInt64(u32(data, cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= data.count else { throw ImportError.notAZip }
            guard flags & 0x1 == 0, method == 0 || method == 8 else {
                throw ImportError.unsupportedEntry(centralName(data, cursor + 46, nameLength))
            }
            // zip64 extra field (id 0x0001): the real values, in this order, for
            // every field above that is 0xFFFFFFFF.
            if size == 0xFFFFFFFF || compressed == 0xFFFFFFFF || offset == 0xFFFFFFFF {
                var e = cursor + 46 + nameLength
                let eEnd = cursor + 46 + nameLength + extraLength
                while e + 4 <= eEnd {
                    let id = u16(data, e), len = u16(data, e + 2)
                    guard e + 4 + len <= eEnd else { break }
                    if id == 0x0001 {
                        var f = e + 4
                        if size == 0xFFFFFFFF, f + 8 <= e + 4 + len { size = u64(data, f); f += 8 }
                        if compressed == 0xFFFFFFFF, f + 8 <= e + 4 + len { compressed = u64(data, f); f += 8 }
                        if offset == 0xFFFFFFFF, f + 8 <= e + 4 + len { offset = u64(data, f); f += 8 }
                        break
                    }
                    e += 4 + len
                }
            }
            // Bounded before any Int conversion: a value beyond the archive's own
            // size is corrupt, and an unbounded one would trap the widening below.
            guard offset <= UInt64(data.count), size <= maxUncompressedBytes,
                  compressed <= maxUncompressedBytes else { throw ImportError.tooLarge }
            // Symlinks and other special unix entries are refused outright.
            guard (external >> 16) & 0xF000 != 0xA000 else {
                throw ImportError.unsupportedEntry(centralName(data, cursor + 46, nameLength))
            }
            // Valve's packages and Windows zip tools use backslash separators;
            // normalize BEFORE every check, as SteamRuntime.swift does.
            let normalized = centralName(data, cursor + 46, nameLength).replacingOccurrences(of: "\\", with: "/")
            let directory = normalized.hasSuffix("/")
            let name = directory ? String(normalized.dropLast()) : normalized
            guard SteamRuntimeFiles.validPath(name) else { throw ImportError.unsupportedEntry(normalized) }
            guard method != 0 || compressed == size else { throw ImportError.unsupportedEntry(name) }
            guard seen.insert(name.lowercased()).inserted else { throw ImportError.duplicateEntry(name) }
            if !directory {
                guard method == 0 || method == 8, size <= maxUncompressedBytes else { throw ImportError.tooLarge }
                total += size
                guard total <= maxUncompressedBytes else { throw ImportError.tooLarge }
            }
            entries.append(Entry(name: name, isDirectory: directory, method: method, crc: crc,
                                 compressedSize: compressed, size: size, offset: offset))
            cursor = next
        }
        guard !entries.isEmpty else { throw ImportError.empty }
        return entries
    }

    private static func centralName(_ data: Data, _ at: Int, _ len: Int) -> String {
        guard len > 0, at + len <= data.count else { return "" }
        return String(data: data.subdata(in: at..<at + len), encoding: .utf8) ?? ""
    }

    /// Extract the archive at `url` into `destination` (already created). Names
    /// were validated by readDirectory; local headers are re-verified per entry
    /// so a forged central directory cannot redirect a write. Returns the number
    /// of files written. `progress` fires about every 64 files.
    @discardableResult
    static func extract(_ url: URL, into destination: URL,
                        progress: (String) -> Void = { _ in }) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try readDirectory(data)
        let fm = FileManager.default
        var written = 0
        var crcState: UInt32 = 0
        for entry in entries {
            let target = destination.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let local = Int(entry.offset)
            guard local + 30 <= data.count, u32(data, local) == 0x04034b50 else { throw ImportError.notAZip }
            let nameLength = u16(data, local + 26), extraLength = u16(data, local + 28)
            let body = local + 30 + nameLength + extraLength
            guard body >= 0, Int(entry.compressedSize) <= data.count - body else { throw ImportError.notAZip }
            let headerName = String(data: data.subdata(in: local + 30..<local + 30 + nameLength), encoding: .utf8) ?? ""
            guard headerName.replacingOccurrences(of: "\\", with: "/") == entry.name ||
                  headerName == entry.name + "/" else { throw ImportError.unsupportedEntry(headerName) }

            fm.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            crcState = 0
            if entry.method == 0 {
                // Stored: chunked CRC (a corrupted stored file must fail too) and a
                // chunked copy — never a whole-file buffer on top of the mapped archive.
                try data.withUnsafeBytes { (r: UnsafeRawBufferPointer) in
                    var done = 0
                    while done < Int(entry.size) {
                        let n = min(1 << 20, Int(entry.size) - done)
                        let piece = Data(r[body + done..<body + done + n])
                        crcState = UInt32(piece.withUnsafeBytes { zlib.crc32(uLong(crcState), $0.bindMemory(to: UInt8.self).baseAddress!, UInt32(n)) })
                        try out.write(contentsOf: piece)
                        done += n
                    }
                }
            } else {
                var stream = z_stream()
                var ok = false
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                    var produced: UInt64 = 0
                    var consumed = 0
                    let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 18)
                    defer { chunk.deallocate() }
                    inflateLoop: while true {
                        let avail = Int(entry.compressedSize) - consumed
                        if avail == 0 && produced == entry.size { break }
                        stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: body + consumed).assumingMemoryBound(to: UInt8.self))
                        stream.avail_in = u32_clamp(min(avail, 1 << 20))
                        stream.next_out = chunk
                        stream.avail_out = u32_clamp(1 << 18)
                        let rc = inflate(&stream, Z_NO_FLUSH)
                        let got = (1 << 18) - Int(stream.avail_out)
                        if got > 0 {
                            let piece = Data(bytes: chunk, count: got)
                            crcState = UInt32(zlib.crc32(uLong(crcState), chunk, UInt32(got)))
                            do { try out.write(contentsOf: piece) } catch { inflateEnd(&stream); return }
                            produced += UInt64(got)
                        }
                        consumed = Int(entry.compressedSize) - Int(stream.avail_in)
                        switch rc {
                        case Z_STREAM_END: ok = produced == entry.size && consumed == Int(entry.compressedSize)
                        case Z_OK: if got == 0 { ok = false; break inflateLoop } // no progress: corrupt stream, not a hang
                        default: ok = false; break inflateLoop
                        }
                        if rc == Z_STREAM_END { break }
                    }
                    inflateEnd(&stream)
                }
                guard ok else { throw ImportError.unsupportedEntry(entry.name) }
            }
            guard crcState == entry.crc else { throw ImportError.unsupportedEntry(entry.name) }
            written += 1
            if written & 63 == 0 { progress("Importing… \(written) files") }
        }
        return written
    }

    private static func u32_clamp(_ v: Int) -> UInt32 { UInt32(min(v, Int(UInt32.max))) }

    /// The archive's single top-level folder, when every entry lives inside one —
    /// imported directly as Games/<that folder> instead of double-nesting.
    static func singleRoot(_ entries: [Entry]) -> String? {
        var root: String?
        for entry in entries {
            guard let first = entry.name.split(separator: "/").first.map(String.init) else { continue }
            if let known = root {
                if known != first { return nil }
            } else {
                root = first
            }
        }
        guard let root, entries.contains(where: { $0.name.hasPrefix(root + "/") }) else { return nil }
        return root
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// The Library's import flow: pick a game .zip, extract it under
/// drive_c/Games/<name>/ (staged, then moved into place), then hand the folder
/// to the executable browser so the player picks the game's .exe. Plain
/// DRM-free games and fan re-packages alike — no Steam, no network, no DRM.
@MainActor
final class GameImportModel: ObservableObject {
    static let shared = GameImportModel()

    @Published private(set) var importing = false
    @Published private(set) var progress = ""
    @Published var error: String?
    /// The imported game folder inside drive_c/Games, once an import succeeded.
    /// Cleared by the Library view when its executable-browser sheet closes.
    @Published var importedFolder: URL?

    static var gamesRoot: URL { LibraryModel.drive.appendingPathComponent("Games", isDirectory: true) }

    func importArchive(at picked: URL) {
        guard !importing else { return }
        importing = true; error = nil; progress = "Reading the archive…"
        Task { @MainActor in
            defer { importing = false }
            do {
                let scoped = picked.startAccessingSecurityScopedResource()
                defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
                let fm = FileManager.default
                let zipName = picked.deletingPathExtension().lastPathComponent
                let stage = Self.gamesRoot.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: Self.gamesRoot, withIntermediateDirectories: true)
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                do {
                    // All heavy work happens off the main thread; only progress text
                    // hops back.
                    let root = try await Task.detached(priority: .userInitiated) { () -> String? in
                        GameZip.singleRoot(try GameZip.readDirectory(Data(contentsOf: picked, options: .mappedIfSafe)))
                    }.value
                    let written = try await Task.detached(priority: .userInitiated) { () -> Int in
                        try GameZip.extract(picked, into: stage) { text in
                            Task { @MainActor in self.progress = text }
                        }
                    }.value
                    // An archive holding one top-level folder imports AS that folder;
                    // a flat one takes the zip's name. Both land at Games/<name>/.
                    let name = root ?? zipName
                    let source = root.map { stage.appendingPathComponent($0, isDirectory: true) } ?? stage
                    let final = Self.gamesRoot.appendingPathComponent(name, isDirectory: true)
                    guard !fm.fileExists(atPath: final.path) else {
                        throw GameZip.ImportError.unsupportedEntry("Games/\(name) already exists — remove it or rename the zip.")
                    }
                    try fm.moveItem(at: source, to: final)
                    if source != stage { try? fm.removeItem(at: stage) }
                    importedFolder = final
                    LogStore.shared.log("[game-import] \(name): \(written) files from \(picked.lastPathComponent)")
                } catch {
                    try? fm.removeItem(at: stage)
                    throw error
                }
            } catch {
                self.error = error.localizedDescription
                LogStore.shared.log("[game-import] failed: \(error.localizedDescription)", level: .error)
            }
        }
    }
}
