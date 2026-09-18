/*
 *  Copyright (c) 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/aec3/residual_echo_estimator.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <vector>

#include "api/audio/echo_canceller3_config.h"
#include "api/audio/neural_residual_echo_estimator.h"
#include "api/environment/environment.h"
#include "api/field_trials_view.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/aec_state.h"
#include "modules/audio_processing/aec3/block.h"
#include "modules/audio_processing/aec3/delay_estimate.h"
#include "modules/audio_processing/aec3/render_buffer.h"
#include "modules/audio_processing/aec3/reverb_model.h"
#include "modules/audio_processing/aec3/spectrum_buffer.h"
#include "rtc_base/checks.h"

namespace webrtc {
namespace {

constexpr float kDefaultTransparentModeGain = 0.01f;

float GetTransparentModeGain() {
  return kDefaultTransparentModeGain;
}

float GetEarlyReflectionsDefaultModeGain(
    const FieldTrialsView& field_trials,
    const EchoCanceller3Config::EpStrength& config) {
  if (field_trials.IsEnabled("WebRTC-Aec3UseLowEarlyReflectionsDefaultGain")) {
    return 0.1f;
  }
  return config.default_gain;
}

float GetLateReflectionsDefaultModeGain(
    const FieldTrialsView& field_trials,
    const EchoCanceller3Config::EpStrength& config) {
  if (field_trials.IsEnabled("WebRTC-Aec3UseLowLateReflectionsDefaultGain")) {
    return 0.1f;
  }
  return config.default_gain;
}

bool UseErleOnsetCompensationInDominantNearend(
    const FieldTrialsView& field_trials,
    const EchoCanceller3Config::EpStrength& config) {
  return config.erle_onset_compensation_in_dominant_nearend ||
         field_trials.IsEnabled(
             "WebRTC-Aec3UseErleOnsetCompensationInDominantNearend");
}

// Computes the indexes that will be used for computing spectral power over
// the blocks surrounding the delay.
void GetRenderIndexesToAnalyze(
    const SpectrumBuffer& spectrum_buffer,
    const EchoCanceller3Config::EchoModel& echo_model,
    int filter_delay_blocks,
    int* idx_start,
    int* idx_stop) {
  RTC_DCHECK(idx_start);
  RTC_DCHECK(idx_stop);
  size_t window_start;
  size_t window_end;
  window_start =
      std::max(0, filter_delay_blocks -
                      static_cast<int>(echo_model.render_pre_window_size));
  window_end = filter_delay_blocks +
               static_cast<int>(echo_model.render_post_window_size);
  *idx_start = spectrum_buffer.OffsetIndex(spectrum_buffer.read, window_start);
  *idx_stop = spectrum_buffer.OffsetIndex(spectrum_buffer.read, window_end + 1);
}

// Estimates the residual echo power based on the echo return loss enhancement
// (ERLE) and the linear power estimate.
void LinearEstimate(
    std::span<const std::array<float, kFftLengthBy2Plus1>> S2_linear,
    std::span<const std::array<float, kFftLengthBy2Plus1>> erle,
    std::span<std::array<float, kFftLengthBy2Plus1>> R2) {
  RTC_DCHECK_EQ(S2_linear.size(), erle.size());
  RTC_DCHECK_EQ(S2_linear.size(), R2.size());

  const size_t num_capture_channels = R2.size();
  for (size_t ch = 0; ch < num_capture_channels; ++ch) {
    for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
      RTC_DCHECK_LT(0.f, erle[ch][k]);
      R2[ch][k] = S2_linear[ch][k] / erle[ch][k];
    }
  }
}

// Estimates the residual echo power based on the estimate of the echo path
// gain.
void NonLinearEstimate(float echo_path_gain,
                       const std::array<float, kFftLengthBy2Plus1>& X2,
                       std::span<std::array<float, kFftLengthBy2Plus1>> R2) {
  const size_t num_capture_channels = R2.size();
  for (size_t ch = 0; ch < num_capture_channels; ++ch) {
    for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
      R2[ch][k] = X2[k] * echo_path_gain;
    }
  }
}

// Applies a soft noise gate to the echo generating power.
void ApplyNoiseGate(const EchoCanceller3Config::EchoModel& config,
                    std::span<float, kFftLengthBy2Plus1> X2) {
  for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
    if (config.noise_gate_power > X2[k]) {
      X2[k] = std::max(0.f, X2[k] - config.noise_gate_slope *
                                        (config.noise_gate_power - X2[k]));
    }
  }
}

// Estimates the echo generating signal power as gated maximal power over a
// time window.
void EchoGeneratingPower(size_t num_render_channels,
                         const SpectrumBuffer& spectrum_buffer,
                         const EchoCanceller3Config::EchoModel& echo_model,
                         int filter_delay_blocks,
                         std::span<float, kFftLengthBy2Plus1> X2) {
  int idx_stop;
  int idx_start;
  GetRenderIndexesToAnalyze(spectrum_buffer, echo_model, filter_delay_blocks,
                            &idx_start, &idx_stop);

  std::fill(X2.begin(), X2.end(), 0.f);
  if (num_render_channels == 1) {
    for (int k = idx_start; k != idx_stop; k = spectrum_buffer.IncIndex(k)) {
      for (size_t j = 0; j < kFftLengthBy2Plus1; ++j) {
        X2[j] = std::max(X2[j], spectrum_buffer.buffer[k][/*channel=*/0][j]);
      }
    }
  } else {
    for (int k = idx_start; k != idx_stop; k = spectrum_buffer.IncIndex(k)) {
      std::array<float, kFftLengthBy2Plus1> render_power;
      render_power.fill(0.f);
      for (size_t ch = 0; ch < num_render_channels; ++ch) {
        const auto& channel_power = spectrum_buffer.buffer[k][ch];
        for (size_t j = 0; j < kFftLengthBy2Plus1; ++j) {
          render_power[j] += channel_power[j];
        }
      }
      for (size_t j = 0; j < kFftLengthBy2Plus1; ++j) {
        X2[j] = std::max(X2[j], render_power[j]);
      }
    }
  }
}

}  // namespace

ResidualEchoEstimator::ResidualEchoEstimator(
    const Environment& env,
    const EchoCanceller3Config& config,
    size_t num_render_channels,
    NeuralResidualEchoEstimator* neural_residual_echo_estimator)
    : config_(config),
      num_render_channels_(num_render_channels),
      early_reflections_transparent_mode_gain_(GetTransparentModeGain()),
      late_reflections_transparent_mode_gain_(GetTransparentModeGain()),
      early_reflections_general_gain_(
          GetEarlyReflectionsDefaultModeGain(env.field_trials(),
                                             config_.ep_strength)),
      late_reflections_general_gain_(
          GetLateReflectionsDefaultModeGain(env.field_trials(),
                                            config_.ep_strength)),
      erle_onset_compensation_in_dominant_nearend_(
          UseErleOnsetCompensationInDominantNearend(env.field_trials(),
                                                    config_.ep_strength)),
      neural_residual_echo_estimator_(neural_residual_echo_estimator) {
  Reset();
}

ResidualEchoEstimator::~ResidualEchoEstimator() = default;

void ResidualEchoEstimator::Estimate(
    const AecState& aec_state,
    const RenderBuffer& render_buffer,
    std::span<const std::array<float, kFftLengthBy2>> capture,
    std::span<const std::array<float, kFftLengthBy2>> linear_aec_output,
    std::span<const std::array<float, kFftLengthBy2Plus1>> S2_linear,
    std::span<const std::array<float, kFftLengthBy2Plus1>> Y2,
    std::span<const std::array<float, kFftLengthBy2Plus1>> E2,
    bool dominant_nearend,
    std::span<std::array<float, kFftLengthBy2Plus1>> R2,
    std::span<std::array<float, kFftLengthBy2Plus1>> R2_unbounded) {
  RTC_DCHECK_EQ(R2.size(), Y2.size());
  RTC_DCHECK_EQ(R2.size(), S2_linear.size());

  const size_t num_capture_channels = R2.size();

  if (neural_residual_echo_estimator_ != nullptr &&
      neural_residual_echo_estimator_->IsInitialized()) {
    ml_ree_state_ = aec_state.UsableLinearEstimate() ? MlReeState::kActive
                                                     : MlReeState::kInitialized;
  }

  // Estimate the power of the stationary noise in the render signal.
  UpdateRenderNoisePower(render_buffer);

  // The neural residual echo estimation always runs, even if the estimated
  // spectra |R2| and |R2_unbounded| are overwritten later. This ensures the
  // estimator sees continuous signals at a constant time rate.
  if (ml_ree_state_ != MlReeState::kUninitialized) {
    RTC_DCHECK(neural_residual_echo_estimator_);
    constexpr int kNeuralDelayHeadroomMs = 12;
    constexpr int kNeuralDelayHeadroomBlocks =
        kNeuralDelayHeadroomMs / kBlockSizeMs;
    constexpr int kJitterMarginBlocks = 3;
    std::optional<DelayEstimate> external_delay_blocks =
        aec_state.ExternalDelayBlocks();
    int headroom_blocks = 0;
    int headroom_render_buffer = render_buffer.Headroom();
    if (external_delay_blocks &&
        external_delay_blocks->delay >
            kNeuralDelayHeadroomBlocks + kJitterMarginBlocks &&
        headroom_render_buffer > 0) {
      headroom_blocks =
          std::min(headroom_render_buffer - 1, kNeuralDelayHeadroomBlocks);
    }

    const Block& render = render_buffer.GetBlock(headroom_blocks);
    neural_residual_echo_estimator_->Estimate(
        render, capture, linear_aec_output, S2_linear, Y2, E2, dominant_nearend,
        R2, R2_unbounded);
  }

  // Estimate the residual echo power, used when ml_ree is not active.
  if (ml_ree_state_ != MlReeState::kActive) {
    if (aec_state.UsableLinearEstimate()) {
      // When there is saturated echo, assume the same spectral content as is
      // present in the microphone signal.
      if (aec_state.SaturatedEcho()) {
        for (size_t ch = 0; ch < num_capture_channels; ++ch) {
          std::copy(Y2[ch].begin(), Y2[ch].end(), R2[ch].begin());
          std::copy(Y2[ch].begin(), Y2[ch].end(), R2_unbounded[ch].begin());
        }
      } else {
        const bool onset_compensated =
            erle_onset_compensation_in_dominant_nearend_ || !dominant_nearend;
        LinearEstimate(S2_linear, aec_state.Erle(onset_compensated), R2);
        LinearEstimate(S2_linear, aec_state.ErleUnbounded(), R2_unbounded);
      }

      UpdateReverb(ReverbType::kLinear, aec_state, render_buffer,
                   dominant_nearend);
      AddReverb(R2);
      AddReverb(R2_unbounded);
    } else {
      const float echo_path_gain =
          GetEchoPathGain(aec_state, /*gain_for_early_reflections=*/true);

      // When there is saturated echo, assume the same spectral content as is
      // present in the microphone signal.
      if (aec_state.SaturatedEcho()) {
        for (size_t ch = 0; ch < num_capture_channels; ++ch) {
          std::copy(Y2[ch].begin(), Y2[ch].end(), R2[ch].begin());
          std::copy(Y2[ch].begin(), Y2[ch].end(), R2_unbounded[ch].begin());
        }
      } else {
        // Estimate the echo generating signal power.
        std::array<float, kFftLengthBy2Plus1> X2;
        EchoGeneratingPower(
            num_render_channels_, render_buffer.GetSpectrumBuffer(),
            config_.echo_model, aec_state.MinDirectPathFilterDelay(), X2);
        if (!aec_state.UseStationarityProperties()) {
          ApplyNoiseGate(config_.echo_model, X2);
        }

        // Subtract the stationary noise power to avoid stationary noise causing
        // excessive echo suppression.
        for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
          X2[k] -=
              config_.echo_model.stationary_gate_slope * X2_noise_floor_[k];
          X2[k] = std::max(0.f, X2[k]);
        }

        NonLinearEstimate(echo_path_gain, X2, R2);
        NonLinearEstimate(echo_path_gain, X2, R2_unbounded);
      }

      if (config_.echo_model.model_reverb_in_nonlinear_mode &&
          !aec_state.TransparentModeActive()) {
        UpdateReverb(ReverbType::kNonLinear, aec_state, render_buffer,
                     dominant_nearend);
        AddReverb(R2);
        AddReverb(R2_unbounded);
      }
    }
  }
  if (aec_state.UseStationarityProperties()) {
    // Scale the echo according to echo audibility.
    std::array<float, kFftLengthBy2Plus1> residual_scaling;
    aec_state.GetResidualEchoScaling(residual_scaling);
    for (size_t ch = 0; ch < num_capture_channels; ++ch) {
      for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
        R2[ch][k] *= residual_scaling[k];
        R2_unbounded[ch][k] *= residual_scaling[k];
      }
    }
  }
}

void ResidualEchoEstimator::Reset() {
  echo_reverb_.Reset();
  X2_noise_floor_counter_.fill(config_.echo_model.noise_floor_hold);
  X2_noise_floor_.fill(config_.echo_model.min_noise_floor_power);
  if (neural_residual_echo_estimator_) {
    neural_residual_echo_estimator_->Reset();
  }
}

void ResidualEchoEstimator::UpdateRenderNoisePower(
    const RenderBuffer& render_buffer) {
  std::array<float, kFftLengthBy2Plus1> render_power_data;
  std::span<const std::array<float, kFftLengthBy2Plus1>> X2 =
      render_buffer.Spectrum(0);
  std::span<const float, kFftLengthBy2Plus1> render_power = X2[/*channel=*/0];
  if (num_render_channels_ > 1) {
    render_power_data.fill(0.f);
    for (size_t ch = 0; ch < num_render_channels_; ++ch) {
      const auto& channel_power = X2[ch];
      for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
        render_power_data[k] += channel_power[k];
      }
    }
    render_power = render_power_data;
  }

  // Estimate the stationary noise power in a minimum statistics manner.
  for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
    // Decrease rapidly.
    if (render_power[k] < X2_noise_floor_[k]) {
      X2_noise_floor_[k] = render_power[k];
      X2_noise_floor_counter_[k] = 0;
    } else {
      // Increase in a delayed, leaky manner.
      if (X2_noise_floor_counter_[k] >=
          static_cast<int>(config_.echo_model.noise_floor_hold)) {
        X2_noise_floor_[k] = std::max(X2_noise_floor_[k] * 1.1f,
                                      config_.echo_model.min_noise_floor_power);
      } else {
        ++X2_noise_floor_counter_[k];
      }
    }
  }
}

// Updates the reverb estimation.
void ResidualEchoEstimator::UpdateReverb(ReverbType reverb_type,
                                         const AecState& aec_state,
                                         const RenderBuffer& render_buffer,
                                         bool dominant_nearend) {
  // Choose reverb partition based on what type of echo power model is used.
  const size_t first_reverb_partition =
      reverb_type == ReverbType::kLinear
          ? aec_state.FilterLengthBlocks() + 1
          : aec_state.MinDirectPathFilterDelay() + 1;

  // Compute render power for the reverb.
  std::array<float, kFftLengthBy2Plus1> render_power_data;
  std::span<const std::array<float, kFftLengthBy2Plus1>> X2 =
      render_buffer.Spectrum(first_reverb_partition);
  std::span<const float, kFftLengthBy2Plus1> render_power = X2[/*channel=*/0];
  if (num_render_channels_ > 1) {
    render_power_data.fill(0.f);
    for (size_t ch = 0; ch < num_render_channels_; ++ch) {
      const auto& channel_power = X2[ch];
      for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
        render_power_data[k] += channel_power[k];
      }
    }
    render_power = render_power_data;
  }

  // Update the reverb estimate.
  float reverb_decay = aec_state.ReverbDecay(/*mild=*/dominant_nearend);
  if (reverb_type == ReverbType::kLinear) {
    echo_reverb_.UpdateReverb(
        render_power, aec_state.GetReverbFrequencyResponse(), reverb_decay);
  } else {
    const float echo_path_gain =
        GetEchoPathGain(aec_state, /*gain_for_early_reflections=*/false);
    echo_reverb_.UpdateReverbNoFreqShaping(render_power, echo_path_gain,
                                           reverb_decay);
  }
}
// Adds the estimated power of the reverb to the residual echo power.
void ResidualEchoEstimator::AddReverb(
    std::span<std::array<float, kFftLengthBy2Plus1>> R2) const {
  const size_t num_capture_channels = R2.size();

  // Add the reverb power.
  std::span<const float, kFftLengthBy2Plus1> reverb_power =
      echo_reverb_.reverb();
  for (size_t ch = 0; ch < num_capture_channels; ++ch) {
    for (size_t k = 0; k < kFftLengthBy2Plus1; ++k) {
      R2[ch][k] += reverb_power[k];
    }
  }
}

// Chooses the echo path gain to use.
float ResidualEchoEstimator::GetEchoPathGain(
    const AecState& aec_state,
    bool gain_for_early_reflections) const {
  float gain_amplitude;
  if (aec_state.TransparentModeActive()) {
    gain_amplitude = gain_for_early_reflections
                         ? early_reflections_transparent_mode_gain_
                         : late_reflections_transparent_mode_gain_;
  } else {
    gain_amplitude = gain_for_early_reflections
                         ? early_reflections_general_gain_
                         : late_reflections_general_gain_;
  }
  return gain_amplitude * gain_amplitude;
}

}  // namespace webrtc
