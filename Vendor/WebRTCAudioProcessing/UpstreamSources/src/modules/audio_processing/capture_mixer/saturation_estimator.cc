/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/saturation_estimator.h"

#include <math.h>

#include <cstddef>
#include <span>

namespace webrtc {

namespace {

void AnalyzeChannel(float one_by_num_samples_per_channel,
                    std::span<const float> audio,
                    float dc_level,
                    int& num_frames_since_activity,
                    float& saturation_factors) {
  // Use -50 dBFS threshold for activity detection.
  constexpr float kThresholdForActiveAudio = 100.0f;

  // Use a margin for saturation detection to handle soft-saturations as well as
  // impact of resamplers.
  constexpr float kThresholdForSaturatedAudio = 32000.0f;

  num_frames_since_activity++;

  int num_saturations = 0;
  for (float s : audio) {
    s = fabs(s - dc_level);
    if (s > kThresholdForSaturatedAudio) {
      num_saturations++;
    }
    if (s > kThresholdForActiveAudio) {
      num_frames_since_activity = 0;
    }
  }
  if (num_frames_since_activity == 0) {
    constexpr float kForgettingFactor = 0.95f;
    saturation_factors = kForgettingFactor * saturation_factors +
                         (1.0f - kForgettingFactor) * num_saturations *
                             one_by_num_samples_per_channel;
  }
}

}  // namespace

SaturationEstimator::SaturationEstimator(size_t num_samples_per_channel)
    : one_by_num_samples_per_channel_(1.0f / num_samples_per_channel) {
  num_frames_since_activity_.fill(0);
  saturation_factors_.fill(0.0f);
}

void SaturationEstimator::Update(std::span<const float> channel0,
                                 std::span<const float> channel1,
                                 std::span<const float, 2> dc_levels) {
  AnalyzeChannel(one_by_num_samples_per_channel_, channel0, dc_levels[0],
                 num_frames_since_activity_[0], saturation_factors_[0]);
  AnalyzeChannel(one_by_num_samples_per_channel_, channel1, dc_levels[1],
                 num_frames_since_activity_[1], saturation_factors_[1]);
}

}  // namespace webrtc
