/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_ENERGY_ESTIMATOR_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_ENERGY_ESTIMATOR_H_

#include <stddef.h>

#include <array>
#include <span>

namespace webrtc {

// Estimates the average energy of two audio channels, compensating for DC
// offsets.
class AverageEnergyEstimator {
 public:
  // Constructs an AverageEnergyEstimator.
  AverageEnergyEstimator();
  AverageEnergyEstimator(const AverageEnergyEstimator&) = delete;
  AverageEnergyEstimator& operator=(const AverageEnergyEstimator&) = delete;

  // Updates the average energy estimates for the two channels.
  // `channel0` and `channel1` contain the samples of the two channels.
  // `dc_levels` contains the estimated DC offsets for the two channels, which
  // are subtracted from the samples before energy calculation.
  void Update(std::span<const float> channel0,
              std::span<const float> channel1,
              std::span<const float, 2> dc_levels);

  // Returns the current average energy estimates for the two channels.
  std::span<const float, 2> GetChannelEnergies() const {
    return average_energy_in_channels_;
  }

 private:
  std::array<float, 2> average_energy_in_channels_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_ENERGY_ESTIMATOR_H_
