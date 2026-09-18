/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/post_filter.h"

#include <array>
#include <cstddef>
#include <memory>
#include <span>
#include <vector>

#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/utility/cascaded_biquad_filter.h"
#include "rtc_base/checks.h"

namespace webrtc {

namespace {

// Removes frequencies above 19.5kHz.
// sos = signal.iirdesign(
//    19200 * 2 / 48000, 19500 * 2 / 48000,
//    3, 20, ftype='cheby2', output="sos")
constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 4>
    kPostFilterCoefficients48kHz = {{
        {.b = {0.56142156f, 1.11499931f, 0.56142156f},
         .a = {1.57914249f, 0.63379496f}},
        {.b = {1.00000000f, 1.88944170f, 1.00000000f},
         .a = {1.55130066f, 0.68708719f}},
        {.b = {1.00000000f, 1.76057310f, 1.00000000f},
         .a = {1.53001328f, 0.78591224f}},
        {.b = {1.00000000f, 1.67448535f, 1.00000000f},
         .a = {1.56506670f, 0.92096576f}},
    }};
}  // namespace

std::unique_ptr<PostFilter> PostFilter::CreateIfNeeded(int sample_rate_hz,
                                                       size_t num_channels) {
  if (sample_rate_hz != 48000) {
    return nullptr;
  }

  return std::unique_ptr<PostFilter>(
      new PostFilter(kPostFilterCoefficients48kHz, num_channels));
}

PostFilter::PostFilter(
    std::span<const CascadedBiQuadFilter::BiQuadCoefficients> coefficients,
    size_t num_channels) {
  RTC_DCHECK(!coefficients.empty());

  filters_.resize(num_channels);
  for (size_t k = 0; k < filters_.size(); ++k) {
    filters_[k].reset(new CascadedBiQuadFilter(coefficients));
  }
}

void PostFilter::Process(AudioBuffer& audio) {
  RTC_DCHECK_EQ(filters_.size(), audio.num_channels());
  for (size_t k = 0; k < audio.num_channels(); ++k) {
    std::span<float> channel_data =
        std::span<float>(&audio.channels()[k][0], audio.num_frames());
    filters_[k]->Process(channel_data);
  }
}
}  // namespace webrtc
