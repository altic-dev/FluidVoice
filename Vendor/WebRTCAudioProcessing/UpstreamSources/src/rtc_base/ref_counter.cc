/*
 *  Copyright 2026 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "rtc_base/ref_counter.h"

#include <atomic>
#include <climits>

#include "rtc_base/checks.h"

namespace webrtc {
namespace webrtc_impl {

void RefCounter::IncRef() {
  // Relaxed memory order: The current thread is allowed to act on the
  // resource protected by the reference counter both before and after the
  // atomic op, so this function doesn't prevent memory access reordering.
  int prev = ref_count_.fetch_add(1, std::memory_order_relaxed);
  RTC_CHECK_LT(prev, INT_MAX);
}

}  // namespace webrtc_impl
}  // namespace webrtc
