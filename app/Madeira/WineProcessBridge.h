#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Start Wine process initialization on a background thread.
// Must be called AFTER wineserver is running.
// prefix_path: path to the Wine prefix directory
// Returns 0 on success, -1 on error.
int wine_process_start(const char *prefix_path);

// Check if Wine process is running
int wine_process_is_running(void);

// Steam S0 net-test VPN gate: write C:\madeira-continue.flag into the
// prefix's drive_c so the paused winhttp-test.exe resumes to the Steam
// stage. Called by the "Continue Net Test" UI button after the user has
// detached the JIT debugger and switched VPNs. Returns 0 on success.
int madeira_write_continue_flag(void);

// ---------------------------------------------------------------------------
// ml777: PE architecture detection (32-bit / WoW64 support)
//
// Reads IMAGE_FILE_MACHINE_* from a PE file so launches pick the right
// session architecture from the binary itself instead of the old "x64 in
// the name" filename heuristic. Real 32-bit games and Steam's steam.exe
// carry no "x64" marker, so the header is the only reliable discriminator.
// ---------------------------------------------------------------------------

// IMAGE_FILE_MACHINE values the app distinguishes.
#define MADEIRA_PE_MACHINE_I386   0x014cu
#define MADEIRA_PE_MACHINE_AMD64  0x8664u
#define MADEIRA_PE_MACHINE_ARM64  0xAA64u
#define MADEIRA_PE_MACHINE_ARM64EC 0xA641u

// Read the machine type from a PE file at a UNIX (sandbox) path.
// Returns 0 and fills *machine_out on success, -1 when the file is absent,
// unreadable, too small, or not a PE (no MZ/PE signature).
int madeira_pe_machine_from_unix_path(const char *unix_path, uint32_t *machine_out);

// Same, but for a Wine-style target spec: either a full Windows path
// ("C:\Program Files\Steam\steam.exe") or a bare name ("steam.exe",
// resolved under C:\windows\system32). prefix_path is the Wine prefix
// root (the same string passed to wine_process_start).
// Returns 0 and fills *machine_out on success, -1 otherwise.
int madeira_pe_machine_from_win_path(const char *prefix_path,
                                     const char *win_spec,
                                     uint32_t *machine_out);

#ifdef __cplusplus
}
#endif
