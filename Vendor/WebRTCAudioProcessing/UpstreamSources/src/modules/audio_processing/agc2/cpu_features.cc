/*
 *  Copyright (c) 2020 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/agc2/cpu_features.h"

#include <string>

#include "rtc_base/cpu_info.h"
#include "rtc_base/strings/string_builder.h"
#include "rtc_base/system/arch.h"

namespace webrtc {

std::string AvailableCpuFeatures::ToString() const {
  StringBuilder builder;
  bool first = true;
  if (sse2) {
    builder << (first ? "SSE2" : "_SSE2");
    first = false;
  }
  if (avx2) {
    builder << (first ? "AVX2" : "_AVX2");
    first = false;
  }
  if (neon) {
    builder << (first ? "NEON" : "_NEON");
    first = false;
  }
  if (first) {
    return "none";
  }
  return builder.Release();
}

// Detects available CPU features.
AvailableCpuFeatures GetAvailableCpuFeatures() {
#if defined(WEBRTC_ARCH_X86_FAMILY)
  return {/*sse2=*/cpu_info::Supports(cpu_info::ISA::kSSE2),
          /*avx2=*/cpu_info::Supports(cpu_info::ISA::kAVX2),
          /*neon=*/false};
#elif defined(WEBRTC_HAS_NEON)
  return {/*sse2=*/false,
          /*avx2=*/false,
          /*neon=*/true};
#else
  return {/*sse2=*/false,
          /*avx2=*/false,
          /*neon=*/false};
#endif
}

AvailableCpuFeatures NoAvailableCpuFeatures() {
  return {/*sse2=*/false, /*avx2=*/false, /*neon=*/false};
}

}  // namespace webrtc
