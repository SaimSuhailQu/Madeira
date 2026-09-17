#!/usr/bin/env bash
set -euo pipefail

FEX_DIR="${1:-FEX}"
echo "Applying atomic_ref fallback to FEX at: $FEX_DIR"

# 1. Create FEXCore/include/FEXCore/fextl/atomic.h
ATOMIC_H="$FEX_DIR/FEXCore/include/FEXCore/fextl/atomic.h"
mkdir -p "$(dirname "$ATOMIC_H")"

cat << 'EOF' > "$ATOMIC_H"
// SPDX-License-Identifier: MIT
#pragma once

#include <atomic>
#include <type_traits>

#if !defined(__cpp_lib_atomic_ref) || (__cpp_lib_atomic_ref < 201811L)
namespace std {

template<typename T>
struct atomic_ref {
  static_assert(std::is_trivially_copyable_v<T>, "std::atomic_ref requires trivially copyable type");

  explicit atomic_ref(T& obj) noexcept : ptr(&obj) {}
  atomic_ref(const atomic_ref&) noexcept = default;
  atomic_ref& operator=(const atomic_ref&) = delete;

  void store(T desired, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    __atomic_store_n(ptr, desired, static_cast<int>(order));
  }

  T load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_load_n(ptr, static_cast<int>(order));
  }

  operator T() const noexcept {
    return load();
  }

  T exchange(T desired, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_exchange_n(ptr, desired, static_cast<int>(order));
  }

  bool compare_exchange_strong(T& expected, T desired,
                               std::memory_order success,
                               std::memory_order failure) const noexcept {
    return __atomic_compare_exchange_n(ptr, &expected, desired, false,
                                      static_cast<int>(success),
                                      static_cast<int>(failure));
  }

  bool compare_exchange_strong(T& expected, T desired,
                               std::memory_order order = std::memory_order_seq_cst) const noexcept {
    int fail_order = static_cast<int>(order);
    if (order == std::memory_order_release) {
      fail_order = static_cast<int>(std::memory_order_relaxed);
    } else if (order == std::memory_order_acq_rel) {
      fail_order = static_cast<int>(std::memory_order_acquire);
    }
    return __atomic_compare_exchange_n(ptr, &expected, desired, false,
                                      static_cast<int>(order),
                                      fail_order);
  }

  bool compare_exchange_weak(T& expected, T desired,
                             std::memory_order success,
                             std::memory_order failure) const noexcept {
    return __atomic_compare_exchange_n(ptr, &expected, desired, true,
                                      static_cast<int>(success),
                                      static_cast<int>(failure));
  }

  bool compare_exchange_weak(T& expected, T desired,
                             std::memory_order order = std::memory_order_seq_cst) const noexcept {
    int fail_order = static_cast<int>(order);
    if (order == std::memory_order_release) {
      fail_order = static_cast<int>(std::memory_order_relaxed);
    } else if (order == std::memory_order_acq_rel) {
      fail_order = static_cast<int>(std::memory_order_acquire);
    }
    return __atomic_compare_exchange_n(ptr, &expected, desired, true,
                                      static_cast<int>(order),
                                      fail_order);
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T fetch_add(T arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_add(ptr, arg, static_cast<int>(order));
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T fetch_sub(T arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_sub(ptr, arg, static_cast<int>(order));
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T fetch_and(T arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_and(ptr, arg, static_cast<int>(order));
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T fetch_or(T arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_or(ptr, arg, static_cast<int>(order));
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T fetch_xor(T arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_xor(ptr, arg, static_cast<int>(order));
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T operator++() const noexcept {
    return fetch_add(1) + 1;
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T operator++(int) const noexcept {
    return fetch_add(1);
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T operator--() const noexcept {
    return fetch_sub(1) - 1;
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T operator--(int) const noexcept {
    return fetch_sub(1);
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T operator+=(T arg) const noexcept {
    return fetch_add(arg) + arg;
  }

  template<typename U = T>
  requires (std::is_integral_v<U> && !std::is_same_v<bool, U>)
  T operator-=(T arg) const noexcept {
    return fetch_sub(arg) - arg;
  }

private:
  T* ptr;
};

// Explicit specialization for __uint128_t
template<>
struct atomic_ref<__uint128_t> {
  explicit atomic_ref(__uint128_t& obj) noexcept : ptr(&obj) {}
  atomic_ref(const atomic_ref&) noexcept = default;
  atomic_ref& operator=(const atomic_ref&) = delete;

  void store(__uint128_t desired, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    __atomic_store_n(ptr, desired, static_cast<int>(order));
  }

  __uint128_t load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_load_n(ptr, static_cast<int>(order));
  }

  operator __uint128_t() const noexcept {
    return load();
  }

  __uint128_t exchange(__uint128_t desired, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_exchange_n(ptr, desired, static_cast<int>(order));
  }

  bool compare_exchange_strong(__uint128_t& expected, __uint128_t desired,
                               std::memory_order success,
                               std::memory_order failure) const noexcept {
    return __atomic_compare_exchange_n(ptr, &expected, desired, false,
                                      static_cast<int>(success),
                                      static_cast<int>(failure));
  }

  bool compare_exchange_strong(__uint128_t& expected, __uint128_t desired,
                               std::memory_order order = std::memory_order_seq_cst) const noexcept {
    int fail_order = static_cast<int>(order);
    if (order == std::memory_order_release) {
      fail_order = static_cast<int>(std::memory_order_relaxed);
    } else if (order == std::memory_order_acq_rel) {
      fail_order = static_cast<int>(std::memory_order_acquire);
    }
    return __atomic_compare_exchange_n(ptr, &expected, desired, false,
                                      static_cast<int>(order),
                                      fail_order);
  }

  bool compare_exchange_weak(__uint128_t& expected, __uint128_t desired,
                             std::memory_order success,
                             std::memory_order failure) const noexcept {
    return __atomic_compare_exchange_n(ptr, &expected, desired, true,
                                      static_cast<int>(success),
                                      static_cast<int>(failure));
  }

  bool compare_exchange_weak(__uint128_t& expected, __uint128_t desired,
                             std::memory_order order = std::memory_order_seq_cst) const noexcept {
    int fail_order = static_cast<int>(order);
    if (order == std::memory_order_release) {
      fail_order = static_cast<int>(std::memory_order_relaxed);
    } else if (order == std::memory_order_acq_rel) {
      fail_order = static_cast<int>(std::memory_order_acquire);
    }
    return __atomic_compare_exchange_n(ptr, &expected, desired, true,
                                      static_cast<int>(order),
                                      fail_order);
  }

  __uint128_t fetch_add(__uint128_t arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_add(ptr, arg, static_cast<int>(order));
  }

  __uint128_t fetch_sub(__uint128_t arg, std::memory_order order = std::memory_order_seq_cst) const noexcept {
    return __atomic_fetch_sub(ptr, arg, static_cast<int>(order));
  }

private:
  __uint128_t* ptr;
};

} // namespace std
#endif
EOF

echo "Created $ATOMIC_H"

# 2. Inject include into header/source files if not already present
inject_include() {
  local target_file="$1"
  if [ -f "$target_file" ]; then
    if ! grep -q "FEXCore/fextl/atomic.h" "$target_file"; then
      echo "Injecting into $target_file"
      sed -i.bak '1s|^|#include <FEXCore/fextl/atomic.h>\n|' "$target_file"
      rm -f "${target_file}.bak"
    fi
  fi
}

inject_include "$FEX_DIR/FEXCore/include/FEXCore/Utils/CompilerDefs.h"
inject_include "$FEX_DIR/FEXCore/include/FEXCore/Utils/SpinWaitLock.h"
inject_include "$FEX_DIR/FEXCore/include/FEXCore/Utils/WritePriorityMutex.h"
inject_include "$FEX_DIR/FEXCore/include/FEXCore/Utils/SHMStats.h"
inject_include "$FEX_DIR/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
inject_include "$FEX_DIR/Source/Tools/LinuxEmulation/LinuxSyscalls/Seccomp/SeccompEmulator.cpp"
inject_include "$FEX_DIR/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Thread.cpp"
inject_include "$FEX_DIR/Source/Tools/LinuxEmulation/LinuxSyscalls/Utils/Threads.cpp"

# 3. Patch Core.cpp to guard iOS-specific instrumentation with #ifdef FEX_IOS_HOST
CORE_CPP="$FEX_DIR/FEXCore/Source/Interface/Core/Core.cpp"
if [ -f "$CORE_CPP" ]; then
  if grep -q "iOS-Madeira ml304" "$CORE_CPP" && ! grep -B 2 "iOS-Madeira ml304" "$CORE_CPP" | grep -q "FEX_IOS_HOST"; then
    echo "Guarding iOS diagnostic instrumentation in $CORE_CPP with #ifdef FEX_IOS_HOST"
    awk '
      /\/\* iOS-Madeira ml304/ { print "#ifdef FEX_IOS_HOST" }
      { print }
      /REFUSING low\/invalid RIP/ { in_refusing = 1 }
      in_refusing && /^  \}/ { print "#endif"; in_refusing = 0 }
    ' "$CORE_CPP" > "${CORE_CPP}.tmp" && mv "${CORE_CPP}.tmp" "$CORE_CPP"
  fi
fi

# 4. Guard Windows-specific VirtualQuery in Arm64.cpp with #ifdef _WIN32
ARM64_CPP="$FEX_DIR/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
if [ -f "$ARM64_CPP" ]; then
  if grep -q "VirtualQuery(reinterpret_cast<LPCVOID>" "$ARM64_CPP" && ! grep -B 2 "MEMORY_BASIC_INFORMATION mbi" "$ARM64_CPP" | grep -q "_WIN32"; then
    echo "Guarding VirtualQuery in $ARM64_CPP with #ifdef _WIN32"
    python3 -c "
import sys
with open('$ARM64_CPP', 'r') as f:
    content = f.read()
target = '''  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = \"?\";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? \"MEM_IMAGE\" : mbi.Type == MEM_MAPPED ? \"MEM_MAPPED\" : \"MEM_PRIVATE\";
  }
  LogMan::Msg::EFmt(\"[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} \"
                    \"crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}\",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? \"yes\" : \"no\", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);'''
replacement = '''#ifdef _WIN32
  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = \"?\";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? \"MEM_IMAGE\" : mbi.Type == MEM_MAPPED ? \"MEM_MAPPED\" : \"MEM_PRIVATE\";
  }
  LogMan::Msg::EFmt(\"[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} \"
                    \"crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}\",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? \"yes\" : \"no\", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
#else
  LogMan::Msg::EFmt(\"[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} crosses16B={}\",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? \"yes\" : \"no\");
#endif'''
if target in content:
    content = content.replace(target, replacement)
    with open('$ARM64_CPP', 'w') as f:
        f.write(content)
" 2>/dev/null || true
  fi
fi

# 5. Patch LinkerGC.cmake and vixl CMakeLists.txt to use Apple-compatible linker flags (-dead_strip, -x)
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

# 6. Patch FEXCore/Source/CMakeLists.txt to link softfloat_3e and FEXCore_Base, and skip shared library on APPLE
FEXCORE_CMAKE="$FEX_DIR/FEXCore/Source/CMakeLists.txt"
if [ -f "$FEXCORE_CMAKE" ]; then
  python3 -c "
with open('$FEXCORE_CMAKE', 'r') as f:
    c = f.read()

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

# 7. Patch Core.cpp to provide fallback definitions for iOS symbols in non-Windows builds
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

echo "Successfully patched FEX for atomic_ref and iOS guards"
