# Stage 0.5 paired ScreenCaptureKit evidence

This is a DEBUG-only, one-shot capture harness for the signal-domain gate. It is not a
production capture path and it does not start unless all of the following are set:

```text
FLUIDVOICE_STAGE05_EVIDENCE=1
FLUIDVOICE_STAGE05_EVIDENCE_AUTORUN=1
FLUIDVOICE_STAGE05_TARGET_BUNDLE_ID=com.google.Chrome
FLUIDVOICE_STAGE05_EVIDENCE_CONSENT=I_CONFIRM_STAGE05_RECORDING_CONSENT
FLUIDVOICE_STAGE05_EVIDENCE_ROOT=/private/tmp/fv-stage05-evidence.<unique-suffix>
FLUIDVOICE_STAGE05_FIXTURE_PATH=<absolute path to the checked-in stimulus HTML>
```

For the separately consented operator-media variant, the fixture path instead identifies the
checked-in operator-media descriptor and this additional exact token is required:

```text
FLUIDVOICE_STAGE05_OPERATOR_MEDIA_CONSENT=I_CONFIRM_OPERATOR_CONTROLLED_WEB_MEDIA
```

That variant selects exactly one live Chrome window with a nonzero ScreenCaptureKit window ID and
a finite frame of at least 640 by 360 points. It retains the exact Chrome bundle/PID and selected-
window filter checks, but neither reads nor persists a page title or URL. Zero or multiple eligible
windows fail before capture. The same route, volume, duration, format, privacy, cleanup, and hard
watchdog gates apply.

Open the controlled Chrome stimulus in its `FluidVoice C2 Diagnostic Stimulus — READY` state.
After the harness emits the generic `{"status":"ready"}` line, click Start; it then requires
that same window/owner/PID to transition to exactly one matching
`FluidVoice C2 Diagnostic Stimulus — PLAYING — 22s` (or greater) window and a unique display
intersection.
The READY-to-PLAYING operator-response window is limited to thirty seconds; no stream or audio
capture exists during that wait. Once playback starts, the exact title must still report at least
22 seconds remaining. A separate 56-second hard process
watchdog leaves margin around the declared start/stop budgets without changing the fourteen-second
target or twenty-second frame ceiling. Fixed-name emergency cleanup is registered before either WAV is created.
It requires Screen Recording and microphone permission, the default built-in speakers, and the
default built-in microphone; exact input/output UIDs and the route are rechecked after capture.
It captures one fourteen-second `SCStream` with `.audio` and
`.microphone`, requesting mono at 48 kHz. Every callback is checked against its actual native
ASBD; no resampling, downmixing, or float-to-integer conversion is performed. The runtime accepts
only little-endian mono packed IEEE float32 at 48 kHz. Float samples must all be finite. A format
change, stereo/non-PCM callback, missing timing, gap, overlap, or
resource bound failure invalidates the run.

On success the private root contains `render.wav`, `capture.wav`, `provenance.json`, and `manifest.json`. WAV payload
bytes preserve the native callback bytes. The manifest stores relative artifact names, SHA-256
hashes, codec/geometry, and per-callback presentation time, duration, frame count, and monotonic
arrival time. The provenance sidecar contains only hashes (including the exact capture executable
and fixture), build/configuration identity, the validated route and volume, peaks, and counts; it contains no PCM, transcript text, window title, URL,
device name, UID, or absolute path. The output line is only a generic status. Existing
`MeetingSignalDomainGate.loadManifest(from:)` and `evaluate(manifest:sessions:)` consume this
manifest; no AEC dependency or production behavior is enabled by the harness.

The root must be a uniquely suffixed `/private/tmp/fv-stage05-evidence.*` path to a new or empty
mode-0700 directory and must not contain the
fixed artifact names. Failed runs
remove partial WAV/manifest artifacts. Do not point the harness at a production recording store,
cloud-synced directory, or a corpus without consent from every participant.

## Observed run — 2026-09-10

One controlled run completed successfully at the capture layer. The private mode-0700 root
contained four mode-0600 artifacts. Numeric provenance recorded 280 render blocks / 268,800
frames and 521 microphone blocks / 266,752 frames; output volume remained 0.25, render peak was
0.036000002, and microphone peak was 0.06660158. Hash, schema, route, format, consent, and timing
validation passed. PCM was not played, transcribed, or copied into the repository.

The privacy-safe gate result is `meeting_playback_stage05_builtin_2026-09-10.json`. The session
was rejected for `lowExcitation`, `driftUnscored`, and `linearPathUnlearnable`. Five seconds at the
registered 1 kHz delay-tracker resolution cannot substantiate the frozen 100-ppm drift bound. The
user also reported possible incidental noise, so the result does not establish a general failure
of paired SCK; it establishes only that this session cannot authorize candidate/AEC3 work.

## Longer clean calibration — 2026-09-10

A stationary broadband fixture was tried in a user-confirmed quiet window. The first longer run
failed closed at the 960,000-frame ceiling because repeated relative sleeps accumulated scheduler
delay. The harness now uses an absolute monotonic deadline, targets fourteen seconds, and reports
only fixed privacy-safe finalization categories. The corrected run reached
`finalizeRenderTiming`: the selected-window render callbacks did not satisfy the frozen contiguous
timing invariant over the longer window. Both failed runs removed every partial artifact; no PCM,
manifest, or report was retained.

This result does not establish that acoustic echo cancellation is impossible. It establishes that
the raw selected-window ScreenCaptureKit reference cannot yet authorize an echo-canceller trial:
an explicitly tested synchronizer would first need to preserve and handle the observed render
timing discontinuity without flattening or inventing samples.

The offline synchronizer follow-up replays 1,400 ten-millisecond render and microphone blocks
with a two-millisecond reference PTS jump at the midpoint. The test initially exposed that the
gap mask was correct but the adaptation-freeze and resynchronization-boundary controls were not
set. The synchronizer now freezes adaptation for incomplete coverage or a reset boundary, marks
the PTS-jump boundary explicitly, keeps the 32 missing analysis samples invalid, and resumes in a
new epoch. The full 47-test synchronizer suite and combined 61-test Stage 0.5 suite pass. This is
offline evidence only; it does not authorize or enable a production echo canceller.

## DEBUG callback adapter and mock seam — 2026-09-11

`MeetingStage05SCKFrameAdapter` is a DEBUG-only, bounded bridge for native ScreenCaptureKit
`CMSampleBuffer` callbacks. It keeps callback PTS, monotonic arrival time, and independent
per-track arrival sequence as separate facts. It maps render callbacks to reference PTS and maps
microphone callback PTS to source sample time; it never derives either clock from concatenated WAV
length. Unsupported formats/rates, non-finite samples, invalid geometry, and resource overruns are
rejected. Gaps, overlaps, backward timestamps, discontinuities, and rejected-callback sequence
holes remain visible to the pure synchronizer.

`MeetingStage05MockAECSeam` is an identity contract checker, not an echo canceller. It returns the
synchronized sample arrays unchanged, authorizes nothing for failed-open, empty, or structurally
invalid results, resets once per epoch boundary, freezes every incomplete/reset hop, and emits an
eligible hop's render event before its capture event. A boundary that falls partway through a hop
cannot cause a second reset when the integer epoch label advances on the next hop.

The synthetic 48 kHz matrix covers contiguous callbacks; one-sample, 2 ms, 10 ms, and 100 ms
gaps; repeated gaps; overlaps and backward timestamps; discontinuities; rejected callbacks;
format/rate failures; bounds; drift; deterministic replay; and native `CMSampleBuffer` extraction.
A 2 ms internal hole maps to exactly 32 invalid samples at 16 kHz. Unmatched leading or trailing
track coverage remains separately invalid and is not miscounted as part of that internal hole.

For a completed `renderTiming` or `captureTiming` finalization failure only, the DEBUG evidence
collector now deletes both WAVs plus manifest/provenance and may retain one exclusive mode-0600
`timing.json`. That versioned record contains numeric callback timing/geometry and derived counts
only—no PCM, peaks, hashes, UIDs, PIDs, titles, paths, labels, transcripts, or provenance. All
other failures, cancellation, abort, and watchdog cleanup retain nothing. The existing contiguous
WAV success gate is unchanged.

This implementation has not run another browser, speaker, or microphone capture and does not add
AEC3 or any production meeting-runtime behavior. The separately reviewed implementation plan is
`MEETING_STAGE05_LIVE_ADAPTER_IMPLEMENTATION_PLAN.md`.

Final offline verification passed on 2026-09-11: 89 signed Swift tests (47 synchronizer, 14
evidence-harness, 4 timing-record, and 24 adapter/mock-seam), 19 Python signal-gate tests, Python
bytecode compilation, and the unsigned Release build. A symbol/string scan of the Release binary
found none of the Stage 0.5 adapter, mock seam, timing-record, autorun, or diagnostic-gate symbols.
The final read-only Grok 4.6 adversarial review returned PASS with no P0/P1 finding after verifying
the DEBUG isolation, resynchronization naming/gating, bounded `Int64` conversion, fail-open mock
behavior, and timing-only artifact lifecycle.

## Real callback attachment — 2026-09-11

The DEBUG-only Stage 0.5 evidence stream now feeds each real ScreenCaptureKit `.audio` and
`.microphone` callback to both the existing WAV collector and `MeetingStage05SCKFrameAdapter`.
It samples the monotonic arrival clock exactly once at the callback boundary and shares that value
between both consumers. Other SCStream output types are ignored without sampling the clock.

After `stopCapture`, the dedicated render and microphone queues are both drained synchronously.
Only then is the adapter drained and synchronized once and the identity/mock AEC seam processed
once. A structural synchronization or ordering failure deletes all PCM and returns the fixed
`adapterGate` failure. Gaps that are safely masked and frozen remain valid diagnostic evidence but
cannot set `eligibleForAECTrial`.

The one-shot stdout outcome now includes a bounded `adapter` object containing integers, Booleans,
and one finite drift value only. It reports callback anomaly counts, synchronizer resource and mask
counts, and mock reset/freeze/order counts. It contains no callback timestamps, PCM, peaks,
identifiers, hashes, PIDs, titles, paths, labels, transcripts, or provenance. This does not create a
new file or weaken the mutually exclusive WAV-success and timing-only-failure artifact states.

Offline verification passed 94 signed Swift tests: 47 synchronizer, 14 evidence-harness, 4 timing
record, 24 adapter/mock-seam, and 5 real-callback/summary tests. Grok 4.6's read-only adversarial
review returned PASS with no P0/P1 blocker for one separately cued controlled calibration. No live
capture, stimulus, app reinstall, or AEC was performed as part of this implementation step.

## Controlled real-callback calibration — 2026-09-11

One separately cued fourteen-second run completed the strict PCM collector successfully. The
private mode-0700 root contains four original mode-0600 evidence artifacts plus the mode-0600
offline report; PCM was not played, transcribed, or copied into the repository. Numeric provenance
recorded 702 render callbacks / 673,920 native frames and 1,313 microphone callbacks / 672,256
native frames. Output volume remained 0.25, render peak was 0.037170984, and microphone peak was
0.03196026.

The privacy-safe callback result is `meeting_stage05_live_adapter_builtin_2026-09-11.json`.
Every callback was accepted with zero reported gap, overlap, backward-timestamp, discontinuity,
or format-change events. The synchronizer and mock seam remained structurally closed and preserved
render-before-capture ordering. The simultaneous stop left 555 unmatched 16 kHz microphone-tail
samples, so four edge analysis frames were masked and frozen; `eligibleForAECTrial` is therefore
false despite collector success.

The frozen signal-gate result is `meeting_playback_stage05_builtin_2026-09-11.json`. It rejects
this session for `delayUnresolved`, `driftUnscored`, `unstablePath`, and
`linearPathUnlearnable`. Common-span diagnostics found healthy excitation RMS (0.0110116), zero
clipping, strong low/mid/high band coherence (0.956881 / 0.916681 / 0.515547), but no sufficiently
prominent delay observation and a held-out linear residual of 0.777411 against the frozen 0.75
ceiling. The analyzer already uses the common render/capture span, so merely copying or trimming
the WAVs would not change this result. Grok 4.6's read-only result review returned BLOCK for any
AEC3 dependency or live trial. The retained corpus is suitable for offline delay-estimator and
path-model investigation only; no additional capture is authorized by this result.

## Offline delay-estimator implementation — 2026-09-11

The offline analyzer now separates acoustic array lag, callback PTS offset, and render lead. A
whole-span non-overlapping energy-envelope anchor narrows a mean-removed/first-differenced 4 kHz
search, followed by native-rate refinement. Five-to-eight local windows cover the complete
analyzable span; every scheduled window must resolve, and all long-baseline slope uncertainty
intervals must remain inside the frozen drift ceiling. Missing delay, drift, alignment, coverage,
or path evidence is ineligible rather than zero-valued.

The native refinement uses a maximum three-bin 4 kHz neighborhood. A one-bin neighborhood was
tested and rejected because ordinary +/-50 ppm affine fixtures spread the three-second
box-decimated peak across adjacent bins and falsely failed at the final scheduled window. The
wider native search remains downstream of the unchanged score/prominence ambiguity gate and still
requires an interior maximum with at least half-native-sample uncertainty.

Aligned samples now come only from the measured affine common support; no edge is padded, repeated,
or clamped. Coherence and path scoring share that support. The 64 ms/256-tap path remains bounded,
uses fixed train-only NLMS passes, and reports the worse of disjoint validation and final held-out
residuals against the unchanged 0.75 ceiling.

Offline regression coverage now includes periodic and equal-peak ambiguity, full-span required
windows, resolved late outliers, +/-50 ppm drift, outside-limit drift, signed acoustic/PTS/render-
lead combinations, measured-support coverage, short-resolution failure, a fixed 64 ms FIR, and all
existing manifest/privacy/no-overwrite contracts. The frozen implementation passed 8 Stage 0 and
21 Stage 0.5 Python tests, bytecode compilation, whitespace checks, and an unsigned Release build.
Grok 4.6's final routed implementation-contract review returned PASS with no P0/P1 finding.

The retained private corpus was then replayed exactly once into a new exclusive mode-0600 report.
The privacy-safe repository summary is
`meeting_playback_stage05_delay_estimator_builtin_2026-09-11.json`. The new estimator preserved
the ambiguity stop: it resolved no delay, so drift, measured-support alignment, coverage, and path
metrics remained unscored. The aggregate outcome is `rejected`, with one count each for
`delayUnresolved`, `driftUnscored`, `insufficientCoverage`, `unstablePath`,
`linearPathUnscored`, and `noEligibleSessions`. The analyzer source SHA-256 was
`3379f9a36fdda278e47ac64af8fe7c7e3fc0fd583bb8518e25e793d85cbf7336`; the Stage 0.5 test SHA-256
was `602f6c85632e3cdc90fd539f056d8dd3a1f4b587599311f51dea580b2897e313`.

No PCM was played, transcribed, copied to the repository, or captured again. The one-replay stop
condition is now closed. The acoustic gate and the separate callback-adapter gate are both false,
so AEC3 remains blocked. Any next evidence attempt requires a separately reviewed fixture redesign
and a newly authorized capture; it is not an automatic continuation of this phase.

## Operator-controlled speech capture — 2026-09-11

After separate user authorization, one fourteen-second operator-media capture completed. Earlier
selection and setup refusals retained no artifacts; one out-of-bounds finalization attempt also
aborted and removed its partial corpus. The successful private mode-0700 root contains only the
four original mode-0600 evidence files and two immutable mode-0600 analyzer reports. Playback was
paused immediately afterward, and the temporary system-volume reduction was restored.

The successful callback stream had 703 accepted render callbacks and 1,313 accepted microphone
callbacks, with no rejected callback, gap, overlap, backward timestamp, discontinuity, format
change, resource failure, late/duplicate frame, non-finite sample, synthesized microphone frame,
or failed-open state. Synchronization produced 224,960 samples per track; all render samples and
224,085 microphone samples were valid. Six edge analysis frames were frozen, so the separate
callback-adapter `eligibleForAECTrial` value remains false even though the mock identity contract
processed 1,400 frames with render-before-capture ordering.

The first offline invocation produced an immutable `invalidManifest` report because the analyzer
recognized only the original broadband fixture digest. The narrow fix replaces that equality with
an immutable two-entry allowlist containing the broadband fixture and the exact checked-in
operator-media descriptor; an unknown valid-looking digest is still rejected. The corrected
invocation accepted the manifest and performed the only signal analysis of this corpus. It rejected
the session for `delayUnresolved`, `driftUnscored`, `insufficientCoverage`, `unstablePath`, and
`linearPathUnscored`, with `noEligibleSessions` at the aggregate level. No metric was fabricated
after the acoustic delay remained ambiguous.

The bounded repository record is `meeting_stage05_operator_media_2026-09-11.json`. The analyzer
and its 21-test suite passed locally after the allowlist change. No PCM was played back by the
analyzer, transcribed, copied, uploaded, or committed; the record contains no title, URL, identity,
path, or content. Both the acoustic gate and callback-adapter gate are false, so AEC3 remains
blocked and no further live capture follows from this result.
