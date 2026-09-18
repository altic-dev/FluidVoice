/*
 *  Copyright 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef API_FIELD_TRIALS_VIEW_H_
#define API_FIELD_TRIALS_VIEW_H_

#include <memory>
#include <string>

#include "absl/strings/match.h"
#include "absl/strings/string_view.h"
#include "rtc_base/checks.h"
#include "rtc_base/system/rtc_export.h"

namespace webrtc {

// An interface that provides the means to access field trials.
//
// A FieldTrialsView is guaranteed to be immutable,
//
// Note that there are no guarantess that the meaning of a particular key-value
// mapping will be preserved over time and no announcements will be made if they
// are changed. It's up to the library user to ensure that the behavior does not
// break.
class RTC_EXPORT FieldTrialsView {
 public:
  virtual ~FieldTrialsView() = default;

  // Returns the configured value for `key` or an empty string if the field
  // trial isn't configured.
  virtual std::string Lookup(absl::string_view key) const = 0;

  bool IsEnabled(absl::string_view key) const {
    return absl::StartsWith(Lookup(key), "Enabled");
  }

  bool IsDisabled(absl::string_view key) const {
    return absl::StartsWith(Lookup(key), "Disabled");
  }

  // Returns true if this view is of a registry that is suitable for use
  // in a test environment.
  virtual bool IsTest() const { return false; }

  // Create a copy of this view.
  //
  // This method can't be pure virtual, due to downstream projects
  // but that is fine since they won't use the method...if they
  // implement their own FieldTrialsView.
  virtual std::unique_ptr<FieldTrialsView> CreateCopy() const {
    RTC_CHECK_NOTREACHED();
    return nullptr;
  }
};

}  // namespace webrtc

#endif  // API_FIELD_TRIALS_VIEW_H_
