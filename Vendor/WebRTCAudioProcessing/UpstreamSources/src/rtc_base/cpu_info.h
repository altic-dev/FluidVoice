/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef RTC_BASE_CPU_INFO_H_
#define RTC_BASE_CPU_INFO_H_

#include <cstdint>

namespace webrtc {

namespace cpu_info {

// Returned number of cores is always >= 1.
uint32_t DetectNumberOfCores();

enum class ISA { kSSE2 = 0, kSSE3, kAVX2, kFMA3, kNeon };

// Returns true if the CPU supports the given instruction set.
bool Supports(ISA instruction_set_architecture);

}  // namespace cpu_info

}  // namespace webrtc

#endif  // RTC_BASE_CPU_INFO_H_
