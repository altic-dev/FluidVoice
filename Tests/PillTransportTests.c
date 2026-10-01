#include "PillPCMTransport.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
static FVPillTransport *queue;
static _Atomic bool done;
static void *produce(void *unused) {
    (void)unused;
    float samples[160];
    for (int n = 1; n <= 100000; ++n) {
        for (int i = 0; i < 160; ++i) samples[i] = (float)n;
        FVPillPush(queue, samples, 160, 16000, n, false);
    }
    atomic_store(&done, true);
    return NULL;
}
int main(void) {
    queue = FVPillCreate(); assert(queue);
    FVPillSetVisible(queue, true); FVPillBegin(queue, 12, 34);
    float samples[160] = {0};
    for (int i = 0; i < FV_PILL_QUEUE_CAPACITY; ++i) assert(FVPillPush(queue, samples, 160, 16000, i, false));
    assert(!FVPillPush(queue, samples, 160, 16000, 9, false));
    assert(FVPillDropped(queue) == 1);
    FVPillPacket p;
    assert(FVPillTakeLatest(queue, &p)); assert(p.discontinuity); assert(p.sequence == 8);
    assert(p.session == 12 && p.attempt == 34 && p.hostTime == 7 && p.sampleRate == 16000);
    uint64_t epoch = p.epoch;
    FVPillEnd(queue); assert(FVPillEpoch(queue) != epoch);
    assert(!FVPillPush(queue, samples, 160, 16000, 0, false));
    FVPillBegin(queue, 13, 35);
    pthread_t producer; pthread_create(&producer, NULL, produce, NULL);
    uint64_t sequence = 0, consumed = 0;
    while (!atomic_load(&done)) {
        if (!FVPillTakeNext(queue, &p)) continue;
        assert(p.sequence > sequence); sequence = p.sequence;
        assert(p.session == 13 && p.attempt == 35);
        for (int i = 0; i < 160; ++i) assert(p.samples[i] == (float)p.hostTime);
        ++consumed;
    }
    pthread_join(producer, NULL);
    FVPillDestroy(queue);
    printf("PILL_TRANSPORT 100000 concurrent packets, %llu snapshots, no torn/overwritten samples; overflow/session checks passed\n", (unsigned long long)consumed);
}
