/*
 *  Copyright (c) 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "api/environment/force_test_environment.h"

#include <atomic>

namespace webrtc {
namespace {

std::atomic<bool> g_force_test_environment{false};
thread_local int g_bypass_test_environment_check_count = 0;

}  // namespace

void SetForceTestEnvironment(bool force) {
  g_force_test_environment.store(force, std::memory_order_relaxed);
}

bool IsForceTestEnvironmentEnabled() {
  return g_force_test_environment.load(std::memory_order_relaxed);
}

AutoBypassTestEnvironmentCheck::AutoBypassTestEnvironmentCheck() {
  ++g_bypass_test_environment_check_count;
}

AutoBypassTestEnvironmentCheck::~AutoBypassTestEnvironmentCheck() {
  --g_bypass_test_environment_check_count;
}

bool IsTestEnvironmentCheckBypassed() {
  return g_bypass_test_environment_check_count > 0;
}

}  // namespace webrtc
