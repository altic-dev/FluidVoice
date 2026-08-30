#ifndef CORE_AUDIO_CAPTURE_SUPPORT_H
#define CORE_AUDIO_CAPTURE_SUPPORT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *FVCoreAudioCaptureRef;

typedef struct {
    const float *samples;
    uint32_t frameCount;
    double sampleRate;
    uint64_t inputHostTime;
    int64_t inputSampleTime;
    uint64_t sequence;
} FVCoreAudioPacket;

/// Layout helpers shared by capture and deterministic tests.
uint32_t fv_core_audio_buffer_bytes_per_frame(
    uint32_t bytesPerSample,
    uint32_t channelCount
);
uint32_t fv_core_audio_buffer_frame_count(
    uint32_t dataByteSize,
    uint32_t bytesPerSample,
    uint32_t channelCount
);

/// Creates a prepared capture for one physical Core Audio input device.
/// The device is not started and the microphone is not active until start.
int32_t fv_core_audio_capture_create(
    AudioObjectID deviceID,
    FVCoreAudioCaptureRef *outCapture
);

/// Starts input capture and optionally keeps one output device active and silent.
int32_t fv_core_audio_capture_start(
    FVCoreAudioCaptureRef capture,
    AudioObjectID outputKeepAliveDeviceID
);
int32_t fv_core_audio_capture_stop(FVCoreAudioCaptureRef capture);
int32_t fv_core_audio_capture_destroy(FVCoreAudioCaptureRef capture);

/// Waits until the realtime producer publishes a packet or capture stops.
/// Returns true when the consumer should attempt to drain the ring.
bool fv_core_audio_capture_wait(FVCoreAudioCaptureRef capture, uint32_t timeoutMilliseconds);

/// Returns a view into the next immutable ring slot. The pointer remains valid
/// until consume is called and must never escape the consumer callback.
bool fv_core_audio_capture_peek(FVCoreAudioCaptureRef capture, FVCoreAudioPacket *packet);
void fv_core_audio_capture_consume(FVCoreAudioCaptureRef capture);
void fv_core_audio_capture_clear(FVCoreAudioCaptureRef capture);
void fv_core_audio_capture_wake(FVCoreAudioCaptureRef capture);

bool fv_core_audio_capture_is_running(FVCoreAudioCaptureRef capture);
void fv_core_audio_capture_mark_format_dirty(FVCoreAudioCaptureRef capture);
bool fv_core_audio_capture_open_packet_gate_if_clean(FVCoreAudioCaptureRef capture);
bool fv_core_audio_capture_copy_stream_format(
    FVCoreAudioCaptureRef capture,
    AudioStreamID *streamID,
    AudioStreamBasicDescription *format
);
double fv_core_audio_capture_sample_rate(FVCoreAudioCaptureRef capture);
uint32_t fv_core_audio_capture_buffer_frame_size(FVCoreAudioCaptureRef capture);
uint64_t fv_core_audio_capture_dropped_packet_count(FVCoreAudioCaptureRef capture);

#ifdef __cplusplus
}
#endif

#endif
