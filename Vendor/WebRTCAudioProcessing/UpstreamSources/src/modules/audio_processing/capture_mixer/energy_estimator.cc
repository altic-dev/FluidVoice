/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/energy_estimator.h"

#include <span>

namespace webrtc {

namespace {

void UpdateChannelEnergyEstimate(std::span<const float> audio,
                                 float dc_level,
                                 float& channel_energy_estimate) {
  float energy = 0.0f;
  for (float sample : audio) {
    const float sample_minus_dc = sample - dc_level;
    energy += sample_minus_dc * sample_minus_dc;
  }

  constexpr float kForgettingFactor = 0.005f;
  channel_energy_estimate +=
      kForgettingFactor * (energy - channel_energy_estimate);
}

}  // namespace

AverageEnergyEstimator::AverageEnergyEstimator() {
  average_energy_in_channels_.fill(0.0f);
}

void AverageEnergyEstimator::Update(std::span<const float> channel0,
                                    std::span<const float> channel1,
                                    std::span<const float, 2> dc_levels) {
  UpdateChannelEnergyEstimate(channel0, dc_levels[0],
                              average_energy_in_channels_[0]);
  UpdateChannelEnergyEstimate(channel1, dc_levels[1],
                              average_energy_in_channels_[1]);
}

}  // namespace webrtc
