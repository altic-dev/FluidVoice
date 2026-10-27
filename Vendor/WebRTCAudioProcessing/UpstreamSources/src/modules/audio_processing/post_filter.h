/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_POST_FILTER_H_
#define MODULES_AUDIO_PROCESSING_POST_FILTER_H_

#include <cstddef>
#include <memory>
#include <span>
#include <vector>

#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/utility/cascaded_biquad_filter.h"

namespace webrtc {

// Provides functionality for general enhancement and compensation of
// artefacts/shortcomings introduced by prior processing. The processing is
// applied to the fullband signal.
class PostFilter {
 public:
  // Creates a Post Processing Filter.
  // Returns nullptr if sample_rate is low enough that no filter are required.
  static std::unique_ptr<PostFilter> CreateIfNeeded(int sample_rate_hz,
                                                    size_t num_channels);

  ~PostFilter() = default;
  PostFilter(const PostFilter&) = delete;
  PostFilter& operator=(const PostFilter&) = delete;

  void Process(AudioBuffer& audio);

 private:
  PostFilter(
      std::span<const CascadedBiQuadFilter::BiQuadCoefficients> coefficients,
      size_t num_channels);

  std::vector<std::unique_ptr<CascadedBiQuadFilter>> filters_;
};
}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_POST_FILTER_H_
