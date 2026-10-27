/*
 *  Copyright (c) 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/agc2/speech_level_estimator.h"

#include <memory>

#include "api/audio/audio_processing.h"
#include "api/field_trials_view.h"
#include "modules/audio_processing/agc2/speech_level_estimator_experimental_impl.h"
#include "modules/audio_processing/agc2/speech_level_estimator_impl.h"
#include "rtc_base/logging.h"

namespace webrtc {

std::unique_ptr<SpeechLevelEstimator> SpeechLevelEstimator::Create(
    const FieldTrialsView& field_trials,
    ApmDataDumper* apm_data_dumper,
    const AudioProcessing::Config::GainController2::AdaptiveDigital& config,
    int adjacent_speech_frames_threshold) {
  if (field_trials.IsEnabled("WebRTC-Agc2SpeechLevelEstimatorExperimental")) {
    RTC_LOG(LS_INFO) << "AGC2 using SpeechLevelEstimatorExperimental";
    return std::make_unique<SpeechLevelEstimatorExperimentalImpl>(
        apm_data_dumper, config, adjacent_speech_frames_threshold);
  } else {
    RTC_LOG(LS_INFO) << "AGC2 using SpeechLevelEstimator";
    return std::make_unique<SpeechLevelEstimatorImpl>(
        apm_data_dumper, config, adjacent_speech_frames_threshold);
  }
}

}  // namespace webrtc
