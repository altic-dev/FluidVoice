/*
 *  Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/audio_processing/high_pass_filter.h"

#include <array>
#include <cstddef>
#include <span>
#include <vector>

#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/utility/cascaded_biquad_filter.h"
#include "rtc_base/checks.h"

namespace webrtc {

namespace {
constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 3>
    kHighPassFilterCoefficients16kHz = {{
        {.b = {0.8773539420715290582f, -1.754683920749088077f,
               0.8773539420715289472f},
         .a = {-1.881687317862849707f, 0.8880584644559580410f}},
        {.b = {1.0f, -1.999810143464515022f, 1.0f},
         .a = {-1.976035417167170793f, 0.9779708644868606582f}},
        {.b = {1.0f, -1.999669231394235469f, 1.0f},
         .a = {-1.994265767864654482f, 0.9954861594635392441f}},
    }};

constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 3>
    kHighPassFilterCoefficients32kHz = {{
        {.b = {0.9102055685511306615f, -1.820404922871161624f,
               0.9102055685511306615f},
         .a = {-1.940710875829138482f, 0.9423512845457852061f}},
        {.b = {1.0f, -1.999952541587768806f, 1.0f},
         .a = {-1.988434609801665420f, 0.9889212529819323416f}},
        {.b = {1.0f, -1.999917315632020021f, 1.0f},
         .a = {-1.997434723613889629f, 0.9977401885079651978f}},
    }};

constexpr std::array<CascadedBiQuadFilter::BiQuadCoefficients, 3>
    kHighPassFilterCoefficients48kHz = {{
        {.b = {0.9213790163564168f, -1.8427552370064049f, 0.9213790163564168f},
         .a = {-1.9604500061078971f, 0.9611862979079667f}},
        {.b = {1.0f, -1.9999789078432082f, 1.0f},
         .a = {-1.9923834169149972f, 0.9926001112941157f}},
        {.b = {1.0f, -1.9999632520325810f, 1.0f},
         .a = {-1.9983570340145236f, 0.9984928491805198f}},
    }};

std::span<const CascadedBiQuadFilter::BiQuadCoefficients> ChooseCoefficients(
    int sample_rate_hz) {
  switch (sample_rate_hz) {
    case 16000:
      return std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
          kHighPassFilterCoefficients16kHz);
    case 32000:
      return std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
          kHighPassFilterCoefficients32kHz);
    case 48000:
      return std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
          kHighPassFilterCoefficients48kHz);
    default:
      RTC_DCHECK_NOTREACHED();
  }
  RTC_DCHECK_NOTREACHED();
  return std::span<const CascadedBiQuadFilter::BiQuadCoefficients>(
      kHighPassFilterCoefficients16kHz);
}

}  // namespace

HighPassFilter::HighPassFilter(int sample_rate_hz, size_t num_channels)
    : sample_rate_hz_(sample_rate_hz) {
  filters_.resize(num_channels);
  auto coefficients = ChooseCoefficients(sample_rate_hz_);
  for (size_t k = 0; k < filters_.size(); ++k) {
    filters_[k].reset(new CascadedBiQuadFilter(coefficients));
  }
}

HighPassFilter::~HighPassFilter() = default;

void HighPassFilter::Process(AudioBuffer* audio, bool use_split_band_data) {
  RTC_DCHECK(audio);
  RTC_DCHECK_EQ(filters_.size(), audio->num_channels());
  if (use_split_band_data) {
    for (size_t k = 0; k < audio->num_channels(); ++k) {
      std::span<float> channel_data = std::span<float>(
          audio->split_bands(k)[0], audio->num_frames_per_band());
      filters_[k]->Process(channel_data);
    }
  } else {
    for (size_t k = 0; k < audio->num_channels(); ++k) {
      std::span<float> channel_data =
          std::span<float>(&audio->channels()[k][0], audio->num_frames());
      filters_[k]->Process(channel_data);
    }
  }
}

void HighPassFilter::Process(std::vector<std::vector<float>>* audio) {
  RTC_DCHECK_EQ(filters_.size(), audio->size());
  for (size_t k = 0; k < audio->size(); ++k) {
    filters_[k]->Process((*audio)[k]);
  }
}

void HighPassFilter::Reset() {
  for (size_t k = 0; k < filters_.size(); ++k) {
    filters_[k]->Reset();
  }
}

void HighPassFilter::Reset(size_t num_channels) {
  const size_t old_num_channels = filters_.size();
  filters_.resize(num_channels);
  if (filters_.size() < old_num_channels) {
    Reset();
  } else {
    for (size_t k = 0; k < old_num_channels; ++k) {
      filters_[k]->Reset();
    }
    const auto& coefficients = ChooseCoefficients(sample_rate_hz_);
    for (size_t k = old_num_channels; k < filters_.size(); ++k) {
      filters_[k].reset(new CascadedBiQuadFilter(coefficients));
    }
  }
}

}  // namespace webrtc
