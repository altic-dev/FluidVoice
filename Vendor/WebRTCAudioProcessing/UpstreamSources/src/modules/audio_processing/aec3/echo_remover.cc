/*
 *  Copyright (c) 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/aec3/echo_remover.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <memory>
#include <optional>
#include <span>
#include <vector>

#include "api/audio/echo_canceller3_config.h"
#include "api/audio/echo_control.h"
#include "api/audio/neural_residual_echo_estimator.h"
#include "api/environment/environment.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/aec3_fft.h"
#include "modules/audio_processing/aec3/aec_state.h"
#include "modules/audio_processing/aec3/block.h"
#include "modules/audio_processing/aec3/comfort_noise_generator.h"
#include "modules/audio_processing/aec3/delay_estimate.h"
#include "modules/audio_processing/aec3/echo_path_variability.h"
#include "modules/audio_processing/aec3/echo_remover_metrics.h"
#include "modules/audio_processing/aec3/fft_data.h"
#include "modules/audio_processing/aec3/render_buffer.h"
#include "modules/audio_processing/aec3/render_signal_analyzer.h"
#include "modules/audio_processing/aec3/residual_echo_estimator.h"
#include "modules/audio_processing/aec3/subtractor.h"
#include "modules/audio_processing/aec3/subtractor_output.h"
#include "modules/audio_processing/aec3/suppression_filter.h"
#include "modules/audio_processing/aec3/suppression_gain.h"
#include "modules/audio_processing/logging/apm_data_dumper.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"

namespace webrtc {

namespace {

// Maximum number of channels for which the capture channel data is stored on
// the stack. If the number of channels are larger than this, they are stored
// using scratch memory that is pre-allocated on the heap. The reason for this
// partitioning is not to waste heap space for handling the more common numbers
// of channels, while at the same time not limiting the support for higher
// numbers of channels by enforcing the capture channel data to be stored on the
// stack using a fixed maximum value.
constexpr size_t kMaxNumChannelsOnStack = 2;

// Chooses the number of channels to store on the heap when that is required due
// to the number of capture channels being larger than the pre-defined number
// of channels to store on the stack.
size_t NumChannelsOnHeap(size_t num_capture_channels) {
  return num_capture_channels > kMaxNumChannelsOnStack ? num_capture_channels
                                                       : 0;
}

void LinearEchoPower(const FftData& E,
                     const FftData& Y,
                     std::array<float, kFftLengthBy2Plus1>* S2) {
  for (size_t k = 0; k < E.re.size(); ++k) {
    (*S2)[k] = (Y.re[k] - E.re[k]) * (Y.re[k] - E.re[k]) +
               (Y.im[k] - E.im[k]) * (Y.im[k] - E.im[k]);
  }
}

// Fades between two input signals using a fix-sized transition.
void SignalTransition(std::span<const float> from,
                      std::span<const float> to,
                      std::span<float> out) {
  RTC_DCHECK_EQ(from.size(), to.size());
  RTC_DCHECK_EQ(from.size(), out.size());
  if (from.data() == to.data()) {
    std::copy(to.begin(), to.end(), out.begin());
  } else {
    constexpr size_t kTransitionSize = 30;
    constexpr float kOneByTransitionSizePlusOne = 1.f / (kTransitionSize + 1);

    RTC_DCHECK_LE(kTransitionSize, out.size());

    for (size_t k = 0; k < kTransitionSize; ++k) {
      float a = (k + 1) * kOneByTransitionSizePlusOne;
      out[k] = a * to[k] + (1.f - a) * from[k];
    }

    std::copy(to.begin() + kTransitionSize, to.end(),
              out.begin() + kTransitionSize);
  }
}

// Computes a windowed (square root Hanning) padded FFT and updates the related
// memory.
void WindowedPaddedFft(const Aec3Fft& fft,
                       std::span<const float> v,
                       std::span<float> v_old,
                       FftData* V) {
  fft.PaddedFft(v, v_old, Aec3Fft::Window::kSqrtHanning, V);
  std::copy(v.begin(), v.end(), v_old.begin());
}

// Detects whether the output of the refined filter is more appropriate to use
// than the output of the coarse filter, returning the result as a bool.
bool UseRefinedOutput(const SubtractorOutput& subtractor_output) {
  // As the output of the refined adaptive filter generally should be better
  // than the coarse filter output, add a margin and threshold for when
  // choosing the coarse filter output.
  if (subtractor_output.e2_coarse < 0.9f * subtractor_output.e2_refined &&
      subtractor_output.y2 > 30.f * 30.f * kBlockSize &&
      (subtractor_output.s2_refined > 60.f * 60.f * kBlockSize ||
       subtractor_output.s2_coarse > 60.f * 60.f * kBlockSize)) {
    return false;
  }

  // If the refined filter is diverged, choose the filter output that has
  // the lowest power.
  if (subtractor_output.e2_coarse < subtractor_output.e2_refined &&
      subtractor_output.y2 < subtractor_output.e2_refined) {
    return false;
  }
  return true;
}

// Forms the linear filter output by smoothly transition between the refined and
// coarse filter outputs according to which of the filters is to be used.
void FormLinearFilterOutput(bool refined_filter_output_last_selected,
                            bool use_refined_output,
                            const SubtractorOutput& subtractor_output,
                            std::span<float> output) {
  RTC_DCHECK_EQ(subtractor_output.e_refined.size(), output.size());
  RTC_DCHECK_EQ(subtractor_output.e_coarse.size(), output.size());

  SignalTransition(refined_filter_output_last_selected
                       ? subtractor_output.e_refined
                       : subtractor_output.e_coarse,
                   use_refined_output ? subtractor_output.e_refined
                                      : subtractor_output.e_coarse,
                   output);
}

// Class for removing the echo from the capture signal.
class EchoRemoverImpl final : public EchoRemover {
 public:
  EchoRemoverImpl(const Environment& env,
                  const EchoCanceller3Config& config,
                  int sample_rate_hz,
                  size_t num_render_channels,
                  size_t num_capture_channels,
                  NeuralResidualEchoEstimator* neural_residual_echo_estimator);
  ~EchoRemoverImpl() override;
  EchoRemoverImpl(const EchoRemoverImpl&) = delete;
  EchoRemoverImpl& operator=(const EchoRemoverImpl&) = delete;

  void GetMetrics(EchoControl::Metrics* metrics) const override;

  // Removes the echo from a block of samples from the capture signal. The
  // supplied render signal is assumed to be pre-aligned with the capture
  // signal.
  void ProcessCapture(EchoPathVariability echo_path_variability,
                      bool capture_signal_saturation,
                      const std::optional<DelayEstimate>& external_delay,
                      RenderBuffer* render_buffer,
                      Block* linear_output,
                      Block* capture) override;

  // Updates the status on whether echo leakage is detected in the output of the
  // echo remover.
  void UpdateEchoLeakageStatus(bool leakage_detected) override {
    echo_leakage_detected_ = leakage_detected;
  }

  void SetCaptureOutputUsage(bool capture_output_used) override {
    capture_output_used_ = capture_output_used;
  }

 private:
  static std::atomic<int> instance_count_;
  const EchoCanceller3Config config_;
  const std::optional<EchoCanceller3Config::Suppressor>
      ml_ree_suppressor_config_;
  const Aec3Fft fft_;
  std::unique_ptr<ApmDataDumper> data_dumper_;
  const Aec3Optimization optimization_;
  const int sample_rate_hz_;
  const size_t num_render_channels_;
  const size_t num_capture_channels_;
  const bool use_coarse_filter_output_;
  Subtractor subtractor_;
  SuppressionGain suppression_gain_;
  ComfortNoiseGenerator cng_;
  SuppressionFilter suppression_filter_;
  RenderSignalAnalyzer render_signal_analyzer_;
  ResidualEchoEstimator residual_echo_estimator_;
  bool echo_leakage_detected_ = false;
  bool capture_output_used_ = true;
  AecState aec_state_;
  EchoRemoverMetrics metrics_;
  std::vector<std::array<float, kFftLengthBy2>> e_old_;
  std::vector<std::array<float, kFftLengthBy2>> y_old_;
  size_t block_counter_ = 0;
  int gain_change_hangover_ = 0;
  bool refined_filter_output_last_selected_ = true;
  bool ml_ree_was_active_ = false;

  std::vector<std::array<float, kFftLengthBy2>> e_heap_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> Y2_heap_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> E2_heap_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> R2_heap_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> R2_unbounded_heap_;
  std::vector<std::array<float, kFftLengthBy2Plus1>> S2_linear_heap_;
  std::vector<FftData> Y_heap_;
  std::vector<FftData> E_heap_;
  std::vector<FftData> comfort_noise_heap_;
  std::vector<FftData> high_band_comfort_noise_heap_;
  std::vector<SubtractorOutput> subtractor_output_heap_;
};

std::atomic<int> EchoRemoverImpl::instance_count_(0);

EchoRemoverImpl::EchoRemoverImpl(
    const Environment& env,
    const EchoCanceller3Config& config,
    int sample_rate_hz,
    size_t num_render_channels,
    size_t num_capture_channels,
    NeuralResidualEchoEstimator* neural_residual_echo_estimator)
    : config_(config),
      ml_ree_suppressor_config_(
          neural_residual_echo_estimator
              ? std::make_optional(neural_residual_echo_estimator->AdjustConfig(
                    config.suppressor))
              : std::nullopt),
      fft_(),
      data_dumper_(new ApmDataDumper(instance_count_.fetch_add(1) + 1)),
      optimization_(DetectOptimization()),
      sample_rate_hz_(sample_rate_hz),
      num_render_channels_(num_render_channels),
      num_capture_channels_(num_capture_channels),
      use_coarse_filter_output_(
          config_.filter.enable_coarse_filter_output_usage),
      subtractor_(env,
                  config,
                  num_render_channels_,
                  num_capture_channels_,
                  data_dumper_.get(),
                  optimization_),
      suppression_gain_(config_,
                        optimization_,
                        sample_rate_hz,
                        num_capture_channels),
      cng_(config_, optimization_, num_capture_channels_),
      suppression_filter_(optimization_,
                          sample_rate_hz_,
                          num_capture_channels_),
      render_signal_analyzer_(config_),
      residual_echo_estimator_(env,
                               config_,
                               num_render_channels,
                               neural_residual_echo_estimator),
      aec_state_(env, config_, num_capture_channels_),
      e_old_(num_capture_channels_, {0.f}),
      y_old_(num_capture_channels_, {0.f}),
      e_heap_(NumChannelsOnHeap(num_capture_channels_), {0.f}),
      Y2_heap_(NumChannelsOnHeap(num_capture_channels_)),
      E2_heap_(NumChannelsOnHeap(num_capture_channels_)),
      R2_heap_(NumChannelsOnHeap(num_capture_channels_)),
      R2_unbounded_heap_(NumChannelsOnHeap(num_capture_channels_)),
      S2_linear_heap_(NumChannelsOnHeap(num_capture_channels_)),
      Y_heap_(NumChannelsOnHeap(num_capture_channels_)),
      E_heap_(NumChannelsOnHeap(num_capture_channels_)),
      comfort_noise_heap_(NumChannelsOnHeap(num_capture_channels_)),
      high_band_comfort_noise_heap_(NumChannelsOnHeap(num_capture_channels_)),
      subtractor_output_heap_(NumChannelsOnHeap(num_capture_channels_)) {
  RTC_DCHECK(ValidFullBandRate(sample_rate_hz));
}

EchoRemoverImpl::~EchoRemoverImpl() = default;

void EchoRemoverImpl::GetMetrics(EchoControl::Metrics* metrics) const {
  // Echo return loss (ERL) is inverted to go from gain to attenuation.
  metrics->echo_return_loss = -10.0 * std::log10(aec_state_.ErlTimeDomain());
  metrics->echo_return_loss_enhancement =
      Log2TodB(aec_state_.FullBandErleLog2());
}

void EchoRemoverImpl::ProcessCapture(
    EchoPathVariability echo_path_variability,
    bool capture_signal_saturation,
    const std::optional<DelayEstimate>& external_delay,
    RenderBuffer* render_buffer,
    Block* linear_output,
    Block* capture) {
  ++block_counter_;
  const Block& x = render_buffer->GetBlock(0);
  Block* y = capture;
  RTC_DCHECK(render_buffer);
  RTC_DCHECK(y);
  RTC_DCHECK_EQ(x.NumBands(), NumBandsForRate(sample_rate_hz_));
  RTC_DCHECK_EQ(y->NumBands(), NumBandsForRate(sample_rate_hz_));
  RTC_DCHECK_EQ(x.NumChannels(), num_render_channels_);
  RTC_DCHECK_EQ(y->NumChannels(), num_capture_channels_);

  // Stack allocated data to use when the number of channels is low.
  std::array<std::array<float, kFftLengthBy2>, kMaxNumChannelsOnStack> e_stack;
  std::array<std::array<float, kFftLengthBy2Plus1>, kMaxNumChannelsOnStack>
      Y2_stack;
  std::array<std::array<float, kFftLengthBy2Plus1>, kMaxNumChannelsOnStack>
      E2_stack;
  std::array<std::array<float, kFftLengthBy2Plus1>, kMaxNumChannelsOnStack>
      R2_stack;
  std::array<std::array<float, kFftLengthBy2Plus1>, kMaxNumChannelsOnStack>
      R2_unbounded_stack;
  std::array<std::array<float, kFftLengthBy2Plus1>, kMaxNumChannelsOnStack>
      S2_linear_stack;
  std::array<FftData, kMaxNumChannelsOnStack> Y_stack;
  std::array<FftData, kMaxNumChannelsOnStack> E_stack;
  std::array<FftData, kMaxNumChannelsOnStack> comfort_noise_stack;
  std::array<FftData, kMaxNumChannelsOnStack> high_band_comfort_noise_stack;
  std::array<SubtractorOutput, kMaxNumChannelsOnStack> subtractor_output_stack;

  std::span<std::array<float, kFftLengthBy2>> e(e_stack.data(),
                                                num_capture_channels_);
  std::span<std::array<float, kFftLengthBy2Plus1>> Y2(Y2_stack.data(),
                                                      num_capture_channels_);
  std::span<std::array<float, kFftLengthBy2Plus1>> E2(E2_stack.data(),
                                                      num_capture_channels_);
  std::span<std::array<float, kFftLengthBy2Plus1>> R2(R2_stack.data(),
                                                      num_capture_channels_);
  std::span<std::array<float, kFftLengthBy2Plus1>> R2_unbounded(
      R2_unbounded_stack.data(), num_capture_channels_);
  std::span<std::array<float, kFftLengthBy2Plus1>> S2_linear(
      S2_linear_stack.data(), num_capture_channels_);
  std::span<FftData> Y(Y_stack.data(), num_capture_channels_);
  std::span<FftData> E(E_stack.data(), num_capture_channels_);
  std::span<FftData> comfort_noise(comfort_noise_stack.data(),
                                   num_capture_channels_);
  std::span<FftData> high_band_comfort_noise(
      high_band_comfort_noise_stack.data(), num_capture_channels_);
  std::span<SubtractorOutput> subtractor_output(subtractor_output_stack.data(),
                                                num_capture_channels_);
  if (NumChannelsOnHeap(num_capture_channels_) > 0) {
    // If the stack-allocated space is too small, use the heap for storing the
    // microphone data.
    e = std::span<std::array<float, kFftLengthBy2>>(e_heap_.data(),
                                                    num_capture_channels_);
    Y2 = std::span<std::array<float, kFftLengthBy2Plus1>>(
        Y2_heap_.data(), num_capture_channels_);
    E2 = std::span<std::array<float, kFftLengthBy2Plus1>>(
        E2_heap_.data(), num_capture_channels_);
    R2 = std::span<std::array<float, kFftLengthBy2Plus1>>(
        R2_heap_.data(), num_capture_channels_);
    R2_unbounded = std::span<std::array<float, kFftLengthBy2Plus1>>(
        R2_unbounded_heap_.data(), num_capture_channels_);
    S2_linear = std::span<std::array<float, kFftLengthBy2Plus1>>(
        S2_linear_heap_.data(), num_capture_channels_);
    Y = std::span<FftData>(Y_heap_.data(), num_capture_channels_);
    E = std::span<FftData>(E_heap_.data(), num_capture_channels_);
    comfort_noise =
        std::span<FftData>(comfort_noise_heap_.data(), num_capture_channels_);
    high_band_comfort_noise = std::span<FftData>(
        high_band_comfort_noise_heap_.data(), num_capture_channels_);
    subtractor_output = std::span<SubtractorOutput>(
        subtractor_output_heap_.data(), num_capture_channels_);
  }

  data_dumper_->DumpWav("aec3_echo_remover_capture_input",
                        y->View(/*band=*/0, /*channel=*/0), 16000, 1);
  data_dumper_->DumpWav("aec3_echo_remover_render_input",
                        x.View(/*band=*/0, /*channel=*/0), 16000, 1);
  data_dumper_->DumpRaw("aec3_echo_remover_capture_input",
                        y->View(/*band=*/0, /*channel=*/0));
  data_dumper_->DumpRaw("aec3_echo_remover_render_input",
                        x.View(/*band=*/0, /*channel=*/0));

  aec_state_.UpdateCaptureSaturation(capture_signal_saturation);

  if (echo_path_variability.AudioPathChanged()) {
    // Ensure that the gain change is only acted on once per frame.
    if (echo_path_variability.gain_change) {
      if (gain_change_hangover_ == 0) {
        constexpr int kMaxBlocksPerFrame = 3;
        gain_change_hangover_ = kMaxBlocksPerFrame;
        LoggingSeverity log_level = config_.delay.log_warning_on_delay_changes
                                        ? LS_WARNING
                                        : LS_VERBOSE;
        RTC_LOG_V(log_level)
            << "Gain change detected at block " << block_counter_;
      } else {
        echo_path_variability.gain_change = false;
      }
    }

    subtractor_.HandleEchoPathChange(echo_path_variability);
    aec_state_.HandleEchoPathChange(echo_path_variability);

    if (echo_path_variability.delay_change !=
        EchoPathVariability::DelayAdjustment::kNone) {
      suppression_gain_.SetInitialState(true);
    }
  }
  if (gain_change_hangover_ > 0) {
    --gain_change_hangover_;
  }

  // Analyze the render signal.
  render_signal_analyzer_.Update(*render_buffer,
                                 aec_state_.MinDirectPathFilterDelay());

  // State transition.
  if (aec_state_.TransitionTriggered()) {
    subtractor_.ExitInitialState();
    suppression_gain_.SetInitialState(false);
  }

  // Perform linear echo cancellation.
  subtractor_.Process(*render_buffer, *y, render_signal_analyzer_, aec_state_,
                      subtractor_output);

  const bool ml_ree_is_active = residual_echo_estimator_.IsMlReeActive();

  // Compute spectra.
  bool use_refined_output;
  if (use_coarse_filter_output_ && !ml_ree_is_active) {
    use_refined_output = false;
    for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
      if (UseRefinedOutput(subtractor_output[ch])) {
        use_refined_output = true;
        break;
      }
    }
  } else {
    use_refined_output = true;
  }
  for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
    FormLinearFilterOutput(refined_filter_output_last_selected_,
                           use_refined_output, subtractor_output[ch], e[ch]);
    WindowedPaddedFft(fft_, y->View(/*band=*/0, ch), y_old_[ch], &Y[ch]);
    WindowedPaddedFft(fft_, e[ch], e_old_[ch], &E[ch]);
    LinearEchoPower(E[ch], Y[ch], &S2_linear[ch]);
    Y[ch].Spectrum(optimization_, Y2[ch]);
    E[ch].Spectrum(optimization_, E2[ch]);
  }
  refined_filter_output_last_selected_ = use_refined_output;
  const auto& nearend_spectrum = aec_state_.UsableLinearEstimate() ? E2 : Y2;
  // `y_old_` and `e_old_` now point to the current block. Though their channel
  // layout is already suitable for residual echo estimation, an alias is
  // created for clarity.
  const auto& y_current = y_old_;
  const auto& e_current = e_old_;

  // Optionally return the linear filter output.
  if (linear_output) {
    RTC_DCHECK_GE(1, linear_output->NumBands());
    RTC_DCHECK_EQ(num_capture_channels_, linear_output->NumChannels());
    for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
      std::copy(e[ch].begin(), e[ch].end(),
                linear_output->begin(/*band=*/0, ch));
    }
  }

  // Update the AEC state information.
  aec_state_.Update(external_delay, subtractor_.FilterFrequencyResponses(),
                    subtractor_.FilterImpulseResponses(), *render_buffer, E2,
                    Y2, subtractor_output);

  // Choose the linear output.
  const auto& Y_fft = aec_state_.UseLinearFilterOutput() ? E : Y;

  data_dumper_->DumpWav("aec3_output_linear",
                        y->View(/*band=*/0, /*channel=*/0), 16000, 1);
  data_dumper_->DumpWav("aec3_output_linear2", kBlockSize, &e[0][0], 16000, 1);

  // Estimate the comfort noise.
  cng_.Compute(aec_state_.SaturatedCapture(), nearend_spectrum, comfort_noise,
               high_band_comfort_noise);

  // Only do the below processing if the output of the audio processing module
  // is used.
  std::array<float, kFftLengthBy2Plus1> G;
  if (capture_output_used_) {
    // Estimate the residual echo power.
    residual_echo_estimator_.Estimate(
        aec_state_, *render_buffer, y_current, e_current, S2_linear, Y2, E2,
        suppression_gain_.IsDominantNearend(), R2, R2_unbounded);

    // Suppressor nearend estimate.
    if (aec_state_.UsableLinearEstimate()) {
      // E2 is bound by Y2.
      for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
        std::transform(E2[ch].begin(), E2[ch].end(), Y2[ch].begin(),
                       E2[ch].begin(),
                       [](float a, float b) { return std::min(a, b); });
      }
    }

    // Suppressor echo estimate.
    const auto& echo_spectrum =
        aec_state_.UsableLinearEstimate() ? S2_linear : R2;

    // Determine if the suppressor should assume clock drift.
    const bool clock_drift = config_.echo_removal_control.has_clock_drift ||
                             echo_path_variability.clock_drift;

    // Select the active suppressor configuration.
    const EchoCanceller3Config::Suppressor& active_suppressor_config =
        (ml_ree_is_active && ml_ree_suppressor_config_.has_value())
            ? *ml_ree_suppressor_config_
            : config_.suppressor;

    // Determine if the configuration affecting the suppressor has changed.
    const bool config_changed = (ml_ree_is_active != ml_ree_was_active_);
    ml_ree_was_active_ = ml_ree_is_active;

    // Compute preferred gains.
    float high_bands_gain;
    suppression_gain_.GetGain(active_suppressor_config, config_changed,
                              nearend_spectrum, echo_spectrum, R2, R2_unbounded,
                              cng_.NoiseSpectrum(), render_signal_analyzer_,
                              aec_state_, x, clock_drift, &high_bands_gain, &G);

    suppression_filter_.ApplyGain(comfort_noise, high_band_comfort_noise, G,
                                  high_bands_gain, Y_fft, y);

  } else {
    G.fill(0.f);
  }

  // Update the metrics.
  metrics_.Update(aec_state_, cng_.NoiseSpectrum()[0], G);

  // Debug outputs for the purpose of development and analysis.
  data_dumper_->DumpWav("aec3_echo_estimate", kBlockSize,
                        &subtractor_output[0].s_refined[0], 16000, 1);
  data_dumper_->DumpRaw("aec3_output", y->View(/*band=*/0, /*channel=*/0));
  data_dumper_->DumpRaw("aec3_narrow_render",
                        render_signal_analyzer_.NarrowPeakBand() ? 1 : 0);
  data_dumper_->DumpRaw("aec3_N2", cng_.NoiseSpectrum()[0]);
  data_dumper_->DumpRaw("aec3_suppressor_gain", G);
  data_dumper_->DumpWav("aec3_output", y->View(/*band=*/0, /*channel=*/0),
                        16000, 1);
  data_dumper_->DumpRaw("aec3_using_subtractor_output[0]",
                        aec_state_.UseLinearFilterOutput() ? 1 : 0);
  data_dumper_->DumpRaw("aec3_E2", E2[0]);
  data_dumper_->DumpRaw("aec3_S2_linear", S2_linear[0]);
  data_dumper_->DumpRaw("aec3_Y2", Y2[0]);
  data_dumper_->DumpRaw(
      "aec3_X2", render_buffer->Spectrum(
                     aec_state_.MinDirectPathFilterDelay())[/*channel=*/0]);
  data_dumper_->DumpRaw("aec3_R2", R2[0]);
  data_dumper_->DumpRaw("aec3_filter_delay",
                        aec_state_.MinDirectPathFilterDelay());
  data_dumper_->DumpRaw("aec3_capture_saturation",
                        aec_state_.SaturatedCapture() ? 1 : 0);
}

}  // namespace

std::unique_ptr<EchoRemover> EchoRemover::Create(
    const Environment& env,
    const EchoCanceller3Config& config,
    int sample_rate_hz,
    size_t num_render_channels,
    size_t num_capture_channels,
    NeuralResidualEchoEstimator* neural_residual_echo_estimator) {
  return std::make_unique<EchoRemoverImpl>(
      env, config, sample_rate_hz, num_render_channels, num_capture_channels,
      neural_residual_echo_estimator);
}

}  // namespace webrtc
