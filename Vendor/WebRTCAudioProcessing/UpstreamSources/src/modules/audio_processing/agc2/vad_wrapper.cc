/*
 *  Copyright (c) 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/agc2/vad_wrapper.h"

#include <array>
#include <memory>
#include <utility>

#include "api/audio/audio_view.h"
#include "common_audio/resampler/include/push_resampler.h"
#include "modules/audio_processing/agc2/agc2_common.h"
#include "modules/audio_processing/agc2/cpu_features.h"
#include "modules/audio_processing/agc2/rnn_vad/common.h"
#include "modules/audio_processing/agc2/rnn_vad/features_extraction.h"
#include "modules/audio_processing/agc2/rnn_vad/rnn.h"
#include "rtc_base/checks.h"

namespace webrtc {
namespace {

constexpr int kNumFramesPerSecond = 100;

class MonoVadImpl : public VoiceActivityDetectorWrapper::MonoVad {
 public:
  explicit MonoVadImpl(const AvailableCpuFeatures& cpu_features)
      : features_extractor_(cpu_features), rnn_vad_(cpu_features) {}
  MonoVadImpl(const MonoVadImpl&) = delete;
  MonoVadImpl& operator=(const MonoVadImpl&) = delete;
  ~MonoVadImpl() override = default;

  int SampleRateHz() const override { return rnn_vad::kSampleRate24kHz; }
  void Reset() override { rnn_vad_.Reset(); }
  float Analyze(MonoView<const float> frame) override {
    RTC_DCHECK_EQ(frame.size(), rnn_vad::kFrameSize10ms24kHz);
    std::array<float, rnn_vad::kFeatureVectorSize> feature_vector;
    const bool is_silence = features_extractor_.CheckSilenceComputeFeatures(
        /*samples=*/frame.first<rnn_vad::kFrameSize10ms24kHz>(),
        feature_vector);
    return rnn_vad_.ComputeVadProbability(feature_vector, is_silence);
  }

 private:
  rnn_vad::FeaturesExtractor features_extractor_;
  rnn_vad::RnnVad rnn_vad_;
};

}  // namespace

VoiceActivityDetectorWrapper::VoiceActivityDetectorWrapper(
    const AvailableCpuFeatures& cpu_features,
    int sample_rate_hz)
    : VoiceActivityDetectorWrapper(kVadResetPeriodMs,
                                   cpu_features,
                                   sample_rate_hz) {}

VoiceActivityDetectorWrapper::VoiceActivityDetectorWrapper(
    int vad_reset_period_ms,
    const AvailableCpuFeatures& cpu_features,
    int sample_rate_hz)
    : VoiceActivityDetectorWrapper(vad_reset_period_ms,
                                   std::make_unique<MonoVadImpl>(cpu_features),
                                   sample_rate_hz) {}

VoiceActivityDetectorWrapper::VoiceActivityDetectorWrapper(
    int vad_reset_period_ms,
    std::unique_ptr<MonoVad> vad,
    int sample_rate_hz)
    : vad_reset_period_frames_(
          CheckedDivExact(vad_reset_period_ms, kFrameDurationMs)),
      frame_size_(CheckedDivExact(sample_rate_hz, kNumFramesPerSecond)),
      time_to_vad_reset_(vad_reset_period_frames_),
      vad_(std::move(vad)),
      resampled_buffer_(
          CheckedDivExact(vad_->SampleRateHz(), kNumFramesPerSecond)),
      resampler_(frame_size_,
                 resampled_buffer_.size(),
                 /*num_channels=*/1) {
  RTC_DCHECK_GT(vad_reset_period_frames_, 1);
  vad_->Reset();
}

VoiceActivityDetectorWrapper::~VoiceActivityDetectorWrapper() = default;

float VoiceActivityDetectorWrapper::Analyze(
    DeinterleavedView<const float> frame) {
  // Periodically reset the VAD.
  time_to_vad_reset_--;
  if (time_to_vad_reset_ <= 0) {
    vad_->Reset();
    time_to_vad_reset_ = vad_reset_period_frames_;
  }

  // Resample the first channel of `frame`.
  RTC_DCHECK_EQ(frame.samples_per_channel(), frame_size_);
  MonoView<float> dst(resampled_buffer_.data(), resampled_buffer_.size());
  resampler_.Resample(frame[0], dst);

  return vad_->Analyze(resampled_buffer_);
}

}  // namespace webrtc
