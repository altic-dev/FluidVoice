/*
 *  Copyright (c) 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_AEC3_MOVING_AVERAGE_SPECTRUM_H_
#define MODULES_AUDIO_PROCESSING_AEC3_MOVING_AVERAGE_SPECTRUM_H_

#include <stddef.h>

#include <span>
#include <vector>

namespace webrtc {

class MovingAverageSpectrum {
 public:
  // Creates an instance of MovingAverageSpectrum that accepts inputs of length
  // num_elem and averages over mem_len inputs.
  MovingAverageSpectrum(size_t num_elem, size_t mem_len);
  ~MovingAverageSpectrum();

  // Computes the average of the current input and up to mem_len-1 previous
  // inputs and stores the result in output.
  void Average(std::span<const float> input, std::span<float> output);

  // If a new memory length is provided, resets the state and clears the
  // average memory to use the new window size.
  void UpdateMemoryLength(size_t mem_len);

 private:
  const size_t num_elem_;
  size_t mem_len_;
  std::vector<float> memory_;
  size_t mem_index_;
  int number_updates_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AEC3_MOVING_AVERAGE_SPECTRUM_H_
