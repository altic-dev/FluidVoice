/*
 *  Copyright (c) 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_AEC3_DOMINANT_NEAREND_DETECTOR_H_
#define MODULES_AUDIO_PROCESSING_AEC3_DOMINANT_NEAREND_DETECTOR_H_

#include <array>
#include <cstddef>
#include <span>
#include <vector>

#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/nearend_detector.h"

namespace webrtc {
// Class for selecting whether the suppressor is in the nearend or echo state.
class DominantNearendDetector : public NearendDetector {
 public:
  DominantNearendDetector(
      const EchoCanceller3Config::Suppressor::DominantNearendDetection& config,
      size_t num_capture_channels);

  // Returns whether the current state is the nearend state.
  bool IsNearendState() const override { return nearend_state_; }

  // Updates the state selection based on latest spectral estimates.
  void Update(
      std::span<const std::array<float, kFftLengthBy2Plus1>> nearend_spectrum,
      std::span<const std::array<float, kFftLengthBy2Plus1>>
          residual_echo_spectrum,
      std::span<const std::array<float, kFftLengthBy2Plus1>>
          comfort_noise_spectrum,
      bool initial_state) override;

  // Sets the configuration.
  void SetConfig(const EchoCanceller3Config::Suppressor& config) override;

 private:
  EchoCanceller3Config::Suppressor::DominantNearendDetection config_;
  const size_t num_capture_channels_;

  bool nearend_state_ = false;
  std::vector<int> trigger_counters_;
  std::vector<int> hold_counters_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AEC3_DOMINANT_NEAREND_DETECTOR_H_
