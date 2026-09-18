/*
 *  Copyright (c) 2016 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/utility/cascaded_biquad_filter.h"

#include <algorithm>
#include <cstddef>
#include <span>
#include <vector>

#include "rtc_base/checks.h"

namespace webrtc {

void CascadedBiQuadFilter::BiQuad::BiQuad::Reset() {
  x[0] = x[1] = y[0] = y[1] = 0.f;
}

CascadedBiQuadFilter::CascadedBiQuadFilter(
    std::span<const CascadedBiQuadFilter::BiQuadCoefficients> coefficients) {
  for (const auto& single_biquad_coefficients : coefficients) {
    biquads_.push_back(BiQuad(single_biquad_coefficients));
  }
}

CascadedBiQuadFilter::~CascadedBiQuadFilter() = default;

void CascadedBiQuadFilter::Process(std::span<const float> x,
                                   std::span<float> y) {
  if (!biquads_.empty()) {
    ApplyBiQuad(x, y, &biquads_[0]);
    for (size_t k = 1; k < biquads_.size(); ++k) {
      ApplyBiQuad(y, y, &biquads_[k]);
    }
  } else {
    std::copy(x.begin(), x.end(), y.begin());
  }
}

void CascadedBiQuadFilter::Process(std::span<float> y) {
  for (auto& biquad : biquads_) {
    ApplyBiQuad(y, y, &biquad);
  }
}

void CascadedBiQuadFilter::Reset() {
  for (auto& biquad : biquads_) {
    biquad.Reset();
  }
}

void CascadedBiQuadFilter::ApplyBiQuad(std::span<const float> x,
                                       std::span<float> y,
                                       CascadedBiQuadFilter::BiQuad* biquad) {
  RTC_DCHECK_EQ(x.size(), y.size());
  const float c_a_0 = biquad->coefficients.a[0];
  const float c_a_1 = biquad->coefficients.a[1];
  const float c_b_0 = biquad->coefficients.b[0];
  const float c_b_1 = biquad->coefficients.b[1];
  const float c_b_2 = biquad->coefficients.b[2];
  float m_x_0 = biquad->x[0];
  float m_x_1 = biquad->x[1];
  float m_y_0 = biquad->y[0];
  float m_y_1 = biquad->y[1];
  for (size_t k = 0; k < x.size(); ++k) {
    const float tmp = x[k];
    y[k] = c_b_0 * tmp + c_b_1 * m_x_0 + c_b_2 * m_x_1 - c_a_0 * m_y_0 -
           c_a_1 * m_y_1;
    m_x_1 = m_x_0;
    m_x_0 = tmp;
    m_y_1 = m_y_0;
    m_y_0 = y[k];
  }
  biquad->x[0] = m_x_0;
  biquad->x[1] = m_x_1;
  biquad->y[0] = m_y_0;
  biquad->y[1] = m_y_1;
}

}  // namespace webrtc
