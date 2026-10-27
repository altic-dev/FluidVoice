/*
 *  Copyright (c) 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_AGC2_SPEECH_LEVEL_ESTIMATOR_H_
#define MODULES_AUDIO_PROCESSING_AGC2_SPEECH_LEVEL_ESTIMATOR_H_

#include <memory>

#include "api/audio/audio_processing.h"
#include "api/field_trials_view.h"

namespace webrtc {
class ApmDataDumper;

// Active speech level estimator based on the analysis of the following
// framewise properties: RMS level (dBFS), speech probability.
class SpeechLevelEstimator {
 public:
  virtual ~SpeechLevelEstimator() {}
  // Updates the level estimation.
  virtual void Update(float rms_dbfs, float speech_probability) = 0;
  // Returns the estimated speech plus noise level.
  virtual float GetLevelDbfs() const = 0;
  // Returns true if the estimator is confident on its current estimate.
  virtual bool IsConfident() const = 0;

  virtual void Reset() = 0;

  static std::unique_ptr<SpeechLevelEstimator> Create(
      const FieldTrialsView& field_trials,
      ApmDataDumper* apm_data_dumper,
      const AudioProcessing::Config::GainController2::AdaptiveDigital& config,
      int adjacent_speech_frames_threshold);
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AGC2_SPEECH_LEVEL_ESTIMATOR_H_
