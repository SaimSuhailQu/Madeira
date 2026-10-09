// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games binary build manifest: the format Legendary's get_download reads
// (legendary/models/manifest.py) — header, metadata, the chunk data list, the
// file manifest list and custom fields. Foundation only, so
// tests/host/check-epic-launcher.py compiles this file as it is.
//
// A manifest is downloaded from a CDN URL the assets v2 API names. It says,
// for every file, which "chunk parts" (offset and length inside 1 MiB chunks)
// build it up; chunks live on the CDN in ChunksV* folders. Everything here
// reads; nothing writes.

import Foundation
import CommonCrypto

enum EpicManifestError: Error {
    case magic
    case truncated(String)
}

/// One 1 MiB chunk on the CDN: its GUID, hashes, group (part of the path) and
/// sizes. `path` is the CDN path under the manifest's base URL.
struct EpicChunkInfo {
    var guid: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    var hash: UInt64 = 0
    var shaHash: [UInt8] = []
    var groupNum: UInt8 = 0
    var windowSize: UInt32 = 0
    var fileSize: Int64 = 0

    var guidString: String {
        String(format: "%08X-%08X-%08X-%08X", guid.0, guid.1, guid.2, guid.3)
    }

    /// The lower-case GUID string Epic's older CDN paths use.
    var guidLower: String { guidString.lowercased() }

    /// The chunk's path under the base URL: ChunksV3/05/<hash>_<guid>.chunk for
    /// manifests under v22 (the format every game Madeira could run has used so
    /// far). The version is the manifest's feature level.
    func path(featureLevel: UInt32) -> String {
        let dir: String
        switch featureLevel {
        case 22...: dir = "ChunksV5"
        case 15...: dir = "ChunksV4"
        case 6...: dir = "ChunksV3"
        case 3...: dir = "ChunksV2"
        default: dir = "Chunks"
        }
        return "\(dir)/\(String(format: "%02d", groupNum))/\(String(format: "%016llX", hash))_\(guidLower).chunk"
    }
}

/// One piece of a file: where in the chunk the bytes are, and where in the
/// file they go.
struct EpicChunkPart {
    var guid: (UInt32, UInt32, UInt32, UInt32)
    var offset: UInt32
    var size: UInt32
    /// Where this part starts in the assembled file.
    var fileOffset: UInt32
}

/// One file the build installs: its path, hash and chunk parts.
struct EpicFileManifest {
    var filename: String = ""
    var symlinkTarget: String = ""
    /// SHA-1 of the whole file.
    var hash: [UInt8] = []
    /// 0x1 = executable.
    var flags: UInt8 = 0
    var chunkParts: [EpicChunkPart] = []
    var fileSize: Int64 { chunkParts.reduce(0) { $0 + Int64($1.size) } }
    var isExecutable: Bool { flags & 0x1 != 0 }

    /// Windows path parts, safe to join inside the install folder: nil when
    /// the name escapes it ("..", a drive letter, an empty part). Hostile
    /// manifest names never leave the install folder (as Steam's
    /// SteamInstallFiles.safeRelativePath does).
    var safeRelativePath: String? {
        let parts = filename.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, filename.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        return parts.joined(separator: "/")
    }
}

/// The parsed manifest: metadata (build version, launch exe), chunks, files.
struct EpicManifest {
    struct Meta {
        var dataVersion: UInt8 = 0
        var featureLevel: UInt32 = 18
        var isFileData = false
        var appID: UInt32 = 0
        var appName = ""
        var buildVersion = ""
        /// The executable to start, relative to the install folder; the launch
        /// command's first token. May be empty.
        var launchExe = ""
        var launchCommand = ""
    }

    var meta = Meta()
    var chunks: [EpicChunkInfo] = []
    var files: [EpicFileManifest] = []
    var customFields: [String: String] = [:]
    private var chunkIndex: [String: Int] = [:]

    /// The chunk with this lower-case GUID string, or nil.
    func chunk(guidString: String) -> EpicChunkInfo? {
        if chunkIndex.isEmpty {
            // filled after read; rebuild lazily for manifests made by hand
            return chunks.first(where: { $0.guidLower == guidString.lowercased() })
        }
        return chunkIndex[guidString.lowercased()].flatMap { chunks[$0] }
    }

    // MARK: - Reading

    private struct Reader {
        let data: [UInt8]
        var offset = 0
        var remaining: Int { data.count - offset }

        mutating func raw(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, remaining >= count else { throw EpicManifestError.truncated("need \(count), have \(remaining)") }
            let slice = data[offset..<(offset + count)]
            offset += count
            return slice
        }

        mutating func u8() throws -> UInt8 { try raw(1).first! }
        mutating func u32() throws -> UInt32 {
            let bytes = try raw(4)
            var value: UInt32 = 0
            for (index, byte) in bytes.enumerated() { value |= UInt32(byte) << (index * 8) }
            return value
        }
        mutating func u64() throws -> UInt64 {
            let bytes = try raw(8)
            var value: UInt64 = 0
            for (index, byte) in bytes.enumerated() { value |= UInt64(byte) << (index * 8) }
            return value
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func skip(_ count: Int) throws { _ = try raw(count) }
    }

    /// Epic's fstring: a signed length (negative = UTF-16) then the bytes and a
    /// null terminator (or two, for UTF-16). Returns nil for an empty string.
    private static func fstring(_ reader: inout Reader) throws -> String? {
        let length = try reader.i32()
        if length == 0 { return nil }
        if length < 0 {
            let count = Int(-length) * 2
            guard count >= 2, reader.remaining >= count else { throw EpicManifestError.truncated("utf16 string") }
            let bytes = Array(try reader.raw(count))
            try reader.skip(2)
            // Epic's deserializer only ever writes UTF-16LE here; decode
            // little-endian UTF-16 code units.
            var units: [UInt16] = []
            var i = 0
            while i + 1 < count - 2 {   // exclude the two null terminators
                units.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        let count = Int(length)
        guard count >= 1, reader.remaining >= count else { throw EpicManifestError.truncated("ascii string") }
        let bytes = Array(try reader.raw(count - 1))
        try reader.skip(1)
        return String(decoding: bytes, as: UTF8.self)
    }

    static func headerMagic(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x0C && data[data.startIndex + 1] == 0xC0
            && data[data.startIndex + 2] == 0xBE && data[data.startIndex + 3] == 0x44
    }

    /// Parses a manifest: its raw CDN bytes, its compressed body included. The
    /// header's SHA-1 covers the inflated body (the API names it, and the CDN
    /// fetch checks it first).
    static func parse(_ data: Data) throws -> EpicManifest {
        guard data.count > 41 else { throw EpicManifestError.truncated("manifest") }
        var manifest = EpicManifest()
        var reader = Reader(data: [UInt8](data))

        let magic = try reader.u32()
        guard magic == 0x44BEC00C else { throw EpicManifestError.magic }
        let headerSize = try reader.u32()
        let sizeUncompressed = try reader.u32()
        let sizeCompressed = try reader.u32()
        let sha = Array(try reader.raw(20))
        let storedAs = try reader.u8()
        let version = try reader.u32()
        guard version <= 24 else { throw EpicManifestError.truncated("manifest version \(version)") }
        guard Int(headerSize) <= reader.data.count, headerSize >= 30 else {
            throw EpicManifestError.truncated("header size")
        }
        let compressed = Data(data.dropFirst(Int(headerSize)))
        guard compressed.count == Int(sizeCompressed) else {
            throw EpicManifestError.truncated("body \(compressed.count), header says \(sizeCompressed)")
        }
        let inflated: Data
        if storedAs & 0x1 != 0 {
            inflated = EpicChunk.inflate(compressed, expected: Int(sizeUncompressed))
            guard inflated.count == Int(sizeUncompressed) else {
                throw EpicManifestError.truncated("inflated \(inflated.count), expected \(sizeUncompressed)")
            }
            guard sha1(inflated) == sha else { throw EpicManifestError.truncated("body hash") }
        } else {
            inflated = compressed
            guard inflated.count == Int(sizeUncompressed) else {
                throw EpicManifestError.truncated("body \(inflated.count), header says \(sizeUncompressed)")
            }
        }

        var bodyReader = Reader(data: [UInt8](inflated))
        try parseBody(&bodyReader, into: &manifest)
        return manifest
    }

    /// The body: metadata, chunk list, file list, custom fields.
    private static func parseBody(_ reader: inout Reader, into manifest: inout EpicManifest) throws {
        let metaSize = try reader.u32()
        manifest.meta.dataVersion = try reader.u8()
        manifest.meta.featureLevel = try reader.u32()
        manifest.meta.isFileData = try reader.u8() == 1
        manifest.meta.appID = try reader.u32()
        manifest.meta.appName = try fstring(&reader) ?? ""
        manifest.meta.buildVersion = try fstring(&reader) ?? ""
        manifest.meta.launchExe = try fstring(&reader) ?? ""
        manifest.meta.launchCommand = try fstring(&reader) ?? ""
        let prereqCount = try reader.u32()
        for _ in 0..<prereqCount { _ = try fstring(&reader) }
        _ = try fstring(&reader)   // prereq name
        _ = try fstring(&reader)   // prereq path
        _ = try fstring(&reader)   // prereq args
        if manifest.meta.dataVersion >= 1 { _ = try fstring(&reader) }   // build id
        if manifest.meta.dataVersion >= 2 {
            _ = try fstring(&reader)   // uninstall path
            _ = try fstring(&reader)   // uninstall args
        }
        // Legendary: the metadata block can be longer than what we read; skip the rest.
        // The block's size field counts itself (Legendary compares its stream
        // position, which starts at the size field, against metaSize), so the
        // rest is metaSize - 4; anything longer is skipped.
        let metaSizeRest = Int(metaSize) - 4
        guard metaSizeRest >= 0 else { throw EpicManifestError.truncated("metadata size") }
        if reader.offset < metaSizeRest {
            try reader.skip(metaSizeRest - reader.offset)
        }

        // Chunk data list: SoA — guids, then hashes, then shas, then groups...
        let cdlStart = reader.offset
        let cdlSize = try reader.u32()
        let cdlVersion = try reader.u8()
        let cdlCount = try reader.u32()
        guard cdlVersion <= 1 else { throw EpicManifestError.truncated("chunk list version \(cdlVersion)") }
        manifest.chunks = (0..<Int(cdlCount)).map { _ in EpicChunkInfo() }
        for index in manifest.chunks.indices {
            let g0 = try reader.u32(), g1 = try reader.u32(), g2 = try reader.u32(), g3 = try reader.u32()
            manifest.chunks[index].guid = (g0, g1, g2, g3)
        }
        for index in manifest.chunks.indices { manifest.chunks[index].hash = try reader.u64() }
        for index in manifest.chunks.indices {
            manifest.chunks[index].shaHash = Array(try reader.raw(20))
        }
        for index in manifest.chunks.indices { manifest.chunks[index].groupNum = try reader.u8() }
        for index in manifest.chunks.indices { manifest.chunks[index].windowSize = try reader.u32() }
        for index in manifest.chunks.indices { manifest.chunks[index].fileSize = Int64(bitPattern: try reader.u64()) }
        if cdlVersion >= 1 {
            // window size compressed and encryption tag (preloaded builds; not run here)
            for _ in manifest.chunks.indices { _ = try reader.u32() }
            for _ in manifest.chunks.indices { try reader.skip(16) }
        }
        let cdlSizeRest = Int(cdlSize) - 4
        guard cdlSizeRest >= 0 else { throw EpicManifestError.truncated("chunk list size") }
        if cdlSizeRest > reader.offset - cdlStart { try reader.skip(cdlSizeRest - (reader.offset - cdlStart)) }

        // File manifest list: names first, then the rest.
        let fmlStart = reader.offset
        let fmlSize = try reader.u32()
        let fmlVersion = try reader.u8()
        let fmlCount = try reader.u32()
        guard fmlVersion <= 2 else { throw EpicManifestError.truncated("file list version \(fmlVersion)") }
        manifest.files = (0..<Int(fmlCount)).map { _ in EpicFileManifest() }
        for index in manifest.files.indices {
            manifest.files[index].filename = try fstring(&reader) ?? ""
        }
        for index in manifest.files.indices {
            manifest.files[index].symlinkTarget = try fstring(&reader) ?? ""
        }
        for index in manifest.files.indices { manifest.files[index].hash = Array(try reader.raw(20)) }
        for index in manifest.files.indices { manifest.files[index].flags = try reader.u8() }
        for _ in manifest.files.indices {
            let tagCount = try reader.u32()
            for _ in 0..<tagCount { _ = try fstring(&reader) }
        }
        for index in manifest.files.indices {
            let partCount = try reader.u32()
            var fileOffset: UInt32 = 0
            for _ in 0..<partCount {
                let partSize = try reader.u32()
                let g0 = try reader.u32(), g1 = try reader.u32(), g2 = try reader.u32(), g3 = try reader.u32()
                let offset = try reader.u32()
                let size = try reader.u32()
                manifest.files[index].chunkParts.append(EpicChunkPart(
                    guid: (g0, g1, g2, g3), offset: offset, size: size, fileOffset: fileOffset))
                fileOffset += size
                if Int(partSize) > 28 { try reader.skip(Int(partSize) - 28) }
            }
        }
        if fmlVersion >= 1 {
            for _ in manifest.files.indices {
                let hasMD5 = try reader.u32()
                if hasMD5 != 0 { try reader.skip(16) }
            }
            for _ in manifest.files.indices { _ = try fstring(&reader) }   // mime type
        }
        if fmlVersion >= 2 {
            for _ in manifest.files.indices { try reader.skip(32) }   // sha-256
        }
        let fmlSizeRest = Int(fmlSize) - 4
        guard fmlSizeRest >= 0 else { throw EpicManifestError.truncated("file list size") }
        if fmlSizeRest > reader.offset - fmlStart { try reader.skip(fmlSizeRest - (reader.offset - fmlStart)) }

        // Custom fields (key/value fstring pairs).
        let keyCount = try reader.u32()
        for _ in 0..<keyCount {
            guard let key = try fstring(&reader), let value = try fstring(&reader) else { break }
            manifest.customFields[key] = value
        }

        var index: [String: Int] = [:]
        for (i, chunk) in manifest.chunks.enumerated() { index[chunk.guidLower] = i }
        manifest.chunkIndex = index
    }
}

extension EpicManifest {
    /// SHA-1 of a whole manifest (a few MB at most), checked against the
    /// API's hash. One digest call, as DepotDownloader checks its chunks.
    nonisolated static func sha1(_ data: Data) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA1(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest
    }
}
