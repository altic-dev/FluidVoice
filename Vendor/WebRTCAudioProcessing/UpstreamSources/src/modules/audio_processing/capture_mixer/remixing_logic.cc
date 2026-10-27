/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/remixing_logic.h"

#include <cstddef>
#include <optional>
#include <span>

#include "modules/audio_processing/capture_mixer/channel_content_remixer.h"
#include "rtc_base/checks.h"

namespace webrtc {
namespace {

constexpr int kInactivityThresholdFrames = 100;

bool ChoiceOfChannelMatchesSingleChannelMixing(int channel,
                                               StereoMixingVariant mixing) {
  if (channel == 0 && mixing == StereoMixingVariant::kUseChannel0) {
    return true;
  }
  if (channel == 1 && mixing == StereoMixingVariant::kUseChannel1) {
    return true;
  }
  return false;
}

bool EnoughContentForUpdatingMixing(
    std::span<const int, 2> num_frames_since_activity) {
  const bool channel0_inactive =
      num_frames_since_activity[0] > kInactivityThresholdFrames;
  const bool channel1_inactive =
      num_frames_since_activity[1] > kInactivityThresholdFrames;

  return !(channel0_inactive && channel1_inactive);
}

bool SingleSilentChannelDetected(
    size_t num_samples_per_channel,
    std::span<const float, 2> average_energies,
    std::span<const int, 2> num_frames_since_activity) {
  RTC_DCHECK(EnoughContentForUpdatingMixing(num_frames_since_activity));

  const bool channel0_inactive =
      num_frames_since_activity[0] > kInactivityThresholdFrames;
  const bool channel1_inactive =
      num_frames_since_activity[1] > kInactivityThresholdFrames;

  RTC_DCHECK(!(channel0_inactive && channel1_inactive));

  const float absolute_energy_threshold =
      100.0f * 100.0f * num_samples_per_channel;
  constexpr float kRelativeEnergyThreshold = 100.0f;

  if (channel0_inactive) {
    return average_energies[0] < absolute_energy_threshold &&
           average_energies[0] * kRelativeEnergyThreshold < average_energies[1];
  }

  if (channel1_inactive) {
    return average_energies[1] < absolute_energy_threshold &&
           average_energies[1] * kRelativeEnergyThreshold < average_energies[0];
  }
  return false;
}

std::optional<int> IdentifyLargelyImbalancedChannel(
    std::span<const float, 2> average_energies) {
  constexpr float kEnergyRatioThreshold = 50.0f;
  const float& energy0 = average_energies[0];
  const float& energy1 = average_energies[1];
  const bool large_energy_imbalance =
      energy0 > kEnergyRatioThreshold * energy1 ||
      energy1 > kEnergyRatioThreshold * energy0;

  if (large_energy_imbalance) {
    return energy0 > energy1 ? 0 : 1;
  }
  return std::nullopt;
}

std::optional<int> IdentifyModerateImbalancedAndSaturatedChannel(
    std::span<const float, 2> average_energies,
    std::span<const float, 2> saturation_factors) {
  constexpr float kEnergyRatioModerateThreshold = 4.0f;
  constexpr float kSignificantSaturationThreshold = 0.8f;
  constexpr float kNoSaturationThreshold = 0.1f;
  const float& energy0 = average_energies[0];
  const float& energy1 = average_energies[1];
  const float& saturation0 = saturation_factors[0];
  const float& saturation1 = saturation_factors[1];

  // Rely on that large energy imbalances have been handled before calling the
  // function.
  if (IdentifyLargelyImbalancedChannel(average_energies).has_value()) {
    return std::nullopt;
  }

  // Detect if any, and in that case which, channel would be preferable from a
  // saturation perspective.
  if (energy0 > kEnergyRatioModerateThreshold * energy1 &&
      saturation0 > kSignificantSaturationThreshold &&
      saturation1 < kNoSaturationThreshold) {
    return 1;
  }
  if (energy1 > kEnergyRatioModerateThreshold * energy0 &&
      saturation1 > kSignificantSaturationThreshold &&
      saturation0 < kNoSaturationThreshold) {
    return 0;
  }
  return std::nullopt;
}

}  // namespace

RemixingLogic::RemixingLogic(size_t num_samples_per_channel)
    : RemixingLogic(num_samples_per_channel, Settings()) {}
RemixingLogic::RemixingLogic(size_t num_samples_per_channel,
                             const Settings& settings)
    : settings_(settings), num_samples_per_channel_(num_samples_per_channel) {}

StereoMixingVariant RemixingLogic::SelectStereoChannelMixing(
    std::span<const float, 2> average_energies,
    std::span<const int, 2> num_frames_since_activity,
    std::span<const float, 2> saturation_factors) {
  // Only update the mixing when there is sufficient audio activity.
  if (!EnoughContentForUpdatingMixing(num_frames_since_activity)) {
    return mixing_;
  }

  // Handle mixing variants in an order of precedence.

  // Handle the case when audio is active in only one channel.
  if (settings_.silent_channel_handling) {
    if (HandleAnySilentChannels(average_energies, num_frames_since_activity)) {
      RTC_DCHECK_EQ(mode_, Mode::kSilentChannel);
      RTC_DCHECK_EQ(mixing_, StereoMixingVariant::kUseAverage);
      return mixing_;
    }
  }

  // Handle the case when the energy content in the channels is very imbalanced.
  if (settings_.largely_imbalanced_handling) {
    if (HandleAnyLargelyImbalancedChannels(average_energies)) {
      RTC_DCHECK_EQ(mode_, Mode::kImbalancedChannels);
      RTC_DCHECK(mixing_ == StereoMixingVariant::kUseChannel0 ||
                 mixing_ == StereoMixingVariant::kUseChannel1);
      return mixing_;
    }
  }

  // Handle the case when audio is more saturated in one of the channels than
  // the other, but the energy content in the channels is still fairly balanced.
  if (settings_.imbalanced_and_saturated_channel_handling) {
    if (HandleAnyImbalancedAndSaturatedChannels(average_energies,
                                                saturation_factors)) {
      RTC_DCHECK_EQ(mode_, Mode::kSaturatedChannel);
      RTC_DCHECK(mixing_ == StereoMixingVariant::kUseChannel0 ||
                 mixing_ == StereoMixingVariant::kUseChannel1);
      return mixing_;
    }
  }
  RTC_DCHECK_EQ(mode_, Mode::kIdle);
  mixing_ = StereoMixingVariant::kUseBothChannels;
  return mixing_;
}

bool RemixingLogic::HandleAnySilentChannels(
    std::span<const float, 2> average_energies,
    std::span<const int, 2> num_frames_since_activity) {
  RTC_DCHECK(mode_ != Mode::kSilentChannel ||
             mixing_ == StereoMixingVariant::kUseAverage);

  bool inactive_channel_detected = SingleSilentChannelDetected(
      num_samples_per_channel_, average_energies, num_frames_since_activity);

  // If the remixing is not in silent channel handling mode, and no inactive
  // channels have been detected there is no need to take any action.
  if (mode_ != Mode::kSilentChannel && !inactive_channel_detected) {
    return false;
  }

  // If inactive channels have been detected, reset frame counter and enter the
  // mode for silent channel handling. Set mixing to use the average of the
  // channels as a safe fallback.
  if (inactive_channel_detected) {
    num_frames_since_mode_triggered_ = 0;
    mode_ = Mode::kSilentChannel;
    mixing_ = StereoMixingVariant::kUseAverage;
    return true;
  }

  // Once no inactive channels are no longer detected, wait for a certain time
  // before exiting silent channel detection mode.
  constexpr int kNumFramesForModeExit = 10 * 100;
  if (++num_frames_since_mode_triggered_ > kNumFramesForModeExit) {
    mode_ = Mode::kIdle;
    num_frames_since_mode_triggered_ = 0;
    return false;
  }
  return true;
}

bool RemixingLogic::HandleAnyImbalancedAndSaturatedChannels(
    std::span<const float, 2> average_energies,
    std::span<const float, 2> saturation_factors) {
  RTC_DCHECK(mode_ != Mode::kSaturatedChannel ||
             (mixing_ == StereoMixingVariant::kUseChannel0 ||
              mixing_ == StereoMixingVariant::kUseChannel1));
  std::optional<int> single_channel_to_use =
      IdentifyModerateImbalancedAndSaturatedChannel(average_energies,
                                                    saturation_factors);

  // If the remixing is not in saturated channel handling mode, and no
  // preferable single channel was detected to be used, there is no further
  // action to take.
  if (mode_ != Mode::kSaturatedChannel && !single_channel_to_use.has_value()) {
    return false;
  }

  // If a single channel to used was identified and that matches the
  // single-channel selection which is currently in use, reset frame counter and
  // enter the mode for handling saturated channels. Set mixing to use the
  // appropriate channel.
  if (single_channel_to_use.has_value() &&
      (mode_ != Mode::kSaturatedChannel ||
       ChoiceOfChannelMatchesSingleChannelMixing(single_channel_to_use.value(),
                                                 mixing_))) {
    num_frames_since_mode_triggered_ = 0;
    StereoMixingVariant mixing = single_channel_to_use.value() == 0
                                     ? StereoMixingVariant::kUseChannel0
                                     : StereoMixingVariant::kUseChannel1;

    RTC_DCHECK(mode_ != Mode::kSaturatedChannel || mixing == mixing_);
    mode_ = Mode::kSaturatedChannel;
    mixing_ = mixing;
    return true;
  }

  // If a preferable channel is no longer detected, wait for a certain time
  // before exiting the mode for handling saturated channels.
  constexpr int kNumFramesForModeExit = 300;
  if (++num_frames_since_mode_triggered_ > kNumFramesForModeExit) {
    mode_ = Mode::kIdle;
    num_frames_since_mode_triggered_ = 0;
    mixing_ = StereoMixingVariant::kUseAverage;
    return false;
  }
  return true;
}

bool RemixingLogic::HandleAnyLargelyImbalancedChannels(
    std::span<const float, 2> average_energies) {
  RTC_DCHECK(mode_ != Mode::kImbalancedChannels ||
             (mixing_ == StereoMixingVariant::kUseChannel0 ||
              mixing_ == StereoMixingVariant::kUseChannel1));

  std::optional<int> single_channel_to_use =
      IdentifyLargelyImbalancedChannel(average_energies);

  // If the remixing is not in imbalanced channel handling mode, and no channels
  // with large imbalance have been detected there is no need to take any
  // action.
  if (mode_ != Mode::kImbalancedChannels &&
      !single_channel_to_use.has_value()) {
    return false;
  }

  // If the single channel to used was matches the single-channel selection
  // which is currently in use, reset frame counter and enter the mode for
  // handling imbalanced channels. Set mixing to use the appropriate channel.
  if (single_channel_to_use.has_value() &&
      (mode_ != Mode::kImbalancedChannels ||
       ChoiceOfChannelMatchesSingleChannelMixing(single_channel_to_use.value(),
                                                 mixing_))) {
    num_frames_since_mode_triggered_ = 0;
    mode_ = Mode::kImbalancedChannels;
    mixing_ = single_channel_to_use.value() == 0
                  ? StereoMixingVariant::kUseChannel0
                  : StereoMixingVariant::kUseChannel1;
    return true;
  }

  // If a channel imbalance is no longer detected, wait for a certain time
  // before exiting the mode for handling saturated channels.
  constexpr int kNumFramesForModeExit = 300;
  if (++num_frames_since_mode_triggered_ > kNumFramesForModeExit) {
    mode_ = Mode::kIdle;
    num_frames_since_mode_triggered_ = 0;
    mixing_ = StereoMixingVariant::kUseAverage;
    return false;
  }
  return true;
}

}  // namespace webrtc
