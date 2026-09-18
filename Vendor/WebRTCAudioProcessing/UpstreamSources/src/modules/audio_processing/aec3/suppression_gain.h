/*
 *  Copyright (c) 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_AEC3_SUPPRESSION_GAIN_H_
#define MODULES_AUDIO_PROCESSING_AEC3_SUPPRESSION_GAIN_H_

#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <optional>
#include <span>
#include <vector>

#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/aec_state.h"
#include "modules/audio_processing/aec3/block.h"
#include "modules/audio_processing/aec3/moving_average_spectrum.h"
#include "modules/audio_processing/aec3/nearend_detector.h"
#include "modules/audio_processing/aec3/render_signal_analyzer.h"
#include "modules/audio_processing/logging/apm_data_dumper.h"
#include "rtc_base/gtest_prod_util.h"

namespace webrtc {

class SuppressionGain {
 public:
  SuppressionGain(const EchoCanceller3Config& config,
                  Aec3Optimization optimization,
                  int sample_rate_hz,
                  size_t num_capture_channels);
  ~SuppressionGain();

  SuppressionGain(const SuppressionGain&) = delete;
  SuppressionGain& operator=(const SuppressionGain&) = delete;

  void GetGain(
      const EchoCanceller3Config::Suppressor& suppressor_config,
      bool config_changed,
      std::span<const std::array<float, kFftLengthBy2Plus1>> nearend_spectrum,
      std::span<const std::array<float, kFftLengthBy2Plus1>> echo_spectrum,
      std::span<const std::array<float, kFftLengthBy2Plus1>>
          residual_echo_spectrum,
      std::span<const std::array<float, kFftLengthBy2Plus1>>
          residual_echo_spectrum_unbounded,
      std::span<const std::array<float, kFftLengthBy2Plus1>>
          comfort_noise_spectrum,
      const RenderSignalAnalyzer& render_signal_analyzer,
      const AecState& aec_state,
      const Block& render,
      bool clock_drift,
      float* high_bands_gain,
      std::array<float, kFftLengthBy2Plus1>* low_band_gain);

  bool IsDominantNearend() {
    return dominant_nearend_detector_->IsNearendState();
  }

  // Toggles the usage of the initial state.
  void SetInitialState(bool state);

 private:
  FRIEND_TEST_ALL_PREFIXES(SuppressionGainTest, UpdateStateDependingOnConfig);

  // Updates the internal state, e.g. sizes and parameters, if the config
  // changes.
  void UpdateStateDependingOnConfig(
      const EchoCanceller3Config::Suppressor& suppressor_config);
  // Computes the gain to apply for the bands beyond the first band.
  float UpperBandsGain(
      const EchoCanceller3Config::Suppressor& suppressor_config,
      std::span<const std::array<float, kFftLengthBy2Plus1>> echo_spectrum,
      std::span<const std::array<float, kFftLengthBy2Plus1>>
          comfort_noise_spectrum,
      const std::optional<int>& narrow_peak_band,
      bool saturated_echo,
      const Block& render,
      const std::array<float, kFftLengthBy2Plus1>& low_band_gain) const;

  void GainToNoAudibleEcho(const std::array<float, kFftLengthBy2Plus1>& nearend,
                           const std::array<float, kFftLengthBy2Plus1>& echo,
                           const std::array<float, kFftLengthBy2Plus1>& masker,
                           std::array<float, kFftLengthBy2Plus1>* gain) const;

  void LowerBandGain(
      const EchoCanceller3Config::Suppressor& suppressor_config,
      bool stationary_with_low_power,
      const AecState& aec_state,
      std::span<const std::array<float, kFftLengthBy2Plus1>> suppressor_input,
      std::span<const std::array<float, kFftLengthBy2Plus1>> residual_echo,
      std::span<const std::array<float, kFftLengthBy2Plus1>> comfort_noise,
      bool clock_drift,
      std::array<float, kFftLengthBy2Plus1>* gain);

  void GetMinGain(const EchoCanceller3Config::Suppressor& suppressor_config,
                  std::span<const float> weighted_residual_echo,
                  std::span<const float> last_nearend,
                  std::span<const float> last_echo,
                  bool low_noise_render,
                  bool saturated_echo,
                  std::span<float> min_gain) const;

  void GetMaxGain(float floor_first_increase, std::span<float> max_gain) const;

  class LowNoiseRenderDetector {
   public:
    bool Detect(const Block& render);

   private:
    float average_power_ = 32768.f * 32768.f;
  };

  struct GainParameters {
    explicit GainParameters(
        int last_lf_band,
        int first_hf_band,
        const EchoCanceller3Config::Suppressor::Tuning& tuning);
    void SetConfig(int last_lf_band,
                   int first_hf_band,
                   const EchoCanceller3Config::Suppressor::Tuning& tuning);
    float max_inc_factor;
    float max_dec_factor_lf;
    std::array<float, kFftLengthBy2Plus1> enr_transparent_;
    std::array<float, kFftLengthBy2Plus1> enr_suppress_;
    std::array<float, kFftLengthBy2Plus1> emr_transparent_;
  };

  static std::atomic<int> instance_count_;
  std::unique_ptr<ApmDataDumper> data_dumper_;
  const Aec3Optimization optimization_;
  const size_t num_capture_channels_;
  const EchoCanceller3Config::EchoAudibility echo_audibility_config_;
  const bool use_subband_nearend_detection_;
  std::array<float, kFftLengthBy2Plus1> last_gain_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> last_nearend_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> last_echo_;
  LowNoiseRenderDetector low_render_detector_;
  bool initial_state_ = true;
  std::vector<MovingAverageSpectrum> nearend_smoothers_;
  GainParameters nearend_params_;
  GainParameters normal_params_;
  std::unique_ptr<NearendDetector> dominant_nearend_detector_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AEC3_SUPPRESSION_GAIN_H_
