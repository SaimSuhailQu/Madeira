// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games chunk container (legendary/models/chunk.py): the header magic
// 0xB1FE3AA2, a versioned header, then the payload — zlib-compressed or
// encrypted (preloaded builds, not supported here). The body of every chunk is
// a 1 MiB window; a file is assembled from slices of chunk windows. Foundation
// only, so tests/host/check-epic-launcher.py compiles this file as it is.

import Foundation
import zlib

enum EpicChunkError: Error {
    case magic
    case truncated(String)
    case unsupported(String)
    case hashMismatch
}

struct EpicChunk {
    var headerVersion: UInt32 = 3
    var headerSize: UInt32 = 0
    var compressedSize: UInt32 = 0
    var guid: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    var hash: UInt64 = 0
    /// 0x1 = compressed, 0x2 = encrypted.
    var storedAs: UInt8 = 0
    var shaHash: [UInt8] = []
    var hashType: UInt8 = 0
    var uncompressedSize: UInt32 = 1024 * 1024

    var isCompressed: Bool { storedAs & 0x1 != 0 }
    var isEncrypted: Bool { storedAs & 0x2 != 0 }

    var guidString: String {
        String(format: "%08X-%08X-%08X-%08X", guid.0, guid.1, guid.2, guid.3)
    }

    /// Parses the header and inflates the payload. Encrypted chunks (only in
    /// preloaded builds, never in Live ones) are refused with a clear reason.
    static func parse(_ data: Data) throws -> (header: EpicChunk, payload: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 25 else { throw EpicChunkError.truncated("chunk header") }
        var offset = 0
        func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw EpicChunkError.truncated("chunk header") }
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (i * 8) }
            offset += 4
            return value
        }
        func u64() throws -> UInt64 {
            guard offset + 8 <= bytes.count else { throw EpicChunkError.truncated("chunk header") }
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (i * 8) }
            offset += 8
            return value
        }

        let magic = try u32()
        guard magic == 0xB1FE3AA2 else { throw EpicChunkError.magic }
        var chunk = EpicChunk()
        chunk.headerVersion = try u32()
        chunk.headerSize = try u32()
        chunk.compressedSize = try u32()
        let g0 = try u32(), g1 = try u32(), g2 = try u32(), g3 = try u32()
        chunk.guid = (g0, g1, g2, g3)
        chunk.hash = try u64()
        guard offset < bytes.count else { throw EpicChunkError.truncated("chunk header") }
        chunk.storedAs = bytes[offset]; offset += 1
        if chunk.headerVersion >= 2 {
            guard offset + 21 <= bytes.count else { throw EpicChunkError.truncated("chunk header") }
            chunk.shaHash = Array(bytes[offset..<offset + 20]); offset += 20
            chunk.hashType = bytes[offset]; offset += 1
        }
        if chunk.headerVersion >= 3 {
            chunk.uncompressedSize = try u32()
        }
        if chunk.headerVersion >= 4 {
            // secret GUID and GCM tag: encrypted chunks are not supported
            if offset + 32 > bytes.count { throw EpicChunkError.truncated("chunk header") }
            offset += 32
        }
        if offset != Int(chunk.headerSize) {
            guard Int(chunk.headerSize) <= bytes.count else { throw EpicChunkError.truncated("chunk header size") }
            offset = Int(chunk.headerSize)
        }
        guard chunk.headerVersion <= 4 else { throw EpicChunkError.unsupported("chunk version \(chunk.headerVersion)") }
        guard !chunk.isEncrypted else { throw EpicChunkError.unsupported("encrypted (preloaded) chunks") }

        let payload = Data(bytes[offset...])
        guard payload.count == Int(chunk.compressedSize) else {
            throw EpicChunkError.truncated("payload \(payload.count), header says \(chunk.compressedSize)")
        }
        guard chunk.isCompressed else { return (chunk, payload) }
        let inflated = EpicChunk.inflate(payload, expected: Int(chunk.uncompressedSize))
        guard inflated.count == Int(chunk.uncompressedSize) else {
            throw EpicChunkError.truncated("inflated \(inflated.count), expected \(chunk.uncompressedSize)")
        }
        return (chunk, inflated)
    }

    /// zlib (deflate) inflate, with an optional expected size. Falls back to a
    /// raw-deflate second pass when the stream has no zlib header: the CDN
    /// serves some manifests that way (Legendary reports the same).
    static func inflate(_ data: Data, expected: Int? = nil) -> Data {
        let viaZlib = inflateStream(data, expected: expected, raw: false)
        if !viaZlib.isEmpty { return viaZlib }
        if data.count >= 2, data[data.startIndex] & 0x0F == 8 {
            // A zlib header would end in the right bits; a miss here means the
            // stream is raw deflate.
            let raw = inflateStream(data, expected: expected, raw: true)
            if !raw.isEmpty { return raw }
        }
        return Data()
    }

    /// One inflate pass. `raw` runs plain deflate (no zlib header).
    private static func inflateStream(_ data: Data, expected: Int?, raw: Bool) -> Data {
        var stream = z_stream()
        var status = raw
            ? zlib.inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : zlib.inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return Data() }
        defer { zlib.inflateEnd(&stream) }
        var input = [UInt8](data)
        let reserve = expected.map { $0 } ?? max(data.count * 4, 1 << 20)
        var output = [UInt8](repeating: 0, count: reserve)
        var produced = 0
        return input.withUnsafeMutableBufferPointer { inBuf -> Data in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = UInt32(inBuf.count)
            return output.withUnsafeMutableBufferPointer { outBuf -> Data in
                while produced < outBuf.count {
                    stream.next_out = outBuf.baseAddress! + produced
                    stream.avail_out = UInt32(outBuf.count - produced)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let written = outBuf.count - produced - Int(stream.avail_out)
                    produced += written
                    if status == Z_STREAM_END || (status != Z_OK && status != Z_BUF_ERROR) { break }
                    if written == 0 { break }
                }
                return Data(outBuf.prefix(produced))
            }
        }
    }

    /// Assembles a file from chunk payloads: every part is a slice of its
    /// chunk's 1 MiB window. Parts must be in file order.
    static func assemble(parts: [EpicChunkPart],
                         payloads: [String: Data]) -> Data {
        var file = Data()
        file.reserveCapacity(parts.last.map { Int($0.fileOffset + $0.size) } ?? 0)
        for part in parts {
            guard let payload = payloads[part.guidStringLower] else { continue }
            let start = Int(part.offset)
            let end = min(start + Int(part.size), payload.count)
            guard start <= end else { continue }
            file.append(payload.subdata(in: payload.startIndex + start..<payload.startIndex + end))
        }
        return file
    }
}

extension EpicChunkPart {
    /// The key chunk payloads are stored under: the GUID string as the
    /// manifest spells it (lower case, hyphenated).
    var guidStringLower: String {
        String(format: "%08x-%08x-%08x-%08x", guid.0, guid.1, guid.2, guid.3)
    }
}
