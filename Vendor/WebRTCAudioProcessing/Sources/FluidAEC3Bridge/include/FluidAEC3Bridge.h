#ifndef FLUID_AEC3_BRIDGE_H_
#define FLUID_AEC3_BRIDGE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FVAEC3Engine FVAEC3Engine;

typedef enum FVAEC3Status {
  FV_AEC3_OK = 0,
  FV_AEC3_INVALID_ARGUMENT = 1,
  FV_AEC3_INITIALIZATION_FAILED = 2,
  FV_AEC3_PROCESSING_FAILED = 3,
  FV_AEC3_NONFINITE_OUTPUT = 4,
} FVAEC3Status;

typedef struct FVAEC3Stats {
  uint64_t render_frames;
  uint64_t capture_frames;
  uint64_t resets;
  int32_t estimated_delay_ms;
  float residual_echo_likelihood;
} FVAEC3Stats;

enum {
  FV_AEC3_SAMPLE_RATE_HZ = 48000,
  FV_AEC3_FRAME_SAMPLES = 480,
};

FVAEC3Engine* fv_aec3_create_48k_mono(void);
void fv_aec3_destroy(FVAEC3Engine* engine);
FVAEC3Status fv_aec3_reset(FVAEC3Engine* engine);
FVAEC3Status fv_aec3_process_10ms(FVAEC3Engine* engine,
                                  const float render[FV_AEC3_FRAME_SAMPLES],
                                  const float capture[FV_AEC3_FRAME_SAMPLES],
                                  float output[FV_AEC3_FRAME_SAMPLES],
                                  FVAEC3Stats* stats);
const char* fv_aec3_upstream_revision(void);
const char* fv_aec3_configuration_id(void);

#ifdef __cplusplus
}
#endif

#endif  // FLUID_AEC3_BRIDGE_H_
