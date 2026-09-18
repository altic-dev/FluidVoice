# Direct WebRTC AEC3 implementation plan

Status: implementation-ready; adversarial review passed with no P0/P1. This is a local planning artifact and
must remain untracked. It does not authorize a commit, a new recording, or generated evidence.

## Outcome

Ship WebRTC Audio Processing Module's AEC3 directly in the pre-production macOS app for the
explicitly classified speaker-route ScreenCaptureKit online-call path. The application-audio
callback is the far-end/render stream;
the paired microphone callback is the near-end/capture stream. On speaker routes, only the
AEC-processed microphone reaches the microphone writer or live microphone ASR. If AEC cannot
provide an ordered, valid output, recording continues with the raw microphone marked
`unprotected`, and microphone transcription stays closed.

This is not another evidence stage or a shadow deployment. The implementation is enabled by
default on the applicable, positively identified speaker ScreenCaptureKit path once its source,
tests, and build checks pass. An ambiguous/settling route remains raw and unprotected; it does not
enter AEC on the assumption that “unknown” means speaker.
The existing VoiceProcessingIO path and in-room recording path remain unchanged.

## Non-negotiable decisions

1. **Process before both consumers.** `ScreenCaptureMeetingRuntime` may continue to write and tee
   the original application track immediately, but it must never write or tee a speaker-route
   microphone callback before the AEC pipeline decides that callback's output. Persisted mic audio
   and live mic ASR therefore see the same processed/bypass decision.
2. **Preserve original timestamps.** AEC output carries the source microphone PTS and duration.
   AEC algorithmic/acoustic delay is not subtracted from the recording timeline. No zero padding,
   extrapolated audio, or retimestamping is used to manufacture a pair.
3. **One serial owner.** Extraction, format conversion, render/capture joining, APM calls, resets,
   and output ordering have one serial executor. `ProcessReverseStream` always precedes
   `ProcessStream` for a 10 ms pair, and no APM call is concurrent with another APM call.
4. **Physical protection and software processing are different facts.** Add
   `MeetingMicrophoneEchoProtection.softwareEchoCancelled`; do not relabel AEC output as
   `acousticallyClosed` or `voiceProcessed`. Existing values keep their meanings.
5. **Fail closed for speech evidence.** An unmeasured/late render region, invalid PCM, discontinuity,
   format change, queue/resource bound, bridge error, metadata persistence failure, or stream
   rebuild immediately closes live mic admission and starts/preserves an `unprotected` era.
   Raw audio may still be recorded in timestamp order; it may not reach live or batch transcript.
6. **No optimistic startup.** A speaker-route era starts `unprotected`. It can be promoted to
   `softwareEchoCancelled` only after a fresh engine has completed the warm-up contract below and
   the new era has been durably written. Every reset repeats this process.
7. **No shadow product path.** Do not retain a parallel raw mic file, dual-ASR path, analytics
   upload, user-media fixture, remote flag, or default-off feature flag. A DEBUG-only environment
   bypass is acceptable for diagnosis, and must degrade to the existing raw/unprotected behavior.
8. **Attest the clock contract at runtime.** Being outputs of one `SCStream` is necessary but not
   sufficient evidence that numeric PTS values are sample-accurately interchangeable. Before a
   speaker epoch can promote, both streams must pass the continuing common-clock attestation in
   Phase 3. PTS equality alone never opens transcript admission.
9. **No scope creep.** Do not change microphone election, VPIO recovery, diarization, speaker
   identity, text echo heuristics, admission thresholds, or the offline Stage 0/0.5 analyzers.

## Runtime data flow

```text
one SCStream, one shared serial callback queue
  .audio callback --------+--> original application writer + application live ASR
                           |
                           +--> extract/downmix 48 kHz render PCM --+
                                                                  |
  .microphone callback --> extract/downmix 48 kHz capture PCM -----+--> bounded PTS joiner
                                                                         |
                                               render 10 ms -> AEC3 <- capture 10 ms
                                                                         |
                                      timestamped processed or raw mic output
                                                                         |
                                    ordered provenance/output committer
                                           |                       |
                                  microphone writer        gated microphone live ASR
```

The application writer remains byte-for-byte on its current path. The AEC branch receives a copy.
The microphone writer moves behind the AEC output committer. There is no second persisted raw mic
track.

## Change map

Expected production changes (names may be refined without changing ownership):

- `Vendor/WebRTCAudioProcessing/`
  - pinned, minimal upstream source snapshot;
  - upstream `LICENSE`, `PATENTS`, `AUTHORS`, and all required third-party notices;
  - a local Swift package containing the upstream C++ and the C bridge;
  - a machine-readable revision/source-file hash manifest and a deterministic refresh script.
- `Sources/Fluid/Services/Meeting/AEC/FluidAECBridge.h/.cc`
  - preferably live inside the vendor package's bridge target, not the app target;
  - C ABI only; Swift never imports WebRTC C++ headers.
- `Sources/Fluid/Services/Meeting/AEC/MeetingAECModels.swift`
  - frame, format, state, failure, reset, provenance, and bounded diagnostics values.
- `Sources/Fluid/Services/Meeting/AEC/MeetingAECPCMAdapter.swift`
  - immediate `CMSampleBuffer` copy/extraction, explicit mono downmix, and output synthesis.
- `Sources/Fluid/Services/Meeting/AEC/MeetingAECStreamJoiner.swift`
  - the bounded common-PTS 10 ms slicer and discontinuity detector.
- `Sources/Fluid/Services/Meeting/AEC/MeetingAECProcessor.swift`
  - single-owner bridge lifecycle, warm-up, resets, and processed/bypass output.
- `Sources/Fluid/Services/Meeting/AEC/MeetingAECOutputCommitter.swift`
  - ordered writer/provenance/live-ASR handoff and fail-closed persistence.
- `Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift`
  - attach both SCK audio outputs to one serial callback queue; integrate lifecycle and route reset.
- `Sources/Fluid/Services/Meeting/MeetingModels.swift`
  - add `softwareEchoCancelled` and optional AEC provenance to capture eras.
- focused tests in `Tests/FluidDictationIntegrationTests/` and C++ package tests.
- `Package.swift` and `Fluid.xcodeproj/project.pbxproj` only for the local package/product and new
  Swift production/test sources.

Do not turn `MeetingReferenceSynchronizer`, `MeetingStage05SCKFrameAdapter`, or
`MeetingStage05MockAECSeam` into production streaming code. They are bounded offline/DEBUG seams
with different ownership and memory contracts. Reuse their tested vocabulary and invariants, not
their whole-array implementation.

## Phase 1 — pin and integrate the dependency

Use Google's WebRTC source, not an unpinned third-party binary. Select one exact upstream git
commit that is current when implementation begins and record the full commit hash. Never track a
moving branch, semantic range, Homebrew path, system-installed dylib, or downloaded binary without
a checksum.

The implementation agent should first build a tiny standalone bridge executable against that
commit for both `arm64` and `x86_64`. Use WebRTC's GN dependency graph to identify the complete
transitive source set for the built-in Audio Processing Module/AEC3. Then vendor the exact required
source and license set as a local Swift package so a clean repository build does not depend on a
developer's WebRTC checkout or network access. Avoid shipping the rest of libwebrtc.

The package contract is:

- static linkage only;
- macOS 15 minimum matching FluidVoice;
- C++17 or the exact newer standard required by the pinned revision;
- exceptions and RTTI configured exactly as required by upstream, recorded in the manifest;
- AEC dump/file output, tests, and examples absent; peer-connection, codecs, video, and network
  targets are absent only when they are not members of the pinned APM/AEC3 target's actual GN
  closure. Never call a manually subtracted graph the complete closure;
- use the pinned revision's actual GN closure as truth for protobuf: set the supported build option
  that removes protobuf when the closure permits it; if an otherwise required APM target retains a
  protobuf runtime dependency, vendor that exact minimal source and its notices while compiling
  out and unlinking every dump/write entry point. A runtime-disabled file API is not sufficient;
  verify the forbidden dump/write symbols are absent from the final binary. Never delete a
  required edge merely to claim “no protobuf”;
- no public C++ headers outside the package;
- no duplicate Abseil/field-trial symbols exported by the final app;
- reproducible source hashes and deterministic architecture settings;
- clean `arm64` and `x86_64` compile/link checks, plus a universal app linkage check;
- attribution copied into the app's shipped third-party notices if the app already has such a
  surface; otherwise add the smallest compliant bundled notice resource.

If a minimal source package cannot be made cleanly reproducible, stop at this phase and report the
dependency blocker. Do not silently substitute an old CocoaPod, a full unsigned WebRTC framework,
or an ad-hoc local archive.

## Phase 2 — C ABI around APM/AEC3

Expose an opaque engine with a narrow, allocation-free hot-path ABI. A representative interface is:

```c
typedef struct FVAEC3Engine FVAEC3Engine;

typedef enum {
  FV_AEC3_OK = 0,
  FV_AEC3_INVALID_ARGUMENT,
  FV_AEC3_INITIALIZATION_FAILED,
  FV_AEC3_PROCESSING_FAILED,
  FV_AEC3_NONFINITE_OUTPUT
} FVAEC3Status;

typedef struct {
  uint64_t render_frames;
  uint64_t capture_frames;
  uint64_t resets;
  int32_t estimated_delay_ms;       /* -1 when unavailable */
  float residual_echo_likelihood;   /* NaN when unavailable */
} FVAEC3Stats;

FVAEC3Engine *fv_aec3_create_48k_mono(void);
void fv_aec3_destroy(FVAEC3Engine *engine);
FVAEC3Status fv_aec3_reset(FVAEC3Engine *engine);
FVAEC3Status fv_aec3_process_10ms(
    FVAEC3Engine *engine,
    const float render[480],
    const float capture[480],
    float output[480],
    FVAEC3Stats *stats);
const char *fv_aec3_upstream_revision(void);
const char *fv_aec3_configuration_id(void);
```

Implementation requirements:

- build with `BuiltinAudioProcessingBuilder` and enable only `config.echo_canceller.enabled`;
- explicitly keep preamp, capture-level adjustment, AGC1/2, high-pass, noise suppression,
  transient suppression, and voice detection disabled for the first integration;
- configure mono capture and mono render at 48 kHz; float samples are deinterleaved and clamped to
  `[-1, 1]` only after rejecting NaN/infinity;
- invoke `ProcessReverseStream` before `ProcessStream` inside the single function so Swift cannot
  invert the order;
- do not provide `set_stream_delay_ms` from callback arrival time or the offline synchronizer's
  configured lag. Only add a delay hint later if it can be derived from the actual render/capture
  hardware timing definition required by WebRTC;
- rebuild/reinitialize the APM object on reset rather than assuming `Initialize()` erases every
  adaptive state relevant to a route/stream epoch;
- return standard processed capture audio. `GetLinearAecOutput()` can be exposed in C++ fixture
  tests, but it must not create a second product path or silently substitute a 16 kHz signal;
- allocate scratch buffers at creation. No heap allocation, logging, file I/O, lock acquisition,
  callback into Swift, or exception may cross the process function;
- make destroy/reset/process idempotence and invalid-pointer/length behavior explicit and tested.

## Phase 3 — streaming PCM and PTS joiner

Use one serial `DispatchQueue` as the `sampleHandlerQueue` for both `.audio` and `.microphone` on a
given `SCStream`. That establishes one callback-arrival order without claiming that arrival time is
media time. Every accepted callback is copied before return; application writer/live delivery may
still happen immediately after that copy.

Normalize each AEC input to non-interleaved mono Float32 at exactly 48 kHz:

- application audio uses an explicit arithmetic channel average;
- microphone input uses explicit downmix too, even though current paired SCK is observed as mono;
- require valid numeric PTS, positive frame count/duration, internally consistent ASBD geometry,
  finite samples, and duration within 1.5 source samples of `frames / sampleRate`;
- support the PCM layouts ScreenCaptureKit actually emits using `AVAudioPCMBuffer` copying. Any
  sample-rate change or unsupported layout is a reset/bypass boundary, not a reinterpret cast;
- if conversion is ever needed, keep one converter per input format and account for its complete
  algorithmic delay. The initial SCK configuration requests 48 kHz, so a non-48-kHz callback may
  conservatively bypass rather than introduce an unmeasured resampler.

The joiner first locks both sources to 48 kHz; any other rate is absent/unknown and resets. It then
chooses `T` as an actual first common source-sample PTS, never a rounded wall-clock boundary, and
maps later PTS onto a 48 kHz integer grid relative to `T`. Rounding error may be at most one sample.
It stores bounded per-stream interval queues and emits only complete common 480-sample windows. A
per-generation `MeetingAECClockAttestor` must establish and then continuously check all of the
following without looking at audio content or callback arrival time:

- both buffers came from the same accepted `SCStream` object and explicit runtime generation;
- both use valid numeric `CMTime` values with the same epoch and 48 kHz sample geometry;
- each source is independently monotonic and contiguous on its own PTS/sample-count line;
- over the half-open span `[T, T + 96_000/48_000)`, valid original render and capture callback
  intervals provide every one of the 96,000 source samples exactly once. Starting at the same `T`,
  those samples form exactly 200 adjacent 480-sample slots without edge rounding or loss. Received
  callback count and native callback block size are not coverage substitutes;
- each source keeps one epoch anchor and cumulative sample count. For every callback boundary, its
  actual PTS must be within one 48 kHz sample of `anchorPTS + cumulativeSamples / 48000`; error is
  always measured against the anchor, never accumulated from individually tolerated deltas;
- the inter-source grid residual stays within one sample for the whole attestation interval and on
  every later frame. A change in timescale alone is harmless after exact `CMTime` conversion, but
  an epoch, slope, intercept, coverage, or residual failure demotes and resets.

This is a runtime contract check inside the direct implementation, not a Stage 0.5 evidence gate.
It neither estimates acoustic delay nor calls `set_stream_delay_ms`. A generation that cannot
attest stays raw/unprotected for its lifetime; it does not “succeed” merely by processing 200 API
calls. “Exact common 10 ms pairs” always means adjacent covered timeline slots, not 200 successful
calls collected across holes. For each output window after the current grid is attested:

1. take the exact render interval for `[n, n + 480)`;
2. take the exact capture interval for `[n, n + 480)`;
3. call the bridge once, which consumes render then capture;
4. synthesize a fresh mono Float32 `CMSampleBuffer` with the capture window's original PTS and a
   1/48000 per-sample duration;
5. submit processed and original-capture forms to the output committer so it can make a durable
   protection decision without losing the raw fallback.

For a slice beginning `k` samples inside an original callback, derive its PTS exactly as
`callbackPTS + CMTime(value: k, timescale: 48000)` and require its entire coverage to come from the
original callback interval(s). Never mint a 10 ms timestamp from an output ordinal, callback
arrival time, or an assumed continuous counter.

Distinguish measured digital silence from missing data. A render callback whose actual PCM samples
are zero is valid far-end silence and is fed to APM normally; an interval not covered by any valid
render callback is unknown and must never be zero-filled merely because microphone PTS continued.
Unknown capture is emitted raw/unprotected. A true render or capture PTS gap, overlap, backward
step, format change, stream identity change, source sequence gap, non-finite input, or bound breach
ends the current epoch. Flush complete older windows, classify incomplete capture as
raw/unprotected, reset the APM, and start a new grid/attestation at the next well-formed pair. If a
macOS/SCK revision suppresses zero-valued render callbacks, the affected mic spans correctly stay
unprotected rather than converting absence into invented evidence. At stop, emit any retained
capture tail as raw/unprotected; do not pad it to 10 ms.

Initial hard bounds (constants with unit tests):

- at most 64 callback blocks or 24,000 samples (500 ms at 48 kHz) retained per input;
- at most 100 ms of capture waits for matching render PTS;
- at most one sample of PTS quantization disagreement;
- zero tolerance for overlapping accepted samples or non-finite PCM;
- the hot path must not enqueue onto an unbounded dispatch queue.

If the shared callback queue plus synchronous 10 ms processing cannot meet the performance gate,
move APM work to a bounded worker with explicit capacity and an ordered raw-fallback handoff. Do not
replace the bounds with an ordinary unbounded `queue.async` backlog.

## Phase 4 — durable provenance and ordered output

Extend `MeetingCaptureEra` with optional, backwards-compatible AEC provenance:

```swift
struct MeetingAECProvenance: Codable, Equatable, Sendable {
    var upstreamRevision: String
    var bridgeConfigurationID: String
    var sampleRateHz: Int
    var frameDurationMilliseconds: Int
}
```

`softwareEchoCancelled` admits transcript; `unprotected` does not. Old manifests continue to
decode exactly as they do now, and no migration rewrites a historical era as software-protected.

The output committer is the sole component allowed to pair a microphone sample with an era change.
It preserves this ordering:

```text
close live gate synchronously
  -> enqueue/persist era transition on the microphone writer's serial order
  -> enqueue the corresponding mic sample(s)
  -> open live gate only after successful promotion persistence
  -> offer only protected sample(s) to live mic ASR
```

Add a writer API that accepts an era transition and sample in the same writer-queue transaction, or
an equivalent sequenced command API. Do not race the current async `updateTrackMetadata` against a
separate `enqueue`. A demotion persistence failure is handled like the existing fail-closed route
metadata failure: keep in-memory state unprotected, keep live closed, emit one terminal interruption,
and stop capture so the returned track cannot resurrect optimistic provenance.

On speaker routes, a fresh AEC epoch has a two-second warm-up: 200 consecutive successful paired
10 ms calls, a passing common-clock attestation spanning those frames, no
discontinuity/reset/bound failure, and finite output. Warm-up output is persisted as processed audio
but its era remains `unprotected` and it is not sent to live mic ASR. The first post-warm-up frame
begins a durably persisted `softwareEchoCancelled` era. This is an engineering stabilization rule,
not a claim that optional APM statistics prove privacy.

On a positively classified headphone route, preserve the existing raw `acousticallyClosed` path;
do not construct or route through the AEC processor/committer, and verify byte-identical sample and
era behavior against today's `ScreenCaptureMeetingRuntime`. The VPIO runtime is a separate class
and likewise never constructs or calls the AEC components; verify its `voiceProcessed` samples and
eras are byte-identical at the integration seam. On all other ScreenCaptureKit routes, raw/bypass
output is `unprotected`.

## Phase 5 — `ScreenCaptureMeetingRuntime` integration and lifecycle

Add a pure `MeetingAECOutputRouteClassifier` with three dispositions:

- `physicallyClosed`: the existing positive headphone test returns `acousticallyClosed`;
- `supportedSpeaker`: two matching snapshots separated by the existing 0.75 s settle positively
  identify the built-in speaker (`deviceExists && isBuiltIn && !isHeadphonesDataSource`, no
  headphone terminal, not Bluetooth). Additional external speaker types require their own future
  positive test; they are not inferred from absence of a headphone flag;
- `ambiguous`: missing, changing, aggregate, Bluetooth, virtual, external-unknown, or otherwise
  unclassified. This stays byte-identical raw and `unprotected` and never constructs AEC.

Arm route observation before settling/classifying and before `startCapture`. Snapshot the route
revision with the first route value, wait, then accept the second value only if it matches and the
revision is unchanged. Under `stateLock`, reserve `.constructingAEC(routeGeneration:)`; build the
candidate outside the lock; commit it only if the generation and reservation still match. Any
route callback invalidates the reservation synchronously. A successful commit enters `.aecReady`,
not `.aecActive`. Recheck the route/stream/lifecycle token immediately before `startCapture`; while
the async start is in flight, every callback still takes the raw/unprotected path. Recheck again
after `startCapture` returns and enter `.aecArmedAwaitingFormats` only if the token and ready state
are unchanged. The shared callback queue keeps all mic raw/unprotected while it validates the first
actual render and capture format/CMTime observations. Only after both validate and the token remains
current may it atomically enter `.aecActive` and begin a fresh joiner/attestation with subsequent
samples. Thus no concurrent first frame can observe an active state before the first-format gate.
A failure at either recheck or first-format gate atomically clears `.aecReady`/armed state to
`.rawUnprotected`, detaches the candidate, and then destroys it serially; it must not leave a ready
shell pointing at an object pending destruction. A stale candidate is never called. An AEC object
may therefore become active only for the same route generation that produced both stable snapshots
and survived the whole start/first-format interval.
Physically closed and ambiguous paths preserve the original microphone bytes from their first
accepted callback.

Pin startup invalidation to a finite event set: output/input route revision, SCStream generation or
replacement, runtime stop/teardown generation, and the first accepted callback's format/CMTime
validation. Unit-test each event immediately before and after snapshot two, reservation, candidate
creation, commit, pre-start recheck, callbacks during async start, start completion, post-start
recheck, both first-format observations, and active transition. Format/CMTime failure while armed
demotes before calling the candidate and destroys/resets in serial order.

At construction:

- create the shared callback queue before attaching outputs;
- settle/classify the route; initialize the AEC pipeline before `startCapture` only for
  `supportedSpeaker`, while keeping transcript state unprotected;
- for `physicallyClosed` and `ambiguous`, keep the existing direct mic writer/gate path and do not
  create an AEC committer, joiner, or engine;
- route both output registrations to the same queue;
- provide the pipeline with the exact current stream generation, writers, event handler, and live
  handler. It must not retain application/window names or other PII.

In `didOutputSampleBuffer`:

- `.audio`: copy/feed render to AEC first, then preserve the current original application writer
  and live tee;
- `.microphone`: offer only to the AEC pipeline; remove the current direct microphone writer and
  direct live tee;
- keep the current stream-identity/stopping check before either action.

On output-route notification:

- close live admission synchronously at the existing conservative boundary;
- synchronously set the disposition to `ambiguous` so every callback during settling takes the
  byte-identical raw/unprotected path, then destroy/reset the old AEC in serial order;
- persist `unprotected` during settling; a newly supported speaker then creates a fresh engine and
  repeats attestation/warm-up, while an ambiguous route stays raw/unprotected;
- retain the existing 0.75 s settling and require two matching snapshots before selecting either
  `physicallyClosed` or `supportedSpeaker`; a nonmatching/unknown result remains ambiguous;
- do not allow the old raw-route code to reopen a speaker route merely because AEC exists;
- reset on both input and output route changes, because either invalidates the adaptive path.

On unexpected `SCStream` stop/rebuild:

- demote and reset before starting the replacement stream;
- use a new stream generation and reject callbacks from old/pending streams;
- do not carry render FIFO, capture FIFO, warm-up count, delay estimate, or APM state across the
  rebuild;
- promote only after the replacement stream's own warm-up;
- retain existing bounded rebuild attempts and interruption events.

On normal stop:

1. mark the runtime stopping and stop route observation;
2. stop SCK capture;
3. drain the shared callback queue;
4. flush complete pairs, emit capture tails raw/unprotected, and drain pending era commits;
5. destroy APM and return from runtime stop;
6. only then may `MeetingCaptureEngine` stop the writers and the live coordinator.

No pipeline task or callback may reference a writer after runtime stop returns.

## Phase 6 — tests before app installation

### C++ bridge tests

- create/destroy/reset and wrong pointer/geometry cases;
- silence, render-only, capture-only, finite maximum-amplitude, and non-finite rejection;
- deterministic delayed/attenuated linear echo after warm-up;
- near-end-only preservation and double-talk preservation;
- exact render-before-capture counters and reset clearing adaptive state;
- upstream revision/configuration strings match the vendored manifest.

For a deterministic 10-second synthetic fixture (`capture = nearEnd + delayedGain * render`), use
disjoint warm-up and measurement regions. In the final measurement region require at least 6 dB
echo reduction relative to raw capture, no NaN/infinity, no output beyond `[-1, 1]`, and no more
than 3 dB near-end RMS attenuation during double-talk. Treat these as regression floors, not a
claim about real-room performance.

### Swift unit tests

- stereo planar/interleaved render downmix and mono capture extraction;
- invalid ASBD, nonnumeric PTS, duration mismatch, NaN/infinity, rate/layout changes;
- arbitrary callback sizes split/reassembled into exact 480-sample frames;
- mic-first and render-first arrival produce identical PTS-ordered output;
- gaps, overlaps, backward PTS, one-sample boundary tolerance, >1-sample rejection;
- continuously delivered zero-valued render PCM is processed as measured far-end silence without
  demotion, reset, or warm-up restart;
- missing/late render coverage never becomes synthesized silence or protected mic;
- common-clock attestation locks 48 kHz and chooses an actual common sample PTS `T`; exactly 96,000
  original samples per source cover `[T, T+2)` once and form 200 adjacent slots, with each callback
  checked against one fixed anchor/cumulative-count equation within one sample for the whole span
  and continuously afterward;
- native 512-frame (and other non-480) callback blocks reblock without rounding `T`, losing edge
  samples, or satisfying coverage through callback counts;
- a 20 ms missing render interval cannot hide inside a percentage allowance or promote after 200
  nonadjacent successful calls;
- equal-looking PTS from different epochs/generations and stable-but-skewed/drifting grids cannot
  promote even after 200 successful bridge calls;
- every eligible frame records render then capture and never crosses an epoch;
- reset on route, format, stream generation, and discontinuity;
- 64-block/24,000-sample/100-ms bounds and deterministic overflow behavior;
- incomplete stop tail is raw/unprotected with its original PTS;
- processed and raw fallback buffers own their bytes beyond the callback lifetime.

### Provenance/output integration tests

- speaker startup writes an initial `unprotected` era;
- exactly 199 good frames do not promote; frame 201 begins only after the 200-frame warm-up;
- 200 calls without a passing clock attestation remain unprotected;
- persistence completion precedes first live mic offer;
- processed samples, never raw source samples, reach writer/live after promotion;
- a bridge failure atomically closes live, begins `unprotected`, writes raw in order, and resets;
- a persistence failure stops capture and the final in-memory track remains unprotected;
- route notification cuts admission conservatively and stale settle tasks cannot reopen it;
- headphones stay byte-identical/raw `acousticallyClosed` and never instantiate AEC; VPIO remains
  byte-identical/`voiceProcessed`; speaker return creates a fresh engine and attestation/warm-up;
- startup and route-change decision tables keep missing/changing/Bluetooth/aggregate/virtual/
  external-unknown routes raw/unprotected and prevent AEC construction until two settled snapshots
  positively identify the supported speaker;
- route/stream/lifecycle/first-format token tests invalidate candidate construction before/after
  snapshot two, reservation, candidate creation, commit, pre-start recheck, callbacks during async
  start, start completion, post-start recheck, each first-format observation, and active transition;
  `.aecReady`/`.aecArmedAwaitingFormats` callbacks stay raw/unprotected, two validated formats are
  required before active, and every failure clears the state before detached candidate destruction;
- stream rebuild rejects stale callbacks and cannot reuse old APM/FIFO/warm-up state;
- batch admission rejects every turn intersecting warm-up/bypass eras and admits only wholly
  protected eras under the existing indivisible-turn rule;
- legacy manifests and all existing VPIO/in-room tests remain unchanged.

### Build and runtime checks

- top-level Swift package build/test where supported;
- focused integration test target, then the complete meeting test suite;
- Debug and Release app builds for the active architecture;
- explicit `x86_64` compile/link build even on Apple Silicon, followed by `lipo -info`/`file` and
  `nm` checks proving both slices and no unresolved/duplicate WebRTC symbols;
- Release binary scan proving the DEBUG bypass/diagnostic harness is absent or inert;
- Instruments/signpost benchmark in Release: after warm-up, p99 bridge time below 5 ms per 10 ms
  pair, no single frame at or above 10 ms, bounded retained sample/block counts, and no monotonic
  memory growth over a 30-minute synthetic stream;
- `git diff --check`, source/license manifest verification, and a forbidden-artifact scan.

Do not create or use a new user recording to pass these checks. If a later real-room listening or
ASR evaluation is wanted, request it as a separate task after this code implementation.

## Phase 7 — direct enablement, rollback, and commit discipline

After all checks pass, the normal ScreenCaptureKit online-call speaker path constructs AEC3 by
default. There is no shadow mode and no release cohort. Keep one DEBUG-only
`FLUIDVOICE_DISABLE_AEC3=1` escape hatch that selects raw/unprotected recording for local diagnosis;
it must never mark the mic protected.

Rollback is one code revert: restore direct mic writer/gate handling in
`ScreenCaptureMeetingRuntime`, remove the local package/product and AEC sources, and leave the
existing VPIO/headphone/in-room behavior untouched. Existing manifests with
`softwareEchoCancelled` remain decodable even if a later build no longer produces that value.

The implementation commit allowlist is production source, tests, Xcode/Swift package wiring, the
vendored source/revision manifest, and legally required notices. Explicitly exclude this plan,
router transcripts, generated reports, WAV/audio/video, DerivedData, `.build`, profiler data, and
all pre-existing unrelated dirty-tree files. Do not stage or commit anything automatically unless
the user separately asks.

## GPT-5.3-Codex-Spark execution protocol

Implementation may be delegated through the local Codex CLI with:

```sh
codex exec \
  -m gpt-5.3-codex-spark \
  --approve-for-me \
  -C /Users/shreeram/Projects/FluidVoice \
  "Implement only Phase N of the reviewed direct AEC3 plan. Preserve the dirty tree. Do not commit."
```

Run one bounded phase per session, review its diff locally, and test it before sending the next
phase. The agent may edit only the phase's allowlisted source/tests/package files. It may not edit
this plan or existing Stage 0/0.5 artifacts, install/launch the app, create a recording, access
secrets, publish, or commit. Dependency network fetches and any app install remain explicit host
operations under the repository's normal approval/signing policy.

Before implementation starts, capture a path-specific `git status --short` baseline. After every
agent turn, compare the status and diff to that baseline, revert no user files, and reject any
out-of-scope output rather than staging it.

## Definition of done

Implementation is complete only when:

- the pinned source and legal provenance rebuild cleanly without an ambient WebRTC install;
- the APM bridge performs one render-before-capture 48 kHz mono call for each eligible 10 ms pair;
- every protected epoch has a continuously passing common-clock attestation; numeric PTS equality
  or successful APM return codes alone can never promote it;
- the speaker-route microphone writer and live ASR never receive raw audio during a protected era;
- no missing data, reset, warm-up frame, failure frame, or stale callback is marked protected;
- route/rebuild/stop transitions are durably ordered with samples and leave no background owner;
- synthetic echo/double-talk, all bounds, failure-injection, legacy, and batch-admission tests pass;
- arm64 and x86_64 Debug/Release linkage and the Release real-time/memory gates pass;
- adversarial review has no unresolved P0/P1 finding; and
- only the explicit implementation allowlist is eligible for a later user-requested commit.

## Adversarial review disposition

The standard router served Grok 4.6 read-only and reported `editedTree=false` on every completed
attempt. The initial repository-reading attempt and the first self-contained retry reached the
router's primary time limit; the latter still returned a usable partial `REVISE` verdict. Bounded
delta rechecks then completed normally.

The review's blocking findings and dispositions were:

- **Missing render versus silence:** the first draft risked continuous demote/reset behavior if SCK
  omitted far-end callbacks. The final contract distinguishes zero-valued samples delivered inside
  valid callbacks (measured silence) from uncovered time (unknown). Unknown is never fabricated as
  zeros or protected. The suggestion to infer zeros solely from continuing mic PTS was rejected as
  unsafe; tests cover both cases.
- **PTS was not a clock proof:** successful APM calls and numerically equal PTS can no longer
  promote. The final contract adds the fixed-anchor, same-generation `CMTime` attestation with
  complete original-sample coverage over `[T,T+2)`, exact adjacent reblocking, one-sample total
  residual, and continuing checks.
- **Warm-up coverage ambiguity:** the draft's 99% allowance was removed. All 96,000 render and
  capture samples must be present exactly once in 200 adjacent slots; non-480 native callbacks and
  missing-slot cases are explicit tests.
- **Headphone/startup races:** AEC is constructed only for a positively settled supported speaker.
  Ambiguous and physically closed routes remain byte-identical raw. A route-generation reservation,
  pre/post-`startCapture` checks, an armed first-format state, and atomic clear-before-destroy rules
  close snapshot, construction, async-start, and first-callback races.
- **Dependency closure:** the pinned GN graph, not an aspirational subsystem list, defines the
  vendored source. Required protobuf is retained with notices if the pin cannot remove it, while
  AEC dump/write code must be compiled out, unlinked, and absent from the final symbol scan.
- **Timestamp provenance:** every 10 ms slice derives its PTS from the original callback plus the
  exact source-sample offset; ordinal/arrival/synthetic timestamps are forbidden.

The final delta review returned **PASS**, `P0: none`, `P1: none`, and `editedTree=false`. Its sole P2
was incorporated: post-start state remains armed/raw until both first formats validate, and every
failed recheck clears the ready/armed state before serially destroying the detached candidate.
