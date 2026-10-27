/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/audio_content_analyzer.h"

#include <cstddef>
#include <span>

namespace webrtc {

AudioContentAnalyzer::AudioContentAnalyzer(size_t num_samples_per_channel)
    : dc_levels_estimator_(num_samples_per_channel),
      saturation_estimator_(num_samples_per_channel) {}

bool AudioContentAnalyzer::Analyze(std::span<const float> channel0,
                                   std::span<const float> channel1) {
  ++num_frames_analyzed_;

  // Exclude the first frame from the analysis to avoid reacting on any
  // uninitialized buffer content.
  constexpr int kNumFramesToExcludeAtStartup = 1;
  if (num_frames_analyzed_ <= kNumFramesToExcludeAtStartup) {
    return false;
  }

  dc_levels_estimator_.Update(channel0, channel1);

  // Empirical threshold for the number of frames that has to be analyzed for a
  // sufficiently reliable DC level estimate to be obtained.
  constexpr int kNumFramesAnalyzedForReliableDcEstimates = 100;

  if (num_frames_analyzed_ < kNumFramesAnalyzedForReliableDcEstimates) {
    return false;
  }

  std::span<const float, 2> dc_levels = dc_levels_estimator_.GetLevels();
  energy_estimator_.Update(channel0, channel1, dc_levels);
  saturation_estimator_.Update(channel0, channel1, dc_levels);

  // Empirical threshold for the number of frames that has to be analyzed for a
  // sufficiently reliable energy estimate to be obtained.
  constexpr int kNumFramesAnalyzedForReliableEstimates = 200;
  return num_frames_analyzed_ >= kNumFramesAnalyzedForReliableEstimates;
}

}  // namespace webrtc
