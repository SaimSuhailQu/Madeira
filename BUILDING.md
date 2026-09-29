# Building Madeira

Madeira builds into a sideload-ready iOS Application Archive (`.ipa`) containing the Wine runtime, FEX-Emu, DXMT, and pre-seeded prefixes.

## Prerequisites

- macOS 14+ with **Xcode 15+** installed
- Apple command-line developer tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)

## Building the IPA

Run the automated build script from the repository root:

```bash
./scripts/build-ipa.sh
```

The script will:
1. Install required build dependencies via Homebrew (`cmake`, `ninja`, `meson`, `llvm`, etc.)
2. Check out all required submodules (`FEX`, `wine`, `research/dxmt`)
3. Set up the `llvm-mingw` toolchain
4. Configure Wine and build required headers/stubs
5. Cross-compile FEX-Emu for iOS (`libFEXCore.a`, `libFEXCore_Base.a`)
6. Compile FreeType and GnuTLS static libraries for iOS
7. Bootstrap and build `libwineserver.a`, `libntdll_unix.a`, and `libwin32u_unix.a`
8. Compile DXMT and generate Metal shader headers
9. Download and extract the Microsoft Visual C++ 64-bit runtime DLLs
10. Build the Xcode project and package `dist/Madeira.ipa` with JIT entitlements

## Output

Once complete, the sideload-ready IPA is located at:
```
dist/Madeira.ipa
```

Install using **SideStore**, **AltStore**, **LiveContainer**, or **TrollStore**.
