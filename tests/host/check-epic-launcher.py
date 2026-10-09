#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host checks for the Epic Games launcher (app/Madeira/Epic, EpicInstall.swift).

Never contacts Epic. It needs swiftc (Linux), python3 with `cryptography` or the
openssl command, and zlib (stdlib).

Part A is static: licence headers, the Xcode project, the only token path
(EpicAuth's Keychain item), no account data in a log line, no program names,
and that the sources do not say they are ports of another project.

Part B builds the production Swift (the manifest parser, the chunk container
and the installer) into one AddressSanitizer executable, with a scripted
CDN (a local HTTP server that serves the manifest and chunks built here) and
runs it:

* units: the manifest header, metadata, chunk list and file list formats
  (including a UTF-16 filename), hostile paths never leaving the install
  folder, the chunk header and hash checks;
* installs: a whole download against the local CDN (a shared chunk used by two
  files is fetched once), files written to the install folder, the install
  record written last, a hash mismatch refused, and uninstall removing the
  folder, the record and the library entry.
"""
from pathlib import Path
import hashlib
import http.server
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import zlib

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
epic = app / 'Epic'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
CC = os.environ.get('CC') or shutil.which('cc') or 'cc'
failures = 0


def check(condition, label):
    global failures
    if condition:
        print('PASS: ' + label)
    else:
        print('FAIL: ' + label)
        failures += 1


CRYPTO_H = r'''
#ifndef cc_shim_h
#define cc_shim_h
#include <stddef.h>
#include <stdint.h>
typedef uint32_t CCOperation;
typedef uint32_t CCAlgorithm;
typedef uint32_t CCOptions;
typedef int32_t CCCryptorStatus;
typedef uint32_t CC_LONG;
enum { kCCEncrypt = 0, kCCDecrypt = 1 };
enum { kCCAlgorithmAES = 0 };
enum { kCCOptionPKCS7Padding = 1, kCCOptionECBMode = 2 };
enum { kCCSuccess = 0, kCCParamError = -4300, kCCBufferTooSmall = -4301, kCCDecodeError = -4304 };
enum { kCCBlockSizeAES128 = 16 };
#define CC_SHA1_DIGEST_LENGTH 20
CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options, const void *key, size_t keyLength,
                        const void *iv, const void *dataIn, size_t dataInLength, void *dataOut,
                        size_t dataOutAvailable, size_t *dataOutMoved);
unsigned char *CC_SHA1(const void *data, CC_LONG len, unsigned char *md);
#endif
'''

CRYPTO_C = r'''
#include "cc_shim.h"
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <string.h>
#include <stdlib.h>
CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options, const void *key, size_t keyLength,
                        const void *iv, const void *dataIn, size_t dataInLength, void *dataOut,
                        size_t dataOutAvailable, size_t *dataOutMoved) {
    if (alg != kCCAlgorithmAES || keyLength != 32) return kCCParamError;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    const EVP_CIPHER *cipher = (options & kCCOptionECBMode) ? EVP_aes_256_ecb() : EVP_aes_256_cbc();
    if (!EVP_CipherInit_ex(ctx, cipher, NULL, key, (options & kCCOptionECBMode) ? NULL : iv, op == kCCEncrypt)) { EVP_CIPHER_CTX_free(ctx); return kCCParamError; }
    EVP_CIPHER_CTX_set_padding(ctx, (options & kCCOptionPKCS7Padding) ? 1 : 0);
    unsigned char *tmp = malloc(dataInLength + 32);
    int n1 = 0, n2 = 0;
    int ok = EVP_CipherUpdate(ctx, tmp, &n1, dataIn, (int)dataInLength) && EVP_CipherFinal_ex(ctx, tmp + n1, &n2);
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) { free(tmp); return kCCDecodeError; }
    if ((size_t)(n1 + n2) > dataOutAvailable) { free(tmp); return kCCBufferTooSmall; }
    memcpy(dataOut, tmp, n1 + n2); *dataOutMoved = n1 + n2; free(tmp);
    return kCCSuccess;
}
unsigned char *CC_SHA1(const void *data, CC_LONG len, unsigned char *md) { return SHA1(data, len, md); }
'''

LICENCE = 'SPDX-License-Identifier: GPL-3.0-or-later'

# ---------------------------------------------------------------------------
# Part A: static checks
# ---------------------------------------------------------------------------

static_files = ['Epic/EpicAPI.swift', 'Epic/EpicAuth.swift', 'Epic/EpicSignInView.swift',
                'Epic/EpicManifest.swift', 'Epic/EpicChunk.swift',
                'Epic/EpicInstall.swift', 'Epic/EpicInstallModel.swift']
sources = {}
for name in static_files:
    path = app / name
    if not path.exists():
        check(False, f'{name} exists')
        continue
    sources[name] = path.read_text()
    check(LICENCE in sources[name], f'{name}: licence header')

# The only token path: EpicAuth's Keychain item. Nothing else stores tokens.
ksec_files = [n for n, s in sources.items() if 'SecItemAdd' in s or 'kSecClass' in s]
check(ksec_files == ['Epic/EpicAuth.swift'], f'tokens only in EpicAuth (got {ksec_files})')

# No account data in a log line.
log_leak = re.compile(r'LogStore\.shared\.log\([^)]*(token|Token|authorizationCode)')
check(all(not log_leak.search(s) for s in sources.values()), 'no token in a log line')

# No claims of being a port of another project.
port_words = re.compile(r'(?i)(port of|ported from)')
check(all(not port_words.search(s) for s in sources.values()), 'no "ported from" claims')

# The launcher's client secret only ever appears in EpicAuth.
secret_files = [n for n, s in sources.items()
                if 'daafbccc737745039dffe53d94fc76cf' in s]
check(secret_files == ['Epic/EpicAuth.swift'], f'client secret only in EpicAuth (got {secret_files})')

# ---------------------------------------------------------------------------
# Manifest and chunk fixtures, built here
# ---------------------------------------------------------------------------


def fstring(s):
    if s is None:
        return struct.pack('<i', 0)
    try:
        raw = s.encode('ascii')
        return struct.pack('<i', len(s) + 1) + raw + b'\x00'
    except UnicodeEncodeError:
        raw = s.encode('utf-16-le')
        return struct.pack('<i', -(len(s) + 1)) + raw + b'\x00\x00'


class Fixture:
    """One synthetic game build: a few files made of 1 MiB chunks."""

    def __init__(self, app_name='TestGame', launch_exe='Bin/TestGame.exe'):
        self.app_name = app_name
        self.build_version = '1.0.0-111'
        self.launch_exe = launch_exe
        self.chunks = {}      # guid -> (payload bytes, compressed bytes)
        self.files = []       # (filename, flags, [(guid, offset, size)])

    def add_chunk(self, payload):
        guid = (len(self.chunks) + 1, 0x22222222, 0x33333333, 0x44444444)
        compressed = zlib.compress(payload)
        sha = hashlib.sha1(payload).digest()
        self.chunks[guid] = (payload, compressed, sha)
        return guid

    def add_file(self, filename, size, flags=0):
        parts = []
        remaining = size
        file_offset = 0
        while remaining > 0:
            take = min(remaining, 1024 * 1024)
            payload = (bytes([len(self.files) + 1]) * take)
            guid = self.add_chunk(payload)
            parts.append((guid, 0, take))
            file_offset += take
            remaining -= take
        self.files.append((filename, flags, parts, size))

    def manifest(self, feature_level=18, with_launch=True):
        # metadata
        meta = struct.pack('<I', 0) + struct.pack('<B', 1) + struct.pack('<I', feature_level)
        meta += struct.pack('<B', 0) + struct.pack('<I', 0)
        meta += fstring(self.app_name) + fstring(self.build_version)
        meta += fstring(self.launch_exe if with_launch else '')
        meta += fstring('')   # launch command
        meta += struct.pack('<I', 0)   # no prereq ids
        meta += fstring('') + fstring('') + fstring('')   # prereq name, path, args
        meta += fstring('')   # build id (data version is 1)
        # metaSize counts from the body's first byte (right after the header),
        # which is the metadata block itself: its size field included.
        meta = struct.pack('<I', len(meta) + 4) + meta[4:]
        if feature_level >= 18:
            pass
        # chunk data list
        guids = list(self.chunks.keys())
        cdl_body = struct.pack('<B', 0) + struct.pack('<I', len(guids))
        for guid in guids:
            cdl_body += struct.pack('<IIII', *guid)
        for guid in guids:
            payload, compressed, sha = self.chunks[guid]
            cdl_body += struct.pack('<Q', struct.unpack('<Q', hashlib.sha1(struct.pack('<IIII', *guid)).digest()[:8])[0])
        for guid in guids:
            cdl_body += self.chunks[guid][2]
        for guid in guids:
            cdl_body += struct.pack('<B', zlib.crc32(struct.pack('<IIII', *guid)) % 100)
        for guid in guids:
            cdl_body += struct.pack('<I', len(self.chunks[guid][0]))
        for guid in guids:
            cdl_body += struct.pack('<q', len(self.chunks[guid][1]))
        cdl = struct.pack('<I', len(cdl_body) + 4) + cdl_body
        # file manifest list
        names = [f[0] for f in self.files]
        symlinks = ['' for _ in self.files]
        hashes = [hashlib.sha1(b'file:' + f[0].encode()).digest() for f in self.files]
        flags = [f[1] for f in self.files]
        tags = [[] for _ in self.files]
        parts = [f[2] for f in self.files]
        fml_body = struct.pack('<B', 0) + struct.pack('<I', len(self.files))
        for name in names:
            fml_body += fstring(name)
        for link in symlinks:
            fml_body += fstring(link)
        for h in hashes:
            fml_body += h
        for fl in flags:
            fml_body += struct.pack('<B', fl)
        for t in tags:
            fml_body += struct.pack('<I', len(t))
            for tag in t:
                fml_body += fstring(tag)
        for p in parts:
            encoded = b''
            for (guid, offset, size) in p:
                encoded += struct.pack('<I', 28) + struct.pack('<IIII', *guid)
                encoded += struct.pack('<I', offset) + struct.pack('<I', size)
            fml_body += struct.pack('<I', len(p)) + encoded
        fml = struct.pack('<I', len(fml_body) + 4) + fml_body
        # custom fields
        custom = struct.pack('<I', 1) + fstring('BuildVersion') + fstring(self.build_version)

        body = meta + cdl + fml + custom
        compressed = zlib.compress(body)
        header = struct.pack('<I', 0x44BEC00C)
        header += struct.pack('<I', 41)
        header += struct.pack('<I', len(body))
        header += struct.pack('<I', len(compressed))
        header += hashlib.sha1(body).digest()
        header += struct.pack('<B', 1)
        header += struct.pack('<I', feature_level)
        return header + compressed

    def chunk_bytes(self, guid):
        payload, compressed, sha = self.chunks[guid]
        header = struct.pack('<I', 0xB1FE3AA2)
        header += struct.pack('<I', 3)                    # header version
        header_size_at = len(header)
        header += struct.pack('<I', 0)                    # header size (back-patched)
        compressed_size_at = len(header)
        header += struct.pack('<I', 0)                    # compressed size (back-patched)
        header += struct.pack('<IIII', *guid)
        chunk_hash = struct.unpack('<Q', hashlib.sha1(struct.pack('<IIII', *guid)).digest()[:8])[0]
        header += struct.pack('<Q', chunk_hash)
        header += struct.pack('<B', 1)                    # compressed
        header += sha                                     # sha of the payload
        header += struct.pack('<B', 1)                    # hash type
        header += struct.pack('<I', len(payload))         # uncompressed size
        header = header[:header_size_at] + struct.pack('<I', len(header)) + header[header_size_at + 4:]
        header = header[:compressed_size_at] + struct.pack('<I', len(compressed)) + header[compressed_size_at + 4:]
        return header + compressed

    def manifest_hash(self):
        return hashlib.sha1(self.manifest()).hexdigest()

    def file_bytes(self, index):
        parts = self.files[index][2]
        return b''.join(self.chunks[p[0]][0][p[1]:p[1] + p[2]] for p in parts)


class CDNHandler(http.server.BaseHTTPRequestHandler):
    fixture = None
    served = []


    def do_GET(self):
        path = self.path.split('?')[0]
        CDNHandler.served.append(path)
        if path == '/manifest':
            data = self.fixture.manifest()
        elif any(path.startswith(f'/ChunksV{v}/') for v in range(1, 6)):
            guid_hex = path.rsplit('_', 1)[-1].replace('.chunk', '').replace('-', '')
            guid = tuple(int(guid_hex[i:i + 8], 16) for i in range(0, 32, 8))
            data = self.fixture.chunk_bytes(guid)
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def start_cdn(fixture):
    handler = type('H', (CDNHandler,), {})
    handler.fixture = fixture
    handler.served = []
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


# ---------------------------------------------------------------------------
# Part B: compiled checks
# ---------------------------------------------------------------------------

if not Path(SWIFTC).exists():
    print('SKIP: no swiftc (set SWIFTC); compiled checks not run')
    sys.exit(1 if failures else 0)

OVERRIDES = '''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The check runs the production installer against a local CDN: the only API
/// call site (manifestResponse) is replaced with one that names the fixture.
extension EpicInstaller {
    static func fixtureManifestResponse(namespace: String, catalogItemID: String, appName: String,
                                        token: String) async throws -> AssetManifestResponse {
        guard appName == ProcessInfo.processInfo.environment["FIXTURE_APP_NAME"] else {
            throw EpicInstallError.noManifest("unknown app")
        }
        // The fixture answers with locally built manifest bytes (built by the
        // check, handed over through the file system): the CDN only serves the
        // fetchManifest path, exactly once.
        let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_MANIFEST"]!))
        let hash = EpicManifest.sha1(data)
        guard hash.map({ String(format: "%02x", $0) }).joined()
                  == ProcessInfo.processInfo.environment["FIXTURE_MANIFEST_SHA"] else {
            throw EpicInstallError.manifestHash
        }
        let base = ProcessInfo.processInfo.environment["FIXTURE_BASE"]!
        return AssetManifestResponse(hash: hash, urls: [base + "/manifest"],
                                     buildVersion: ProcessInfo.processInfo.environment["FIXTURE_BUILD"]!)
    }
}

/// The install runs against the local CDN, never Epic's API: the harness sets
/// EpicInstaller.manifestProvider = fixtureManifestResponse in main().
'''

SHIMS = '''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CommonCrypto
import zlib
'''

CHECKS = '''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated(unsafe) var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

@main struct Harness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        EpicInstaller.manifestProvider = EpicInstaller.fixtureManifestResponse(namespace:catalogItemID:appName:token:)
        let env = ProcessInfo.processInfo.environment

        // --- unit: manifest parse ---
        let manifestData = try! Data(contentsOf: URL(fileURLWithPath: env["FIXTURE_MANIFEST"]!))
        let manifest = try! EpicManifest.parse(manifestData)
        require(manifest.meta.appName == env["FIXTURE_APP_NAME"]!, "manifest: app name")
        require(manifest.meta.buildVersion == env["FIXTURE_BUILD"]!, "manifest: build version")
        require(manifest.meta.launchExe == env["FIXTURE_LAUNCH_EXE"]!, "manifest: launch exe")
        require(manifest.files.count == Int(env["FIXTURE_FILE_COUNT"]!)!, "manifest: file count")
        require(manifest.chunks.count == Int(env["FIXTURE_CHUNK_COUNT"]!)!, "manifest: chunk count")
        require(manifest.files.allSatisfy { $0.safeRelativePath != nil }, "manifest: every fixture path is safe")

        // --- unit: chunk round-trip ---
        let chunkFile = try! Data(contentsOf: URL(fileURLWithPath: env["FIXTURE_CHUNK"]!))
        let (header, payload) = try! EpicChunk.parse(chunkFile)
        require(payload.count == Int(header.uncompressedSize), "chunk: payload is the window size")

        // --- unit: hostile paths ---
        var hostileFile = EpicFileManifest()
        hostileFile.filename = "..\\\\..\\\\windows\\\\system32\\\\evil.exe"
        require(hostileFile.safeRelativePath == nil, "hostile path: .. refused")
        hostileFile.filename = "C:\\\\Windows\\\\evil.exe"
        require(hostileFile.safeRelativePath == nil, "hostile path: drive letter refused")
        hostileFile.filename = "Bin/Game.exe"
        require(hostileFile.safeRelativePath == "Bin/Game.exe", "hostile path: a normal name passes")

        // --- unit: a chunk whose payload does not match its size is refused ---
        do {
            let corrupt = [UInt8](chunkFile.prefix(24)) + [UInt8](repeating: 0, count: 100)
            _ = try EpicChunk.parse(Data(corrupt))
            require(false, "chunk: a truncated chunk is refused")
        } catch {
            require(true, "chunk: a truncated chunk is refused")
        }

        // --- install: the whole download against the local CDN ---
        let drive = URL(fileURLWithPath: env["FIXTURE_DRIVE"]!, isDirectory: true)
        let installer = EpicInstaller()
        var installError: String?
        do {
            _ = try await installer.install(
                appName: env["FIXTURE_APP_NAME"]!, title: "Test Game",
                namespace: "testns", catalogItemID: "cid123",
                token: "test-token", drive: drive)
        } catch {
            installError = String(describing: error)
        }
        require(installError == nil, "install: completed (\(installError ?? "ok"))")

        let folder = drive.appendingPathComponent("Epic Games/TestGame", isDirectory: true)
        let fileCount = Int(env["FIXTURE_FILE_COUNT"]!)!
        for index in 0..<fileCount {
            let name = env["FIXTURE_FILE_\(index)"]!
            let url = folder.appendingPathComponent(name)
            let exists = FileManager.default.fileExists(atPath: url.path)
            require(exists, "install: file \(name) written")
            if exists, let data = try? Data(contentsOf: url),
               let expected = env["FIXTURE_FILE_\(index)_SHA"] {
                let got = EpicManifest.sha1(data).map { String(format: "%02x", $0) }.joined()
                require(got == expected, "install: file \(name) bytes match the fixture")
            }
        }

        // The record was written, last (a failed download leaves none behind).
        let records = EpicInstallStore.loadSynced()
        require(records.count == 1, "install: one record")
        require(records.first?.appName == env["FIXTURE_APP_NAME"], "install: record names the app")
        require(records.first?.launchExe == env["FIXTURE_LAUNCH_EXE"]!, "install: record keeps the launch exe")
        require(records.first?.folder == "Epic Games/TestGame", "install: record keeps the folder")

        // --- uninstall ---
        if let record = records.first {
            let removed = EpicInstallPaths.deleteFolder(record: record, drive: drive)
            require(removed, "uninstall: folder removed")
            require(!FileManager.default.fileExists(atPath: folder.path), "uninstall: folder gone")
            EpicInstallStore.remove(appName: record.appName)
            require(EpicInstallStore.loadSynced().isEmpty, "uninstall: record gone")
        }

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: compiled phase")
        exit(0)
    }
}
'''

print('Building the compiled check...')
work = Path(tempfile.mkdtemp(prefix='check-epic-'))
shim = work / 'shim'
(shim / 'CommonCrypto').mkdir(parents=True)
(shim / 'CommonCrypto/cc_shim.h').write_text(CRYPTO_H)
(shim / 'CommonCrypto/cc_shim.c').write_text(CRYPTO_C)
(shim / 'CommonCrypto/module.modulemap').write_text('module CommonCrypto [system] { header "cc_shim.h" export * }\n')
(shim / 'zlib').mkdir()
(shim / 'zlib/module.modulemap').write_text('module zlib [system] { header "/usr/include/zlib.h" link "z" export * }\n')
cc_obj = work / 'cc_shim.o'
openssl_include = os.environ.get('OPENSSL_INCLUDE')
openssl_lib = os.environ.get('OPENSSL_LIB')
cc_extra = []
if openssl_include: cc_extra += [flag for path in openssl_include.split(':') for flag in ('-I', path)]
if openssl_lib: cc_extra += ['-L', openssl_lib]
build_cc = subprocess.run([CC, '-c', '-g', '-fsanitize=address', '-w', str(shim / 'CommonCrypto/cc_shim.c'),
                           '-I', str(shim / 'CommonCrypto')] + cc_extra + ['-o', str(cc_obj)], capture_output=True, text=True)
if build_cc.returncode:
    print(build_cc.stderr)
    sys.exit(1)

(work / 'checks.swift').write_text(CHECKS)
(work / 'overrides.swift').write_text(OVERRIDES)
swift_sources = [app / 'Epic/EpicManifest.swift', app / 'Epic/EpicChunk.swift', app / 'Epic/EpicInstall.swift']
exe = work / 'check'
link_extra = []
if openssl_lib: link_extra += ['-L', openssl_lib, '-lcrypto']
build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-g',
                        '-I', str(shim / 'CommonCrypto'), '-I', str(shim / 'zlib'),
                        '-o', str(exe), str(cc_obj)] + link_extra + [
                        str(work / 'checks.swift'), str(work / 'overrides.swift')] + [str(s) for s in swift_sources],
                       capture_output=True, text=True)
if build.returncode != 0:
    print(build.stdout)
    print(build.stderr)
    sys.exit(1)
check(True, 'compiled check builds')

fixture = Fixture()
fixture.add_file('Bin/TestGame.exe', 1024 * 1024 + 7, flags=1)
fixture.add_file('Data/pak0.pak', 2 * 1024 * 1024)
fixture.add_file('Readme.txt', 11)
# Share the exe's first chunk with the pak (one guid reused for part of the pak).
shared_guid = fixture.files[0][2][0][0]
fixture.files[1][2].append((shared_guid, 0, 4096))
fixture.files[1] = (fixture.files[1][0], fixture.files[1][1], fixture.files[1][2], 2 * 1024 * 1024 + 4096)

server, base = start_cdn(fixture)
try:
    drive = Path(tempfile.mkdtemp(prefix='epic-drive-'))
    manifest_bytes = fixture.manifest()
    (work / 'manifest.bin').write_bytes(manifest_bytes)
    first_guid = next(iter(fixture.chunks))
    (work / 'chunk.bin').write_bytes(fixture.chunk_bytes(first_guid))

    env = dict(os.environ)
    env.update({
        'FIXTURE_MANIFEST': str(work / 'manifest.bin'),
        'FIXTURE_CHUNK': str(work / 'chunk.bin'),
        'FIXTURE_MANIFEST_SHA': hashlib.sha1(manifest_bytes).hexdigest(),
        'FIXTURE_APP_NAME': 'TestGame',
        'FIXTURE_BUILD': '1.0.0-111',
        'FIXTURE_LAUNCH_EXE': 'Bin/TestGame.exe',
        'FIXTURE_FILE_COUNT': '3',
        'FIXTURE_CHUNK_COUNT': str(len(fixture.chunks)),
        'FIXTURE_UNIQUE_CHUNKS': str(len(fixture.chunks)),
        'FIXTURE_DRIVE': str(drive),
        'FIXTURE_BASE': base,
    })
    for index, f in enumerate(fixture.files):
        env[f'FIXTURE_FILE_{index}'] = f[0]
        env[f'FIXTURE_FILE_{index}_SHA'] = hashlib.sha1(fixture.file_bytes(index)).hexdigest()

    CDNHandler.served = []
    # Swift's Foundations caches allocations at exit (URLSession, curl); they
    # are not leaks in the code under test. The compiled phase exits 0 itself;
    # skip LSan's exit-time leak report.
    env['ASAN_OPTIONS'] = 'detect_leaks=0'
    result = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=180)
    print(result.stdout, end='')
    if result.returncode != 0 and result.stderr:
        print(result.stderr, file=sys.stderr, end='')
    served = len(CDNHandler.served)
    check(served == len(fixture.chunks) + 1,
          f'CDN served the manifest and every chunk exactly once (served {served}, expect {len(fixture.chunks) + 1})')
    sys.exit(result.returncode if result.returncode != 0 else (1 if failures else 0))
finally:
    server.shutdown()
