/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/dc_levels_estimator.h"

#include <cstddef>
#include <numeric>
#include <span>

namespace webrtc {

namespace {

void UpdateDcEstimate(float one_by_num_samples_per_channel,
                      std::span<const float> audio,
                      float& dc_estimate) {
  constexpr float kForgettingFactor = 0.05f;
  float mean = std::accumulate(audio.begin(), audio.end(), 0.0f) *
               one_by_num_samples_per_channel;
  dc_estimate += kForgettingFactor * (mean - dc_estimate);
}

}  // namespace

DcLevelsEstimator::DcLevelsEstimator(size_t num_samples_per_channel)
    : one_by_num_samples_per_channel_(1.0f / num_samples_per_channel) {
  dc_levels_.fill(0.0f);
}

void DcLevelsEstimator::Update(std::span<const float> channel0,
                               std::span<const float> channel1) {
  UpdateDcEstimate(one_by_num_samples_per_channel_, channel0, dc_levels_[0]);
  UpdateDcEstimate(one_by_num_samples_per_channel_, channel1, dc_levels_[1]);
}

}  // namespace webrtc
