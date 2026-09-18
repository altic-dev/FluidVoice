/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "rtc_base/cpu_info.h"

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "rtc_base/system/arch.h"
#include "rtc_base/system/unused.h"  // IWYU pragma: keep

#if defined(WEBRTC_WIN)
#include <windows.h>
#elif defined(WEBRTC_MAC)
#include <sys/sysctl.h>
#elif defined(WEBRTC_ANDROID)
#include <cpu-features.h>
#include <unistd.h>
#elif defined(WEBRTC_FUCHSIA)
#include <zircon/syscalls.h>
#elif defined(WEBRTC_LINUX)
#include <unistd.h>
#endif  // WEBRTC_LINUX

#if defined(WEBRTC_ARCH_X86_FAMILY) && defined(_MSC_VER)
#include <intrin.h>
#endif
#if defined(WEBRTC_ARCH_ARM_FAMILY) && defined(WEBRTC_LINUX)
#include <asm/hwcap.h>
#include <sys/auxv.h>
#endif

// Parts of this file derived from Chromium's base/cpu.cc.

namespace webrtc {

namespace {

uint32_t DetectNumberOfCoresHelper() {
  int number_of_cores = 0;

#if defined(WEBRTC_WIN)
  SYSTEM_INFO si;
  GetNativeSystemInfo(&si);
  number_of_cores = static_cast<int>(si.dwNumberOfProcessors);
#elif defined(WEBRTC_LINUX) || defined(WEBRTC_ANDROID)
  number_of_cores = static_cast<int>(sysconf(_SC_NPROCESSORS_ONLN));
  if (number_of_cores <= 0) {
    RTC_LOG(LS_ERROR) << "Failed to get number of cores";
    number_of_cores = 1;
  }
#elif defined(WEBRTC_MAC) || defined(WEBRTC_IOS)
  int name[] = {CTL_HW, HW_AVAILCPU};
  size_t size = sizeof(number_of_cores);
  if (0 != sysctl(name, 2, &number_of_cores, &size, NULL, 0)) {
    RTC_LOG(LS_ERROR) << "Failed to get number of cores";
    number_of_cores = 1;
  }
#elif defined(WEBRTC_FUCHSIA)
  number_of_cores = zx_system_get_num_cpus();
#else
  RTC_LOG(LS_ERROR) << "No function to get number of cores";
  number_of_cores = 1;
#endif

  RTC_LOG(LS_INFO) << "Available number of cores: " << number_of_cores;

  RTC_CHECK_GT(number_of_cores, 0);
  return static_cast<uint32_t>(number_of_cores);
}

#if defined(WEBRTC_ARCH_X86_FAMILY)

#if defined(WEBRTC_ENABLE_AVX2)
// xgetbv returns the value of an Intel Extended Control Register (XCR).
// Currently only XCR0 is defined by Intel so `xcr` should always be zero.
uint64_t xgetbv(uint32_t xcr) {
#if defined(_MSC_VER)
  return _xgetbv(xcr);
#else
  uint32_t eax, edx;

  __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(xcr));
  return (static_cast<uint64_t>(edx) << 32) | eax;
#endif  // _MSC_VER
}
#endif  // WEBRTC_ENABLE_AVX2

#ifndef _MSC_VER
// Intrinsic for "cpuid".
#if defined(__pic__) && defined(__i386__)
static inline void __cpuid(int cpu_info[4], int info_type) {
  __asm__ volatile(
      "mov %%ebx, %%edi\n"
      "cpuid\n"
      "xchg %%edi, %%ebx\n"
      : "=a"(cpu_info[0]), "=D"(cpu_info[1]), "=c"(cpu_info[2]),
        "=d"(cpu_info[3])
      : "a"(info_type));
}
#else
inline void __cpuid(int cpu_info[4], int info_type) {
  __asm__ volatile("cpuid\n"
                   : "=a"(cpu_info[0]), "=b"(cpu_info[1]), "=c"(cpu_info[2]),
                     "=d"(cpu_info[3])
                   : "a"(info_type), "c"(0));
}
#endif
#endif  // _MSC_VER

#endif  // WEBRTC_ARCH_X86_FAMILY

}  // namespace

namespace cpu_info {

uint32_t DetectNumberOfCores() {
  // Statically cache the number of system cores available since if the process
  // is running in a sandbox, we may only be able to read the value once (before
  // the sandbox is initialized) and not thereafter.
  // For more information see crbug.com/176522.
  static const uint32_t logical_cpus = DetectNumberOfCoresHelper();
  return logical_cpus;
}

bool Supports(ISA instruction_set_architecture) {
#if defined(WEBRTC_ARCH_X86_FAMILY)
  int cpu_info[4];
  __cpuid(cpu_info, 1);
  if (instruction_set_architecture == ISA::kSSE2) {
    return 0 != (cpu_info[3] & 0x04000000);
  }
  if (instruction_set_architecture == ISA::kSSE3) {
    return 0 != (cpu_info[2] & 0x00000001);
  }
#if defined(WEBRTC_ENABLE_AVX2)
  if (instruction_set_architecture == ISA::kAVX2) {
    int cpu_info7[4];
    __cpuid(cpu_info7, 0);
    int num_ids = cpu_info7[0];
    if (num_ids < 7) {
      return false;
    }
    // Interpret CPU feature information.
    __cpuid(cpu_info7, 7);

    // AVX instructions can be used when
    //     a) AVX are supported by the CPU,
    //     b) XSAVE is supported by the CPU,
    //     c) XSAVE is enabled by the kernel.
    // Compiling with MSVC and /arch:AVX2 surprisingly generates BMI2
    // instructions (see crbug.com/1315519).
    return (cpu_info[2] & 0x10000000) != 0 /* AVX */ &&
           (cpu_info[2] & 0x04000000) != 0 /* XSAVE */ &&
           (cpu_info[2] & 0x08000000) != 0 /* OSXSAVE */ &&
           (xgetbv(0) & 0x00000006) == 6 /* XSAVE enabled by kernel */ &&
           (cpu_info7[1] & 0x00000020) != 0 /* AVX2 */ &&
           (cpu_info7[1] & 0x00000100) != 0 /* BMI2 */;
  }
#endif  // WEBRTC_ENABLE_AVX2
  if (instruction_set_architecture == ISA::kFMA3) {
    return 0 != (cpu_info[2] & 0x00001000);
  }
#elif defined(WEBRTC_ARCH_ARM_FAMILY)
  if (instruction_set_architecture == ISA::kNeon) {
#if defined(WEBRTC_ANDROID)
    return 0 != (android_getCpuFeatures() & ANDROID_CPU_ARM_FEATURE_NEON);
#elif defined(WEBRTC_LINUX)
    uint64_t hwcap = 0;
    hwcap = getauxval(AT_HWCAP);
#if defined(__aarch64__)
    if ((hwcap & HWCAP_ASIMD) != 0) {
      return true;
    }
#else
    if ((hwcap & HWCAP_NEON) != 0) {
      return true;
    }
#endif
#endif  // WEBRTC_LINUX
  }
#else
  RTC_UNUSED(instruction_set_architecture);
#endif  // WEBRTC_ARCH_ARM_FAMILY
  return false;
}

}  // namespace cpu_info

}  // namespace webrtc
