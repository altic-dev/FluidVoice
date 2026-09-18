/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_AGC2_SPEECH_LEVEL_ESTIMATOR_EXPERIMENTAL_IMPL_H_
#define MODULES_AUDIO_PROCESSING_AGC2_SPEECH_LEVEL_ESTIMATOR_EXPERIMENTAL_IMPL_H_

#include <type_traits>

#include "api/audio/audio_processing.h"
#include "modules/audio_processing/agc2/speech_level_estimator.h"

namespace webrtc {
class ApmDataDumper;

// Active speech level estimator based on the analysis of RMS level (dBFS), and
// speech probability.
class SpeechLevelEstimatorExperimentalImpl : public SpeechLevelEstimator {
 public:
  SpeechLevelEstimatorExperimentalImpl(
      ApmDataDumper* apm_data_dumper,
      const AudioProcessing::Config::GainController2::AdaptiveDigital& config,
      int adjacent_speech_frames_threshold);
  SpeechLevelEstimatorExperimentalImpl(
      const SpeechLevelEstimatorExperimentalImpl&) = delete;
  SpeechLevelEstimatorExperimentalImpl& operator=(
      const SpeechLevelEstimatorExperimentalImpl&) = delete;

  // Updates the level estimation.
  void Update(float rms_dbfs, float speech_probability) override;
  // Returns the estimated speech plus noise level.
  float GetLevelDbfs() const override { return level_dbfs_; }
  // Returns true if the estimator is confident on its current estimate.
  bool IsConfident() const override { return is_confident_; }

  void Reset() override;

 private:
  // Part of the level estimator state used for check-pointing and restore ops.
  struct LevelEstimatorState {
    int num_frames;
    float sum_of_levels_dbfs;
  };
  static_assert(std::is_trivially_copyable<LevelEstimatorState>::value, "");

  void UpdateIsConfident();

  void ResetLevelEstimatorState(LevelEstimatorState& state) const;

  void DumpDebugData() const;

  ApmDataDumper* const apm_data_dumper_;

  const float initial_speech_level_dbfs_;
  const int adjacent_speech_frames_threshold_;
  LevelEstimatorState preliminary_state_;
  LevelEstimatorState reliable_state_;
  float level_dbfs_;
  bool is_confident_;
  int num_adjacent_speech_frames_;
  float tracking_level_dbfs_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AGC2_SPEECH_LEVEL_ESTIMATOR_EXPERIMENTAL_IMPL_H_
