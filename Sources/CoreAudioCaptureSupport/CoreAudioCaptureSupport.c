#include "include/CoreAudioCaptureSupport.h"

#include <dispatch/dispatch.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// 64 hardware cycles provides ample scheduling headroom while keeping the
// realtime producer strictly allocation-free.
#define FV_RING_CAPACITY 64u
#define FV_MAX_FRAMES_PER_PACKET 8192u
#define FV_OUTPUT_START_TIMEOUT_MILLISECONDS 1000u

typedef struct {
    float samples[FV_MAX_FRAMES_PER_PACKET];
    uint32_t frameCount;
    uint64_t inputHostTime;
    int64_t inputSampleTime;
    uint64_t sequence;
} FVPacketSlot;

typedef struct {
    AudioObjectID deviceID;
    AudioStreamID streamID;
    AudioDeviceIOProcID ioProcID;
    AudioObjectID outputKeepAliveDeviceID;
    AudioDeviceIOProcID outputKeepAliveIOProcID;
    AudioStreamBasicDescription format;
    uint32_t bufferFrameSize;
    uint32_t bytesPerSample;
    dispatch_semaphore_t packetSemaphore;
    dispatch_semaphore_t outputStartSemaphore;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t droppedPackets;
    _Atomic bool running;
    _Atomic bool formatDirty;
    _Atomic bool packetGateOpen;
    _Atomic bool outputKeepAliveRunning;
    _Atomic bool awaitingOutputCallback;
    FVPacketSlot slots[FV_RING_CAPACITY];
} FVCapture;

static OSStatus fv_output_io_proc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void) inDevice;
    (void) inNow;
    (void) inInputData;
    (void) inInputTime;
    // Core Audio clears output buffers before calling an AudioDeviceIOProc.
    // Leaving them untouched produces silence.
    (void) outOutputData;
    (void) inOutputTime;

    FVCapture *capture = (FVCapture *) inClientData;
    if (capture != NULL && atomic_exchange_explicit(
        &capture->awaitingOutputCallback,
        false,
        memory_order_acq_rel
    )) {
        dispatch_semaphore_signal(capture->outputStartSemaphore);
    }
    return noErr;
}

static OSStatus fv_prepare_output_keep_alive(
    FVCapture *capture,
    AudioObjectID deviceID
) {
    if (deviceID == kAudioObjectUnknown) {
        return noErr;
    }
    if (capture->outputKeepAliveIOProcID != NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    capture->outputKeepAliveDeviceID = deviceID;
    OSStatus status = AudioDeviceCreateIOProcID(
        deviceID,
        fv_output_io_proc,
        capture,
        &capture->outputKeepAliveIOProcID
    );
    if (status != noErr) {
        capture->outputKeepAliveDeviceID = kAudioObjectUnknown;
    }
    return status;
}

static OSStatus fv_start_output_keep_alive(FVCapture *capture) {
    if (capture->outputKeepAliveIOProcID == NULL ||
        atomic_load_explicit(&capture->outputKeepAliveRunning, memory_order_acquire)) {
        return noErr;
    }
    while (dispatch_semaphore_wait(
        capture->outputStartSemaphore,
        DISPATCH_TIME_NOW
    ) == 0) {}
    atomic_store_explicit(
        &capture->awaitingOutputCallback,
        true,
        memory_order_release
    );
    atomic_store_explicit(
        &capture->outputKeepAliveRunning,
        true,
        memory_order_release
    );
    OSStatus status = AudioDeviceStart(
        capture->outputKeepAliveDeviceID,
        capture->outputKeepAliveIOProcID
    );
    if (status != noErr) {
        atomic_store_explicit(
            &capture->outputKeepAliveRunning,
            false,
            memory_order_release
        );
        atomic_store_explicit(
            &capture->awaitingOutputCallback,
            false,
            memory_order_release
        );
        return status;
    }

    dispatch_time_t timeout = dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t) FV_OUTPUT_START_TIMEOUT_MILLISECONDS * NSEC_PER_MSEC
    );
    if (dispatch_semaphore_wait(capture->outputStartSemaphore, timeout) != 0) {
        atomic_store_explicit(
            &capture->awaitingOutputCallback,
            false,
            memory_order_release
        );
        OSStatus stopStatus = AudioDeviceStop(
            capture->outputKeepAliveDeviceID,
            capture->outputKeepAliveIOProcID
        );
        if (stopStatus == noErr) {
            atomic_store_explicit(
                &capture->outputKeepAliveRunning,
                false,
                memory_order_release
            );
        }
        return stopStatus == noErr ? kAudioHardwareNotReadyError : stopStatus;
    }
    return noErr;
}

static OSStatus fv_stop_output_keep_alive(FVCapture *capture) {
    if (capture->outputKeepAliveIOProcID == NULL ||
        !atomic_load_explicit(
            &capture->outputKeepAliveRunning,
            memory_order_acquire
        )) {
        return noErr;
    }
    atomic_store_explicit(
        &capture->awaitingOutputCallback,
        false,
        memory_order_release
    );
    OSStatus status = AudioDeviceStop(
        capture->outputKeepAliveDeviceID,
        capture->outputKeepAliveIOProcID
    );
    if (status == noErr) {
        atomic_store_explicit(
            &capture->outputKeepAliveRunning,
            false,
            memory_order_release
        );
    }
    return status;
}

static OSStatus fv_destroy_output_keep_alive(FVCapture *capture) {
    if (capture->outputKeepAliveIOProcID == NULL) {
        capture->outputKeepAliveDeviceID = kAudioObjectUnknown;
        return noErr;
    }
    if (atomic_load_explicit(
        &capture->outputKeepAliveRunning,
        memory_order_acquire
    )) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus status = AudioDeviceDestroyIOProcID(
        capture->outputKeepAliveDeviceID,
        capture->outputKeepAliveIOProcID
    );
    if (status == noErr) {
        capture->outputKeepAliveDeviceID = kAudioObjectUnknown;
        capture->outputKeepAliveIOProcID = NULL;
    }
    return status;
}

static OSStatus fv_stop_and_destroy_output_keep_alive(FVCapture *capture) {
    OSStatus status = fv_stop_output_keep_alive(capture);
    if (status != noErr) {
        return status;
    }
    return fv_destroy_output_keep_alive(capture);
}

static OSStatus fv_get_input_stream_format(
    AudioObjectID deviceID,
    AudioStreamID *streamID,
    AudioStreamBasicDescription *format
) {
    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 streamsSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        deviceID,
        &streamsAddress,
        0,
        NULL,
        &streamsSize
    );
    if (status != noErr || streamsSize != sizeof(AudioStreamID)) {
        // Multiple independent input streams can have different formats. Let
        // AVAudioEngine handle those uncommon devices instead of guessing.
        return status != noErr ? status : kAudioHardwareUnsupportedOperationError;
    }

    AudioStreamID resolvedStreamID = kAudioObjectUnknown;
    status = AudioObjectGetPropertyData(
        deviceID,
        &streamsAddress,
        0,
        NULL,
        &streamsSize,
        &resolvedStreamID
    );
    if (status != noErr || resolvedStreamID == kAudioObjectUnknown) {
        return status != noErr ? status : kAudioHardwareBadObjectError;
    }
    if (streamID != NULL) {
        *streamID = resolvedStreamID;
    }

    AudioObjectPropertyAddress formatAddress = {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 formatSize = sizeof(*format);
    return AudioObjectGetPropertyData(
        resolvedStreamID,
        &formatAddress,
        0,
        NULL,
        &formatSize,
        format
    );
}

static OSStatus fv_get_buffer_frame_size(AudioObjectID deviceID, uint32_t *frameSize) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*frameSize);
    return AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, frameSize);
}

static OSStatus fv_get_maximum_buffer_frame_size(
    AudioObjectID deviceID,
    uint32_t fallbackFrameSize,
    uint32_t *maximumFrameSize
) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyUsesVariableBufferFrameSizes,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &address)) {
        *maximumFrameSize = fallbackFrameSize;
        return noErr;
    }
    UInt32 size = sizeof(*maximumFrameSize);
    OSStatus status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        NULL,
        &size,
        maximumFrameSize
    );
    if (status == noErr && *maximumFrameSize == 0) {
        *maximumFrameSize = fallbackFrameSize;
    }
    return status;
}

static bool fv_format_is_supported(
    const AudioStreamBasicDescription *format,
    uint32_t *bytesPerSample
) {
    if (format->mFormatID != kAudioFormatLinearPCM ||
        format->mSampleRate <= 0.0 ||
        format->mChannelsPerFrame == 0 ||
        format->mBytesPerFrame == 0 ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return false;
    }

    const bool nonInterleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const uint32_t channelDivisor = nonInterleaved ? 1u : format->mChannelsPerFrame;
    if (channelDivisor == 0 || format->mBytesPerFrame % channelDivisor != 0) {
        return false;
    }

    const uint32_t sampleBytes = format->mBytesPerFrame / channelDivisor;
    const bool isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isSignedInteger =
        (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool isPacked = (format->mFormatFlags & kAudioFormatFlagIsPacked) != 0;

    if (isFloat && format->mBitsPerChannel == 32 && sampleBytes == sizeof(float)) {
        *bytesPerSample = sampleBytes;
        return true;
    }
    if (isSignedInteger && isPacked &&
        ((format->mBitsPerChannel == 16 && sampleBytes == 2) ||
         (format->mBitsPerChannel == 24 && sampleBytes == 3) ||
         (format->mBitsPerChannel == 32 && sampleBytes == 4))) {
        *bytesPerSample = sampleBytes;
        return true;
    }
    return false;
}

static inline float fv_read_sample(
    const uint8_t *bytes,
    const AudioStreamBasicDescription *format
) {
    if ((format->mFormatFlags & kAudioFormatFlagIsFloat) != 0) {
        float sample;
        memcpy(&sample, bytes, sizeof(sample));
        return sample;
    }

    switch (format->mBitsPerChannel) {
    case 16: {
        int16_t sample;
        memcpy(&sample, bytes, sizeof(sample));
        return (float) sample / 32768.0f;
    }
    case 24: {
        int32_t sample =
            ((int32_t) bytes[0]) |
            ((int32_t) bytes[1] << 8) |
            ((int32_t) bytes[2] << 16);
        if ((sample & 0x00800000) != 0) {
            sample |= (int32_t) 0xFF000000;
        }
        return (float) sample / 8388608.0f;
    }
    case 32: {
        int32_t sample;
        memcpy(&sample, bytes, sizeof(sample));
        return (float) ((double) sample / 2147483648.0);
    }
    default:
        return 0.0f;
    }
}

uint32_t fv_core_audio_buffer_bytes_per_frame(
    uint32_t bytesPerSample,
    uint32_t channelCount
) {
    if (bytesPerSample == 0 || channelCount == 0 ||
        bytesPerSample > UINT32_MAX / channelCount) {
        return 0;
    }
    return bytesPerSample * channelCount;
}

uint32_t fv_core_audio_buffer_frame_count(
    uint32_t dataByteSize,
    uint32_t bytesPerSample,
    uint32_t channelCount
) {
    const uint32_t bytesPerFrame =
        fv_core_audio_buffer_bytes_per_frame(bytesPerSample, channelCount);
    return bytesPerFrame == 0 ? 0 : dataByteSize / bytesPerFrame;
}

static uint32_t fv_frame_count(
    const FVCapture *capture,
    const AudioBufferList *inputData
) {
    uint32_t frameCount = UINT_MAX;
    const AudioBuffer *buffers = inputData->mBuffers;
    for (UInt32 index = 0; index < inputData->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &buffers[index];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0) {
            continue;
        }
        // Derive the stride from the actual AudioBuffer layout. Core Audio can
        // expose one buffer per channel even when the device's virtual ASBD
        // temporarily reports the stream-wide interleaved byte stride during
        // a route change. Using ASBD.mBytesPerFrame in that state turns a
        // 512-frame, 3-buffer callback into 170 frames and speeds audio up 3x.
        const uint32_t frames = fv_core_audio_buffer_frame_count(
            buffer->mDataByteSize,
            capture->bytesPerSample,
            buffer->mNumberChannels
        );
        if (frames == 0) {
            continue;
        }
        if (frames < frameCount) {
            frameCount = frames;
        }
    }
    return frameCount == UINT_MAX ? 0u : frameCount;
}

static OSStatus fv_io_proc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void) inDevice;
    (void) inNow;
    (void) outOutputData;
    (void) inOutputTime;

    FVCapture *capture = (FVCapture *) inClientData;
    if (capture == NULL || inInputData == NULL ||
        !atomic_load_explicit(&capture->running, memory_order_relaxed) ||
        atomic_load_explicit(&capture->formatDirty, memory_order_acquire) ||
        !atomic_load_explicit(&capture->packetGateOpen, memory_order_acquire)) {
        return noErr;
    }

    uint32_t frameCount = fv_frame_count(capture, inInputData);
    if (frameCount == 0) {
        return noErr;
    }
    if (frameCount > FV_MAX_FRAMES_PER_PACKET) {
        atomic_fetch_add_explicit(&capture->droppedPackets, 1, memory_order_relaxed);
        return noErr;
    }

    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_relaxed);
    const uint64_t readIndex =
        atomic_load_explicit(&capture->readIndex, memory_order_acquire);
    if (writeIndex - readIndex >= FV_RING_CAPACITY) {
        atomic_fetch_add_explicit(&capture->droppedPackets, 1, memory_order_relaxed);
        return noErr;
    }

    FVPacketSlot *slot = &capture->slots[writeIndex % FV_RING_CAPACITY];
    memset(slot->samples, 0, frameCount * sizeof(float));

    uint32_t availableChannels = 0;
    const AudioBuffer *buffers = inInputData->mBuffers;
    for (UInt32 bufferIndex = 0; bufferIndex < inInputData->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &buffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0 ||
            buffer->mNumberChannels == 0) {
            continue;
        }

        const uint8_t *data = (const uint8_t *) buffer->mData;
        const uint32_t channelCount = buffer->mNumberChannels;
        const uint32_t bufferBytesPerFrame =
            fv_core_audio_buffer_bytes_per_frame(capture->bytesPerSample, channelCount);
        for (uint32_t frame = 0; frame < frameCount; ++frame) {
            const uint8_t *frameData = data + frame * bufferBytesPerFrame;
            float sum = 0.0f;
            for (uint32_t channel = 0; channel < channelCount; ++channel) {
                sum += fv_read_sample(
                    frameData + channel * capture->bytesPerSample,
                    &capture->format
                );
            }
            slot->samples[frame] += sum;
        }
        availableChannels += channelCount;
    }

    if (availableChannels == 0) {
        return noErr;
    }
    const float channelScale = 1.0f / (float) availableChannels;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        slot->samples[frame] *= channelScale;
    }

    slot->frameCount = frameCount;
    slot->inputHostTime =
        inInputTime != NULL &&
        (inInputTime->mFlags & kAudioTimeStampHostTimeValid) != 0
            ? inInputTime->mHostTime
            : mach_absolute_time();
    slot->inputSampleTime =
        inInputTime != NULL &&
        (inInputTime->mFlags & kAudioTimeStampSampleTimeValid) != 0
            ? (int64_t) inInputTime->mSampleTime
            : -1;
    slot->sequence = writeIndex;

    atomic_store_explicit(&capture->writeIndex, writeIndex + 1, memory_order_release);
    dispatch_semaphore_signal(capture->packetSemaphore);
    return noErr;
}

int32_t fv_core_audio_capture_create(
    AudioObjectID deviceID,
    FVCoreAudioCaptureRef *outCapture
) {
    if (outCapture == NULL || deviceID == kAudioObjectUnknown) {
        return kAudioHardwareBadObjectError;
    }
    *outCapture = NULL;

    FVCapture *capture = (FVCapture *) calloc(1, sizeof(FVCapture));
    if (capture == NULL) {
        return kAudioHardwareUnspecifiedError;
    }
    capture->deviceID = deviceID;
    capture->outputKeepAliveDeviceID = kAudioObjectUnknown;

    OSStatus status = fv_get_input_stream_format(
        deviceID,
        &capture->streamID,
        &capture->format
    );
    if (status == noErr &&
        !fv_format_is_supported(&capture->format, &capture->bytesPerSample)) {
        status = kAudioHardwareUnsupportedOperationError;
    }
    if (status == noErr) {
        status = fv_get_buffer_frame_size(deviceID, &capture->bufferFrameSize);
    }
    uint32_t maximumBufferFrameSize = capture->bufferFrameSize;
    if (status == noErr) {
        status = fv_get_maximum_buffer_frame_size(
            deviceID,
            capture->bufferFrameSize,
            &maximumBufferFrameSize
        );
    }
    if (status == noErr &&
        (capture->bufferFrameSize == 0 ||
         maximumBufferFrameSize > FV_MAX_FRAMES_PER_PACKET)) {
        status = kAudioHardwareUnsupportedOperationError;
    }
    if (status != noErr) {
        free(capture);
        return status;
    }

    capture->packetSemaphore = dispatch_semaphore_create(0);
    capture->outputStartSemaphore = dispatch_semaphore_create(0);
    if (capture->packetSemaphore == NULL || capture->outputStartSemaphore == NULL) {
#if !OS_OBJECT_USE_OBJC
        if (capture->packetSemaphore != NULL) {
            dispatch_release(capture->packetSemaphore);
        }
        if (capture->outputStartSemaphore != NULL) {
            dispatch_release(capture->outputStartSemaphore);
        }
#endif
        free(capture);
        return kAudioHardwareUnspecifiedError;
    }
    atomic_init(&capture->writeIndex, 0);
    atomic_init(&capture->readIndex, 0);
    atomic_init(&capture->droppedPackets, 0);
    atomic_init(&capture->running, false);
    atomic_init(&capture->formatDirty, false);
    atomic_init(&capture->packetGateOpen, false);
    atomic_init(&capture->outputKeepAliveRunning, false);
    atomic_init(&capture->awaitingOutputCallback, false);

    status = AudioDeviceCreateIOProcID(
        deviceID,
        fv_io_proc,
        capture,
        &capture->ioProcID
    );
    if (status != noErr) {
#if !OS_OBJECT_USE_OBJC
        dispatch_release(capture->packetSemaphore);
        dispatch_release(capture->outputStartSemaphore);
#endif
        free(capture);
        return status;
    }

    *outCapture = (FVCoreAudioCaptureRef) capture;
    return noErr;
}

int32_t fv_core_audio_capture_start(
    FVCoreAudioCaptureRef captureRef,
    AudioObjectID outputKeepAliveDeviceID
) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL || capture->ioProcID == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (atomic_load_explicit(&capture->running, memory_order_acquire)) {
        return noErr;
    }

    OSStatus status = fv_prepare_output_keep_alive(
        capture,
        outputKeepAliveDeviceID
    );
    if (status != noErr) {
        return status;
    }
    status = fv_start_output_keep_alive(capture);
    if (status != noErr) {
        (void) fv_stop_and_destroy_output_keep_alive(capture);
        return status;
    }
    atomic_store_explicit(&capture->packetGateOpen, false, memory_order_release);
    atomic_store_explicit(&capture->running, true, memory_order_release);
    status = AudioDeviceStart(capture->deviceID, capture->ioProcID);
    if (status != noErr) {
        atomic_store_explicit(&capture->running, false, memory_order_release);
        dispatch_semaphore_signal(capture->packetSemaphore);
        (void) fv_stop_and_destroy_output_keep_alive(capture);
    }
    return status;
}

int32_t fv_core_audio_capture_stop(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL || capture->ioProcID == NULL) {
        return kAudioHardwareBadObjectError;
    }
    OSStatus inputStatus = noErr;
    if (atomic_load_explicit(&capture->running, memory_order_acquire)) {
        // Close publication before synchronizing with the IOProc. The consumer
        // still drains every packet already committed to the ring.
        atomic_store_explicit(&capture->packetGateOpen, false, memory_order_release);
        inputStatus = AudioDeviceStop(capture->deviceID, capture->ioProcID);
        atomic_store_explicit(&capture->running, false, memory_order_release);
    }
    dispatch_semaphore_signal(capture->packetSemaphore);
    OSStatus outputStatus = fv_stop_and_destroy_output_keep_alive(capture);
    return inputStatus == noErr ? outputStatus : inputStatus;
}

int32_t fv_core_audio_capture_destroy(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL) {
        return noErr;
    }
    if (atomic_load_explicit(&capture->running, memory_order_acquire) ||
        atomic_load_explicit(
            &capture->outputKeepAliveRunning,
            memory_order_acquire
        )) {
        OSStatus stopStatus = fv_core_audio_capture_stop(captureRef);
        if (stopStatus != noErr) {
            return stopStatus;
        }
    }
    if (capture->ioProcID != NULL) {
        OSStatus destroyStatus = AudioDeviceDestroyIOProcID(
            capture->deviceID,
            capture->ioProcID
        );
        if (destroyStatus != noErr) {
            return destroyStatus;
        }
        capture->ioProcID = NULL;
    }
    OSStatus outputDestroyStatus = fv_destroy_output_keep_alive(capture);
    if (outputDestroyStatus != noErr) {
        return outputDestroyStatus;
    }
#if !OS_OBJECT_USE_OBJC
    dispatch_release(capture->packetSemaphore);
    dispatch_release(capture->outputStartSemaphore);
#endif
    free(capture);
    return noErr;
}

bool fv_core_audio_capture_wait(
    FVCoreAudioCaptureRef captureRef,
    uint32_t timeoutMilliseconds
) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL) {
        return false;
    }
    dispatch_time_t timeout = dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t) timeoutMilliseconds * NSEC_PER_MSEC
    );
    return dispatch_semaphore_wait(capture->packetSemaphore, timeout) == 0;
}

bool fv_core_audio_capture_peek(
    FVCoreAudioCaptureRef captureRef,
    FVCoreAudioPacket *packet
) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL || packet == NULL ||
        atomic_load_explicit(&capture->formatDirty, memory_order_acquire)) {
        return false;
    }
    const uint64_t readIndex =
        atomic_load_explicit(&capture->readIndex, memory_order_relaxed);
    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    if (readIndex == writeIndex) {
        return false;
    }

    const FVPacketSlot *slot = &capture->slots[readIndex % FV_RING_CAPACITY];
    packet->samples = slot->samples;
    packet->frameCount = slot->frameCount;
    packet->sampleRate = capture->format.mSampleRate;
    packet->inputHostTime = slot->inputHostTime;
    packet->inputSampleTime = slot->inputSampleTime;
    packet->sequence = slot->sequence;
    return true;
}

void fv_core_audio_capture_consume(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL) {
        return;
    }
    const uint64_t readIndex =
        atomic_load_explicit(&capture->readIndex, memory_order_relaxed);
    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    if (readIndex != writeIndex) {
        atomic_store_explicit(&capture->readIndex, readIndex + 1, memory_order_release);
    }
}

void fv_core_audio_capture_clear(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL || atomic_load_explicit(&capture->running, memory_order_acquire)) {
        return;
    }
    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    atomic_store_explicit(&capture->readIndex, writeIndex, memory_order_release);
    atomic_store_explicit(&capture->droppedPackets, 0, memory_order_relaxed);
    while (dispatch_semaphore_wait(capture->packetSemaphore, DISPATCH_TIME_NOW) == 0) {
        // Remove stale per-packet wakeups from the previous stopped session.
    }
}

void fv_core_audio_capture_wake(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture != NULL) {
        dispatch_semaphore_signal(capture->packetSemaphore);
    }
}

bool fv_core_audio_capture_is_running(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    return capture != NULL &&
        atomic_load_explicit(&capture->running, memory_order_acquire);
}

void fv_core_audio_capture_mark_format_dirty(FVCoreAudioCaptureRef captureRef) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL) {
        return;
    }
    atomic_store_explicit(&capture->formatDirty, true, memory_order_release);
    atomic_store_explicit(&capture->packetGateOpen, false, memory_order_release);
}

bool fv_core_audio_capture_open_packet_gate_if_clean(
    FVCoreAudioCaptureRef captureRef
) {
    FVCapture *capture = (FVCapture *) captureRef;
    if (capture == NULL ||
        !atomic_load_explicit(&capture->running, memory_order_acquire) ||
        atomic_load_explicit(&capture->formatDirty, memory_order_acquire)) {
        return false;
    }

    atomic_store_explicit(&capture->packetGateOpen, true, memory_order_release);
    if (atomic_load_explicit(&capture->formatDirty, memory_order_acquire)) {
        atomic_store_explicit(&capture->packetGateOpen, false, memory_order_release);
        return false;
    }
    return true;
}

bool fv_core_audio_capture_copy_stream_format(
    FVCoreAudioCaptureRef captureRef,
    AudioStreamID *streamID,
    AudioStreamBasicDescription *format
) {
    const FVCapture *capture = (const FVCapture *) captureRef;
    if (capture == NULL || streamID == NULL || format == NULL) {
        return false;
    }
    *streamID = capture->streamID;
    *format = capture->format;
    return true;
}

double fv_core_audio_capture_sample_rate(FVCoreAudioCaptureRef captureRef) {
    const FVCapture *capture = (const FVCapture *) captureRef;
    return capture == NULL ? 0.0 : capture->format.mSampleRate;
}

uint32_t fv_core_audio_capture_buffer_frame_size(FVCoreAudioCaptureRef captureRef) {
    const FVCapture *capture = (const FVCapture *) captureRef;
    return capture == NULL ? 0u : capture->bufferFrameSize;
}

uint64_t fv_core_audio_capture_dropped_packet_count(FVCoreAudioCaptureRef captureRef) {
    const FVCapture *capture = (const FVCapture *) captureRef;
    return capture == NULL
        ? 0u
        : atomic_load_explicit(&capture->droppedPackets, memory_order_relaxed);
}
