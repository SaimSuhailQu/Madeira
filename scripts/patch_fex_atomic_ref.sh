#!/usr/bin/env bash
# Patch FEX to fix macOS/iOS cross-compilation:
# 1. atomic_ref fallback on Clang/libc++ when __cpp_lib_atomic_ref is missing
# 2. Add weak fallbacks for iOS symbols in FEXCore and Core.cpp
# 3. Guard host-specific code on Apple platforms
set -euo pipefail

FEX_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../FEX" && pwd)}"

if [ ! -d "$FEX_DIR" ]; then
  echo "ERROR: FEX directory not found: $FEX_DIR" >&2
  exit 1
fi

echo "Patching FEX for atomic_ref and iOS guards in $FEX_DIR..."

# 1. atomic_ref fallback in IntrusiveSList.h
SLIST_H="$FEX_DIR/FEXCore/Source/Utils/IntrusiveSList.h"
if [ -f "$SLIST_H" ]; then
  if grep -q "<atomic>" "$SLIST_H" && ! grep -q "std::atomic_ref" "$SLIST_H"; then
    echo "IntrusiveSList.h already clean or doesn't use atomic_ref"
  fi
  # If IntrusiveSList uses atomic_ref without fallback, provide an emulation wrapper
  if grep -q "std::atomic_ref" "$SLIST_H" && ! grep -q "FALLBACK_ATOMIC_REF" "$SLIST_H"; then
    echo "Adding atomic_ref fallback to $SLIST_H"
    python3 -c "
with open('$SLIST_H', 'r') as f:
    c = f.read()
fallback = '''#define FALLBACK_ATOMIC_REF 1
#if !defined(__cpp_lib_atomic_ref)
namespace std {
template <typename T>
struct atomic_ref {
  T* ptr;
  explicit atomic_ref(T& obj) : ptr(&obj) {}
  T load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_load_n(ptr, static_cast<int>(order));
  }
  void store(T desired, std::memory_order order = std::memory_order_seq_cst) noexcept {
    __atomic_store_n(ptr, desired, static_cast<int>(order));
  }
  bool compare_exchange_weak(T& expected, T desired,
                             std::memory_order success,
                             std::memory_order failure) noexcept {
    return __atomic_compare_exchange_n(ptr, &expected, desired, true,
                                       static_cast<int>(success),
                                       static_cast<int>(failure));
  }
};
}
#endif
'''
if '#include <atomic>' in c:
    c = c.replace('#include <atomic>', '#include <atomic>\n' + fallback, 1)
    with open('$SLIST_H', 'w') as f:
        f.write(c)
" 2>/dev/null || true
  fi
fi

# 2. Guard LinkerGC.cmake
LINKER_GC_CMAKE="$FEX_DIR/Data/CMake/LinkerGC.cmake"
if [ -f "$LINKER_GC_CMAKE" ]; then
  cat << 'EOF' > "$LINKER_GC_CMAKE"
# SPDX-License-Identifier: MIT

macro(LinkerGC target)
  if (CMAKE_BUILD_TYPE MATCHES "RELEASE")
    if (APPLE)
      target_link_options(${target} PRIVATE
        "LINKER:-dead_strip"
        "LINKER:-x")
    else()
      target_link_options(${target} PRIVATE
        "LINKER:--gc-sections"
        "LINKER:--strip-all"
        "LINKER:--as-needed")
    endif()
  endif()
endmacro()
EOF
fi

# 3. Guard vixl CMakeLists.txt
VIXL_CMAKE="$FEX_DIR/External/vixl/src/CMakeLists.txt"
if [ -f "$VIXL_CMAKE" ]; then
  python3 -c "
with open('$VIXL_CMAKE', 'r') as f:
    c = f.read()
target = '''if (CMAKE_BUILD_TYPE MATCHES \"RELEASE\")
  target_link_options(vixl
    PRIVATE
    \"LINKER:--gc-sections\"
    \"LINKER:--strip-all\"
    \"LINKER:--as-needed\"
  )
endif()'''
replacement = '''if (CMAKE_BUILD_TYPE MATCHES \"RELEASE\")
  if (APPLE)
    target_link_options(vixl
      PRIVATE
      \"LINKER:-dead_strip\"
      \"LINKER:-x\"
    )
  else()
    target_link_options(vixl
      PRIVATE
      \"LINKER:--gc-sections\"
      \"LINKER:--strip-all\"
      \"LINKER:--as-needed\"
    )
  endif()
endif()'''
if target in c:
    c = c.replace(target, replacement)
    with open('$VIXL_CMAKE', 'w') as f:
        f.write(c)
" 2>/dev/null || true
fi

# 4. Patch FEXCore/Source/CMakeLists.txt
FEXCORE_CMAKE="$FEX_DIR/FEXCore/Source/CMakeLists.txt"
if [ -f "$FEXCORE_CMAKE" ]; then
  python3 -c "
with open('$FEXCORE_CMAKE', 'r') as f:
    c = f.read()

target0 = '''set(FEXCORE_BASE_SRCS
  Interface/Config/Config.cpp
  Utils/Allocator.cpp'''
replacement0 = '''set(FEXCORE_BASE_SRCS
  Interface/Config/Config.cpp
  Utils/Allocator.cpp
  Utils/AllocatorHooks.cpp'''
if target0 in c:
    c = c.replace(target0, replacement0)

target1 = '''  if (MINGW)
    target_link_libraries(\${Name} PRIVATE FEXCore_Base)
  endif()'''
replacement1 = '''  if (MINGW OR APPLE)
    target_link_libraries(\${Name} PRIVATE FEXCore_Base softfloat_3e)
  endif()'''
if target1 in c:
    c = c.replace(target1, replacement1)

target2 = '''AddObject(\${PROJECT_NAME}_object)
AddLibrary(\${PROJECT_NAME} STATIC)
AddLibrary(\${PROJECT_NAME}_shared SHARED)'''
replacement2 = '''AddObject(\${PROJECT_NAME}_object)
AddLibrary(\${PROJECT_NAME} STATIC)
if (NOT APPLE)
  AddLibrary(\${PROJECT_NAME}_shared SHARED)
endif()'''
if target2 in c:
    c = c.replace(target2, replacement2)

target3 = '''# The shared library should always link enabled jemalloc libraries
target_link_libraries(\${PROJECT_NAME}_shared PRIVATE JemallocLibs)'''
replacement3 = '''# The shared library should always link enabled jemalloc libraries
if (TARGET \${PROJECT_NAME}_shared)
  target_link_libraries(\${PROJECT_NAME}_shared PRIVATE JemallocLibs)
endif()'''
if target3 in c:
    c = c.replace(target3, replacement3)

with open('$FEXCORE_CMAKE', 'w') as f:
    f.write(c)
" 2>/dev/null || true
fi

# 5. Patch Core.cpp to provide weak fallbacks for iOS symbols on non-Windows targets
CORE_CPP="$FEX_DIR/FEXCore/Source/Interface/Core/Core.cpp"
if [ -f "$CORE_CPP" ]; then
  python3 -c "
with open('$CORE_CPP', 'r') as f:
    c = f.read()

target1 = '''extern \"C\" uint64_t IosJitReverseTranslate(uint64_t Addr);'''
replacement1 = '''extern \"C\" uint64_t IosJitReverseTranslate(uint64_t Addr);
#if !defined(_WIN32)
__attribute__((weak)) uint64_t IosJitReverseTranslate(uint64_t Addr) { return Addr; }
#endif'''
if target1 in c and '__attribute__((weak)) uint64_t IosJitReverseTranslate' not in c:
    c = c.replace(target1, replacement1)

target2 = '''extern \"C\" uint64_t IosFfsBypassLog[4];'''
replacement2 = '''extern \"C\" uint64_t IosFfsBypassLog[4];
#if !defined(_WIN32)
__attribute__((weak)) uint64_t IosFfsBypassLog[4] {};
#endif'''
if target2 in c and '__attribute__((weak)) uint64_t IosFfsBypassLog' not in c:
    c = c.replace(target2, replacement2)

target3 = '''int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out);'''
replacement3 = '''int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out);
#if !defined(_WIN32)
__attribute__((weak)) int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out) {
  (void)out;
  return 0;
}
#endif'''
if target3 in c and '__attribute__((weak)) int rpm_cas_snapshot_take' not in c:
    c = c.replace(target3, replacement3)

target4 = '''extern \"C\" int ios_fex_mono_bridge_armed();'''
replacement4 = '''extern \"C\" int ios_fex_mono_bridge_armed();

#if !defined(_WIN32)
__attribute__((weak)) uint64_t IosMonoResolveRW(uint64_t GuestAddr, uint64_t Size) {
  (void)GuestAddr; (void)Size;
  return 0;
}
__attribute__((weak)) void ios_fex_mono_count_helper(int Miss) {
  (void)Miss;
}
__attribute__((weak)) int ios_fex_mono_take_pending(uint64_t* BlockBegin, uint64_t* HostPC, uint64_t* FaultAddr) {
  (void)BlockBegin; (void)HostPC; (void)FaultAddr;
  return 0;
}
__attribute__((weak)) void ios_fex_mono_count_activated() {}
__attribute__((weak)) uint64_t ios_fex_mono_captured_count() { return 0; }
__attribute__((weak)) int ios_fex_mono_bridge_armed() { return 0; }
#endif'''
if target4 in c and '__attribute__((weak)) int ios_fex_mono_take_pending' not in c:
    c = c.replace(target4, replacement4)

with open('$CORE_CPP', 'w') as f:
    f.write(c)
" 2>/dev/null || true
fi

# 6. Patch AllocatorHooks.cpp so IOS_RPM_GUARD() is always defined
ALLOC_HOOKS="$FEX_DIR/FEXCore/Source/Utils/AllocatorHooks.cpp"
if [ -f "$ALLOC_HOOKS" ]; then
  python3 -c "
with open('$ALLOC_HOOKS', 'r') as f:
    c = f.read()

target = '#else\nvoid InitializeThread() {}'
replacement = '''#else
#ifndef IOS_RPM_GUARD
#define IOS_RPM_GUARD() ((void)0)
#endif
void InitializeThread() {}'''
if target in c and '#ifndef IOS_RPM_GUARD' not in c:
    c = c.replace(target, replacement)
    with open('$ALLOC_HOOKS', 'w') as f:
        f.write(c)
" 2>/dev/null || true
fi

echo "Successfully patched FEX for atomic_ref and iOS guards"
