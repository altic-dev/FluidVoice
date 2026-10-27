/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_CHANNEL_CONTENT_REMIXER_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_CHANNEL_CONTENT_REMIXER_H_

#include <cstddef>
#include <span>

namespace webrtc {

// Specifies how to mix two stereo channels down to one or two channels.
enum class StereoMixingVariant {
  kUseBothChannels,  // Keep both channels as they are (stereo to stereo).
  kUseChannel0,      // Use only channel 0 for all output channels.
  kUseChannel1,      // Use only channel 1 for all output channels.
  kUseAverage  // Use the average of channel 0 and channel 1 for all output
               // channels.
};

// Remixes the content of two input channels into one or two output channels
// based on the selected StereoMixingVariant. Handles cross-fading to avoid
// abrupt changes when the mixing variant changes.
class ChannelContentRemixer {
 public:
  // Constructs a ChannelContentRemixer.
  // `num_samples_per_channel` is the number of samples in each channel frame
  // and `num_frames_for_crossfade` is the number of frames that a crossfade
  // should be performed pver
  ChannelContentRemixer(size_t num_samples_per_channel,
                        size_t num_frames_for_crossfade);

  ChannelContentRemixer(const ChannelContentRemixer&) = delete;
  ChannelContentRemixer& operator=(const ChannelContentRemixer&) = delete;

  // Mixes the input channels `channel0` and `channel1` in place based on the
  // `mixing_variant`.
  // `num_output_channels`: Currently supports 1 or 2. If 1, the output is mono
  //   and written to `channel0`.
  // `mixing_variant`: Specifies how to combine the input channels.
  // The results are written back to `channel0` and potentially `channel1` if
  // `num_output_channels` is 2. The return value specifies whether all
  // crossfades are completed.
  bool Mix(size_t num_output_channels,
           StereoMixingVariant mixing_variant,
           std::span<float> channel0,
           std::span<float> channel1);

 private:
  const size_t num_samples_per_channel_;
  const size_t num_samples_for_crossfade_;
  const float one_by_num_samples_for_crossfade_;
  StereoMixingVariant mixing_from_;
  StereoMixingVariant mixing_to_;
  size_t crossfade_sample_counter_ = 0;
  size_t num_output_channels_ = 0;

  // Returns whether the crossfade is completed, and resets any crossfade
  // counters.
  bool IsCrossfadeCompleted();

  // Copies content from source to destination.
  void CopyChannelContent(std::span<const float> source,
                          std::span<float> destination) const;

  // Calculates the average of channel0 and channel1 and writes it to both.
  void StoreChannelAverageIntoBothChannels(std::span<float> channel0,
                                           std::span<float> channel1) const;

  // Performs a linear cross-fade from `crossfade_from` to `crossfade_to` into
  // `destination`.
  void CrossFadeFromSingleChannelToSingleChannel(
      std::span<const float> crossfade_from,
      std::span<const float> crossfade_to,
      std::span<float> destination,
      size_t& crossfade_sample_counter) const;

  // Cross-fades from a single channel to the average of both channels.
  void CrossFadeFromSingleChannelContentToAverage(
      std::span<const float> crossfade_from,
      std::span<float> channel0,
      std::span<float> channel1,
      size_t& crossfade_sample_counter) const;

  // Cross-fades from the average of both channels to a single channel.
  void CrossFadeFromAverageToSingleChannelContent(
      std::span<const float> crossfade_to,
      std::span<float> channel0,
      std::span<float> channel1,
      size_t& crossfade_sample_counter) const;

  // Cross-fades from the average of both channels to using both channels
  // independently.
  void CrossFadeFromAverageToBothChannels(
      std::span<float> channel0,
      std::span<float> channel1,
      size_t& crossfade_sample_counter) const;

  // Cross-fades from using both channels independently to their average.
  void CrossFadeFromBothChannelsToAverage(
      std::span<float> channel0,
      std::span<float> channel1,
      size_t& crossfade_sample_counter) const;

  // specific helper for Mix when num_output_channels == 1.
  void CrossFadeFromAverageInToChannel0(std::span<const float> crossfade_to,
                                        std::span<float> channel0,
                                        std::span<float> channel1,
                                        size_t& crossfade_sample_counter) const;

  // specific helper for Mix when num_output_channels == 1.
  void CrossFadeChannel0ToAverage(std::span<const float> crossfade_from,
                                  std::span<float> channel0,
                                  std::span<const float> channel1,
                                  size_t& crossfade_sample_counter) const;

  // specific helper for Mix when num_output_channels == 1.
  void StoreChannelAverageIntoChannel0(std::span<float> channel0,
                                       std::span<const float> channel1) const;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_CHANNEL_CONTENT_REMIXER_H_
