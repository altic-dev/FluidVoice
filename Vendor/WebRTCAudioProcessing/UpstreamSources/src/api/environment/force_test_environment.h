/*
 *  Copyright (c) 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef API_ENVIRONMENT_FORCE_TEST_ENVIRONMENT_H_
#define API_ENVIRONMENT_FORCE_TEST_ENVIRONMENT_H_

namespace webrtc {

// Sets flag to crash if non-test Environment or FieldTrials are created.
void SetForceTestEnvironment(bool force);

// Returns true if force-test-environment is enabled.
bool IsForceTestEnvironmentEnabled();

// RAII class to temporarily bypass the check.
class AutoBypassTestEnvironmentCheck {
 public:
  AutoBypassTestEnvironmentCheck();
  ~AutoBypassTestEnvironmentCheck();
  AutoBypassTestEnvironmentCheck(const AutoBypassTestEnvironmentCheck&) =
      delete;
  AutoBypassTestEnvironmentCheck& operator=(
      const AutoBypassTestEnvironmentCheck&) = delete;
};

// Returns true if the check should be bypassed.
bool IsTestEnvironmentCheckBypassed();

}  // namespace webrtc

#endif  // API_ENVIRONMENT_FORCE_TEST_ENVIRONMENT_H_
