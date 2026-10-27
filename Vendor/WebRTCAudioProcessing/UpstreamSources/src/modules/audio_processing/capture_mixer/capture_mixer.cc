/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/capture_mixer.h"

#include <cstddef>
#include <span>

#include "modules/audio_processing/capture_mixer/channel_content_remixer.h"
#include "rtc_base/checks.h"

namespace webrtc {
namespace {

constexpr size_t kNumFramesForCrossfade = 20;
}  // namespace

CaptureMixer::CaptureMixer(size_t num_samples_per_channel)
    : audio_content_analyzer_(num_samples_per_channel),
      channel_content_mixer_(num_samples_per_channel, kNumFramesForCrossfade),
      mixing_variant_(StereoMixingVariant::kUseAverage),
      remixing_logic_(num_samples_per_channel) {}

void CaptureMixer::Mix(size_t num_output_channels,
                       std::span<float> channel0,
                       std::span<float> channel1) {
  RTC_DCHECK_GE(num_output_channels, 1);
  RTC_DCHECK_LE(num_output_channels, 2);

  const bool reliable_estimates =
      audio_content_analyzer_.Analyze(channel0, channel1);

  if (!reliable_estimates) {
    // Downmix to mono (fake-stereo content with the same channel content) in an
    // average manner until reliable estimates have been achieved.
    mixing_variant_ = StereoMixingVariant::kUseAverage;
    channel_content_mixer_.Mix(num_output_channels, mixing_variant_, channel0,
                               channel1);
    return;
  }

  std::span<const float, 2> average_energies =
      audio_content_analyzer_.GetChannelEnergies();
  std::span<const int, 2> num_frames_since_activity =
      audio_content_analyzer_.GetNumFramesSinceActivity();
  std::span<const float, 2> saturation_factors =
      audio_content_analyzer_.GetSaturationFactors();

  mixing_variant_ = remixing_logic_.SelectStereoChannelMixing(
      average_energies, num_frames_since_activity, saturation_factors);

  channel_content_mixer_.Mix(num_output_channels, mixing_variant_, channel0,
                             channel1);
}

}  // namespace webrtc
