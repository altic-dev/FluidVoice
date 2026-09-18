# Stage 0.5 live-callback adapter implementation plan

## Decision

Implement a DEBUG-only bridge from bounded ScreenCaptureKit callback buffers into the existing
offline `MeetingReferenceSynchronizer`, followed by an identity/mock AEC contract checker. This
phase does not add an echo canceller, alter production capture, or run a live microphone test.

The previous long controlled capture failed because the selected-window render callback timeline
was discontinuous. Concatenating those callback bytes would erase the gap and create a false clock.
The adapter therefore places every block from its presentation timestamp, preserves discontinuity
evidence, and lets the synchronizer produce explicit invalid masks, epochs, freezes, and resets.

## Scope and order

### 1. Add a testable ScreenCaptureKit frame adapter

Add `MeetingStage05SCKFrameAdapter.swift` behind `#if DEBUG`.

- Validate callback PCM and ASBD without writing files: native packed mono Float32, finite samples,
  finite nonnegative timing, bounded geometry, and an exact supported sample rate.
- Map render callbacks to `MeetingReferencePCMFrame` using callback PTS as `presentationTime`.
- Map microphone callbacks to `MeetingMicrophonePCMFrame` using PTS converted to the sample-rate
  timescale as `sampleTime`; never use cumulative samples written.
- Record callback arrival time separately as microphone `hostTime`.
- Maintain independent render and microphone sequence spaces because callbacks arrive on separate
  serial queues.
- Detect one-sample-or-larger PTS gaps, overlaps/backward timestamps, explicit discontinuity
  attachments, and format/rate transitions. Preserve overlapping/late blocks as synchronizer inputs
  and diagnostics; the synchronizer remains responsible for first-arrival-wins rejection.
- Inject a route identifier from the caller. The adapter must not infer or log a device identity.
- Collect bounded arrays and call the pure synchronizer only after both callback queues are drained.

### 2. Add an identity/mock AEC seam

Add `MeetingStage05MockAECSeam.swift` behind `#if DEBUG`.

- Consume `MeetingSynchronizationResult` and return audio arrays unchanged.
- Emit only numeric observations plus `MeetingAECDelayContractEvent` ordering events.
- For each synchronized hop, handle an epoch change or resynchronization boundary before any normal
  processing, freeze on every incomplete mask or `adaptationFrozen` hop, and emit render before
  capture for eligible hops.
- Never resample, delay, scale, suppress, synthesize, or replace audio.
- Treat a failed-open, empty, or structurally invalid synchronization result as a no-op that
  cannot authorize processing.

### 3. Retain privacy-safe timing evidence only on completed timing failures

Extend the DEBUG Stage 0.5 collector with a separate versioned timing-failure record.

- The successful WAV path remains unchanged and continues to reject any timing gap or overlap.
- Only completed `.renderTiming` or `.captureTiming` finalization may retain `timing.json`.
- Before writing it, close and unlink both WAV files, manifest, and provenance.
- Create `timing.json` atomically/exclusively with mode `0600` inside the existing validated private
  `/private/tmp/fv-stage05-evidence.*` root.
- Store numeric callback timing and derived counts only: schema, fixed failure category, track,
  presentation time, duration, frame count, arrival time, and gap/overlap/backward/format-change
  counts. Do not store PCM, peaks, hashes of PCM, UIDs, PIDs, titles, paths, labels, transcripts, or
  executable/fixture provenance.
- All non-timing failures retain nothing. Cancellation, timeout, watchdog, and emergency cleanup
  must delete `timing.json` as well as the existing artifacts.
- Enforce mutual exclusion: either successful WAV evidence exists or a timing-only failure record
  exists, never both.

### 4. Add deterministic offline tests

Use synthetic `CMSampleBuffer` values or constructed adapter frames only. Tests must never create an
`SCStream`, open Chrome, access a microphone, or install an app.

Cover:

- contiguous paired callbacks and causal render-before-capture events;
- render and microphone gaps of 1 sample, 2 ms, 10 ms, 100 ms, and multiple hops;
- repeated gaps separated by a valid island;
- 1-sample, half-frame, and duplicate-timestamp overlaps;
- sequence disorder and forward sequence with backward PTS;
- explicit discontinuity with otherwise contiguous timing;
- sample-rate/format and route transitions;
- bounded drift cases already supported by the synchronizer configuration, including fail-open and
  failed-open thresholds without estimating drift from SCK callback PTS;
- exact invalid-sample masks, adaptation freezes, resynchronization boundaries, epoch changes, and
  deterministic replay;
- mock-seam audio equality and event ordering;
- timing-only retention, non-timing cleanup, watchdog cleanup, file modes, schema validation, and a
  forbidden-key/privacy scan.

### 5. Document and verify

- Update `MEETING_STAGE05_EVIDENCE.md` to distinguish contiguous WAV evidence from timing-only
  failure characterization and to state that the mock seam performs no cancellation.
- Add any explicit test file references required by `Fluid.xcodeproj/project.pbxproj`.
- Run the focused synchronizer, Stage 0.5 evidence, adapter, and mock-seam tests; run a signed DEBUG
  build and an unsigned Release compile check; run `git diff --check`.
- Do not reinstall the app and do not run live audio in this phase.

## Non-negotiable invariants

1. Callback PTS, callback arrival time, sequence order, and sample placement remain distinct facts.
2. Gaps become invalid masks and reasons, never valid zero-valued silence.
3. First arrival wins; overlaps and late blocks cannot overwrite accepted samples.
4. Epoch/reset and a missing interval are separate concepts; a contiguous discontinuity may reset
   without inventing a gap.
5. Exactly one component owns each operation: the adapter validates/places callbacks, the
   synchronizer maps clocks and masks coverage, and the mock seam checks AEC-facing ordering.
6. No component in this phase owns acoustic delay or estimates clock drift from paired SCK PTS.
7. Resource limits remain bounded by the existing 2,000-block and 960,000-frame ceilings.
8. Release and normal runtime behavior do not change.

## Acceptance criteria

- New adapter and mock seam are DEBUG-only and absent from Release compilation symbols.
- An adapter-driven 2 ms render jump yields exactly 32 invalid 16 kHz render samples inside the
  internal gap (independent unmatched track tails remain separately invalid), freezes adaptation,
  creates a resynchronization boundary/new epoch, and resumes valid output.
- Contiguous mock events validate as render then capture; gaps/resets never produce capture-first
  processing; all input/output audio arrays compare equal.
- A timing-finalization failure leaves only a valid mode-`0600` numeric `timing.json`; every PCM,
  manifest, and provenance artifact is absent. Other failures leave no timing artifact.
- Existing synchronizer and Stage 0.5 tests remain green, the WAV success gate remains contiguous,
  and no AEC/WebRTC dependency or production path is added.

## Explicitly out of scope

- Live microphone, browser stimulus, ScreenCaptureKit capture, app installation, or privacy prompts.
- AEC3/WebRTC or any audio-transforming canceller.
- Acoustic delay measurement, render-lead tuning, or shared-clock calibration.
- Treating gapped/metadata-only evidence as a successful signal-domain gate.
- Production meeting-runtime wiring, streaming synchronization, or changes to ASR, export,
  attribution, speaker profiles, or user-visible behavior.
