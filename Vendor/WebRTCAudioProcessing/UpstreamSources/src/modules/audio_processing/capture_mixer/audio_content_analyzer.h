/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_AUDIO_CONTENT_ANALYZER_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_AUDIO_CONTENT_ANALYZER_H_

#include <stddef.h>

#include <span>

#include "modules/audio_processing/capture_mixer/dc_levels_estimator.h"
#include "modules/audio_processing/capture_mixer/energy_estimator.h"
#include "modules/audio_processing/capture_mixer/saturation_estimator.h"

namespace webrtc {

// Analyzes the content of two audio channels to estimate energy,  saturation
// and activity.
class AudioContentAnalyzer {
 public:
  // Constructs an AudioContentAnalyzer.
  // `num_samples_per_channel` is the number of samples per channel used for
  // the estimations.
  explicit AudioContentAnalyzer(size_t num_samples_per_channel);
  AudioContentAnalyzer(const AudioContentAnalyzer&) = delete;
  AudioContentAnalyzer& operator=(const AudioContentAnalyzer&) = delete;

  // Analyzes the provided audio samples for the two channels.
  // Updates the internal energy, and saturation estimators.
  // Returns true if the current frame is considered to contain activity.
  bool Analyze(std::span<const float> channel0,
               std::span<const float> channel1);

  // Returns the current average energy estimates for the two channels.
  std::span<const float, 2> GetChannelEnergies() const {
    return energy_estimator_.GetChannelEnergies();
  }

  // Returns the number of frames since the last activity was detected in each
  // of the channels.
  std::span<const int, 2> GetNumFramesSinceActivity() const {
    return saturation_estimator_.GetNumFramesSinceActivity();
  }

  // Returns the current saturation factor estimates for the two channels. The
  // saturation factor is a value between 0 and 1, where 1 means that the signal
  // has recently been fully saturated and 0 means that no saturation has been
  // observed in the resent past.
  std::span<const float, 2> GetSaturationFactors() const {
    return saturation_estimator_.GetSaturationFactors();
  }

 private:
  DcLevelsEstimator dc_levels_estimator_;
  AverageEnergyEstimator energy_estimator_;
  SaturationEstimator saturation_estimator_;
  int num_frames_analyzed_ = 0;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_AUDIO_CONTENT_ANALYZER_H_
