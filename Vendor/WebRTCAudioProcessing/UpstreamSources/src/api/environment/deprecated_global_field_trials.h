/*
 *  Copyright 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef API_ENVIRONMENT_DEPRECATED_GLOBAL_FIELD_TRIALS_H_
#define API_ENVIRONMENT_DEPRECATED_GLOBAL_FIELD_TRIALS_H_

#include <memory>
#include <string>

#include "absl/strings/string_view.h"
#include "api/field_trials_registry.h"

namespace webrtc {
// TODO: bugs.webrtc.org/42220378 - Delete after January 1, 2026 when functions
// to set global field trials are deleted.
class DeprecatedGlobalFieldTrials : public FieldTrialsRegistry {
 public:
  static void Set(const char* field_trials);

  std::unique_ptr<FieldTrialsView> CreateCopy() const override {
    return std::make_unique<DeprecatedGlobalFieldTrials>();
  }

 private:
  std::string GetValue(absl::string_view key) const override;
};
}  // namespace webrtc

#endif  // API_ENVIRONMENT_DEPRECATED_GLOBAL_FIELD_TRIALS_H_
