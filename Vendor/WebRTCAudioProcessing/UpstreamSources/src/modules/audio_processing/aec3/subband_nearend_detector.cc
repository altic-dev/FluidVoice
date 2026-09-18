/*
 *  Copyright (c) 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/aec3/subband_nearend_detector.h"

#include <array>
#include <cstddef>
#include <numeric>
#include <span>

#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/moving_average_spectrum.h"

namespace webrtc {
SubbandNearendDetector::SubbandNearendDetector(
    const EchoCanceller3Config::Suppressor& config,
    size_t num_capture_channels)
    : num_capture_channels_(num_capture_channels),
      nearend_smoothers_(
          num_capture_channels_,
          MovingAverageSpectrum(
              kFftLengthBy2Plus1,
              config.subband_nearend_detection.nearend_average_blocks)) {
  SetConfig(config);
}

void SubbandNearendDetector::Update(
    std::span<const std::array<float, kFftLengthBy2Plus1>> nearend_spectrum,
    std::span<const std::array<float, kFftLengthBy2Plus1>>
    /* residual_echo_spectrum */,
    std::span<const std::array<float, kFftLengthBy2Plus1>>
        comfort_noise_spectrum,
    bool /* initial_state */) {
  nearend_state_ = false;
  for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
    const std::array<float, kFftLengthBy2Plus1>& noise =
        comfort_noise_spectrum[ch];
    std::array<float, kFftLengthBy2Plus1> nearend;
    nearend_smoothers_[ch].Average(nearend_spectrum[ch], nearend);

    // Noise power of the first region.
    float noise_power =
        std::accumulate(noise.begin() + config_.subband1.low,
                        noise.begin() + config_.subband1.high + 1, 0.f) *
        one_over_subband_length1_;

    // Nearend power of the first region.
    float nearend_power_subband1 =
        std::accumulate(nearend.begin() + config_.subband1.low,
                        nearend.begin() + config_.subband1.high + 1, 0.f) *
        one_over_subband_length1_;

    // Nearend power of the second region.
    float nearend_power_subband2 =
        std::accumulate(nearend.begin() + config_.subband2.low,
                        nearend.begin() + config_.subband2.high + 1, 0.f) *
        one_over_subband_length2_;

    // One channel is sufficient to trigger nearend state.
    nearend_state_ =
        nearend_state_ ||
        (nearend_power_subband1 <
             config_.nearend_threshold * nearend_power_subband2 &&
         (nearend_power_subband1 > config_.snr_threshold * noise_power));
  }
}

void SubbandNearendDetector::SetConfig(
    const EchoCanceller3Config::Suppressor& config) {
  config_ = config.subband_nearend_detection;
  one_over_subband_length1_ =
      1.f / (config_.subband1.high - config_.subband1.low + 1);
  one_over_subband_length2_ =
      1.f / (config_.subband2.high - config_.subband2.low + 1);
  for (auto& smoother : nearend_smoothers_) {
    smoother.UpdateMemoryLength(config_.nearend_average_blocks);
  }
}

}  // namespace webrtc
