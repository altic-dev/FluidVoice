/*
 *  Copyright (c) 2014 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/splitting_filter.h"

#include <array>
#include <cstddef>
#include <cstring>
#include <span>

#include "common_audio/channel_buffer.h"
#include "common_audio/signal_processing/include/signal_processing_library.h"
#include "modules/audio_processing/three_band_filter_bank.h"
#include "rtc_base/checks.h"

namespace webrtc {
namespace {

constexpr size_t kSamplesPerBand = 160;
constexpr size_t kTwoBandFilterSamplesPerFrame = 320;

}  // namespace

SplittingFilter::SplittingFilter(size_t num_channels,
                                 size_t num_bands,
                                 size_t /* num_frames */)
    : num_bands_(num_bands),
      two_bands_states_(num_bands_ == 2 ? num_channels : 0),
      three_band_filter_banks_(num_bands_ == 3 ? num_channels : 0) {
  RTC_CHECK(num_bands_ == 2 || num_bands_ == 3);
}

SplittingFilter::~SplittingFilter() = default;

void SplittingFilter::Analysis(const ChannelBuffer<float>* data,
                               ChannelBuffer<float>* bands) {
  RTC_DCHECK_EQ(num_bands_, bands->num_bands());
  RTC_DCHECK_EQ(data->num_channels(), bands->num_channels());
  RTC_DCHECK_EQ(data->num_frames(),
                bands->num_frames_per_band() * bands->num_bands());
  if (bands->num_bands() == 2) {
    TwoBandsAnalysis(data, bands);
  } else if (bands->num_bands() == 3) {
    ThreeBandsAnalysis(data, bands);
  }
}

void SplittingFilter::Synthesis(const ChannelBuffer<float>* bands,
                                ChannelBuffer<float>* data) {
  RTC_DCHECK_EQ(num_bands_, bands->num_bands());
  RTC_DCHECK_EQ(data->num_channels(), bands->num_channels());
  RTC_DCHECK_EQ(data->num_frames(),
                bands->num_frames_per_band() * bands->num_bands());
  if (bands->num_bands() == 2) {
    TwoBandsSynthesis(bands, data);
  } else if (bands->num_bands() == 3) {
    ThreeBandsSynthesis(bands, data);
  }
}

void SplittingFilter::TwoBandsAnalysis(const ChannelBuffer<float>* data,
                                       ChannelBuffer<float>* bands) {
  RTC_DCHECK_EQ(two_bands_states_.size(), data->num_channels());
  RTC_DCHECK_EQ(data->num_frames(), kTwoBandFilterSamplesPerFrame);

  for (size_t i = 0; i < two_bands_states_.size(); ++i) {
    std::array<std::array<float, kSamplesPerBand>, 2> bands16;
    WebRtcSpl_AnalysisQMF(data->channels(0)[i], data->num_frames(),
                          bands16[0].data(), bands16[1].data(),
                          two_bands_states_[i].analysis_state1,
                          two_bands_states_[i].analysis_state2);
    memcpy(bands->channels(0)[i], bands16[0].data(),
           kSamplesPerBand * sizeof(float));
    memcpy(bands->channels(1)[i], bands16[1].data(),
           kSamplesPerBand * sizeof(float));
  }
}

void SplittingFilter::TwoBandsSynthesis(const ChannelBuffer<float>* bands,
                                        ChannelBuffer<float>* data) {
  RTC_DCHECK_LE(data->num_channels(), two_bands_states_.size());
  RTC_DCHECK_EQ(data->num_frames(), kTwoBandFilterSamplesPerFrame);
  for (size_t i = 0; i < data->num_channels(); ++i) {
    std::array<std::array<float, kSamplesPerBand>, 2> bands16;
    memcpy(bands16[0].data(), bands->channels(0)[i],
           kSamplesPerBand * sizeof(float));
    memcpy(bands16[1].data(), bands->channels(1)[i],
           kSamplesPerBand * sizeof(float));
    WebRtcSpl_SynthesisQMF(bands16[0].data(), bands16[1].data(),
                           bands->num_frames_per_band(), data->channels(0)[i],
                           two_bands_states_[i].synthesis_state1,
                           two_bands_states_[i].synthesis_state2);
  }
}

void SplittingFilter::ThreeBandsAnalysis(const ChannelBuffer<float>* data,
                                         ChannelBuffer<float>* bands) {
  RTC_DCHECK_EQ(three_band_filter_banks_.size(), data->num_channels());
  RTC_DCHECK_LE(data->num_channels(), three_band_filter_banks_.size());
  RTC_DCHECK_LE(data->num_channels(), bands->num_channels());
  RTC_DCHECK_EQ(data->num_frames(), ThreeBandFilterBank::kFullBandSize);
  RTC_DCHECK_EQ(bands->num_frames(), ThreeBandFilterBank::kFullBandSize);
  RTC_DCHECK_EQ(bands->num_bands(), ThreeBandFilterBank::kNumBands);
  RTC_DCHECK_EQ(bands->num_frames_per_band(),
                ThreeBandFilterBank::kSplitBandSize);

  for (size_t i = 0; i < three_band_filter_banks_.size(); ++i) {
    three_band_filter_banks_[i].Analysis(
        std::span<const float, ThreeBandFilterBank::kFullBandSize>(
            data->channels_view()[i].data(),
            ThreeBandFilterBank::kFullBandSize),
        std::span<const std::span<float>, ThreeBandFilterBank::kNumBands>(
            bands->bands_view(i).data(), ThreeBandFilterBank::kNumBands));
  }
}

void SplittingFilter::ThreeBandsSynthesis(const ChannelBuffer<float>* bands,
                                          ChannelBuffer<float>* data) {
  RTC_DCHECK_LE(data->num_channels(), three_band_filter_banks_.size());
  RTC_DCHECK_LE(data->num_channels(), bands->num_channels());
  RTC_DCHECK_LE(data->num_channels(), three_band_filter_banks_.size());
  RTC_DCHECK_EQ(data->num_frames(), ThreeBandFilterBank::kFullBandSize);
  RTC_DCHECK_EQ(bands->num_frames(), ThreeBandFilterBank::kFullBandSize);
  RTC_DCHECK_EQ(bands->num_bands(), ThreeBandFilterBank::kNumBands);
  RTC_DCHECK_EQ(bands->num_frames_per_band(),
                ThreeBandFilterBank::kSplitBandSize);

  for (size_t i = 0; i < data->num_channels(); ++i) {
    three_band_filter_banks_[i].Synthesis(
        std::span<const std::span<float>, ThreeBandFilterBank::kNumBands>(
            bands->bands_view(i).data(), ThreeBandFilterBank::kNumBands),
        std::span<float, ThreeBandFilterBank::kFullBandSize>(
            data->channels_view()[i].data(),
            ThreeBandFilterBank::kFullBandSize));
  }
}

}  // namespace webrtc
