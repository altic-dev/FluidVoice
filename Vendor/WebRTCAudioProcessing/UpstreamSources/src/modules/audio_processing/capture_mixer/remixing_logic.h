/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_REMIXING_LOGIC_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_REMIXING_LOGIC_H_

#include <stddef.h>

#include <span>

#include "modules/audio_processing/capture_mixer/channel_content_remixer.h"

namespace webrtc {

// Determines the best way to mix or select stereo channels based on their
// activity, energy levels, and saturation. This class is stateful and designed
// to be called for each audio frame.
class RemixingLogic {
 public:
  struct Settings {
    Settings() {}
    Settings(bool silent_channel_handling,
             bool imbalanced_and_saturated_channel_handling,
             bool largely_imbalanced_handling)
        : silent_channel_handling(silent_channel_handling),
          imbalanced_and_saturated_channel_handling(
              imbalanced_and_saturated_channel_handling),
          largely_imbalanced_handling(largely_imbalanced_handling) {}

    bool silent_channel_handling = true;
    bool imbalanced_and_saturated_channel_handling = false;
    bool largely_imbalanced_handling = true;
  };

  explicit RemixingLogic(size_t num_samples_per_channel);
  RemixingLogic(size_t num_samples_per_channel, const Settings& settings);
  RemixingLogic(const RemixingLogic&) = delete;
  RemixingLogic& operator=(const RemixingLogic&) = delete;

  // Selects the stereo mixing variant based on the provided channel a
  // tributes. `average_energies`: Average energy for each channel.
  // `num_frames_since_activity`: Number of frames since a channel was last
  // active. `saturation_factors`: Saturation measure for each channel. Returns
  // the chosen StereoMixingVariant.
  StereoMixingVariant SelectStereoChannelMixing(
      std::span<const float, 2> average_energies,
      std::span<const int, 2> num_frames_since_activity,
      std::span<const float, 2> saturation_factors);

 private:
  // Checks if any channel is silent and updates the mode and mixing variant
  // accordingly. Returns true if a mode change occurred.
  bool HandleAnySilentChannels(
      std::span<const float, 2> average_energies,
      std::span<const int, 2> num_frames_since_activity);

  // Checks for channels that are moderately imbalanced and have differing
  // saturation levels, updating mode and mixing variant to favor the less
  // saturated channel. Returns true if a mode change occurred.
  bool HandleAnyImbalancedAndSaturatedChannels(
      std::span<const float, 2> average_energies,
      std::span<const float, 2> saturation_factors);

  // Checks for channels with a large energy imbalance and updates mode and
  // mixing variant to favor the louder channel. Returns true if a mode change
  // occurred.
  bool HandleAnyLargelyImbalancedChannels(
      std::span<const float, 2> average_energies);

  // Represents the current state of the remixing logic.
  enum class Mode {
    kIdle,               // Channels are relatively balanced and active.
    kSilentChannel,      // One channel is silent.
    kSaturatedChannel,   // Channels are imbalanced and one is more saturated.
    kImbalancedChannels  // Channels have a large energy imbalance.
  };
  const Settings settings_;
  Mode mode_ = Mode::kIdle;  // Current operational mode.
  StereoMixingVariant mixing_ =
      StereoMixingVariant::kUseAverage;  // Current mixing variant.
  int num_frames_since_mode_triggered_ =
      0;  // Counter for hysteresis, to avoid rapid mode switching.
  size_t num_samples_per_channel_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_REMIXING_LOGIC_H_
