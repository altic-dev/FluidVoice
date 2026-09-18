/*
 *  Copyright 2018 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "rtc_base/strings/string_builder.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "rtc_base/checks.h"

namespace webrtc {

StringBuilder& StringBuilder::operator<<(const absl::string_view str) {
  str_.append(str.data(), str.length());
  return *this;
}

StringBuilder& StringBuilder::operator<<(char c) {
  str_ += c;
  return *this;
}

StringBuilder& StringBuilder::operator<<(int i) {
  str_ += absl::StrCat(i);
  return *this;
}

StringBuilder& StringBuilder::operator<<(unsigned i) {
  str_ += absl::StrCat(i);
  return *this;
}

StringBuilder& StringBuilder::operator<<(long i) {
  str_ += absl::StrCat(i);
  return *this;
}

StringBuilder& StringBuilder::operator<<(long long i) {
  str_ += absl::StrCat(i);
  return *this;
}

StringBuilder& StringBuilder::operator<<(unsigned long i) {
  str_ += absl::StrCat(i);
  return *this;
}

StringBuilder& StringBuilder::operator<<(unsigned long long i) {
  str_ += absl::StrCat(i);
  return *this;
}

StringBuilder& StringBuilder::operator<<(float f) {
  str_ += absl::StrCat(f);
  return *this;
}

StringBuilder& StringBuilder::operator<<(double f) {
  str_ += absl::StrCat(f);
  return *this;
}

StringBuilder& StringBuilder::AppendFormat(const char* fmt, ...) {
  va_list args, copy;
  va_start(args, fmt);
  va_copy(copy, args);
  const int predicted_length = std::vsnprintf(nullptr, 0, fmt, copy);
  va_end(copy);

  RTC_DCHECK_GE(predicted_length, 0);
  if (predicted_length > 0) {
    const size_t size = str_.size();
    str_.resize(size + predicted_length);
    // Pass "+ 1" to vsnprintf to include space for the '\0'.
    const int actual_length =
        std::vsnprintf(&str_[size], predicted_length + 1, fmt, args);
    RTC_DCHECK_GE(actual_length, 0);
  }
  va_end(args);
  return *this;
}

}  // namespace webrtc
