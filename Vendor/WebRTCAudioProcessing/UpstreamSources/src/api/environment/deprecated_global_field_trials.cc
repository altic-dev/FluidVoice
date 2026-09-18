/*
 *  Copyright 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "api/environment/deprecated_global_field_trials.h"

#include <cstddef>
#include <map>
#include <string>

#include "absl/strings/string_view.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"

namespace webrtc {
namespace {

constinit const char* global_field_trial_string = nullptr;

// Validates the given field trial string.
//  E.g.:
//    "WebRTC-experimentFoo/Enabled/WebRTC-experimentBar/Enabled100kbps/"
//    Assigns the process to group "Enabled" on WebRTCExperimentFoo trial
//    and to group "Enabled100kbps" on WebRTCExperimentBar.
//
//  E.g. invalid config:
//    "WebRTC-experiment1/Enabled"  (note missing / separator at the end).
bool FieldTrialsStringIsValid(absl::string_view trials) {
  if (trials.empty())
    return true;

  size_t next_item = 0;
  std::map<absl::string_view, absl::string_view> field_trials;
  while (next_item < trials.length()) {
    size_t name_end = trials.find('/', next_item);
    if (name_end == absl::string_view::npos || next_item == name_end)
      return false;
    size_t group_name_end = trials.find('/', name_end + 1);
    if (group_name_end == absl::string_view::npos ||
        name_end + 1 == group_name_end)
      return false;
    absl::string_view name = trials.substr(next_item, name_end - next_item);
    absl::string_view group_name =
        trials.substr(name_end + 1, group_name_end - name_end - 1);

    next_item = group_name_end + 1;

    // Fail if duplicate with different group name.
    auto [it, inserted] = field_trials.emplace(name, group_name);
    if (!inserted && it->second != group_name) {
      return false;
    }
  }

  return true;
}

}  // namespace

void DeprecatedGlobalFieldTrials::Set(const char* field_trials) {
  RTC_LOG(LS_INFO) << "Setting field trial string:" << field_trials;
  if (field_trials != nullptr) {
    RTC_DCHECK(FieldTrialsStringIsValid(field_trials))
        << "Invalid field trials string:" << field_trials;
  }
  global_field_trial_string = field_trials;
}

std::string DeprecatedGlobalFieldTrials::GetValue(absl::string_view key) const {
  if (global_field_trial_string == nullptr)
    return std::string();

  absl::string_view trials_string(global_field_trial_string);
  if (trials_string.empty())
    return std::string();

  size_t next_item = 0;
  while (next_item < trials_string.length()) {
    // Find next name/value pair in field trial configuration string.
    size_t field_name_end = trials_string.find('/', next_item);
    if (field_name_end == trials_string.npos || field_name_end == next_item)
      break;
    size_t field_value_end = trials_string.find('/', field_name_end + 1);
    if (field_value_end == trials_string.npos ||
        field_value_end == field_name_end + 1)
      break;
    absl::string_view field_name =
        trials_string.substr(next_item, field_name_end - next_item);
    absl::string_view field_value = trials_string.substr(
        field_name_end + 1, field_value_end - field_name_end - 1);
    next_item = field_value_end + 1;

    if (key == field_name)
      return std::string(field_value);
  }
  return std::string();
}
}  // namespace webrtc
