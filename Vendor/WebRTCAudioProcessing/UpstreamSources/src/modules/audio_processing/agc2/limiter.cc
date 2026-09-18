/*
 *  Copyright (c) 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/agc2/limiter.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <span>

#include "absl/strings/string_view.h"
#include "api/audio/audio_view.h"
#include "modules/audio_processing/agc2/agc2_common.h"
#include "modules/audio_processing/agc2/interpolated_gain_curve.h"
#include "modules/audio_processing/logging/apm_data_dumper.h"
#include "rtc_base/checks.h"
#include "rtc_base/numerics/safe_conversions.h"
#include "rtc_base/numerics/safe_minmax.h"

namespace webrtc {
namespace {

// This constant affects the way scaling factors are interpolated for the first
// sub-frame of a frame. Only in the case in which the first sub-frame has an
// estimated level which is greater than the that of the previous analyzed
// sub-frame, linear interpolation is replaced with a power function which
// reduces the chances of over-shooting (and hence saturation), however reducing
// the fixed gain effectiveness.
constexpr float kAttackFirstSubframeInterpolationPower = 8.0f;

void InterpolateFirstSubframe(float last_factor,
                              float current_factor,
                              std::span<float> subframe) {
  const int n = dchecked_cast<int>(subframe.size());
  constexpr float p = kAttackFirstSubframeInterpolationPower;
  for (int i = 0; i < n; ++i) {
    float t = static_cast<float>(i) / n;
    subframe[i] =
        std::pow(1.f - t, p) * (last_factor - current_factor) + current_factor;
  }
}

void ComputePerSampleSubframeFactors(
    const std::array<float, kSubFramesInFrame + 1>& scaling_factors,
    MonoView<float> per_sample_scaling_factors) {
  const size_t num_subframes = scaling_factors.size() - 1;
  const int subframe_size = CheckedDivExact(
      SamplesPerChannel(per_sample_scaling_factors), num_subframes);

  // Handle first sub-frame differently in case of attack.
  const bool is_attack = scaling_factors[0] > scaling_factors[1];
  if (is_attack) {
    InterpolateFirstSubframe(
        scaling_factors[0], scaling_factors[1],
        per_sample_scaling_factors.subspan(0, subframe_size));
  }

  for (size_t i = is_attack ? 1 : 0; i < num_subframes; ++i) {
    const int subframe_start = i * subframe_size;
    const float scaling_start = scaling_factors[i];
    const float scaling_end = scaling_factors[i + 1];
    const float scaling_diff = (scaling_end - scaling_start) / subframe_size;
    for (int j = 0; j < subframe_size; ++j) {
      per_sample_scaling_factors[subframe_start + j] =
          scaling_start + scaling_diff * j;
    }
  }
}

void ScaleSamples(MonoView<const float> per_sample_scaling_factors,
                  DeinterleavedView<float> signal) {
  const int samples_per_channel = signal.samples_per_channel();
  RTC_DCHECK_EQ(samples_per_channel,
                SamplesPerChannel(per_sample_scaling_factors));
  for (size_t i = 0; i < signal.num_channels(); ++i) {
    MonoView<float> channel = signal[i];
    for (int j = 0; j < samples_per_channel; ++j) {
      channel[j] = SafeClamp(channel[j] * per_sample_scaling_factors[j],
                             kMinFloatS16Value, kMaxFloatS16Value);
    }
  }
}
}  // namespace

Limiter::Limiter(ApmDataDumper* apm_data_dumper,
                 size_t samples_per_channel,
                 absl::string_view histogram_name)
    : interp_gain_curve_(apm_data_dumper, histogram_name),
      level_estimator_(samples_per_channel, apm_data_dumper),
      apm_data_dumper_(apm_data_dumper) {
  RTC_DCHECK_LE(samples_per_channel, kMaximalNumberOfSamplesPerChannel);
}

Limiter::~Limiter() = default;

void Limiter::Process(DeinterleavedView<float> signal) {
  RTC_DCHECK_LE(signal.samples_per_channel(),
                kMaximalNumberOfSamplesPerChannel);

  const std::array<float, kSubFramesInFrame> level_estimate =
      level_estimator_.ComputeLevel(signal);

  RTC_DCHECK_EQ(level_estimate.size() + 1, scaling_factors_.size());
  scaling_factors_[0] = last_scaling_factor_;
  std::transform(level_estimate.begin(), level_estimate.end(),
                 scaling_factors_.begin() + 1, [this](float x) {
                   return interp_gain_curve_.LookUpGainToApply(x);
                 });

  MonoView<float> per_sample_scaling_factors(&per_sample_scaling_factors_[0],
                                             signal.samples_per_channel());
  ComputePerSampleSubframeFactors(scaling_factors_, per_sample_scaling_factors);
  ScaleSamples(per_sample_scaling_factors, signal);

  last_scaling_factor_ = scaling_factors_.back();

  // Dump data for debug.
  apm_data_dumper_->DumpRaw("agc2_limiter_last_scaling_factor",
                            last_scaling_factor_);
  apm_data_dumper_->DumpRaw(
      "agc2_limiter_region",
      static_cast<int>(interp_gain_curve_.get_stats().region));
}

InterpolatedGainCurve::Stats Limiter::GetGainCurveStats() const {
  return interp_gain_curve_.get_stats();
}

void Limiter::SetSamplesPerChannel(size_t samples_per_channel) {
  RTC_DCHECK_LE(samples_per_channel, kMaximalNumberOfSamplesPerChannel);
  level_estimator_.SetSamplesPerChannel(samples_per_channel);
}

void Limiter::Reset() {
  level_estimator_.Reset();
}

float Limiter::LastAudioLevel() const {
  return level_estimator_.LastAudioLevel();
}

}  // namespace webrtc
