#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEST="$ROOT/app/Madeira/x86_64-vcruntime"
CACHE="$ROOT/toolchains/downloads"
EXE="${VC_REDIST_X64:-$CACHE/vc_redist.x64.exe}"
URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
DLLS=(
  concrt140.dll
  msvcp140.dll
  msvcp140_1.dll
  msvcp140_2.dll
  msvcp140_atomic_wait.dll
  msvcp140_codecvt_ids.dll
  vcamp140.dll
  vccorlib140.dll
  vcomp140.dll
  vcruntime140.dll
  vcruntime140_1.dll
  vcruntime140_threads.dll
)

all_present=1
for dll in "${DLLS[@]}"; do [[ -f "$DEST/$dll" ]] || all_present=0; done
if (( all_present )); then
  echo "Visual C++ runtime: cached"
  exit 0
fi

SEVENZIP=""
if command -v 7zz >/dev/null; then
  SEVENZIP="7zz"
elif command -v 7z >/dev/null; then
  SEVENZIP="7z"
else
  echo "ERROR: 7zz or 7z is required (brew install sevenzip)" >&2
  exit 1
fi

mkdir -p "$DEST" "$CACHE"

# Validate or re-download executable. Remove partial/corrupt downloads.
validate_exe() {
  [[ -f "$1" && -s "$1" ]] && "$SEVENZIP" t "$1" >/dev/null 2>&1
}

if ! validate_exe "$EXE"; then
  echo "Downloading the official Microsoft Visual C++ x64 Redistributable..."
  rm -f "$EXE"
  curl --fail --location --retry 3 --retry-all-errors -o "$EXE" "$URL"
  if ! validate_exe "$EXE"; then
    echo "ERROR: Downloaded $EXE is invalid or corrupt" >&2
    exit 1
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

EXTRACT_DIR="$TMP/redist"
mkdir -p "$EXTRACT_DIR"
"$SEVENZIP" x -y "$EXE" -o"$EXTRACT_DIR" >/dev/null

# Extract the bootstrapper and search recursively for CAB payloads.
# In case nested executables/installers contain the CABs, extract them as well.
while true; do
  nested_found=0
  while IFS= read -r nested; do
    nested_dir="${nested}_extracted"
    if [[ ! -d "$nested_dir" ]]; then
      mkdir -p "$nested_dir"
      if "$SEVENZIP" x -y "$nested" -o"$nested_dir" >/dev/null 2>&1; then
        nested_found=1
      fi
    fi
  done < <(find "$EXTRACT_DIR" -type f \( -iname '*.exe' -o -iname '*.msi' \) | sort)
  (( nested_found == 0 )) && break
done

# The Microsoft x64 package can also contain ARM64 payloads. Extract all
# CABs, then select only PE32+ AMD64 (Machine 0x8664) DLLs by reading each PE
# header. This keeps the build correct even if Microsoft changes CAB ordering.
CABS=()
while IFS= read -r cab; do CABS+=("$cab"); done < <(find "$EXTRACT_DIR" -type f -iname '*.cab' | sort)
if (( ${#CABS[@]} == 0 )); then
  echo "VC redist contents ($EXE):"
  "$SEVENZIP" l "$EXE" || true
  echo "ERROR: could not locate CAB payloads inside $EXE" >&2
  exit 1
fi

mkdir -p "$TMP/cabs"
for i in "${!CABS[@]}"; do
  mkdir -p "$TMP/cabs/$i"
  "$SEVENZIP" x -y "${CABS[$i]}" -o"$TMP/cabs/$i" >/dev/null || true
done

is_amd64_pe() {
  python3 - "$1" <<'PYPE'
from pathlib import Path
import struct
import sys

p = Path(sys.argv[1])
try:
    data = p.read_bytes()
    if data[:2] != b"MZ" or len(data) < 0x40:
        raise ValueError
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError
    machine = struct.unpack_from("<H", data, pe + 4)[0]
except (OSError, ValueError, struct.error):
    sys.exit(2)

sys.exit(0 if machine == 0x8664 else 1)
PYPE
}

for dll in "${DLLS[@]}"; do
  src=""
  while IFS= read -r candidate; do
    if is_amd64_pe "$candidate"; then
      src="$candidate"
      break
    fi
  done < <(find "$TMP/cabs" -type f -iname "$dll" | sort)
  [[ -n "$src" ]] || { echo "ERROR: x86_64 $dll not found in Microsoft redistributable" >&2; exit 1; }
  cp "$src" "$DEST/$dll"
done

echo "Visual C++ runtime: extracted to $DEST"
