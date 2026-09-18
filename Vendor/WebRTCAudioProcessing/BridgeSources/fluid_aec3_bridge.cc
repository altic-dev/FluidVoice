#include "fluid_aec3_bridge.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>
#include <memory>
#include <new>

#include "api/audio/audio_processing.h"
#include "api/audio/builtin_audio_processing_builder.h"
#include "api/environment/environment_factory.h"

namespace {

constexpr char kUpstreamRevision[] =
    "d9bd07ba5f614156021df666ba4052ac73cf7953";
constexpr char kConfigurationID[] =
    "webrtc-aec3-48k-mono-cxx20-no-protobuf-no-log-v1";

webrtc::scoped_refptr<webrtc::AudioProcessing> BuildAudioProcessing() {
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.export_linear_aec_output = false;
  config.echo_canceller.enforce_high_pass_filtering = false;
  config.pre_amplifier.enabled = false;
  config.capture_level_adjustment.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.high_pass_filter.enabled = false;
  config.noise_suppression.enabled = false;
  config.transient_suppression.enabled = false;
  config.pipeline.maximum_internal_processing_rate = FV_AEC3_SAMPLE_RATE_HZ;
  config.pipeline.multi_channel_render = false;
  config.pipeline.multi_channel_capture = false;

  webrtc::BuiltinAudioProcessingBuilder builder(config);
  return builder.Build(webrtc::CreateEnvironment());
}

webrtc::ProcessingConfig Mono48kProcessingConfig() {
  webrtc::ProcessingConfig config;
  config.input_stream() = webrtc::StreamConfig(FV_AEC3_SAMPLE_RATE_HZ, 1);
  config.output_stream() = webrtc::StreamConfig(FV_AEC3_SAMPLE_RATE_HZ, 1);
  config.reverse_input_stream() =
      webrtc::StreamConfig(FV_AEC3_SAMPLE_RATE_HZ, 1);
  config.reverse_output_stream() =
      webrtc::StreamConfig(FV_AEC3_SAMPLE_RATE_HZ, 1);
  return config;
}

bool CopyFiniteFrame(const float* source,
                     std::array<float, FV_AEC3_FRAME_SAMPLES>& destination) {
  for (size_t index = 0; index < destination.size(); ++index) {
    const float value = source[index];
    if (!std::isfinite(value)) {
      return false;
    }
    destination[index] = std::clamp(value, -1.0f, 1.0f);
  }
  return true;
}

}  // namespace

struct FVAEC3Engine {
  webrtc::scoped_refptr<webrtc::AudioProcessing> audio_processing;
  const webrtc::ProcessingConfig processing_config = Mono48kProcessingConfig();
  std::array<float, FV_AEC3_FRAME_SAMPLES> render{};
  std::array<float, FV_AEC3_FRAME_SAMPLES> capture{};
  std::array<float, FV_AEC3_FRAME_SAMPLES> reverse_output{};
  std::array<float, FV_AEC3_FRAME_SAMPLES> capture_output{};
  uint64_t render_frames = 0;
  uint64_t capture_frames = 0;
  uint64_t resets = 0;
};

extern "C" FVAEC3Engine* fv_aec3_create_48k_mono(void) {
  std::unique_ptr<FVAEC3Engine> engine(new (std::nothrow) FVAEC3Engine());
  if (!engine) {
    return nullptr;
  }
  engine->audio_processing = BuildAudioProcessing();
  if (!engine->audio_processing ||
      engine->audio_processing->Initialize(engine->processing_config) != 0) {
    return nullptr;
  }
  return engine.release();
}

extern "C" void fv_aec3_destroy(FVAEC3Engine* engine) {
  delete engine;
}

extern "C" FVAEC3Status fv_aec3_reset(FVAEC3Engine* engine) {
  if (engine == nullptr) {
    return FV_AEC3_INVALID_ARGUMENT;
  }
  auto replacement = BuildAudioProcessing();
  if (!replacement || replacement->Initialize(engine->processing_config) != 0) {
    return FV_AEC3_INITIALIZATION_FAILED;
  }
  engine->audio_processing = std::move(replacement);
  engine->render.fill(0.0f);
  engine->capture.fill(0.0f);
  engine->reverse_output.fill(0.0f);
  engine->capture_output.fill(0.0f);
  engine->render_frames = 0;
  engine->capture_frames = 0;
  ++engine->resets;
  return FV_AEC3_OK;
}

extern "C" FVAEC3Status fv_aec3_process_10ms(
    FVAEC3Engine* engine,
    const float render[FV_AEC3_FRAME_SAMPLES],
    const float capture[FV_AEC3_FRAME_SAMPLES],
    float output[FV_AEC3_FRAME_SAMPLES],
    FVAEC3Stats* stats) {
  if (engine == nullptr || render == nullptr || capture == nullptr ||
      output == nullptr) {
    return FV_AEC3_INVALID_ARGUMENT;
  }
  if (!CopyFiniteFrame(render, engine->render) ||
      !CopyFiniteFrame(capture, engine->capture)) {
    return FV_AEC3_INVALID_ARGUMENT;
  }

  const float* render_input[] = {engine->render.data()};
  float* render_output[] = {engine->reverse_output.data()};
  if (engine->audio_processing->ProcessReverseStream(
          render_input, engine->processing_config.reverse_input_stream(),
          engine->processing_config.reverse_output_stream(), render_output) !=
      0) {
    return FV_AEC3_PROCESSING_FAILED;
  }
  ++engine->render_frames;

  const float* capture_input[] = {engine->capture.data()};
  float* capture_output[] = {engine->capture_output.data()};
  if (engine->audio_processing->ProcessStream(
          capture_input, engine->processing_config.input_stream(),
          engine->processing_config.output_stream(), capture_output) != 0) {
    return FV_AEC3_PROCESSING_FAILED;
  }

  for (size_t index = 0; index < engine->capture_output.size(); ++index) {
    if (!std::isfinite(engine->capture_output[index])) {
      return FV_AEC3_NONFINITE_OUTPUT;
    }
  }
  ++engine->capture_frames;
  for (size_t index = 0; index < engine->capture_output.size(); ++index) {
    output[index] = std::clamp(engine->capture_output[index], -1.0f, 1.0f);
  }

  if (stats != nullptr) {
    stats->render_frames = engine->render_frames;
    stats->capture_frames = engine->capture_frames;
    stats->resets = engine->resets;
    // GetStatistics() acquires WebRTC's reporting mutex. The bridge's realtime ABI deliberately
    // reports optional diagnostics as unavailable instead of adding that lock to every frame.
    stats->estimated_delay_ms = -1;
    stats->residual_echo_likelihood =
        std::numeric_limits<float>::quiet_NaN();
  }
  return FV_AEC3_OK;
}

extern "C" const char* fv_aec3_upstream_revision(void) {
  return kUpstreamRevision;
}

extern "C" const char* fv_aec3_configuration_id(void) {
  return kConfigurationID;
}
