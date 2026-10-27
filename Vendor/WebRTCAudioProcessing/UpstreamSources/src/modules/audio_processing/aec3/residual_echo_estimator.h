/*
 *  Copyright (c) 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_AEC3_RESIDUAL_ECHO_ESTIMATOR_H_
#define MODULES_AUDIO_PROCESSING_AEC3_RESIDUAL_ECHO_ESTIMATOR_H_

#include <array>
#include <cstddef>
#include <span>

#include "api/audio/echo_canceller3_config.h"
#include "api/audio/neural_residual_echo_estimator.h"
#include "api/environment/environment.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/aec_state.h"
#include "modules/audio_processing/aec3/render_buffer.h"
#include "modules/audio_processing/aec3/reverb_model.h"

namespace webrtc {

class ResidualEchoEstimator {
 public:
  ResidualEchoEstimator(
      const Environment& env,
      const EchoCanceller3Config& config,
      size_t num_render_channels,
      NeuralResidualEchoEstimator* neural_residual_echo_estimator);
  ~ResidualEchoEstimator();

  ResidualEchoEstimator(const ResidualEchoEstimator&) = delete;
  ResidualEchoEstimator& operator=(const ResidualEchoEstimator&) = delete;

  void Estimate(
      const AecState& aec_state,
      const RenderBuffer& render_buffer,
      std::span<const std::array<float, kFftLengthBy2>> capture,
      std::span<const std::array<float, kFftLengthBy2>> linear_aec_output,
      std::span<const std::array<float, kFftLengthBy2Plus1>> S2_linear,
      std::span<const std::array<float, kFftLengthBy2Plus1>> Y2,
      std::span<const std::array<float, kFftLengthBy2Plus1>> E2,
      bool dominant_nearend,
      std::span<std::array<float, kFftLengthBy2Plus1>> R2,
      std::span<std::array<float, kFftLengthBy2Plus1>> R2_unbounded);

  // Returns true if output from neural residual echo estimation is actively
  // used.
  bool IsMlReeActive() const { return ml_ree_state_ == MlReeState::kActive; }

 private:
  enum class ReverbType { kLinear, kNonLinear };

  // State of neural residual echo estimation.
  enum class MlReeState {
    // Neural estimator is either not present or not initialized.
    // Once we leave this state, we never return to it.
    kUninitialized,
    // Neural estimator is initialized but not used.
    kInitialized,
    // Neural estimator is initialized and actively used for estimation.
    kActive
  };

  // Resets the state.
  void Reset();

  // Updates estimate for the power of the stationary noise component in the
  // render signal.
  void UpdateRenderNoisePower(const RenderBuffer& render_buffer);

  // Updates the reverb estimation.
  void UpdateReverb(ReverbType reverb_type,
                    const AecState& aec_state,
                    const RenderBuffer& render_buffer,
                    bool dominant_nearend);

  // Adds the estimated unmodelled echo power to the residual echo power
  // estimate.
  void AddReverb(std::span<std::array<float, kFftLengthBy2Plus1>> R2) const;

  // Gets the echo path gain to apply.
  float GetEchoPathGain(const AecState& aec_state,
                        bool gain_for_early_reflections) const;

  const EchoCanceller3Config config_;
  const size_t num_render_channels_;
  const float early_reflections_transparent_mode_gain_;
  const float late_reflections_transparent_mode_gain_;
  const float early_reflections_general_gain_;
  const float late_reflections_general_gain_;
  const bool erle_onset_compensation_in_dominant_nearend_;
  std::array<float, kFftLengthBy2Plus1> X2_noise_floor_;
  std::array<int, kFftLengthBy2Plus1> X2_noise_floor_counter_;
  ReverbModel echo_reverb_;
  NeuralResidualEchoEstimator* neural_residual_echo_estimator_;
  MlReeState ml_ree_state_ = MlReeState::kUninitialized;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AEC3_RESIDUAL_ECHO_ESTIMATOR_H_
