/*
 *  Copyright (c) 2016 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_UTILITY_CASCADED_BIQUAD_FILTER_H_
#define MODULES_AUDIO_PROCESSING_UTILITY_CASCADED_BIQUAD_FILTER_H_

#include <stddef.h>

#include <span>
#include <vector>

namespace webrtc {

// Applies a number of biquads in a cascaded manner. The filter implementation
// is direct form 1.
class CascadedBiQuadFilter {
 public:
  struct BiQuadCoefficients {
    float b[3];
    float a[2];
  };

  struct BiQuad {
    explicit BiQuad(const BiQuadCoefficients& coefficients)
        : coefficients(coefficients), x(), y() {}
    void Reset();
    BiQuadCoefficients coefficients;
    float x[2];
    float y[2];
  };

  CascadedBiQuadFilter(
      std::span<const CascadedBiQuadFilter::BiQuadCoefficients> coefficients);
  ~CascadedBiQuadFilter();
  CascadedBiQuadFilter(const CascadedBiQuadFilter&) = delete;
  CascadedBiQuadFilter& operator=(const CascadedBiQuadFilter&) = delete;

  // Applies the biquads on the values in x in order to form the output in y.
  void Process(std::span<const float> x, std::span<float> y);
  // Applies the biquads on the values in y in an in-place manner.
  void Process(std::span<float> y);
  // Resets the filter to its initial state.
  void Reset();

 private:
  void ApplyBiQuad(std::span<const float> x,
                   std::span<float> y,
                   CascadedBiQuadFilter::BiQuad* biquad);

  std::vector<BiQuad> biquads_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_UTILITY_CASCADED_BIQUAD_FILTER_H_
