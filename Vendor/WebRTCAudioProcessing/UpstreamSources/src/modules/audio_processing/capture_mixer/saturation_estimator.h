/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_SATURATION_ESTIMATOR_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_SATURATION_ESTIMATOR_H_

#include <stddef.h>

#include <array>
#include <span>

namespace webrtc {

// Estimates the saturation of two audio channels.
class SaturationEstimator {
 public:
  // Constructs a SaturationEstimator.
  // `num_samples_per_channel` is the number of samples per channel used for
  // the estimation.
  explicit SaturationEstimator(size_t num_samples_per_channel);
  SaturationEstimator(const SaturationEstimator&) = delete;
  SaturationEstimator& operator=(const SaturationEstimator&) = delete;

  // Updates the saturation estimates for the two channels.
  // `channel0` and `channel1` contain the samples of the two channels.
  // `dc_levels` contains the estimated DC offsets for the two channels, which
  // are subtracted from the samples before saturation calculation.
  void Update(std::span<const float> channel0,
              std::span<const float> channel1,
              std::span<const float, 2> dc_levels);

  // Returns the number of frames since the last activity was detected in each
  // of the channels.
  std::span<const int, 2> GetNumFramesSinceActivity() const {
    return num_frames_since_activity_;
  }

  // Returns the current saturation factor estimates for the two channels. The
  // saturation factor is a value between 0 and 1, where 1 means that the signal
  // has recently been fully saturated and 0 means that no saturation has been
  // observed in the resent past.
  std::span<const float, 2> GetSaturationFactors() const {
    return saturation_factors_;
  }

 private:
  const float one_by_num_samples_per_channel_;
  std::array<int, 2> num_frames_since_activity_;
  std::array<float, 2> saturation_factors_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_SATURATION_ESTIMATOR_H_
