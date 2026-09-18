/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

/*
 * This file contains the splitting filter functions.
 *
 */

#include "common_audio/signal_processing/include/signal_processing_library.h"
#include "rtc_base/checks.h"

// Maximum number of samples in a low/high-band frame.
enum {
  kMaxBandFrameLength = 320  // 10 ms at 64 kHz.
};

// QMF filter coefficients.
static const float WebRtcSpl_kAllPassFilter1[3] = {0.0979309082f, 0.5643005371f,
                                                   0.8737335205f};
static const float WebRtcSpl_kAllPassFilter2[3] = {
    0.32551574707f, 0.74862670898f, 0.96145629882f};

///////////////////////////////////////////////////////////////////////////////////////////////
// WebRtcSpl_AllPassQMF(...)
//
// Allpass filter used by the analysis and synthesis parts of the QMF filter.
//
// Input:
//    - in_data             : Input data sequence
//    - data_length         : Length of data sequence (>2)
//    - filter_coefficients : Filter coefficients
//
// Input & Output:
//    - filter_state        : Filter state
//
// Output:
//    - out_data            : Output data sequence, length equal to
//                            `data_length`
//

static void WebRtcSpl_AllPassQMF(float* in_data,
                                 size_t data_length,
                                 float* out_data,
                                 const float* filter_coefficients,
                                 float* filter_state) {
  // The procedure is to filter the input with three first order all pass
  // filters (cascade operations).
  //
  //         a_3 + q^-1    a_2 + q^-1    a_1 + q^-1
  // y[n] =  -----------   -----------   -----------   x[n]
  //         1 + a_3q^-1   1 + a_2q^-1   1 + a_1q^-1
  //
  // The input vector `filter_coefficients` includes these three filter
  // coefficients. The filter state contains the in_data state, in_data[-1],
  // followed by the out_data state, out_data[-1]. This is repeated for each
  // cascade. The first cascade filter will filter the `in_data` and store
  // the output in `out_data`. The second will the take the `out_data` as
  // input and make an intermediate storage in `in_data`, to save memory. The
  // third, and final, cascade filter operation takes the `in_data` (which is
  // the output from the previous cascade filter) and store the output in
  // `out_data`. Note that the input vector values are changed during the
  // process.
  size_t k;
  float diff;
  // First all-pass cascade; filter from in_data to out_data.

  // Let y_i[n] indicate the output of cascade filter i (with filter
  // coefficient a_i) at vector position n. Then the final output will be
  // y[n] = y_3[n]

  // First loop, use the states stored in memory.
  // "diff" should be safe from wrap around since max values are 2^25
  // diff = (x[0] - y_1[-1])
  diff = in_data[0] - filter_state[1];
  // y_1[0] =  x[-1] + a_1 * (x[0] - y_1[-1])
  out_data[0] = filter_state[0] + filter_coefficients[0] * diff;

  // For the remaining loops, use previous values.
  for (k = 1; k < data_length; k++) {
    // diff = (x[n] - y_1[n-1])
    diff = in_data[k] - out_data[k - 1];
    // y_1[n] =  x[n-1] + a_1 * (x[n] - y_1[n-1])
    out_data[k] = in_data[k - 1] + filter_coefficients[0] * diff;
  }

  // Update states.
  filter_state[0] =
      in_data[data_length - 1];  // x[N-1], becomes x[-1] next time
  filter_state[1] =
      out_data[data_length - 1];  // y_1[N-1], becomes y_1[-1] next time

  // Second all-pass cascade; filter from out_data to in_data.
  // diff = (y_1[0] - y_2[-1])
  diff = out_data[0] - filter_state[3];
  // y_2[0] =  y_1[-1] + a_2 * (y_1[0] - y_2[-1])
  in_data[0] = filter_state[2] + filter_coefficients[1] * diff;
  for (k = 1; k < data_length; k++) {
    // diff = (y_1[n] - y_2[n-1])
    diff = out_data[k] - in_data[k - 1];
    // y_2[0] =  y_1[-1] + a_2 * (y_1[0] - y_2[-1])
    in_data[k] = out_data[k - 1] + filter_coefficients[1] * diff;
  }

  filter_state[2] =
      out_data[data_length - 1];  // y_1[N-1], becomes y_1[-1] next time
  filter_state[3] =
      in_data[data_length - 1];  // y_2[N-1], becomes y_2[-1] next time

  // Third all-pass cascade; filter from in_data to out_data.
  // diff = (y_2[0] - y[-1])
  diff = in_data[0] - filter_state[5];
  // y[0] =  y_2[-1] + a_3 * (y_2[0] - y[-1])
  out_data[0] = filter_state[4] + filter_coefficients[2] * diff;
  for (k = 1; k < data_length; k++) {
    // diff = (y_2[n] - y[n-1])
    diff = in_data[k] - out_data[k - 1];
    // y[n] =  y_2[n-1] + a_3 * (y_2[n] - y[n-1])
    out_data[k] = in_data[k - 1] + filter_coefficients[2] * diff;
  }
  filter_state[4] =
      in_data[data_length - 1];  // y_2[N-1], becomes y_2[-1] next time
  filter_state[5] =
      out_data[data_length - 1];  // y[N-1], becomes y[-1] next time
}

void WebRtcSpl_AnalysisQMF(const float* in_data,
                           size_t in_data_length,
                           float* low_band,
                           float* high_band,
                           float* filter_state1,
                           float* filter_state2) {
  size_t i;
  int16_t k;
  float half_in1[kMaxBandFrameLength];
  float half_in2[kMaxBandFrameLength];
  float filter1[kMaxBandFrameLength];
  float filter2[kMaxBandFrameLength];
  const size_t band_length = in_data_length / 2;
  RTC_DCHECK_EQ(0, in_data_length % 2);
  RTC_DCHECK_LE(band_length, kMaxBandFrameLength);

  // Split even and odd samples.
  for (i = 0, k = 0; i < band_length; i++, k += 2) {
    half_in2[i] = in_data[k];
    half_in1[i] = in_data[k + 1];
  }

  // All pass filter even and odd samples, independently.
  WebRtcSpl_AllPassQMF(half_in1, band_length, filter1,
                       WebRtcSpl_kAllPassFilter1, filter_state1);
  WebRtcSpl_AllPassQMF(half_in2, band_length, filter2,
                       WebRtcSpl_kAllPassFilter2, filter_state2);

  // Take the sum and difference of filtered version of odd and even
  // branches to get upper & lower band.
  for (i = 0; i < band_length; i++) {
    low_band[i] = (filter1[i] + filter2[i]) * 0.5f;
    high_band[i] = (filter1[i] - filter2[i]) * 0.5f;
  }
}

void WebRtcSpl_SynthesisQMF(const float* low_band,
                            const float* high_band,
                            size_t band_length,
                            float* out_data,
                            float* filter_state1,
                            float* filter_state2) {
  float half_in1[kMaxBandFrameLength];
  float half_in2[kMaxBandFrameLength];
  float filter1[kMaxBandFrameLength];
  float filter2[kMaxBandFrameLength];
  size_t i;
  int16_t k;
  RTC_DCHECK_LE(band_length, kMaxBandFrameLength);

  // Obtain the sum and difference channels out of upper and lower-band
  // channels.
  for (i = 0; i < band_length; i++) {
    half_in1[i] = low_band[i] + high_band[i];
    half_in2[i] = low_band[i] - high_band[i];
  }

  // all-pass filter the sum and difference channels
  WebRtcSpl_AllPassQMF(half_in1, band_length, filter1,
                       WebRtcSpl_kAllPassFilter2, filter_state1);
  WebRtcSpl_AllPassQMF(half_in2, band_length, filter2,
                       WebRtcSpl_kAllPassFilter1, filter_state2);

  // The filtered signals are even and odd samples of the output. Combine
  // them and take care of saturation.
  for (i = 0, k = 0; i < band_length; i++) {
    out_data[k++] = filter2[i] > -32768.0f ?
                    (filter2[i] < 32767.0f ? filter2[i] : 32767.0f) : -32768.0f;
    out_data[k++] = filter1[i] > -32768.0f ?
                    (filter1[i] < 32767.0f ? filter1[i] : 32767.0f) : -32768.0f;
  }
}
