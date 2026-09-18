# Reference-aware microphone de-echo and speech preservation

Date: 2026-09-09 (local)
Status: revision 2 after adversarial review. Implementation plan only. No runtime behavior, installed app, recording, transcript, or speaker profile is changed by this document.

## Decision

The recommended solution is a **post-capture, reference-aware echo-cancellation and attribution pipeline** that consumes the selected application's clean-within-scope ScreenCaptureKit audio as a far-end/render reference and produces a derived microphone residual for ASR. Preserve the recorded microphone and application tracks unchanged; speaker-profile enrollment remains limited to verified clean no-playback microphone intervals in the first release.

Do not try to fix this by lowering the existing correlation threshold, adding a louder VAD cutoff, trusting the `voiceProcessingEnabled` flag, or building a new echo canceller from a single transfer-function estimate. The controlled development recordings show that the current waveform detector and current spectral scorer do not identify this residual reliably. A speech VAD also fires on leaked playback and therefore cannot identify near-end speech by itself.

The solution order is: **(1) fix or rule out FluidVoice's current Apple VPIO configuration, (2) evaluate ScreenCaptureKit's already-implemented paired microphone/application stream, then (3) evaluate a pinned, minimal WebRTC Audio Processing Module / AEC3 wrapper on the winning raw topology.** Cascading AEC3 after the current VPIO output is a fallback experiment, not the preferred input: Apple's nonlinear suppressor/AGC may have removed the linear relationship AEC3 needs. A smaller native Swift/Accelerate multi-band attribution detector is the required comparison and an independent enforcement guard, but it is not the place to recreate a production adaptive echo canceller. If no candidate preserves quiet double-talk on FluidVoice's actual streams, enforcement remains off.

This plan supersedes the feature-selection parts of `MEETING_MICROPHONE_ADMISSION_IMPLEMENTATION_PLAN.md`; its evidence contracts and profile-integrity rules remain applicable. The earlier B1/B2/B3 work is retained as a baseline and regression harness, not promoted to production.

Review record: `tools/MEETING_PLAYBACK_ATTRIBUTION_V2_ADVERSARIAL_REVIEW.md` documents the Claude Opus 5, Kimi K3, and Grok 4.6 findings and their revision-2 dispositions.

## 1. What is established, and what is still a hypothesis

### Established locally

- FluidVoice's preferred built-in-speaker online-call path enables voice processing on an `AVAudioEngine` input node, records a tap from that node, and separately captures selected-application audio with ScreenCaptureKit. Its fallback runtime already captures ScreenCaptureKit `.audio` and `.microphone` outputs from one `SCStream`, but marks speaker-route microphone audio unprotected and therefore does not admit it to transcription.
- The selected application's audio does not enter FluidVoice through an app-owned `AVAudioEngine` render source. It arrives through the ScreenCaptureKit `.audio` output.
- On the five controlled recordings made with speakers and no other nearby talker, the playback-only recording still produced four visible microphone-attributed segments and 49 words.
- The existing B1 two-second raw waveform detector produced zero `duplicateSupported` windows across all eight development recordings, including all five controlled recordings.
- The existing `MeetingEchoSignalScorer` already estimates delay with GCC-PHAT and fits a blockwise frequency-domain transfer function. On the controlled playback-only and overlap data, its explained fractions were generally near zero and it frequently returned the legacy low-explanation rescue. Its failure is therefore not fixed by merely adding “adaptive filter” terminology or reducing the B1 NCC threshold.
- Silero VAD activity remains present in playback-only recordings. It is speech activity evidence, not speaker-source evidence.

### Apple behavior that is documented

Apple describes AVAudioEngine voice processing as intended for echo cancellation and VoIP. Enabling it switches both I/O nodes into voice-processing mode, and it is available only when rendering to an audio device. Apple also says AUVoiceIO and AVAudioEngine expose the same voice-processing capabilities and that FaceTime and Phone use these APIs. The processing includes echo cancellation, noise suppression, and AGC and is device-tuned:

- [What's New in AVAudioEngine, WWDC19](https://developer.apple.com/videos/play/wwdc2019/510/)
- [What's new in voice processing, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/)
- [`AVAudioIONode`](https://developer.apple.com/documentation/avfaudio/avaudioionode)
- [`kAUVoiceIOProperty_BypassVoiceProcessing`](https://developer.apple.com/documentation/audiotoolbox/kauvoiceioproperty_bypassvoiceprocessing)
- [`AVAudioInputNode.isVoiceProcessingAGCEnabled`](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingagcenabled)

ScreenCaptureKit provides audio sample buffers separately from microphone output and exposes their configured sample format. It does not document a public API for supplying an arbitrary ScreenCaptureKit stream as the far-end reference of AUVoiceIO/AVAudioEngine:

- [`SCStreamOutputType`](https://developer.apple.com/documentation/screencapturekit/scstreamoutputtype)
- [`SCStreamOutputType.audio`](https://developer.apple.com/documentation/screencapturekit/scstreamoutputtype/audio)
- [`SCStreamOutput`](https://developer.apple.com/documentation/screencapturekit/scstreamoutput)
- [`SCStreamConfiguration.capturesAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)

### Important unresolved point

Apple's public material does **not** specify enough to assert that macOS VPIO either does or does not use the system-wide output mix from other processes as an echo reference. WWDC19's phrase “audio that is coming from the device” is broader than “audio rendered by this engine,” while its same-I/O-path examples are VoIP-oriented. Therefore:

- treat “Chrome never reaches the VPIO reference” as a plausible architectural hypothesis, not a fact;
- do not infer correct AEC from `isVoiceProcessingEnabled == true`;
- measure the actual behavior on the supported Mac/device/route matrix before changing capture architecture.

FaceTime owns its remote-media receive path and is documented to use Apple's voice processing. A conventional WhatsApp-style VoIP client likewise owns both render and capture streams, but WhatsApp's current proprietary audio implementation is not publicly verified here. Do not claim that its internal AEC is identical to FaceTime or to a particular WebRTC revision.

## 2. Why the current approaches are insufficient

### Voice processing is a useful first layer, not proof of clean microphone audio

`MeetingMicrophoneCapture` requests VPIO, configures other-audio ducking, taps processed input, and records settled device metadata. It binds and reads back audio-unit element 1 (input), but does not bind or persist element 0 (output); the source comments already note that element 0 once read back an unrelated AirPods output. It also persists `voiceProcessingEnabled: true` as a literal after the setter succeeds rather than persisting the getter/readback, and it does not persist bypass or AGC readbacks. The engine has no explicit application render source. These are strong configuration hypotheses, not proof of causality. The controlled recording is direct evidence only that the resulting track can still contain ASR-visible playback.

### B1 waveform correlation assumes too much signal similarity

The B1 detector compares two-second, 2 kHz windows using mean-centered normalized correlation over a bounded lag search. Voice processing, speaker/microphone acoustics, room reverberation, non-linear suppression, AGC, and frequency coloration can leave intelligible speech while reducing raw waveform correlation. The observed correlations never reached the exploratory support threshold. Lowering that threshold would also increase matches to mismatched controls and periodic content.

### The current spectral scorer is not a robust AEC

`MeetingEchoSignalScorer` estimates a single delay, learns one complex transfer coefficient per frequency bin over two-second blocks, and measures residual energy. It lacks a continuously adapting partitioned echo path, explicit double-talk adaptation control, render/capture queue jitter handling, clock-drift tracking, nonlinear residual suppression, ERL/ERLE state, and echo-path-change recovery. Its low explained fraction is ambiguous between near-end speech, nonlinear residual echo, bad alignment, insufficient excitation, and a changing acoustic path.

### VAD and ASR text cannot identify the acoustic source

- VAD answers “does this resemble speech?” Leaked playback is speech.
- Text similarity can corroborate playback, but ASR errors, paraphrase-like errors, repeated phrases, and deliberate local repetition make it unsafe as the only suppression signal.
- Speaker clustering can assign stable identities to repeated leakage. A centroid is not proof of near-end speech.

### Competitor lessons are architectural, not thresholds to copy

Static inspection of Wispr Flow 1.6.492 found separate microphone/system PCM, repeated lag-stability evidence, attack/release behavior, timestamped exclusion spans, epoch resets, bounded-work fail-open behavior, and preservation checks before final microphone zeroing. Those are useful design patterns. Its feature activation and performance on FluidVoice recordings are unverified, and its constants are not FluidVoice calibration.

Static inspection of Granola 7.498.1 found a native capture boundary with separate microphone/system buffers and options related to AEC and gain compensation. The native implementation is unavailable in the inspected JavaScript. Its local diarization worker's gain/VAD/centroid path is not independent near-end proof.

## 3. Target architecture

```text
ScreenCaptureKit app audio ──► reference timeline ─┐
                                                   ├─► synchronizer ─► AEC/attribution engine
preserved microphone track ──► capture timeline ──┘                         │
                                                                             ├─► derived residual PCM
                                                                             ├─► delay/ERL/ERLE/echo state
                                                                             └─► explicit unknown reasons

derived residual PCM ─► VAD + microphone ASR ─► interval evidence ─► admission/profile policy
preserved original PCM ─────────────────────────────────────────────► local recovery/review only
application ASR ────────────────────────────────────────────────────► supporting text alignment
```

### Capture invariants

1. Preserve the original application and microphone tracks byte-for-byte.
2. Treat every derived residual as reproducible output with a versioned configuration and source hashes.
3. Keep original PTS, valid-sample masks, capture eras, route identity, device identity, discontinuities, and clock-drift observations.
4. Never substitute zeroes for unavailable samples before evidence scoring. Missing coverage stays unknown.
5. Never play ScreenCaptureKit-captured application audio back through FluidVoice during normal operation; doing so would duplicate audible output and create a new latency/feedback path.
6. Persist the reference scope (`selectedWindow`, `selectedApplication`, or an explicitly authorized broader mix). The current selected-application reference is not the acoustic system-output mix: other processes, notifications, volume changes, output DSP, and uncaptured helper processes can be absent or transformed.
7. A present selected-application reference is not automatically a complete reference. Carry `referenceScopeLimited`/`referenceCompletenessUnobservable` separately from absent/gapped reference. Without an explicitly authorized broader reference, the feature can promise suppression only for playback attributable to the selected scope; unrelated playback remains fail-open text and cannot be claimed solved.
8. Do not silently broaden capture to the full system mix. Any diagnostic or product full-mix reference requires explicit user-facing scope, retention, privacy, and deletion rules; it must not be transcribed or persisted by default merely because it is useful to AEC.

### Synchronizer

Add a bounded `MeetingReferenceSynchronizer` that emits fixed 10 ms render/capture frames plus metadata. It must:

- resample through an explicitly versioned converter and account for converter delay;
- define three timelines explicitly: microphone host/sample-count time, ScreenCaptureKit PTS, and the derived session-monotonic frame time. Never assume the first two share a clock merely because both use `CMSampleBuffer`;
- reset at either-track discontinuities, route/device changes, sample-rate changes, decoder gaps, or invalid/non-monotonic PTS;
- expose measured buffer delay and slowly varying drift. Either bound an epoch when drift exceeds a frozen limit or apply explicit, versioned drift-compensating resampling; never silently time-stretch one stream;
- compensate codec encoder priming/remainder, edit-list timing, and every converter's algorithmic delay;
- carry valid masks and an epoch ID into every result;
- distinguish `referenceAbsent`, `referenceGap`, `referenceScopeLimited`, `referenceCompletenessUnobservable`, `captureGap`, `captureTimingSynthesized`, `delayUnresolved`, `clockDriftUnstable`, and `engineUnavailable`;
- freeze adaptation, rather than fabricate aligned samples, across microphone spans whose PTS was synthesized after invalid host time; reset after the recorded resynchronization boundary;
- bound queues and processing time and fail open without blocking capture callbacks.

The initial implementation is offline-only and runs from completed lossless chunk files. No real-time callback may call C++ AEC, FFT, ASR, or file I/O.

### Candidate A: native multi-band attribution

Build a new offline experimental detector rather than tuning B1 in place:

- 16 kHz mono analysis, 20–32 ms Hann frames, 10 ms hop;
- log-mel or perceptual multi-band energies plus band-limited modulation envelopes;
- per-band robust normalization so gain and static coloration do not dominate;
- bounded lag candidates and a monotonic delay path with explicit slope/drift limits;
- coherence/support computed across frequency and time, excluding low-excitation and periodic/ambiguous frames;
- deliberately mismatched reference controls from the same recording;
- attack/release state that resets at the synchronizer epoch and never crosses missing coverage;
- a `duplicateSupported` result only when lag-path continuity, multi-band support, and control margin all pass.

This candidate produces attribution evidence only. It does not manufacture residual audio, call speech activity “near-end,” or suppress text by itself. A chosen enforcement path must retain it, or an equivalently independent reference-attribution guard, rather than trusting residual VAD/ASR alone.

### Candidate B: WebRTC APM/AEC3

Build a minimal offline C++/Objective-C++ wrapper around a **pinned commit** of WebRTC APM/AEC3. Feed the application stream to the render/reverse side and the microphone stream to the capture side in the API's required frame order. Export only:

- both the linear-filter output and the nonlinear/suppressed output, identified separately; treat the linear output as the first ASR/embedding-preservation candidate rather than assuming the listening-optimized suppressor output is best;
- convergence/delay state;
- available echo metrics such as ERL/ERLE or residual-echo likelihood;
- reset/failure reason and processing cost;
- the exact WebRTC commit, build flags, configuration, license, and artifact hash.

AEC3 is a mature reference/capture processor: its current code handles 10 ms frames, delay buffering/estimation, adaptive filtering, render/capture timing, residual echo estimation, and clock drift. Its source is BSD-licensed with a separate patent grant, but a dependency/security/license review is still mandatory:

- [WebRTC Audio Processing Module overview](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/g3doc/audio_processing_module.md)
- [`EchoCanceller3`](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/echo_canceller3.h)
- [`EchoPathDelayEstimator`](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/echo_path_delay_estimator.h)
- [`ResidualEchoEstimator`](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/residual_echo_estimator.cc)
- [WebRTC license](https://webrtc.googlesource.com/src/+/main/LICENSE) and [patent grant](https://webrtc.googlesource.com/src/+/refs/heads/main/PATENTS)

Do not vendor all of WebRTC. First prove a reproducible minimal target and enumerate its transitive source/build dependencies, including Abseil, `rtc_base`, `common_audio`, SIMD/FFT code, generated configuration, and field-trial behavior. Pin the field-trial string and all AEC3 suppressor/comfort-noise/high-pass options as part of engine identity. Do not enable WebRTC AGC or separate noise suppression in the first AEC-only comparison; changing multiple processors at once would make attribution and speech-preservation results uninterpretable.

### Capture-input bake-off

Test Candidate B against three explicitly different capture inputs, in this order:

1. **SCK paired microphone + SCK selected-application audio from one `SCStream`.** This code path already exists. Measure—do not assume—whether the microphone is unprocessed, whether the two outputs share a usable clock, and what latency/jitter it adds.
2. **Exclusive raw diagnostic microphone + SCK reference.** Run with VPIO fully torn down; never make two microphone owners race for the same device. Use only if it adds information beyond the paired SCK path.
3. **Current VPIO output + SCK reference.** This is the smallest product diff but the least identifiable signal model because it cascades AEC after Apple's time-varying nonlinear processing. Reject it if delay/convergence/ERLE are unstable or if most valid coverage remains inert/uncertain; do not tune around non-convergence.

Never silently replace VPIO capture based on one recording. On speaker routes, the current SCK microphone era is `.unprotected`, which blocks both live and offline mic transcription. A production raw/SCK topology therefore needs a separately reviewed capture migration and a distinct state such as `rawWithValidatedOfflineCancellation`; it cannot masquerade as behavior-unchanged shadow mode. That migration must cover exclusive device ownership, common-clock verification, interruption/recovery, permission state, file size, rollback to the whole VPIO runtime, and live-caption consequences.

### Admission and speaker-profile policy

The AEC residual is a candidate analysis/ASR source, not ground truth. Combine evidence without pretending correlated signals are independent:

- `likelyPlaybackOnly`: reliable render reference, converged delay/path, sustained echo attribution, and no supported residual speech interval;
- `acceptedNearEndSpeech`: measurable residual speech with adequate coverage and a preservation-safe AEC state; identity may remain unknown;
- `mixedOrUncertain`: residual speech and playback overlap, conflicting engines, unconverged/path-change state, or coarse timing;
- `unscored`: reference/capture/model/engine unavailable;
- `scopeLimited`: the selected reference is healthy but cannot establish whether other audible processes contributed. This is not equivalent to a complete acoustic reference.

Rules:

1. In the first enforcement release, use a selected linear or suppressed residual as the microphone ASR input only for intervals where the chosen engine is valid and held-out tests show speech preservation. Fall back to the existing microphone ASR input when evidence is unscored; include those fail-open words in the playback-leak metric so abstention cannot make a candidate pass.
2. Never delete or overwrite original microphone PCM.
3. Never drop an entire turn because playback was present somewhere in it. Split only at validated frame boundaries with padding; otherwise retain a recoverable uncertain candidate.
4. Do not admit any microphone-derived speaker embedding from `likelyPlaybackOnly`, `mixedOrUncertain`, `scopeLimited`, invalid, or shared-centroid-contaminated intervals.
5. In the first enforcement release, update speaker profiles only from verified no-playback clean intervals using original microphone PCM restricted to independently admitted speech. Do not enroll from overlap residuals. Separately evaluate embeddings from linear residual, suppressed residual, and clean original PCM for domain shift before any later relaxation.
6. Application/microphone fuzzy transcript alignment is supporting evidence and diagnostic output only until independently ablated. It cannot override strong residual speech or prove identity.
7. Missing reference/model/metrics never means “no speech” or “playback only.”
8. Run original and residual ASR side by side offline. Original words with an empty residual are not automatically rescued—that can be successful echo removal—but if residual-side speech activity, the independent attribution engine, or timing evidence conflicts with the empty residual, degrade the interval to `mixedOrUncertain` rather than silently dropping it.
9. Specify whether interval selection occurs before ASR or from word timestamps after ASR. Do not splice original/residual token streams until boundary padding, duplicate removal, and timestamp accuracy are independently tested.

## 4. Implementation phases

### Phase 0 — close the Apple/capture evidence gap

Deliverable: `tools/MEETING_VPIO_REFERENCE_PROBE.md` plus numeric-only result sidecars.

Create a diagnostic-only, correctly signed build or isolated harness. Use a safe-level, known local stimulus containing an impulse/maximum-length-sequence-style alignment probe plus speech-like material; do not use the current scorer's explained-fraction as the sole Apple-AEC meter. On each supported route, run short exclusive trials:

| Trial | Microphone path | Audible render/reference | Purpose |
| --- | --- | --- | --- |
| A | current VPIO input tap | helper/external process, selected-app SCK reference | Reproduce current architecture |
| B | VPIO input tap | known local PCM through a source node on the same engine; reference from an engine-local tap | Test paired VPIO I/O. Informational only: FluidVoice cannot productize ownership of another app's render path |
| C1 | same VPIO graph, uplink processing bypassed | same external stimulus as A | Quantify voice-processing attenuation without changing capture technology |
| C2 | SCK paired `.microphone` + `.audio` from one stream | same external stimulus | Test the already-implemented paired topology, mic processing, clock relation, latency, and jitter |
| D | VPIO with AGC disabled/enabled; ducking variants reported separately | A and B stimulus where public APIs permit | Separate AGC behavior; do not treat ducking volume change as AEC evidence |
| E | headphones | external process | Negative acoustic-leak control |
| F | exclusive raw/HAL diagnostic, VPIO fully stopped | external process | Only if it adds information beyond C2; never use simultaneous mic owners |
| G | selected app plus a second process and a mid-trial volume change | selected-app reference; optional explicitly authorized full-mix diagnostic reference | Measure incomplete-reference and post-tap gain/DSP failure modes |

Before acoustic conclusions, read and persist the actual input and output `kAudioOutputUnitProperty_CurrentDevice` elements, output render activity/connection, `isVoiceProcessingEnabled`, `isVoiceProcessingBypassed` / `kAUVoiceIOProperty_BypassVoiceProcessing`, `isVoiceProcessingAGCEnabled` / `kAUVoiceIOProperty_VoiceProcessingEnableAGC`, `isVoiceProcessingInputMuted`, and ducking state where supported. The exact property, scope, element, `OSStatus`, and value belong in the probe result. Verify that B's render is audible on the read-back output device. Force-binding element 0 is diagnostic-only until route-change and user-output behavior are understood.

For each trial persist only numeric diagnostics unless the user explicitly authorizes local audio retention: device/property readbacks; graph connection/render state; sample formats; all three timelines; delay sign/distribution; drift; multiband coherence; RMS; attenuation; and uncertainty. SCK-paired timestamps are measured rather than assumed to share a clock. A broader full-system reference in G is opt-in, ephemeral, never transcribed, and cannot become a product default through this probe.

Exit: rank (1) a reproducible Apple VPIO graph/device/property fix, (2) SCK-paired capture quality and clock behavior, and (3) current VPIO residual explainability. If the Apple-only configuration passes later speech-preservation gates, prefer it and stop. If SCK pairing wins, freeze that topology before building AEC3. If the current VPIO residual has unstable delay/coherence, remove VPIO+Aec3 from further work rather than tuning it.

### Phase 1 — freeze corpus and evaluation protocol

Deliverables: versioned annotation manifest, local-only runner, aggregate-only report.

1. Keep all existing eight recordings development-only and fixture-only. They exercise the VPIO topology and cannot calibrate a new SCK/raw topology.
2. Add frame-level timing labels for playback-only, clean normal speech, clean quiet speech, short quiet overlap replies, sustained overlap speech, pauses, route transitions, and reference gaps. Coarse whole-recording labels cannot select thresholds.
3. Build the calibration/held-out corpus only after Phase 0 freezes each evaluated topology. Include other-process speech, window-vs-application scope, helper-process audio, system volume changes, music, silence, periodic sounds, and multiple voices.
4. Reserve separate speakers/sessions/environments as held-out before tuning.
5. Compute recording-level metrics; correlated 10/256 ms frames are not independent samples.
6. The corpus minimums and split rules in `MEETING_RELIABILITY_IMPLEMENTATION_PLAN.md` remain binding: at least 12 independent negative sessions across three output configurations and two acoustic environments; at least 30 annotated minutes across three independent recordings for each populated quiet/short/double-talk positive condition; at least 100 labeled short replies; splits by recording/device/speaker; and fresh held-out data after a failed held-out run.
7. Keep source recordings and transcripts local. Reports contain aggregate numbers, hashes, versions, and failure reasons only. Include label-quality/independent-adjudication reporting for quiet overlap.

Metrics:

- playback-only visible microphone words/minute and speech-seconds/minute;
- percentage reduction from the current pipeline;
- scripted near-end WER or phrase recall, separately for clean, quiet, and overlap;
- false removal of near-end intervals;
- speaker-profile contamination and clean-profile yield;
- unscored/unknown coverage by reason;
- decision/inertness coverage: fractions reaching playback-only, accepted, uncertain, scope-limited, and unscored outcomes for each input topology;
- delay lock time, path-reset recovery, CPU time, peak memory, and derived-file size;
- speaker-embedding domain shift: clean-original versus linear-residual versus suppressed-residual similarity and cross-session verification error, reported separately from ASR quality.

### Phase 2 — synchronizer and deterministic fixtures

Targets: new `MeetingReferenceSynchronizer`, offline CLI, and baseline-host tests.

Required fixtures:

- known impulse/FIR echo with positive and negative delay;
- slowly drifting clocks;
- dropped render and capture blocks;
- codec encoder priming/remainder and edit-list offsets;
- discontinuity/route/sample-rate epochs;
- valid audio with synthesized microphone timing, adaptation freeze, and resynchronization;
- silence and low-excitation references;
- nonlinear coloration/clipping;
- near-end-only, echo-only, and double-talk at multiple echo-to-near-end ratios;
- cancellation-safe exact repetition by the near-end talker;
- deterministic replay and bounded-resource failure.

Exit: frame pairing, lag sign, converter delay, masks, and resets are independently test-pinned before either candidate is scored.

### Phase 3 — offline candidate bake-off

Implement Candidate A and a minimal Candidate B behind a common `MeetingReferenceAttributionEngine` protocol. First run a time-boxed out-of-tree AEC3 build-feasibility spike: require a reproducible macOS arm64/x86_64 artifact, enumerated transitive sources/licenses/field trials, a size report, and a Swift-callable smoke test. If that cannot be produced within a project-owner-approved time box, stop the extraction rather than letting WebRTC vendoring dominate the work; evaluate a maintained standalone WebRTC-audio-processing distribution only after the same provenance/security review, or return to the capture-topology/source-separation decision.

After Phase 0 freezes the input topology, run blinded IDs through the corresponding frozen development set. Do not tune on held-out data. VPIO, SCK-paired, and exclusive-raw recordings are different signal domains; results and thresholds do not transfer silently between them.

A candidate is rejected if it:

- labels leaked playback as accepted near-end speech at an unacceptable recording rate;
- removes or corrupts quiet/overlap phrases beyond the corpus gate;
- relies on a VAD or ASR-text-only source decision;
- carries support across gaps/epochs;
- cannot report unknown rather than fabricate a decision;
- is mostly inert: valid coverage remains unconverged/uncertain or fails to reach actionable states;
- depends on a selected-app reference while silently treating unrelated-process or post-volume/DSP audio as covered;
- cannot meet a bounded local processing/storage budget.

Decision rule:

- choose Apple-only if Phase 0 proves it meets the same output gates;
- otherwise choose SCK-paired microphone plus AEC3 if it materially reduces playback-only microphone words while preserving quiet/overlap speech and has an acceptable vendoring footprint;
- consider current VPIO plus AEC3 only when Phase 0 proves its residual remains delay-locked and learnable and it beats the SCK-paired arm on playback reduction without worse speech preservation;
- require Candidate A, or an equivalently independent reference-attribution guard, for any automatic playback-only/residual-ASR enforcement;
- do not implement a home-grown production adaptive canceller if AEC3 fails. Investigate capture topology or a separately reviewed source-separation model instead.

All Phase 3 comparisons use the binding parent-plan release metrics, including unscored/fail-open output in session totals. “Unacceptable recording rate” is not renegotiated during the bake-off.

### Phase 4 — shadow integration, no behavior change

Targets include `MeetingProcessingConfiguration`, `MeetingProcessingPipeline`, a versioned sidecar schema, and local numeric logging.

1. Add explicit `off` and `shadow` modes; default `off`.
2. Snapshot mode/version at processing start. Never consult a mutable global mid-run.
3. Generate the derived residual and typed evidence after chunk finalization, outside capture callbacks.
4. Run residual ASR/VAD and profile eligibility in parallel with the unchanged legacy outputs.
5. Persist only bounded local evidence needed for comparison; no raw PCM or transcript text in logs.
6. Record would-change counts: words, segments, profile observations, unknowns, processing cost, and candidate/legacy disagreements.
7. Make restart/retry idempotent and key outputs by session, source hashes, epoch, engine version, and configuration hash.

Exit: repeated processing is deterministic for the same architecture, binary, configuration, and inputs; record architecture and build hash rather than requiring cross-architecture floating-point byte identity. `off` is identical to today's behavior; `shadow` never changes UI/export/summary/profile output; injected engine failure falls back cleanly.

This phase applies directly only if the selected topology can preserve today's capture path. If SCK/raw wins, first produce the separate capture-migration design described above. A speaker-route raw era cannot be called “shadow/no behavior change” because today's `.unprotected` gate suppresses its mic transcript; the migration's rollback unit is the entire capture runtime.

### Phase 5 — held-out gate and limited offline enforcement

Before enabling enforcement, freeze:

- the engine revision/configuration and all decision thresholds;
- minimum reference and residual-speech coverage;
- delay convergence and path-change recovery requirements;
- interval padding/splitting rules;
- resource budgets;
- recording-level acceptance thresholds.

The stricter parent-plan release gates apply unchanged; this plan does not replace them with relaxed percentages:

- zero false accepted microphone words and zero visible microphone identities on the curated playback-only regression set, with an exposure-normalized upper confidence bound and session-level paired reporting;
- at most one absolute percentage-point increase in missed-speech duration and one point in speaker-attributed WER on each populated quiet, short-reply, and double-talk held-out condition;
- no increase in false confident microphone identities and no more than one additional identity-fragmentation event per annotated hour on echo-heavy held-out positives;
- zero known instances of cross-gap/route/epoch suppression;
- all missing/incomplete-reference, over-budget, dependency-load, and corrupt-sidecar tests fail open with originals recoverable;
- processing completes within a separately measured and product-approved local CPU/memory/latency budget.

Each gate is evaluated only after the binding corpus minimums above are met. Report recording-level paired uncertainty, and require the upper bound to satisfy each non-inferiority margin; do not use a word-level binomial model for bursty errors. Playback-leak totals include unscored/fail-open intervals and have a separately frozen cap on unscored coverage, so abstention cannot pass. Passing development fixtures alone is prohibited.

First enforcement scope:

- offline final processing only;
- supported built-in speaker/microphone routes with validated device metadata;
- derived residual ASR; speaker-profile updates remain restricted to verified clean no-playback original-microphone intervals until the separate embedding-domain gate passes;
- local recovery path that can show/reprocess from original audio;
- a kill switch returning immediately to legacy processing.

Bluetooth, HDMI, external/aggregate, and unknown output routes remain outside this first enforcement scope; their current unprotected-microphone admission behavior is unchanged until they have topology-specific evidence.

Keep live captions unchanged until offline enforcement has passed a longer soak. This deliberately means live text can differ from the cleaned final transcript; document that product tradeoff rather than silently hiding live mic captions whenever application audio is active.

### Phase 6 — live processing, only if separately justified

Real-time AEC introduces callback scheduling, render/capture ordering, latency, interruption, and state-recovery risks. Treat it as a separate project. A live implementation must use a bounded non-real-time worker, never block ScreenCaptureKit/AVAudioEngine callbacks, and must define behavior for stale/missing render frames. It requires its own stress, interruption, sleep/wake, route-change, CPU-pressure, and long-call tests.

## 5. Dependency and packaging gate for AEC3

Before Candidate B code lands:

1. Pin an immutable WebRTC commit and record the repository/commit in source and SBOM.
2. Build only the transitive APM/AEC3 subset needed for macOS arm64/x86_64; enumerate generated and third-party dependencies.
3. Preserve WebRTC license notices and patent-grant text; obtain project-owner/legal review if required by release policy.
4. Reproducibly build a signed/static artifact from source. Do not download a mutable binary during app execution or testing.
5. Run dependency vulnerability and symbol/export review.
6. Wrap C++ ownership in a narrow Objective-C++ API with explicit frame geometry, resets, and error returns; no exceptions across Swift.
7. Prove no network access, telemetry, audio logging, or debug dump is enabled.
8. Verify binary size, startup time, peak memory, CPU, and notarization/code-signing impact before choosing it.
9. Make feasibility time-boxed with an explicit abort result. A failed minimal/reproducible build is a decision outcome, not permission to vendor the full WebRTC tree or fetch a mutable prebuilt binary.

## 6. Required tests

### Unit/property tests

- PTS mapping, converter latency, lag sign, drift, and epoch reset;
- masks never become measured silence;
- render/capture ordering and exact 10 ms frame counts;
- multi-channel render versus versioned downmix policy, with a measured downmix error budget;
- deterministic AEC reset/replay;
- missing/late/duplicate/non-finite frames;
- double-talk adaptation safety and echo-path changes;
- exact local repetition of playback;
- shared speaker-centroid exclusion;
- no profile output from uncertain/playback-only intervals;
- all reason-code and legacy fallback branches;
- bounded queue, cancellation, timeout, and repeated failure latch reset by new session.

### Integration tests

- complete session reprocess with original hashes unchanged;
- `off`/`shadow` output equality;
- shadow sidecar restart/idempotence;
- app-only, mic-only, overlap, route change, and missing reference;
- selected-window/application reference plus unrelated-process audio and system-volume changes;
- SCK-paired microphone/application PTS comparison and raw-era admission behavior;
- model/dependency unavailable with no download attempt;
- exporter/summary/profile behavior under each admission outcome;
- installed-app capture unchanged until Phase 5.

### Acoustic and adversarial tests

- built-in speaker volume/distance/room sweep;
- male/female and quiet/normal/loud near-end voices;
- fast interjections during loud playback;
- music, applause, silence, noise, and periodic tones;
- speaker movement and device rotation;
- output-route and microphone changes;
- intentionally repeated far-end words by the local user;
- one and multiple nearby local speakers;
- long recordings and thermal/CPU pressure.

## 7. Observability and privacy

Emit numeric/enum diagnostics only:

- engine/version/config/source hashes;
- epoch and aggregate valid coverage;
- delay/convergence/path-reset counts;
- ERL/ERLE or candidate-specific aggregate metrics;
- residual/original energy ratios;
- admission outcome/reason counts;
- would-change segment/word/profile counts;
- CPU, memory, duration, and fallback reason.

Never log transcript text, raw PCM, embeddings, window titles, speaker labels, or absolute recording paths. Reviewer prompts may include relevant source and diffs under the repository authorization, but not recordings, transcripts, model weights, secrets, or unrelated files.

## 8. Rollback and recovery

- Feature modes are `off`, `shadow`, and narrowly scoped `enforce`; `off` remains a one-step kill switch.
- Originals are immutable; derived outputs are versioned and disposable.
- Reprocessing from originals can reproduce either legacy or selected-engine output.
- Unsupported routes, missing reference, failed convergence, corrupt sidecars, dependency load failures, or resource-budget failures use the documented fail-open text path and exclude uncertain audio from speaker-profile learning.
- Never reinstall an ad-hoc/invalidly signed build over `/Applications/FluidVoice Debug.app`. Existing bundle identifier, Team ID, designated requirement, and strict signature checks remain mandatory for any later install.

## 9. Concrete first implementation slice

The first code change after this plan is approved is **the revised Phase 0 plus the synchronizer test harness**, not production AEC and not threshold changes:

1. add VPIO input/output element, graph-render, enabled, bypass, AGC, mute, and ducking property readbacks behind a debug-only probe; replace no production metadata yet;
2. run the A/B/C1/C2/D/E/F/G trials above, including SCK-paired capture, unrelated-process/reference-scope, volume-change, and signed-delay measurement;
3. explicitly rank Apple graph/configuration repair, SCK-paired capture, and current VPIO-residual learnability before any AEC3 recommendation is activated;
4. add an offline `MeetingReferenceSynchronizer` with three-timeline, codec-priming, alignment, drift, synthesized-timing, mask, and gap tests;
5. define the common attribution-engine protocol and aggregate result schema;
6. run the time-boxed out-of-tree AEC3 build/license/size spike only if Phase 0 still requires software cancellation;
7. leave all production transcript/profile behavior unchanged.

Only after that slice establishes what reference Apple receives, whether SCK pairing shares a usable timeline, which reference scope is acceptable, and whether the residual remains learnable should an in-tree AEC3 target be introduced.

## 10. Completion definition

This work is complete only when:

- the Apple reference-path question is answered by repeatable hardware evidence rather than API inference;
- selected-app versus full-mix reference limitations are explicit in product behavior and privacy scope;
- the chosen engine wins a frozen development bake-off and a separate held-out evaluation;
- quiet and overlap speech preservation meets the recording-level gate;
- playback-only microphone text and profile contamination meet the reduction gate;
- dependency, privacy, signing, resource, and recovery reviews pass;
- shadow soak shows no unexplained disagreements or cross-epoch decisions;
- enforcement is reversible and original audio remains recoverable;
- live behavior is either deliberately unchanged or separately validated.

Until then, suppression stays off.
