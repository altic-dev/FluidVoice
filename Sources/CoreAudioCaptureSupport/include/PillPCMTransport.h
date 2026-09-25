#ifndef FLUID_PILL_PCM_TRANSPORT_H
#define FLUID_PILL_PCM_TRANSPORT_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#define FV_PILL_PACKET_CAPACITY 4096
#define FV_PILL_QUEUE_CAPACITY 8
typedef struct FVPillTransport FVPillTransport;
typedef struct {
    uint64_t epoch, sequence, session, attempt, hostTime, offeredHostTime;
    double sampleRate;
    uint32_t count;
    bool discontinuity;
    float samples[FV_PILL_PACKET_CAPACITY];
} FVPillPacket;
FVPillTransport *FVPillCreate(void);
void FVPillDestroy(FVPillTransport *queue);
// Control operations never touch slot storage. The capture pipeline serializes
// begin/end with its existing PCM acceptance lock. Visibility is independently atomic.
void FVPillBegin(FVPillTransport *queue, uint64_t session, uint64_t attempt);
void FVPillEnd(FVPillTransport *queue);
void FVPillSetVisible(FVPillTransport *queue, bool visible);
uint64_t FVPillEpoch(const FVPillTransport *queue);
bool FVPillIsVisible(const FVPillTransport *queue);
bool FVPillIsActive(const FVPillTransport *queue);
// One serialized producer, one serial worker consumer. No allocation, waiting,
// borrowed storage retention, or overwrite of a slot owned by the consumer.
bool FVPillPush(FVPillTransport *queue, const float *samples, size_t count,
                double sampleRate, uint64_t hostTime, bool discontinuity);
// FIFO consumption preserves continuous PCM across ordinary worker scheduling jitter.
bool FVPillTakeNext(FVPillTransport *queue, FVPillPacket *destination);
// Used only when retiring/discarding queued visualization work.
bool FVPillTakeLatest(FVPillTransport *queue, FVPillPacket *destination);
uint64_t FVPillDropped(const FVPillTransport *queue);
#endif
