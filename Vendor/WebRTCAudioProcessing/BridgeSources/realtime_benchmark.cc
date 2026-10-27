#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <limits>
#include <vector>

#include <mach/mach.h>
#include <pthread/qos.h>

#include "fluid_aec3_bridge.h"

namespace {

using Frame = std::array<float, FV_AEC3_FRAME_SAMPLES>;

constexpr int kWarmupFrames = 6000;       // One simulated minute.
constexpr int kMeasurementFrames = 180000;  // Thirty simulated minutes.
constexpr int kEchoDelaySamples = 240;
constexpr uint64_t kMaximumGrowthBytes = 1024 * 1024;

uint64_t ResidentBytes() {
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self_, MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
    return 0;
  }
  return info.resident_size;
}

class DeterministicSignal {
 public:
  void Fill(Frame* render, Frame* capture) {
    for (int index = 0; index < FV_AEC3_FRAME_SAMPLES; ++index) {
      render_state_ = render_state_ * 1664525u + 1013904223u;
      const float white =
          static_cast<float>(static_cast<int32_t>(render_state_)) /
          2147483648.0f;
      filtered_render_ = 0.76f * filtered_render_ + 0.24f * white;
      const float render_sample = 0.2f * filtered_render_;
      (*render)[index] = render_sample;

      const float delayed = delay_[delay_index_];
      delay_[delay_index_] = render_sample;
      delay_index_ = (delay_index_ + 1) % delay_.size();

      near_state_ = near_state_ * 1103515245u + 12345u;
      const bool double_talk = ((sample_index_ / 48000) % 4) == 3;
      const float near_white =
          static_cast<float>(static_cast<int32_t>(near_state_)) /
          2147483648.0f;
      filtered_near_ = 0.81f * filtered_near_ + 0.19f * near_white;
      const float near_sample = double_talk ? 0.12f * filtered_near_ : 0.0f;
      (*capture)[index] = std::clamp(near_sample + 0.58f * delayed, -1.0f, 1.0f);
      ++sample_index_;
    }
  }

 private:
  uint32_t render_state_ = 0x12345678u;
  uint32_t near_state_ = 0x87654321u;
  float filtered_render_ = 0.0f;
  float filtered_near_ = 0.0f;
  std::array<float, kEchoDelaySamples> delay_{};
  size_t delay_index_ = 0;
  uint64_t sample_index_ = 0;
};

bool ProcessFrame(FVAEC3Engine* engine, DeterministicSignal* signal,
                  Frame* render, Frame* capture, Frame* output,
                  FVAEC3Stats* statistics) {
  signal->Fill(render, capture);
  if (fv_aec3_process_10ms(engine, render->data(), capture->data(),
                           output->data(), statistics) != FV_AEC3_OK) {
    return false;
  }
  return std::all_of(output->begin(), output->end(), [](float sample) {
    return std::isfinite(sample) && sample >= -1.0f && sample <= 1.0f;
  });
}

}  // namespace

int main() {
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  FVAEC3Engine* engine = fv_aec3_create_48k_mono();
  if (engine == nullptr) {
    std::cerr << "benchmark: engine creation failed\n";
    return 2;
  }

  DeterministicSignal signal;
  Frame render{};
  Frame capture{};
  Frame output{};
  FVAEC3Stats statistics{};
  for (int frame = 0; frame < kWarmupFrames; ++frame) {
    if (!ProcessFrame(engine, &signal, &render, &capture, &output, &statistics)) {
      std::cerr << "benchmark: warm-up processing failed at frame " << frame << '\n';
      fv_aec3_destroy(engine);
      return 3;
    }
  }

  // Fault benchmark-owned storage in before the RSS baseline so lazy vector page commitment is
  // not mistaken for growth inside AEC3.
  std::vector<double> durations_ms(kMeasurementFrames, 0.0);
  volatile double prefault_sink = 0.0;
  for (size_t index = 0; index < durations_ms.size(); ++index) {
    durations_ms[index] = static_cast<double>(index & 1);
    prefault_sink = prefault_sink + durations_ms[index];
  }
  std::vector<uint64_t> minute_rss(31, 0);
  size_t rss_count = 1;
  const uint64_t baseline_rss = ResidentBytes();
  minute_rss[0] = baseline_rss;
  volatile float output_sink = 0.0f;

  for (int frame = 0; frame < kMeasurementFrames; ++frame) {
    signal.Fill(&render, &capture);
    const auto start = std::chrono::steady_clock::now();
    const FVAEC3Status status = fv_aec3_process_10ms(
        engine, render.data(), capture.data(), output.data(), &statistics);
    const auto end = std::chrono::steady_clock::now();
    if (status != FV_AEC3_OK ||
        !std::all_of(output.begin(), output.end(), [](float sample) {
          return std::isfinite(sample) && sample >= -1.0f && sample <= 1.0f;
        })) {
      std::cerr << "benchmark: measured processing failed at frame " << frame << '\n';
      fv_aec3_destroy(engine);
      return 4;
    }
    output_sink = output_sink + output[frame % FV_AEC3_FRAME_SAMPLES];
    durations_ms[frame] =
        std::chrono::duration<double, std::milli>(end - start).count();
    if ((frame + 1) % 6000 == 0) minute_rss[rss_count++] = ResidentBytes();
  }

  fv_aec3_destroy(engine);
  std::sort(durations_ms.begin(), durations_ms.end());
  const size_t p99_index =
      static_cast<size_t>(std::ceil(0.99 * durations_ms.size())) - 1;
  const double p99_ms = durations_ms[p99_index];
  const double maximum_ms = durations_ms.back();
  const auto [minimum_rss_it, maximum_rss_it] =
      std::minmax_element(minute_rss.begin(), minute_rss.end());
  const uint64_t rss_range = *maximum_rss_it - *minimum_rss_it;
  const bool monotonic_growth =
      std::adjacent_find(minute_rss.begin(), minute_rss.end(),
                         std::greater_equal<uint64_t>()) == minute_rss.end() &&
      minute_rss.back() > minute_rss.front();

  std::cout << std::fixed << std::setprecision(4)
            << "aec3_realtime_benchmark frames=" << kMeasurementFrames
            << " simulated_minutes=30"
            << " p99_ms=" << p99_ms
            << " max_ms=" << maximum_ms
            << " rss_start_bytes=" << minute_rss.front()
            << " rss_end_bytes=" << minute_rss.back()
            << " rss_range_bytes=" << rss_range
            << " monotonic_growth=" << (monotonic_growth ? "true" : "false")
            << " sink=" << output_sink + static_cast<float>(prefault_sink * 0.0) << '\n';

  if (p99_ms >= 5.0) return 10;
  if (maximum_ms >= 10.0) return 11;
  if (monotonic_growth || rss_range > kMaximumGrowthBytes) return 12;
  if (statistics.render_frames != kWarmupFrames + kMeasurementFrames ||
      statistics.capture_frames != kWarmupFrames + kMeasurementFrames) {
    return 13;
  }
  return 0;
}
