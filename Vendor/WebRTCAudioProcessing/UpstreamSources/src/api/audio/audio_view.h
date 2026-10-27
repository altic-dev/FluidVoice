/*
 *  Copyright (c) 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef API_AUDIO_AUDIO_VIEW_H_
#define API_AUDIO_AUDIO_VIEW_H_

#include <cstddef>
#include <iterator>
#include <span>
#include <variant>
#include <vector>

#include "absl/algorithm/container.h"
#include "rtc_base/checks.h"

namespace webrtc {

// This file contains 3 types of view classes:
//
// * MonoView<>: A single channel contiguous buffer of samples.
//
// * InterleavedView<>: Channel samples are interleaved (side-by-side) in
//   the buffer. A single channel InterleavedView<> is the same thing as a
//   MonoView<>
//
// * DeinterleavedView<>: Each channel's samples are contiguous within the
//   buffer. Channels can be enumerated and accessing the individual channel
//   data is done via MonoView<>.
//
// The views are comparable to and built on std::span<> but add
// audio specific properties for the dimensions of the buffer and the above
// specialized [de]interleaved support.
//
// There are also a few generic utility functions that can simplify
// generic code for supporting more than one type of view.

// MonoView<> represents a view over a single contiguous, audio buffer. This
// can be either an single channel (mono) interleaved buffer (e.g. AudioFrame),
// or a de-interleaved channel (e.g. from AudioBuffer).
template <typename T>
using MonoView = std::span<T>;

// The maximum number of audio channels supported by WebRTC encoders, decoders
// and the AudioFrame class.
// AudioFrame's max number of samples is 7680, which can hold 16 10ms 16bit
// channels at 48 kHz.
static constexpr size_t kMaxNumberOfAudioChannels = 16;

// InterleavedView<> is a view over an interleaved audio buffer (e.g. from
// AudioFrame).
template <typename T>
class InterleavedView {
 public:
  using value_type = T;
  using iterator = typename std::span<T>::iterator;
  using const_iterator = typename std::span<const T>::iterator;

  InterleavedView() = default;

  template <typename U>
  InterleavedView(U* data, size_t samples_per_channel, size_t num_channels)
      : num_channels_(num_channels),
        samples_per_channel_(samples_per_channel),
        data_(data, num_channels * samples_per_channel) {
    RTC_DCHECK_LE(num_channels_, kMaxNumberOfAudioChannels);
    RTC_DCHECK(num_channels_ == 0u || samples_per_channel_ != 0u);
  }

  // Construct an InterleavedView from a C-style array. Samples per channels
  // is calculated based on the array size / num_channels.
  template <typename U, size_t N>
  InterleavedView(U (&array)[N],  // NOLINT
                  size_t num_channels)
      : InterleavedView(array, N / num_channels, num_channels) {
    RTC_DCHECK_EQ(N % num_channels, 0u);
  }

  template <typename U>
  InterleavedView(const InterleavedView<U>& other)
      : num_channels_(other.num_channels()),
        samples_per_channel_(other.samples_per_channel()),
        data_(other.data()) {}

  size_t num_channels() const { return num_channels_; }
  size_t samples_per_channel() const { return samples_per_channel_; }
  std::span<T> data() const { return data_; }
  bool empty() const { return data_.empty(); }
  size_t size() const { return data_.size(); }

  MonoView<T> AsMono() const {
    RTC_DCHECK_EQ(num_channels(), 1u);
    RTC_DCHECK_EQ(data_.size(), samples_per_channel_);
    return data_;
  }

  // A simple wrapper around memcpy that includes checks for properties.
  // TODO(tommi): Consider if this can be utility function for both interleaved
  // and deinterleaved views.
  template <typename U>
  void CopyFrom(const InterleavedView<U>& source) {
    static_assert(sizeof(T) == sizeof(U), "");
    RTC_DCHECK_EQ(num_channels(), source.num_channels());
    RTC_DCHECK_EQ(samples_per_channel(), source.samples_per_channel());
    RTC_DCHECK_GE(data_.size(), source.data().size());
    const auto data = source.data();
    memcpy(&data_[0], &data[0], data.size() * sizeof(U));
  }

  T& operator[](size_t idx) const { return data_[idx]; }
  iterator begin() const { return data_.begin(); }
  iterator end() const { return data_.end(); }
  const_iterator cbegin() const { return data_.begin(); }
  const_iterator cend() const { return data_.end(); }
  std::reverse_iterator<iterator> rbegin() const { return data_.rbegin(); }
  std::reverse_iterator<iterator> rend() const { return data_.rend(); }
  std::reverse_iterator<const_iterator> crbegin() const {
    return data_.rbegin();
  }
  std::reverse_iterator<const_iterator> crend() const { return data_.rend(); }

 private:
  // TODO(tommi): Consider having these both be stored as uint16_t to
  // save a few bytes per view. Use `dchecked_cast` to support size_t during
  // construction.
  size_t num_channels_ = 0u;
  size_t samples_per_channel_ = 0u;
  std::span<T> data_;
};

template <typename T>
class DeinterleavedView {
 public:
  using value_type = T;

  DeinterleavedView() = default;

  // Construct a view where all the channels are coallocated in a single buffer.
  template <typename U>
  DeinterleavedView(U* data, size_t samples_per_channel, size_t num_channels)
      : num_channels_(num_channels),
        samples_per_channel_(samples_per_channel),
        data_(data) {}

  // Construct a view from an array of channel pointers where the channels
  // may all be allocated seperately.
  template <typename U>
  DeinterleavedView(U* const* channels,
                    size_t samples_per_channel,
                    size_t num_channels)
      : num_channels_(num_channels),
        samples_per_channel_(samples_per_channel),
        data_(channels) {}

  // Construct a view from an array of channel pointers where the pointers are
  // helt in a `std::vector<>`.
  template <typename U>
  DeinterleavedView(const std::vector<U*>& channels, size_t samples_per_channel)
      : num_channels_(channels.size()),
        samples_per_channel_(samples_per_channel),
        data_(channels.data()) {}

  // Construct a view from another view. Note that the type of
  // the other view may be different from the current type and
  // therefore the internal data types may not be exactly the
  // same, but still compatible.
  // E.g.:
  // DeinterleavedView<float> mutable_view;
  // DeinterleavedView<const float> const_view(mutable_view);
  template <typename U>
  DeinterleavedView(const DeinterleavedView<U>& other)
      : num_channels_(other.num_channels_),
        samples_per_channel_(other.samples_per_channel()) {
    if (other.is_ptr_array()) {
      data_ = std::get<U* const*>(other.data_);
    } else {
      data_ = std::get<U*>(other.data_);
    }
  }

  // Returns a deinterleaved channel where `idx` is the zero based index,
  // in the range [0 .. num_channels()-1].
  MonoView<T> operator[](size_t idx) const {
    RTC_DCHECK_LT(idx, num_channels());
    if (is_ptr_array())
      return MonoView<T>(std::get<T* const*>(data_)[idx], samples_per_channel_);
    return MonoView<T>(&std::get<T*>(data_)[idx * samples_per_channel_],
                       samples_per_channel_);
  }

  size_t num_channels() const { return num_channels_; }
  size_t samples_per_channel() const { return samples_per_channel_; }
  bool empty() const {
    return num_channels_ == 0u || samples_per_channel_ == 0u;
  }
  size_t size() const { return num_channels_ * samples_per_channel_; }

  // Returns the first (and possibly only) channel.
  MonoView<T> AsMono() const {
    RTC_DCHECK_GE(num_channels(), 1u);
    return (*this)[0];
  }

  // Zeros out all samples in channels represented by the view.
  void Clear() {
    for (size_t i = 0u; i < num_channels_; ++i) {
      MonoView<T> view = (*this)[i];
      absl::c_fill(view, 0);
    }
  }

 private:
  bool is_ptr_array() const { return std::holds_alternative<T* const*>(data_); }

  template <typename U>
  friend class DeinterleavedView;

  size_t num_channels_ = 0u;
  size_t samples_per_channel_ = 0u;
  std::variant<T* const*, T*> data_;
};

template <typename T>
constexpr size_t NumChannels(const MonoView<T>& /* view */) {
  return 1u;
}

template <typename T>
size_t NumChannels(const InterleavedView<T>& view) {
  return view.num_channels();
}

template <typename T>
size_t NumChannels(const DeinterleavedView<T>& view) {
  return view.num_channels();
}

template <typename T>
constexpr bool IsMono(const MonoView<T>& /* view */) {
  return true;
}

template <typename T>
constexpr bool IsInterleavedView(const MonoView<T>& /* view */) {
  return true;
}

template <typename T>
constexpr bool IsInterleavedView(const InterleavedView<T>& /* view */) {
  return true;
}

template <typename T>
constexpr bool IsInterleavedView(const DeinterleavedView<const T>& /* view */) {
  return false;
}

template <typename T>
bool IsMono(const InterleavedView<T>& view) {
  return NumChannels(view) == 1u;
}

template <typename T>
bool IsMono(const DeinterleavedView<T>& view) {
  return NumChannels(view) == 1u;
}

template <typename T>
size_t SamplesPerChannel(const MonoView<T>& view) {
  return view.size();
}

template <typename T>
size_t SamplesPerChannel(const InterleavedView<T>& view) {
  return view.samples_per_channel();
}

template <typename T>
size_t SamplesPerChannel(const DeinterleavedView<T>& view) {
  return view.samples_per_channel();
}
// A simple wrapper around memcpy that includes checks for properties.
// The parameter order is the same as for memcpy(), first destination then
// source.
template <typename D, typename S>
void CopySamples(D& destination, const S& source) {
  static_assert(
      sizeof(typename D::value_type) == sizeof(typename S::value_type), "");
  // Here we'd really like to do
  // static_assert(IsInterleavedView(destination) == IsInterleavedView(source),
  //               "");
  // but the compiler doesn't like it inside this template function for
  // some reason. The following check is an approximation but unfortunately
  // means that copying between a MonoView and single channel interleaved or
  // deinterleaved views wouldn't work.
  // static_assert(sizeof(destination) == sizeof(source),
  //               "Incompatible view types");
  RTC_DCHECK_EQ(NumChannels(destination), NumChannels(source));
  RTC_DCHECK_EQ(SamplesPerChannel(destination), SamplesPerChannel(source));
  RTC_DCHECK_GE(destination.size(), source.size());
  memcpy(&destination[0], &source[0],
         source.size() * sizeof(typename S::value_type));
}

}  // namespace webrtc

#endif  // API_AUDIO_AUDIO_VIEW_H_
