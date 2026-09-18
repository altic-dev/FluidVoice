/*
 *  Copyright (c) 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/aec3/decimator.h"

#include <array>
#include <cstddef>
#include <span>

#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/utility/cascaded_biquad_filter.h"
#include "rtc_base/checks.h"

namespace webrtc {
namespace {
// signal.ellip(6, 1, 40, 1800/8000, 'lowpass', output='sos')
constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 3>
    kLowPassFilterDs4 = {{
        {.b = {0.0180919877f, 0.00320961363f, 0.0180919877f},
         .a = {-1.5183195f, 0.633165865f}},
        {.b = {1.0f, -1.24550459f, 1.0f}, .a = {-1.49784254f, 0.853586692f}},
        {.b = {1.0f, -1.4221681f, 1.0f}, .a = {-1.49791282f, 0.969572384f}},
    }};

// signal.cheby1(1, 6, [1000/8000, 2000/8000], 'bandpass', output='sos')
// repeated 5 times.
constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 5>
    kBandPassFilterDs8 = {{
        {.b = {0.103304783f, 0.0f, -0.103304783f},
         .a = {-1.520363f, 0.793390435f}},
        {.b = {0.103304783f, 0.0f, -0.103304783f},
         .a = {-1.520363f, 0.793390435f}},
        {.b = {0.103304783f, 0.0f, -0.103304783f},
         .a = {-1.520363f, 0.793390435f}},
        {.b = {0.103304783f, 0.0f, -0.103304783f},
         .a = {-1.520363f, 0.793390435f}},
        {.b = {0.103304783f, 0.0f, -0.103304783f},
         .a = {-1.520363f, 0.793390435f}},
    }};

// signal.butter(2, 1000/8000.0, 'highpass', output='sos')
constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 1>
    kHighPassFilter = {{
        {.b = {0.757076375f, -1.51415275f, 0.757076375f},
         .a = {-1.45424359f, 0.574061915f}},
    }};

constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 0>
    kPassThroughFilter = {{}};
}  // namespace

Decimator::Decimator(size_t down_sampling_factor)
    : down_sampling_factor_(down_sampling_factor),
      anti_aliasing_filter_(
          down_sampling_factor_ == 4
              ? std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
                    kLowPassFilterDs4)
              : std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
                    kBandPassFilterDs8)),
      noise_reduction_filter_(
          down_sampling_factor_ == 8
              ? (std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
                    kPassThroughFilter))
              : (std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
                    kHighPassFilter))) {
  RTC_DCHECK(down_sampling_factor_ == 4 || down_sampling_factor_ == 8);
}

void Decimator::Decimate(std::span<const float> in, std::span<float> out) {
  RTC_DCHECK_EQ(kBlockSize, in.size());
  RTC_DCHECK_EQ(kBlockSize / down_sampling_factor_, out.size());
  std::array<float, kBlockSize> x;

  // Limit the frequency content of the signal to avoid aliasing.
  anti_aliasing_filter_.Process(in, x);

  // Reduce the impact of near-end noise.
  noise_reduction_filter_.Process(x);

  // Downsample the signal.
  for (size_t j = 0, k = 0; j < out.size(); ++j, k += down_sampling_factor_) {
    RTC_DCHECK_GT(kBlockSize, k);
    out[j] = x[k];
  }
}

}  // namespace webrtc
