/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/agc2/speech_level_estimator_experimental_impl.h"

#include "api/audio/audio_processing.h"
#include "modules/audio_processing/agc2/agc2_common.h"
#include "modules/audio_processing/logging/apm_data_dumper.h"
#include "rtc_base/checks.h"
#include "rtc_base/numerics/safe_minmax.h"

namespace webrtc {
namespace {

float ClampLevelEstimateDbfs(float level_estimate_dbfs) {
  return SafeClamp<float>(level_estimate_dbfs, -90.0f, 30.0f);
}

// Returns the initial speech level estimate needed to apply the initial gain.
float GetInitialSpeechLevelEstimateDbfs(
    const AudioProcessing::Config::GainController2::AdaptiveDigital& config) {
  return ClampLevelEstimateDbfs(-kSaturationProtectorInitialHeadroomDb -
                                config.initial_gain_db - config.headroom_db);
}

}  // namespace

SpeechLevelEstimatorExperimentalImpl::SpeechLevelEstimatorExperimentalImpl(
    ApmDataDumper* apm_data_dumper,
    const AudioProcessing::Config::GainController2::AdaptiveDigital& config,
    int adjacent_speech_frames_threshold)
    : apm_data_dumper_(apm_data_dumper),
      initial_speech_level_dbfs_(GetInitialSpeechLevelEstimateDbfs(config)),
      adjacent_speech_frames_threshold_(adjacent_speech_frames_threshold),
      level_dbfs_(initial_speech_level_dbfs_),
      is_confident_(false) {
  RTC_DCHECK(apm_data_dumper_);
  RTC_DCHECK_GE(adjacent_speech_frames_threshold_, 1);
  Reset();
}

void SpeechLevelEstimatorExperimentalImpl::Update(float rms_dbfs,
                                                  float speech_probability) {
  constexpr float kMaxReductionDbfs = 10.0f;
  constexpr int kFramesPerUpdate = 100;

  if (speech_probability < kVadConfidenceThreshold) {
    // Not a speech frame. Reset to the last reliable state.
    preliminary_state_ = reliable_state_;
    num_adjacent_speech_frames_ = 0;
  } else {
    // Speech frame observed.
    num_adjacent_speech_frames_++;

    // Update preliminary level estimate.
    preliminary_state_.num_frames++;
    preliminary_state_.sum_of_levels_dbfs += rms_dbfs;

    if (num_adjacent_speech_frames_ >= adjacent_speech_frames_threshold_) {
      // The ongoing sequence is long enough to update the reliable state.
      reliable_state_ = preliminary_state_;

      if (reliable_state_.num_frames >= kFramesPerUpdate) {
        // The reliable state has enough frames to update the speech level
        // estimation.
        const float reliable_level_dbfs = ClampLevelEstimateDbfs(
            reliable_state_.sum_of_levels_dbfs / reliable_state_.num_frames);
        if (!is_confident_ ||
            reliable_level_dbfs >= level_dbfs_ - kMaxReductionDbfs) {
          level_dbfs_ = reliable_level_dbfs;
          is_confident_ = true;
        }
        ResetLevelEstimatorState(reliable_state_);
        ResetLevelEstimatorState(preliminary_state_);
      }
    }
  }
  DumpDebugData();
}

void SpeechLevelEstimatorExperimentalImpl::Reset() {
  ResetLevelEstimatorState(preliminary_state_);
  ResetLevelEstimatorState(reliable_state_);
  level_dbfs_ = initial_speech_level_dbfs_;
  num_adjacent_speech_frames_ = 0;
  tracking_level_dbfs_ = initial_speech_level_dbfs_;
  is_confident_ = false;
}

void SpeechLevelEstimatorExperimentalImpl::ResetLevelEstimatorState(
    LevelEstimatorState& state) const {
  state.num_frames = 0;
  state.sum_of_levels_dbfs = 0;
}

void SpeechLevelEstimatorExperimentalImpl::DumpDebugData() const {
  if (!apm_data_dumper_)
    return;
  apm_data_dumper_->DumpRaw("agc2_speech_level_dbfs", level_dbfs_);
  apm_data_dumper_->DumpRaw("agc2_speech_level_is_confident", is_confident_);
  apm_data_dumper_->DumpRaw(
      "agc2_adaptive_level_estimator_num_adjacent_speech_frames",
      num_adjacent_speech_frames_);
  apm_data_dumper_->DumpRaw(
      "agc2_adaptive_level_estimator_preliminary_num_frames",
      preliminary_state_.num_frames);
  apm_data_dumper_->DumpRaw("agc2_adaptive_level_estimator_reliable_num_frames",
                            reliable_state_.num_frames);
}

}  // namespace webrtc
