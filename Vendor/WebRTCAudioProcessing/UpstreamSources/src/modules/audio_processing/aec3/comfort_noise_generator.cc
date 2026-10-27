/*
 *  Copyright (c) 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/aec3/comfort_noise_generator.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <numbers>
#include <numeric>
#include <span>
#include <vector>

#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/aec3_common.h"
#include "modules/audio_processing/aec3/fft_data.h"
#include "modules/audio_processing/aec3/vector_math.h"
#include "rtc_base/checks.h"

// Defines WEBRTC_ARCH_X86_FAMILY, used below.
#include "rtc_base/system/arch.h"
#if defined(WEBRTC_ARCH_X86_FAMILY)
#include <emmintrin.h>
#endif

namespace webrtc {

namespace {

using std::numbers::sqrt2_v;

// Computes the noise floor value that matches a WGN input of noise_floor_dbfs.
float GetNoiseFloorFactor(float noise_floor_dbfs) {
  // kdBfsNormalization = 20.f*log10(32768.f).
  constexpr float kdBfsNormalization = 90.30899869919436f;
  return 64.f * powf(10.f, (kdBfsNormalization + noise_floor_dbfs) * 0.1f);
}

// Table of sqrt(2) * sin(2*pi*i/32).
// clang-format off
constexpr std::array<float,32> kSqrt2Sin = {
    +0.0000000f, +0.2758994f, +0.5411961f, +0.7856950f, +1.0000000f,
    +1.1758756f, +1.3065630f, +1.3870398f, +sqrt2_v<float>, +1.3870398f,
    +1.3065630f, +1.1758756f, +1.0000000f, +0.7856950f, +0.5411961f,
    +0.2758994f, +0.0000000f, -0.2758994f, -0.5411961f, -0.7856950f,
    -1.0000000f, -1.1758756f, -1.3065630f, -1.3870398f, -sqrt2_v<float>,
    -1.3870398f, -1.3065630f, -1.1758756f, -1.0000000f, -0.7856950f,
    -0.5411961f, -0.2758994f};
// clang-format on

void GenerateRandomSinTableIndices(
    uint32_t& seed,
    std::span<int16_t, kFftLengthBy2 - 1> re_sin_table_indices,
    std::span<int16_t, kFftLengthBy2 - 1> im_sin_table_indices) {
  RTC_DCHECK_EQ(re_sin_table_indices.size(), im_sin_table_indices.size());

  constexpr int32_t kSeedMask = 0x80000000 - 1;
  constexpr int16_t kImIndexMask = 32 - 1;
  for (size_t k = 0; k < re_sin_table_indices.size(); ++k) {
    // Generate a random 31-bit integer.
    seed = (seed * 69069 + 1) & kSeedMask;

    // Convert to 5-bit indices.
    int16_t index = seed >> 26;
    RTC_DCHECK_LT(index, kSqrt2Sin.size());
    re_sin_table_indices[k] = index;

    index = (re_sin_table_indices[k] + 8) & kImIndexMask;
    RTC_DCHECK_LT(index, kSqrt2Sin.size());
    im_sin_table_indices[k] = index;
  }
}

void GenerateComfortNoise(
    Aec3Optimization optimization,
    const std::array<float, kFftLengthBy2Plus1>& N2,
    std::span<int16_t, kFftLengthBy2 - 1> re_sin_table_indices,
    std::span<int16_t, kFftLengthBy2 - 1> im_sin_table_indices,
    FftData* lower_band_noise,
    FftData* upper_band_noise) {
  FftData* N_low = lower_band_noise;
  FftData* N_high = upper_band_noise;

  // Compute square root spectrum.
  std::array<float, kFftLengthBy2Plus1> N;
  std::copy(N2.begin(), N2.end(), N.begin());
  VectorMath(optimization).Sqrt(N);

  // Compute the noise level for the upper bands.
  constexpr float kOneByNumBands = 1.f / (kFftLengthBy2Plus1 / 2 + 1);
  constexpr int kFftLengthBy2Plus1By2 = kFftLengthBy2Plus1 / 2;
  const float high_band_noise_level =
      std::accumulate(N.begin() + kFftLengthBy2Plus1By2, N.end(), 0.f) *
      kOneByNumBands;

  // The analysis and synthesis windowing cause loss of power when
  // cross-fading the noise where frames are completely uncorrelated
  // (generated with random phase), hence the factor sqrt(2).
  // This is not the case for the speech signal where the input is overlapping
  // (strong correlation).
  N_low->re[0] = N_low->re[kFftLengthBy2] = N_high->re[0] =
      N_high->re[kFftLengthBy2] = 0.f;
  for (size_t k = 1; k < kFftLengthBy2; k++) {
    // y = sqrt(2) * sin(a)
    const float& x = kSqrt2Sin[re_sin_table_indices[k - 1]];
    // x = sqrt(2) * cos(a) = sqrt(2) * sin(a + pi/2)
    const float& y = kSqrt2Sin[im_sin_table_indices[k - 1]];

    // Form low-frequency noise via spectral shaping.
    N_low->re[k] = N[k] * x;
    N_low->im[k] = N[k] * y;

    // Form the high-frequency noise via simple levelling.
    N_high->re[k] = high_band_noise_level * x;
    N_high->im[k] = high_band_noise_level * y;
  }
}

}  // namespace

ComfortNoiseGenerator::ComfortNoiseGenerator(const EchoCanceller3Config& config,
                                             Aec3Optimization optimization,
                                             size_t num_capture_channels)
    : optimization_(optimization),
      seed_(42),
      num_capture_channels_(num_capture_channels),
      noise_floor_(GetNoiseFloorFactor(config.comfort_noise.noise_floor_dbfs)),
      N2_initial_(
          std::make_unique<std::vector<std::array<float, kFftLengthBy2Plus1>>>(
              num_capture_channels_)),
      Y2_smoothed_(num_capture_channels_),
      N2_(num_capture_channels_) {
  for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
    (*N2_initial_)[ch].fill(0.f);
    Y2_smoothed_[ch].fill(0.f);
    N2_[ch].fill(1.0e6f);
  }
}

ComfortNoiseGenerator::~ComfortNoiseGenerator() = default;

void ComfortNoiseGenerator::Compute(
    bool saturated_capture,
    std::span<const std::array<float, kFftLengthBy2Plus1>> capture_spectrum,
    std::span<FftData> lower_band_noise,
    std::span<FftData> upper_band_noise) {
  const auto& Y2 = capture_spectrum;

  if (!saturated_capture) {
    // Smooth Y2.
    for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
      std::transform(Y2_smoothed_[ch].begin(), Y2_smoothed_[ch].end(),
                     Y2[ch].begin(), Y2_smoothed_[ch].begin(),
                     [](float a, float b) { return a + 0.1f * (b - a); });
    }

    if (N2_counter_ > 50) {
      // Update N2 from Y2_smoothed.
      for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
        std::transform(N2_[ch].begin(), N2_[ch].end(), Y2_smoothed_[ch].begin(),
                       N2_[ch].begin(), [](float a, float b) {
                         return b < a ? (0.9f * b + 0.1f * a) * 1.0002f
                                      : a * 1.0002f;
                       });
      }
    }

    if (N2_initial_) {
      if (++N2_counter_ == 1000) {
        N2_initial_.reset();
      } else {
        // Compute the N2_initial from N2.
        for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
          std::transform(N2_[ch].begin(), N2_[ch].end(),
                         (*N2_initial_)[ch].begin(), (*N2_initial_)[ch].begin(),
                         [](float a, float b) {
                           return a > b ? b + 0.001f * (a - b) : a;
                         });
        }
      }
    }

    for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
      for (auto& n : N2_[ch]) {
        n = std::max(n, noise_floor_);
      }
      if (N2_initial_) {
        for (auto& n : (*N2_initial_)[ch]) {
          n = std::max(n, noise_floor_);
        }
      }
    }
  }

  // Choose N2 estimate to use.
  const auto& N2 = N2_initial_ ? (*N2_initial_) : N2_;

  std::array<int16_t, kFftLengthBy2 - 1> re_sin_table_indices;
  std::array<int16_t, kFftLengthBy2 - 1> im_sin_table_indices;
  GenerateRandomSinTableIndices(seed_, re_sin_table_indices,
                                im_sin_table_indices);

  for (size_t ch = 0; ch < num_capture_channels_; ++ch) {
    GenerateComfortNoise(optimization_, N2[ch], re_sin_table_indices,
                         im_sin_table_indices, &lower_band_noise[ch],
                         &upper_band_noise[ch]);
  }
}

}  // namespace webrtc
