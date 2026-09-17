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
  if ! grep -q "if (APPLE)" "$LINKER_GC_CMAKE"; then
    echo "Patching $LINKER_GC_CMAKE for Apple ld"
    sed -i.bak 's/"LINKER:--gc-sections"/if (APPLE)\n      target_link_options(${target} PRIVATE\n        "LINKER:-dead_strip"\n        "LINKER:-x")\n    else()\n      target_link_options(${target} PRIVATE\n        "LINKER:--gc-sections"/' "$LINKER_GC_CMAKE" || true
    sed -i.bak 's/"LINKER:--as-needed")/"LINKER:--as-needed")\n    endif()/' "$LINKER_GC_CMAKE" || true
    rm -f "${LINKER_GC_CMAKE}.bak"
  fi
fi

VIXL_CMAKE="$FEX_DIR/External/vixl/src/CMakeLists.txt"
if [ -f "$VIXL_CMAKE" ]; then
  if ! grep -q "if (APPLE)" "$VIXL_CMAKE"; then
    echo "Patching $VIXL_CMAKE for Apple ld"
    sed -i.bak 's/"LINKER:--gc-sections"/if (APPLE)\n    target_link_options(vixl PRIVATE\n      "LINKER:-dead_strip"\n      "LINKER:-x")\n  else\n    target_link_options(vixl PRIVATE\n      "LINKER:--gc-sections"/' "$VIXL_CMAKE" || true
    sed -i.bak 's/"LINKER:--as-needed"/"LINKER:--as-needed"\n  endif/' "$VIXL_CMAKE" || true
    rm -f "${VIXL_CMAKE}.bak"
  fi
fi

echo "Successfully patched FEX for atomic_ref and iOS guards"
