/*
 *  Copyright (c) 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/aec3/dominant_nearend_detector.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <numeric>
#include <span>

#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "rtc_base/checks.h"

namespace webrtc {
DominantNearendDetector::DominantNearendDetector(
    const EchoCanceller3Config::Suppressor::DominantNearendDetection& config,
    size_t num_capture_channels)
    : config_(config),
      num_capture_channels_(num_capture_channels),
      trigger_counters_(num_capture_channels_),
      hold_counters_(num_capture_channels_) {}

void DominantNearendDetector::Update(
    std::span<const std::array<float, kFftLengthBy2Plus1>> nearend_spectrum,
    std::span<const std::array<float, kFftLengthBy2Plus1>>
        residual_echo_spectrum,
    std::span<const std::array<float, kFftLengthBy2Plus1>>
        comfort_noise_spectrum,
    bool initial_state) {
  nearend_state_ = false;

  auto low_frequency_energy = [](std::span<const float> spectrum) {
    RTC_DCHECK_LE(16, spectrum.size());
    return std::accumulate(spectrum.begin() + 1, spectrum.begin() + 16, 0.f);
  };

  for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
    const float ne_sum = low_frequency_energy(nearend_spectrum[ch]);
    const float echo_sum = low_frequency_energy(residual_echo_spectrum[ch]);
    const float noise_sum = low_frequency_energy(comfort_noise_spectrum[ch]);

    // Detect strong active nearend if the nearend is sufficiently stronger than
    // the echo and the nearend noise.
    if ((!initial_state || config_.use_during_initial_phase) &&
        echo_sum < config_.enr_threshold * ne_sum &&
        ne_sum > config_.snr_threshold * noise_sum) {
      if (++trigger_counters_[ch] >= config_.trigger_threshold) {
        // After a period of strong active nearend activity, flag nearend mode.
        hold_counters_[ch] = config_.hold_duration;
        trigger_counters_[ch] = config_.trigger_threshold;
      }
    } else {
      // Forget previously detected strong active nearend activity.
      trigger_counters_[ch] = std::max(0, trigger_counters_[ch] - 1);
    }

    // Exit nearend-state early at strong echo.
    if (echo_sum > config_.enr_exit_threshold * ne_sum &&
        echo_sum > config_.snr_threshold * noise_sum) {
      hold_counters_[ch] = 0;
    }

    // Remain in any nearend mode for a certain duration.
    hold_counters_[ch] = std::max(0, hold_counters_[ch] - 1);
    nearend_state_ = nearend_state_ || hold_counters_[ch] > 0;
  }
}

void DominantNearendDetector::SetConfig(
    const EchoCanceller3Config::Suppressor& config) {
  config_ = config.dominant_nearend_detection;
}

}  // namespace webrtc
