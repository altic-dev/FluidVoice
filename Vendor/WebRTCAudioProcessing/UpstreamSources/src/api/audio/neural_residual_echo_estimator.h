/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef API_AUDIO_NEURAL_RESIDUAL_ECHO_ESTIMATOR_H_
#define API_AUDIO_NEURAL_RESIDUAL_ECHO_ESTIMATOR_H_

#include <array>
#include <span>

#include "api/audio/echo_canceller3_config.h"

namespace webrtc {
class Block;

// Interface for a neural residual echo estimator module injected into the echo
// canceller.
//
// This estimator estimates the echo residual that is not fully removed by the
// linear AEC3 estimator.
class NeuralResidualEchoEstimator {
 public:
  virtual ~NeuralResidualEchoEstimator() {}

  // Returns true if the estimator is initialized and ready to produce
  // real estimates. Processing function calls are still valid before
  // initialization, but they do nothing.
  virtual bool IsInitialized() = 0;

  // Estimates residual echo power spectrum in the signal after linear AEC
  // subtraction. Returns two estimates:
  //   * R2: A conservative estimate.
  //   * R2_unbounded: A less conservative estimate.
  //
  // Input signals:
  //   * render: Render block (time-domain)
  //   * y: Microphone signal (time-domain)
  //   * e: Output from linear subtraction stage (time-domain)
  //
  // Input power spectra:
  //   * S2: Linear echo estimate
  //   * Y2: Microphone input
  //   * E2: Output of linear stage
  //
  // Other inputs:
  //   * dominant_nearend: True if dominant nearend is active
  virtual void Estimate(const Block& render,
                        std::span<const std::array<float, 64>> y,
                        std::span<const std::array<float, 64>> e,
                        std::span<const std::array<float, 65>> S2,
                        std::span<const std::array<float, 65>> Y2,
                        std::span<const std::array<float, 65>> E2,
                        bool dominant_nearend,
                        std::span<std::array<float, 65>> R2,
                        std::span<std::array<float, 65>> R2_unbounded) = 0;

  // Adjusts the provided AEC3 suppressor configuration based on the estimator's
  // requirements.
  virtual EchoCanceller3Config::Suppressor AdjustConfig(
      const EchoCanceller3Config::Suppressor& config) const = 0;

  // Resets the internal state of the estimator.
  virtual void Reset() = 0;
};
}  // namespace webrtc

#endif  // API_AUDIO_NEURAL_RESIDUAL_ECHO_ESTIMATOR_H_
