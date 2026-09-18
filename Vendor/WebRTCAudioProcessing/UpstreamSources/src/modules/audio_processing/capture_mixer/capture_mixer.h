/*
 *  Copyright (c) 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */
#ifndef MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_CAPTURE_MIXER_H_
#define MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_CAPTURE_MIXER_H_

#include <stddef.h>

#include <span>

#include "modules/audio_processing/capture_mixer/audio_content_analyzer.h"
#include "modules/audio_processing/capture_mixer/channel_content_remixer.h"
#include "modules/audio_processing/capture_mixer/remixing_logic.h"

namespace webrtc {

class CaptureMixer {
 public:
  explicit CaptureMixer(size_t num_samples_per_channel);
  CaptureMixer(const CaptureMixer&) = delete;
  CaptureMixer& operator=(const CaptureMixer&) = delete;

  void Mix(size_t num_output_channels,
           std::span<float> channel0,
           std::span<float> channel1);

 private:
  AudioContentAnalyzer audio_content_analyzer_;
  ChannelContentRemixer channel_content_mixer_;
  StereoMixingVariant mixing_variant_;
  RemixingLogic remixing_logic_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_CAPTURE_MIXER_CAPTURE_MIXER_H_
