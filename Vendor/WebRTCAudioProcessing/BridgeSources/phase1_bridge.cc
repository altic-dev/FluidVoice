#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

#include "fluid_aec3_bridge.h"

namespace {

using Frame = std::array<float, FV_AEC3_FRAME_SAMPLES>;

bool IsFiniteUnitFrame(const Frame& frame) {
  return std::all_of(frame.begin(), frame.end(), [](float value) {
    return std::isfinite(value) && value >= -1.0f && value <= 1.0f;
  });
}

double Rms(const std::vector<float>& values, int begin, int end) {
  double energy = 0.0;
  for (int index = begin; index < end; ++index) {
    energy += static_cast<double>(values[index]) * values[index];
  }
  return std::sqrt(energy / static_cast<double>(end - begin));
}

int BasicContractTest() {
  if (std::strcmp(fv_aec3_upstream_revision(),
                  "d9bd07ba5f614156021df666ba4052ac73cf7953") != 0 ||
      std::strcmp(fv_aec3_configuration_id(),
                  "webrtc-aec3-48k-mono-cxx20-no-protobuf-no-log-v1") != 0) {
    return 10;
  }
  if (fv_aec3_reset(nullptr) != FV_AEC3_INVALID_ARGUMENT) return 11;
  fv_aec3_destroy(nullptr);

  FVAEC3Engine* engine = fv_aec3_create_48k_mono();
  if (engine == nullptr) return 12;
  Frame silence{};
  Frame render{};
  Frame capture{};
  Frame output{};
  for (size_t index = 0; index < render.size(); ++index) {
    const float phase = static_cast<float>(index) / render.size();
    render[index] = 0.25f * std::sin(2.0f * static_cast<float>(M_PI) * phase);
    capture[index] = render[index] * 0.4f;
  }
  FVAEC3Stats stats{};
  if (fv_aec3_process_10ms(nullptr, render.data(), capture.data(),
                           output.data(), &stats) != FV_AEC3_INVALID_ARGUMENT ||
      fv_aec3_process_10ms(engine, nullptr, capture.data(), output.data(),
                           &stats) != FV_AEC3_INVALID_ARGUMENT ||
      fv_aec3_process_10ms(engine, render.data(), nullptr, output.data(),
                           &stats) != FV_AEC3_INVALID_ARGUMENT ||
      fv_aec3_process_10ms(engine, render.data(), capture.data(), nullptr,
                           &stats) != FV_AEC3_INVALID_ARGUMENT) {
    fv_aec3_destroy(engine);
    return 13;
  }
  if (fv_aec3_process_10ms(engine, silence.data(), silence.data(),
                           output.data(), nullptr) != FV_AEC3_OK ||
      !IsFiniteUnitFrame(output)) {
    fv_aec3_destroy(engine);
    return 14;
  }
  if (fv_aec3_process_10ms(engine, render.data(), silence.data(),
                           output.data(), &stats) != FV_AEC3_OK ||
      fv_aec3_process_10ms(engine, silence.data(), capture.data(),
                           output.data(), &stats) != FV_AEC3_OK ||
      !IsFiniteUnitFrame(output) || stats.render_frames != 3 ||
      stats.capture_frames != 3) {
    fv_aec3_destroy(engine);
    return 15;
  }
  Frame maximum;
  maximum.fill(2.0f);  // Finite input is clamped only after validation.
  if (fv_aec3_process_10ms(engine, maximum.data(), maximum.data(),
                           output.data(), &stats) != FV_AEC3_OK ||
      !IsFiniteUnitFrame(output)) {
    fv_aec3_destroy(engine);
    return 16;
  }
  Frame invalid = silence;
  invalid[17] = std::numeric_limits<float>::quiet_NaN();
  if (fv_aec3_process_10ms(engine, invalid.data(), silence.data(),
                           output.data(), &stats) != FV_AEC3_INVALID_ARGUMENT) {
    fv_aec3_destroy(engine);
    return 17;
  }
  fv_aec3_destroy(engine);
  return 0;
}

int SyntheticEchoAndDoubleTalkTest() {
  constexpr int kFrames = 1200;
  constexpr int kSamples = kFrames * FV_AEC3_FRAME_SAMPLES;
  constexpr int kEchoDelaySamples = 240;
  std::vector<float> render(kSamples), near_end(kSamples), capture(kSamples),
      output(kSamples);
  uint32_t render_state = 0x12345678u;
  uint32_t near_state = 0x87654321u;
  float filtered_render = 0.0f;
  float filtered_near = 0.0f;
  for (int index = 0; index < kSamples; ++index) {
    render_state = render_state * 1664525u + 1013904223u;
    const float render_white =
        (static_cast<float>(static_cast<int32_t>(render_state)) /
         2147483648.0f) * 0.22f;
    filtered_render = 0.72f * filtered_render + 0.28f * render_white;
    render[index] = filtered_render;
    if (index >= 900 * FV_AEC3_FRAME_SAMPLES &&
        index < 1100 * FV_AEC3_FRAME_SAMPLES) {
      near_state = near_state * 1103515245u + 12345u;
      const float near_white =
          (static_cast<float>(static_cast<int32_t>(near_state)) /
           2147483648.0f) * 0.6f;
      filtered_near = 0.82f * filtered_near + 0.18f * near_white;
      near_end[index] = filtered_near;
    }
    const float echo = index >= kEchoDelaySamples
                           ? 0.62f * render[index - kEchoDelaySamples]
                           : 0.0f;
    capture[index] = near_end[index] + echo;
  }

  FVAEC3Engine* engine = fv_aec3_create_48k_mono();
  if (engine == nullptr) return 20;
  FVAEC3Stats stats{};
  for (int frame = 0; frame < kFrames; ++frame) {
    const int offset = frame * FV_AEC3_FRAME_SAMPLES;
    if (fv_aec3_process_10ms(engine, render.data() + offset,
                             capture.data() + offset, output.data() + offset,
                             &stats) != FV_AEC3_OK) {
      fv_aec3_destroy(engine);
      return 21;
    }
  }
  if (stats.render_frames != kFrames || stats.capture_frames != kFrames ||
      !std::all_of(output.begin(), output.end(), [](float value) {
        return std::isfinite(value) && value >= -1.0f && value <= 1.0f;
      })) {
    fv_aec3_destroy(engine);
    return 22;
  }

  const int echo_begin = 700 * FV_AEC3_FRAME_SAMPLES;
  const int echo_end = 900 * FV_AEC3_FRAME_SAMPLES;
  const int double_begin = 900 * FV_AEC3_FRAME_SAMPLES;
  const int double_end = 1100 * FV_AEC3_FRAME_SAMPLES;
  const double echo_reduction_db = 20.0 * std::log10(
      Rms(capture, echo_begin, echo_end) / Rms(output, echo_begin, echo_end));
  const double near_attenuation_db = 20.0 * std::log10(
      Rms(output, double_begin, double_end) /
      Rms(near_end, double_begin, double_end));
  if (!(echo_reduction_db >= 6.0) || !(near_attenuation_db >= -3.0)) {
    fv_aec3_destroy(engine);
    return 23;
  }

  if (fv_aec3_reset(engine) != FV_AEC3_OK) {
    fv_aec3_destroy(engine);
    return 24;
  }
  Frame reset_output{};
  if (fv_aec3_process_10ms(engine, render.data(), capture.data(),
                           reset_output.data(), &stats) != FV_AEC3_OK ||
      stats.render_frames != 1 || stats.capture_frames != 1 ||
      stats.resets < 1) {
    fv_aec3_destroy(engine);
    return 25;
  }
  FVAEC3Engine* fresh = fv_aec3_create_48k_mono();
  Frame fresh_output{};
  FVAEC3Stats fresh_stats{};
  if (fresh == nullptr ||
      fv_aec3_process_10ms(fresh, render.data(), capture.data(),
                           fresh_output.data(), &fresh_stats) != FV_AEC3_OK) {
    fv_aec3_destroy(fresh);
    fv_aec3_destroy(engine);
    return 26;
  }
  float maximum_reset_difference = 0.0f;
  for (size_t index = 0; index < reset_output.size(); ++index) {
    maximum_reset_difference =
        std::max(maximum_reset_difference,
                 std::abs(reset_output[index] - fresh_output[index]));
  }
  fv_aec3_destroy(fresh);
  fv_aec3_destroy(engine);
  return maximum_reset_difference <= 1e-6f ? 0 : 27;
}

}  // namespace

int main() {
  if (const int result = BasicContractTest(); result != 0) return result;
  if (const int result = SyntheticEchoAndDoubleTalkTest(); result != 0)
    return result;
  std::cout << "phase1_bridge_ok revision=" << fv_aec3_upstream_revision()
            << " configuration=" << fv_aec3_configuration_id() << '\n';
  return 0;
}
