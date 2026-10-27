/*
 *  Copyright (c) 2019 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_AUDIO_PROCESSING_NS_NS_FFT_H_
#define MODULES_AUDIO_PROCESSING_NS_NS_FFT_H_

#include <cstddef>
#include <span>
#include <vector>

#include "modules/audio_processing/ns/ns_common.h"

namespace webrtc {

// Wrapper class providing 256 point FFT functionality.
class NrFft {
 public:
  NrFft();
  NrFft(const NrFft&) = delete;
  NrFft& operator=(const NrFft&) = delete;

  // Transforms the signal from time to frequency domain.
  void Fft(std::span<float, kFftSize> time_data,
           std::span<float, kFftSize> real,
           std::span<float, kFftSize> imag);

  // Transforms the signal from frequency to time domain.
  void Ifft(std::span<const float> real,
            std::span<const float> imag,
            std::span<float> time_data);

 private:
  std::vector<size_t> bit_reversal_state_;
  std::vector<float> tables_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_NS_NS_FFT_H_
