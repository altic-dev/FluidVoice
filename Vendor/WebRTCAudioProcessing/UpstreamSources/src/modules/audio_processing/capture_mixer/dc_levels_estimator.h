/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_DC_LEVELS_ESTIMATOR_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_DC_LEVELS_ESTIMATOR_H_

#include <stddef.h>

#include <array>
#include <span>

namespace webrtc {

// Estimates the DC levels for each of two audio channels.
class DcLevelsEstimator {
 public:
  // Constructs a DcLevelsEstimator.
  // `num_samples_per_channel` is the number of samples per channel used for
  // the estimation.
  explicit DcLevelsEstimator(size_t num_samples_per_channel);
  DcLevelsEstimator(const DcLevelsEstimator&) = delete;
  DcLevelsEstimator& operator=(const DcLevelsEstimator&) = delete;

  // Updates the DC level estimates.
  // `channel0` and `channel1` contain the samples of the two channels.
  void Update(std::span<const float> channel0, std::span<const float> channel1);

  // Returns the current DC level estimates for the two channels.
  std::span<const float, 2> GetLevels() const { return dc_levels_; }

 private:
  const float one_by_num_samples_per_channel_;
  std::array<float, 2> dc_levels_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_DC_LEVELS_ESTIMATOR_H_
