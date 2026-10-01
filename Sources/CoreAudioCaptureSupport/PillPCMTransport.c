#include "include/PillPCMTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>
struct FVPillTransport {
    _Atomic uint64_t write, read, epoch, dropped;
    _Atomic bool active, visible;
    // Producer-owned, serialized by the existing capture acceptance lock.
    uint64_t sequence, session, attempt;
    FVPillPacket slots[FV_PILL_QUEUE_CAPACITY];
};
FVPillTransport *FVPillCreate(void) {
    FVPillTransport *q = calloc(1, sizeof(FVPillTransport));
    if (!q) return NULL;
    atomic_init(&q->write, 0); atomic_init(&q->read, 0);
    atomic_init(&q->epoch, 0); atomic_init(&q->dropped, 0);
    atomic_init(&q->active, false); atomic_init(&q->visible, false);
    if (!atomic_is_lock_free(&q->write) || !atomic_is_lock_free(&q->visible)) {
        free(q); return NULL;
    }
    return q;
}
void FVPillDestroy(FVPillTransport *q) { free(q); }
void FVPillBegin(FVPillTransport *q, uint64_t session, uint64_t attempt) {
    atomic_store_explicit(&q->active, false, memory_order_release);
    q->session = session; q->attempt = attempt;
    atomic_fetch_add_explicit(&q->epoch, 1, memory_order_acq_rel);
    atomic_store_explicit(&q->active, true, memory_order_release);
}
void FVPillEnd(FVPillTransport *q) {
    atomic_store_explicit(&q->active, false, memory_order_release);
    atomic_fetch_add_explicit(&q->epoch, 1, memory_order_acq_rel);
}
void FVPillSetVisible(FVPillTransport *q, bool visible) {
    atomic_store_explicit(&q->visible, visible, memory_order_release);
    atomic_fetch_add_explicit(&q->epoch, 1, memory_order_acq_rel);
}
uint64_t FVPillEpoch(const FVPillTransport *q) { return atomic_load_explicit(&q->epoch, memory_order_acquire); }
bool FVPillIsVisible(const FVPillTransport *q) { return atomic_load_explicit(&q->visible, memory_order_acquire); }
bool FVPillIsActive(const FVPillTransport *q) { return atomic_load_explicit(&q->active, memory_order_acquire); }
uint64_t FVPillDropped(const FVPillTransport *q) { return atomic_load_explicit(&q->dropped, memory_order_relaxed); }
bool FVPillPush(FVPillTransport *q, const float *samples, size_t count,
                double rate, uint64_t hostTime, bool discontinuity) {
    // Snapshot before checking controls/copying: a concurrent visibility change
    // must invalidate this packet, never relabel old work with the new epoch.
    uint64_t epoch = FVPillEpoch(q);
    if (!FVPillIsActive(q) || !FVPillIsVisible(q) || !samples || !count || !isfinite(rate) || rate <= 0) return false;
    uint64_t sequence = ++q->sequence;
    uint64_t write = atomic_load_explicit(&q->write, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&q->read, memory_order_acquire);
    if (write - read >= FV_PILL_QUEUE_CAPACITY) {
        atomic_fetch_add_explicit(&q->dropped, 1, memory_order_relaxed);
        return false;
    }
    FVPillPacket *p = &q->slots[write % FV_PILL_QUEUE_CAPACITY];
    p->epoch = epoch; p->sequence = sequence;
    p->session = q->session; p->attempt = q->attempt;
    p->hostTime = hostTime; p->offeredHostTime = mach_absolute_time(); p->sampleRate = rate;
    p->discontinuity = discontinuity || count > FV_PILL_PACKET_CAPACITY;
    p->count = (uint32_t)(count > FV_PILL_PACKET_CAPACITY ? FV_PILL_PACKET_CAPACITY : count);
    memcpy(p->samples, samples + count - p->count, p->count * sizeof(float));
    atomic_store_explicit(&q->write, write + 1, memory_order_release);
    return true;
}
bool FVPillTakeNext(FVPillTransport *q, FVPillPacket *destination) {
    uint64_t read = atomic_load_explicit(&q->read, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&q->write, memory_order_acquire);
    if (read == write) return false;
    *destination = q->slots[read % FV_PILL_QUEUE_CAPACITY];
    atomic_store_explicit(&q->read, read + 1, memory_order_release);
    return true;
}
bool FVPillTakeLatest(FVPillTransport *q, FVPillPacket *destination) {
    uint64_t read = atomic_load_explicit(&q->read, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&q->write, memory_order_acquire);
    if (read == write) return false;
    // The producer cannot reuse ANY skipped slot until the copy completes.
    *destination = q->slots[(write - 1) % FV_PILL_QUEUE_CAPACITY];
    if (write - read > 1) destination->discontinuity = true;
    atomic_store_explicit(&q->read, write, memory_order_release);
    return true;
}
