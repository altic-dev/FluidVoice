/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#include "modules/audio_processing/capture_mixer/channel_content_remixer.h"

#include <algorithm>
#include <cstddef>
#include <span>

#include "rtc_base/checks.h"

namespace webrtc {

ChannelContentRemixer::ChannelContentRemixer(size_t num_samples_per_channel,
                                             size_t num_frames_for_crossfade)
    : num_samples_per_channel_(num_samples_per_channel),
      num_samples_for_crossfade_(num_samples_per_channel *
                                 num_frames_for_crossfade),
      one_by_num_samples_for_crossfade_(1.0f / num_samples_for_crossfade_),
      mixing_from_(StereoMixingVariant::kUseAverage),
      mixing_to_(StereoMixingVariant::kUseAverage) {}

bool ChannelContentRemixer::Mix(size_t num_output_channels,
                                StereoMixingVariant mixing_variant,
                                std::span<float> channel0,
                                std::span<float> channel1) {
  RTC_DCHECK_EQ(channel0.size(), num_samples_per_channel_);
  RTC_DCHECK_EQ(channel1.size(), num_samples_per_channel_);

  // Only allow a new target mixing, and a new target number of output channels,
  // if the previous crossfade was completed.
  if (IsCrossfadeCompleted()) {
    mixing_from_ = mixing_to_;
    mixing_to_ = mixing_variant;
    num_output_channels_ = num_output_channels;
  }

  switch (mixing_to_) {
    case StereoMixingVariant::kUseBothChannels: {
      switch (mixing_from_) {
        case StereoMixingVariant::kUseBothChannels: {
          // Mixing from: kUseBothChannels.
          // Mixing to: kUseBothChannels.

          // No remixing needed.
          break;
        }
        case StereoMixingVariant::kUseChannel0: {
          // Mixing from: kUseChannel0.
          // Mixing to: kUseBothChannels.

          if (num_output_channels_ == 2) {
            // Crossfade channel 1 from using content in channel 0 to using
            // content in channel 1.
            CrossFadeFromSingleChannelToSingleChannel(
                /*crossfade_from=*/channel0,
                /*crossfade_to=*/channel1,
                /*destination=*/channel1, crossfade_sample_counter_);
          }
          break;
        }
        case StereoMixingVariant::kUseChannel1: {
          // Mixing from: kUseChannel1.
          // Mixing to: kUseBothChannels.

          // Crossfade channel 0 from using content in channel 1 to using
          // content in channel 0.
          CrossFadeFromSingleChannelToSingleChannel(
              /*crossfade_from=*/channel1,
              /*crossfade_to=*/channel0,
              /*destination=*/channel0, crossfade_sample_counter_);

          break;
        }
        case StereoMixingVariant::kUseAverage: {
          // Mixing from: kUseAverage.
          // Mixing to: kUseBothChannels.

          if (num_output_channels_ == 1) {
            // Crossfade channel0 from using the channel average to using
            // its original content.
            CrossFadeFromAverageInToChannel0(/*crossfade_to=*/channel0,
                                             channel0, channel1,
                                             crossfade_sample_counter_);
          } else {
            // Crossfade both channels from using the channel average to using
            // their original content.
            CrossFadeFromAverageToBothChannels(channel0, channel1,
                                               crossfade_sample_counter_);
          }
          break;
        }
      }
      break;
    }
    case StereoMixingVariant::kUseChannel0: {
      switch (mixing_from_) {
        case StereoMixingVariant::kUseBothChannels: {
          // Mixing from: kUseBothChannels.
          // Mixing to: kUseChannel0.

          if (num_output_channels_ == 2) {
            // Crossfade channel 1 from using content in channel 1 to using
            // content in channel 0.
            CrossFadeFromSingleChannelToSingleChannel(
                /*crossfade_from=*/channel1,
                /*crossfade_to=*/channel0,
                /*destination=*/channel1, crossfade_sample_counter_);
          }
          break;
        }
        case StereoMixingVariant::kUseChannel0: {
          // Mixing from: kUseChannel0.
          // Mixing to: kUseChannel0.

          if (num_output_channels_ == 2) {
            // Copy content of channel 0 into channel 1, no cross-fading needed.
            CopyChannelContent(/*source=*/channel0, /*destination=*/channel1);
          }
          break;
        }
        case StereoMixingVariant::kUseChannel1: {
          // Mixing from: kUseChannel1.
          // Mixing to: kUseChannel0.

          // Crossfade channel 0 from using content in channel 1 to using
          // content in channel 0.
          CrossFadeFromSingleChannelToSingleChannel(
              /*crossfade_from=*/channel1,
              /*crossfade_to=*/channel0,
              /*destination=*/channel0, crossfade_sample_counter_);
          if (num_output_channels_ == 2) {
            // Crossfade channel 1 from using content in channel 1 to using
            // content in channel 0.
            CopyChannelContent(/*source=*/channel0,
                               /*destination=*/channel1);
          }
          break;
        }
        case StereoMixingVariant::kUseAverage: {
          // Mixing from: kUseAverage.
          // Mixing to: kUseChannel0.

          if (num_output_channels_ == 1) {
            // Crossfade both channels from using the channel average to using
            // the content in channel 0.
            CrossFadeFromAverageInToChannel0(/*crossfade_to=*/channel0,
                                             channel0, channel1,
                                             crossfade_sample_counter_);
          } else {
            // Crossfade both channels from using the channel average to using
            // the content in channel 0.
            CrossFadeFromAverageToSingleChannelContent(
                /*crossfade_to=*/channel0, channel0, channel1,
                crossfade_sample_counter_);
          }
          break;
        }
      }
      break;
    }
    case StereoMixingVariant::kUseChannel1: {
      switch (mixing_from_) {
        case StereoMixingVariant::kUseBothChannels: {
          // Mixing from: kUseBothChannels.
          // Mixing to: kUseChannel1.

          // Crossfade channel 0 from using content in channel 1 to using
          // content in channel 1.
          CrossFadeFromSingleChannelToSingleChannel(
              /*crossfade_from=*/channel0,
              /*crossfade_to=*/channel1,
              /*destination=*/channel0, crossfade_sample_counter_);
          break;
        }
        case StereoMixingVariant::kUseChannel0: {
          // Mixing from: kUseChannel0.
          // Mixing to: kUseChannel1.

          // Crossfade channel 0 from using content in channel 0 to using
          // content in channel 1.
          CrossFadeFromSingleChannelToSingleChannel(
              /*crossfade_from=*/channel0,
              /*crossfade_to=*/channel1,
              /*destination=*/channel0, crossfade_sample_counter_);
          if (num_output_channels_ == 2) {
            // Crossfade channel 1 from using content in channel 0 to using
            // content in channel 1.
            CopyChannelContent(/*source=*/channel0,
                               /*destination=*/channel1);
          }
          break;
        }
        case StereoMixingVariant::kUseChannel1: {
          // Mixing from: kUseChannel1.
          // Mixing to: kUseChannel1.

          // Copy content of channel 1 into channel 0, no cross-fading needed.
          CopyChannelContent(/*source=*/channel1,
                             /*destination=*/channel0);
          break;
        }
        case StereoMixingVariant::kUseAverage: {
          // Mixing from: kUseAverage.
          // Mixing to: kUseChannel1.

          if (num_output_channels_ == 1) {
            // Crossfade channel 0 from using the channel average to using the
            // content in channel 1.
            CrossFadeFromAverageInToChannel0(/*crossfade_to=*/channel1,
                                             channel0, channel1,
                                             crossfade_sample_counter_);
          } else {
            // Crossfade both channels from using the channel average to using
            // the content in channel 1.
            CrossFadeFromAverageToSingleChannelContent(
                /*crossfade_to=*/channel1, channel0, channel1,
                crossfade_sample_counter_);
          }
          break;
        }
      }
      break;
    }
    case StereoMixingVariant::kUseAverage: {
      switch (mixing_from_) {
        case StereoMixingVariant::kUseBothChannels: {
          // Mixing from: kUseBothChannels.
          // Mixing to: kUseAverage.
          if (num_output_channels_ == 1) {
            // Crossfade channel 0 to using the channel average.
            CrossFadeChannel0ToAverage(/*crossfade_from=*/channel0, channel0,
                                       channel1, crossfade_sample_counter_);
          } else {
            // Crossfade both channels to using the channel average.
            CrossFadeFromBothChannelsToAverage(channel0, channel1,
                                               crossfade_sample_counter_);
          }
          break;
        }
        case StereoMixingVariant::kUseChannel0: {
          // Mixing from: kUseChannel0.
          // Mixing to: kUseAverage.
          if (num_output_channels_ == 1) {
            // Crossfade channel 0 to using the channel average.
            CrossFadeChannel0ToAverage(/*crossfade_from=*/channel0, channel0,
                                       channel1, crossfade_sample_counter_);
          } else {
            // Crossfade both channels to using the content from channel 0 to
            // using the channel average.
            CrossFadeFromSingleChannelContentToAverage(
                /*crossfade_from=*/channel0, channel0, channel1,
                crossfade_sample_counter_);
          }
          break;
        }
        case StereoMixingVariant::kUseChannel1: {
          // Mixing from: kUseChannel1.
          // Mixing to: kUseAverage.
          if (num_output_channels_ == 1) {
            // Crossfade channel 0 to using the channel average.
            CrossFadeChannel0ToAverage(/*crossfade_from=*/channel1, channel0,
                                       channel1, crossfade_sample_counter_);
          } else {
            // Crossfade both channels to using the content from channel 1 to
            // using the channel average.
            CrossFadeFromSingleChannelContentToAverage(
                /*crossfade_from=*/channel1, channel0, channel1,
                crossfade_sample_counter_);
          }
          break;
        }
        case StereoMixingVariant::kUseAverage: {
          // Mixing from: kUseAverage.
          // Mixing to: kUseAverage.
          if (num_output_channels_ == 1) {
            // Simply store the average into channel 0, no crossfade needed.
            StoreChannelAverageIntoChannel0(channel0, channel1);
          } else {
            // Simply store the average into both channels, no crossfade needed.
            StoreChannelAverageIntoBothChannels(channel0, channel1);
          }
          break;
        }
      }
      break;
    }
  }

  return IsCrossfadeCompleted();
}

bool ChannelContentRemixer::IsCrossfadeCompleted() {
  if (crossfade_sample_counter_ == num_samples_for_crossfade_) {
    crossfade_sample_counter_ = 0;
  }
  return crossfade_sample_counter_ == 0;
}

void ChannelContentRemixer::CopyChannelContent(
    std::span<const float> source,
    std::span<float> destination) const {
  std::copy(source.begin(), source.end(), destination.begin());
}

void ChannelContentRemixer::StoreChannelAverageIntoBothChannels(
    std::span<float> channel0,
    std::span<float> channel1) const {
  for (size_t k = 0; k < channel0.size(); ++k) {
    float average = (channel0[k] + channel1[k]) * 0.5f;
    channel0[k] = average;
    channel1[k] = average;
  }
}

void ChannelContentRemixer::CrossFadeFromSingleChannelToSingleChannel(
    std::span<const float> crossfade_from,
    std::span<const float> crossfade_to,
    std::span<float> destination,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < destination.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;
    destination[k] =
        (1.0f - scaling) * crossfade_from[k] + scaling * crossfade_to[k];
  }
}

void ChannelContentRemixer::CrossFadeFromSingleChannelContentToAverage(
    std::span<const float> crossfade_from,
    std::span<float> channel0,
    std::span<float> channel1,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < channel0.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;

    float average = (channel0[k] + channel1[k]) * 0.5f;
    float sample = (1.0f - scaling) * crossfade_from[k] + scaling * average;

    channel0[k] = sample;
    channel1[k] = sample;
  }
}

void ChannelContentRemixer::CrossFadeFromAverageToSingleChannelContent(
    std::span<const float> crossfade_to,
    std::span<float> channel0,
    std::span<float> channel1,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < channel0.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;

    float average = (channel0[k] + channel1[k]) * 0.5f;
    float sample = (1.0f - scaling) * average + scaling * crossfade_to[k];
    channel0[k] = sample;
    channel1[k] = sample;
  }
}

void ChannelContentRemixer::CrossFadeFromAverageToBothChannels(
    std::span<float> channel0,
    std::span<float> channel1,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < channel0.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;

    float scaled_average =
        (1.0f - scaling) * (channel0[k] + channel1[k]) * 0.5f;
    channel0[k] = scaled_average + scaling * channel0[k];
    channel1[k] = scaled_average + scaling * channel1[k];
  }
}

void ChannelContentRemixer::CrossFadeFromBothChannelsToAverage(
    std::span<float> channel0,
    std::span<float> channel1,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < channel0.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;

    float scaled_average = scaling * (channel0[k] + channel1[k]) * 0.5f;
    channel0[k] = (1.0f - scaling) * channel0[k] + scaled_average;
    channel1[k] = (1.0f - scaling) * channel1[k] + scaled_average;
  }
}

void ChannelContentRemixer::CrossFadeFromAverageInToChannel0(
    std::span<const float> crossfade_to,
    std::span<float> channel0,
    std::span<float> channel1,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < channel0.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;

    float average = (channel0[k] + channel1[k]) * 0.5f;
    channel0[k] = (1.0f - scaling) * average + scaling * crossfade_to[k];
  }
}

void ChannelContentRemixer::CrossFadeChannel0ToAverage(
    std::span<const float> crossfade_from,
    std::span<float> channel0,
    std::span<const float> channel1,
    size_t& crossfade_sample_counter) const {
  for (size_t k = 0; k < channel0.size(); ++k, ++crossfade_sample_counter) {
    const float scaling =
        crossfade_sample_counter * one_by_num_samples_for_crossfade_;

    float average = (channel0[k] + channel1[k]) * 0.5f;
    channel0[k] = (1.0f - scaling) * crossfade_from[k] + scaling * average;
  }
}

void ChannelContentRemixer::StoreChannelAverageIntoChannel0(
    std::span<float> channel0,
    std::span<const float> channel1) const {
  for (size_t k = 0; k < channel0.size(); ++k) {
    float average = (channel0[k] + channel1[k]) * 0.5f;
    channel0[k] = average;
  }
}

}  // namespace webrtc
