# Playback echo cancellation and microphone admission — execution plan

Date: 2026-09-10 (local)
Status: revision 3 after completed Grok 4.6 and Claude Opus 5 adversarial reviews. Planning artifact only; no production behavior is authorized or changed by this document.

## 1. Decision and user-visible outcome

FluidVoice will treat playback cleanup as two different safety systems:

1. **Candidate primary signal cleanup:** if a pre-dependency signal-domain gate proves the paired ScreenCaptureKit streams are learnable, a pinned WebRTC Audio Processing Module / AEC3 engine receives the far-end render reference and microphone capture, then produces a derived microphone residual for offline ASR. AEC3 is rejected before vendoring if that gate fails.
2. **Independent admission guard:** reference-attribution evidence decides whether residual speech is supported near-end speech, likely playback, mixed/uncertain, or unscored. AEC output, VAD activity, or ASR text alone can never prove speaker ownership.

The original application and microphone recordings remain immutable. The first releasable scope is final, offline meeting processing on explicitly validated built-in speaker/microphone routes. Live captions and unsupported routes remain unchanged until separately validated.

The required product outcome is stronger than “the microphone waveform contains no speaker audio,” which software cannot guarantee on an open-speaker route. The enforceable outcome is:

- playback attributable to the captured reference does not enter accepted microphone transcript text or microphone speaker profiles;
- genuine quiet speech, short replies, and double-talk are preserved within the frozen non-inferiority gates;
- missing, incomplete, stale, or invalid evidence stays explicit and recoverable;
- originals remain available for deterministic reprocessing and rollback.

This plan supersedes the remaining execution sequence in `MEETING_PLAYBACK_ATTRIBUTION_V2_IMPLEMENTATION_PLAN.md`. That plan's capture invariants, privacy limits, evaluation minima, and profile-integrity rules remain binding.

Review record: `tools/MEETING_PLAYBACK_ECHO_CANCELLATION_ADVERSARIAL_REVIEW.md` records the completed Grok 4.6 and Claude Opus 5 reviews and every revision-3 disposition. Neither review is implementation approval.

## 2. Current evidence and starting point

### Established

- The selected application's ScreenCaptureKit audio is a clean-within-scope far-end reference. It is not necessarily a complete acoustic reference: other applications, notifications, helper processes, output gain, and device DSP may be absent or transformed.
- Historical paired ScreenCaptureKit recordings already showed that `.audio` plus `.microphone` from one `SCStream` can run for long meetings, but raw speaker-route microphone audio contains substantial playback leakage.
- Current production correctly marks the paired-SCK speaker-route microphone as `.unprotected` and excludes those microphone turns from transcript/profile admission. This is safe against contamination but loses legitimate local speech.
- The existing B1 raw-waveform temporal detector produced no supported locks on the difficult development recordings. Lowering its threshold is not an acceptable fix.
- VAD fires on leaked speech and cannot identify near-end ownership.
- The three controlled VPIO Trial B runs were invalid or inconclusive and are frozen. No additional generic Trial B is planned.
- The unlocked C2 metadata-only run established viable paired delivery: both SCK tracks arrived with valid timing and stable formats. It did not establish acoustic cancellation.
- Trial A did not capture an excited application reference, so it cannot support an AEC conclusion. Later attempts failed closed before capture because the controlled PLAYING window could not be uniquely established.
- `MeetingReferenceSynchronizer`, deterministic replay, valid masks, epoch/gap handling, source timelines, resource bounds, and strict `MeetingReferenceAttributionContracts` already exist with focused test coverage. They are infrastructure, not evidence that an AEC engine works.

### Unresolved

- Whether paired-SCK microphone PCM is the best AEC3 capture input on every supported built-in route.
- Whether the selected-app reference remains sufficiently complete through helper processes and output-device processing.
- Whether a minimal, pinned AEC3 build is maintainable within FluidVoice's binary-size, signing, CPU, memory, and licensing constraints.
- Whether AEC3's linear or nonlinear output preserves quiet speech and double-talk better for ASR.
- Whether independent attribution can reliably distinguish weak nonlinear playback remnants from near-end speech.

## 3. Non-goals and hard boundaries

- Do not implement a home-grown production adaptive echo canceller.
- Do not lower microphone gain or introduce a universal amplitude cutoff.
- Do not treat `isVoiceProcessingEnabled`, ERLE, residual energy, VAD, diarization, or ASR text as proof of near-end identity.
- Do not overwrite original microphone PCM or application PCM.
- Do not feed captured application audio back to an output device.
- Do not broaden selected-application capture to the full system mix without a separate user-facing privacy and retention decision.
- Do not migrate speaker-route capture or enable transcript suppression in the same change that introduces the AEC dependency.
- Do not tune thresholds on held-out recordings or transfer thresholds across VPIO, raw SCK, and external-device signal domains.
- Do not enroll speaker profiles from AEC residuals in the first release.
- Do not modify live transcription in the first release.

## 4. Target architecture and trust boundaries

```text
validated render reference ─► immutable reference track ─┐
                                                      ├─► MeetingReferenceSynchronizer
validated microphone input ─► immutable microphone track ┘          │
                                                                     ▼
                                                          fixed 10 ms frames + masks
                                                                     │
                                      ┌──────────────────────────────┴─────────────┐
                                      ▼                                            ▼
                         candidate pinned WebRTC AEC3                    independent attribution
                         linear + suppressed residuals             stable delay/multiband support
                                      │                                            │
                                      └──────────────────┬─────────────────────────┘
                                                         ▼
                                             microphone admission policy
                                                         │
                           ┌─────────────────────────────┴──────────────────────┐
                           ▼                                                    ▼
                    derived residual ASR                              clean-original profile input
                    offline final text only                           no-playback intervals only
```

### Trust rules

- `MeetingReferenceSynchronizer` owns clock mapping to a common chronological grid, format conversion, continuous clock-drift compensation by explicitly versioned resampling, masks, and epochs. It does not adaptively estimate or remove acoustic echo delay.
- The synchronizer may apply exactly one frozen, constant **render-lead pre-roll** by holding capture frames until the causally related render is queued. This is scheduling, not adaptive acoustic-delay removal. The value and source measurement are persisted per era; it cannot change inside an era.
- When AEC3 is selected, AEC3 alone owns the remaining adaptive acoustic-path bulk-delay estimate. Chronological render frames, including the constant lead, are fed before capture frames; a bounded measured device/buffer-delay hint may seed AEC3, but two components must never adapt the same delay.
- AEC3 owns signal transformation and engine state. It does not own transcript visibility or speaker identity.
- The independent attribution engine owns reference-support evidence. It does not directly erase PCM or text.
- One pure admission policy consumes typed evidence and produces one versioned interval decision used consistently by ASR assembly, export, summaries, search, and profile eligibility.
- Missing samples are unavailable, never measured silence. An invalid mask freezes adaptation and forces an explicit unscored interval.
- Reference scope is session/era provenance, not automatic proof of an interval outcome. Known concurrent out-of-scope playback, helper-process playback, or a route/volume/DSP transition produces `scopeLimited` or `unscored`, never `acceptedNearEndSpeech`; unknown out-of-scope playback remains an explicit limit of a selected-app-only product claim.

### One rendered artifact for every quality metric

All transcript quality metrics and all consumers use the same versioned final-transcript projection:

| Outcome | Default final transcript | Speaker-profile mutation |
| --- | --- | --- |
| `acceptedNearEndSpeech` | Validated residual ASR is visible | None unless a separately verified no-playback original-mic interval qualifies |
| `likelyPlaybackOnly` | Hidden from the default transcript; recoverable in local review | None |
| `mixedOrUncertain` | Fail open to recoverable original-mic ASR, visibly marked unknown/uncertain | None |
| `unscored` | Fail open to the legacy original-mic result | None |
| `scopeLimited` | Fail open to the legacy original-mic result | None |

Playback-leak, missed-speech, and WER gates are all computed from that same projection. Recoverability by itself never counts as visible speech preservation. The duration ceiling for each non-accepted outcome is frozen per corpus condition before candidate tuning.

## 5. Implementation sequence

Every stage is a separate reviewable change. A failed exit gate stops progression; it does not authorize threshold relaxation or architectural shortcuts.

### Stage 0 — freeze baseline and retire redundant experiments

Deliverables:

- Update the existing diagnostic/runbook documents with the final Trial B, C2, and Trial A dispositions.
- Freeze hashes for the current development recordings and current legacy outputs.
- Freeze hashes and reversible snapshots for current speaker-profile/centroid state; no later quarantine or kill-switch operation may destroy or silently reinterpret that baseline.
- Record the current production truth table for VPIO versus paired-SCK capture, `.unprotected` eras, live admission, offline admission, and speaker-profile eligibility.
- Keep the completed synchronizer/contracts/replay infrastructure production-inert.

Exit gate:

- One checked-in baseline manifest names the recordings, topology, route, annotations, source hashes, and whether each artifact is development-only.
- No new acoustic claim is inferred from an invalid Trial B or unexcited Trial A.
- No additional Trial B is scheduled.

### Stage 0.5 — prove the signal domain before choosing AEC3

Use existing paired-SCK lossless recordings if they contain the required excitation. If they do not, acquire the smallest new, safety-reviewed paired-SCK corpus; do not substitute C2 metadata or synthetic fixtures for acoustic evidence.

Tasks:

1. Measure render/capture chronology, delivery jitter, clock drift, signed acoustic delay, frequency-dependent coherence, path stability, clipping, and whether the paired microphone appears raw or already time-varying/nonlinearly processed. Persist p50/p95/p99 delay and drift distributions, not only means.
2. Define the AEC delay contract in an executable test: synchronizer maps clocks/epochs, continuously compensates measured clock drift, and may add one constant render-lead pre-roll; chronological render then enters before capture; AEC3 receives at most one bounded hint and owns all remaining adaptive delay.
3. Compare selected-window, selected-application, and—only under a separate explicit privacy authorization—ephemeral full-system reference completeness. Include helper-process and concurrent-other-process playback plus output-volume changes.
4. Keep current VPIO plus external reference only as a last comparison if existing valid material shows a coherent, learnable residual. Frozen invalid Trial B is neither proof for nor proof against it and does not justify another generic run.
5. Before measuring candidate outcomes, pre-register: the exact eligible built-in route/session predicate; allowed ineligibility reasons and maximum ineligible-session fraction; minimum exposure per condition; maximum render-lead pre-roll; AEC delay-search safety margin; maximum drift ppm and maximum uncorrected cumulative offset per era; at least 99% valid synchronized timing/reference coverage per eligible offline session; and condition-specific `mixedOrUncertain`/`scopeLimited` duration ceilings. Every excluded session and reason remains in the aggregate report.

Exit gate:

- Proceed to AEC3 only if at least one supported capture/reference topology has stable chronological mapping, bounded delay/drift, adequate multiband excitation/coherence, and no evidence that preprocessing makes the echo path unlearnable. After the single frozen render lead, each eligible session's p99 signed echo delay must be causal and fit inside the pinned candidate's documented search/buffer range minus the frozen safety margin; otherwise that era is `unscored`.
- If paired SCK fails, do not vendor AEC3 for that topology. Either retain the current `.unprotected` behavior, evaluate an already-supported Apple path using valid evidence, or open a separately reviewed full-mix/source-separation decision.
- C2 delivery metadata and deterministic FIR fixtures cannot satisfy this gate.

### Stage 1 — conditional, time-boxed AEC3 dependency feasibility spike

Proposed targets: an out-of-tree spike first, followed only on success by `Packages/MeetingAEC3` and `Sources/MeetingAEC3Bridge`.

Tasks:

1. Pin one immutable WebRTC source commit and all build inputs. Record license, patent grant, third-party notices, field trials, compiler flags, SIMD policy, source hashes, suppressor settings, comfort-noise behavior, high-pass filtering, and every enabled/disabled APM submodule.
2. Produce reproducible macOS arm64 and x86_64 static artifacts from source. Do not download a mutable runtime binary.
3. Enumerate the exact transitive APM/AEC3 subset; do not vendor the full WebRTC repository by default.
4. Prove a minimal C ABI/Objective-C++ smoke bridge can create, reset, process, and destroy an engine without exceptions crossing into Swift.
5. Disable AGC, general noise suppression, telemetry, raw-audio debug dumps, and network behavior for the initial AEC-only comparison.
6. Pin one portable SIMD baseline, disable runtime kernel dispatch where feasible, and forbid fast-math and uncontrolled floating-point contraction. Record the CPU feature vector, ABI, native/Rosetta mode, compiler, and deployment target in engine identity even when dispatch is disabled.
7. Measure artifact size, clean-build time, startup time, peak memory, per-10-ms-frame CPU, notarization/signing behavior, and deterministic configuration identity.
8. Run dependency/security/license review before in-tree vendoring.

Exit gate:

- Both architectures build reproducibly and a Swift-callable smoke test passes under sanitizers.
- The transitive source and binary footprint is enumerated and accepted.
- No hidden download, telemetry, dump, exception, or mutable field-trial behavior exists.
- If the spike exceeds the project-owner-approved time/size/maintenance budget, stop and record AEC3 as rejected. Do not fall back to an improvised canceller.

### Stage 2 — narrow engine wrapper and contracts

Proposed targets: `MeetingAEC3Bridge`, `MeetingWebRTCAEC3Engine.swift`, and extensions to the existing `MeetingReferenceAttributionEngine` contracts.

Tasks:

1. Accept chronological 10 ms render/capture frames plus validity masks and epoch identity. “Synchronized” means common clock/epoch mapping, not pre-removal of acoustic delay.
2. Enforce render-before-capture ordering, supported sample rates/channel layouts, the single-owner delay policy, and explicit reset at every epoch/path/route/device/volume-DSP change.
3. Export separately named linear-filter and nonlinear/suppressed outputs. Neither is declared the production winner in code.
4. Export only bounded numeric state available from the pinned revision: convergence, delay, ERL/ERLE/residual likelihood where supported, reset/failure reason, CPU, and allocation counts.
5. Make ownership RAII-safe across Swift/Objective-C++/C++. Return typed errors; never throw a C++ exception across the ABI.
6. Make engine/config/build identity part of every sidecar and cache key.
7. Reject non-finite PCM, wrong frame geometry, invalid masks, stale epochs, and output non-finites without trapping.
8. Freeze a versioned stereo/multichannel-to-mono render policy and measure its cancellation error. Never silently choose one channel or average channels with overflow/non-finite risk.
9. Define asymmetric gaps causally: exactly one render block is queued for each capture block on the common grid. A render-only or capture-only gap beyond a frozen tolerance resets the engine and marks the interval `unscored`; missing blocks are never zero-filled into adaptation.
10. Use original/reference/linear-filter signals for energy, coherence, independent attribution, and residual-empty conflict detection. The nonlinear suppressed output, including any comfort noise, is an ASR candidate only. Measure and report its synthesized comfort-noise floor separately.

Exit gate:

- Deterministic impulse/FIR, echo-only, near-end-only, double-talk, path-change, render-only gap, capture-only gap, drift, clipping, repetition, and low-excitation fixtures pass.
- A synthetic drift ramp of at least one hour proves synchronizer de-drift and AEC3 adaptive delay do not oscillate against each other or repeatedly reconverge.
- Invalid/missing frames never advance adaptation or become silence.
- Address/undefined/thread sanitizers pass the wrapper tests.
- Cancellation, repeated resets, and destruction leak no resources.

### Stage 3 — offline AEC replay, still no behavior change

Proposed targets: the existing baseline replay host, `MeetingReferenceSynchronizer`, `MeetingReferenceAttributionContracts`, and a new numeric-only AEC evaluation report.

Tasks:

1. Feed lossless finalized application/microphone chunks through the existing synchronizer, never from capture callbacks.
2. Run original, linear-residual, and suppressed-residual arms from identical synchronized frames.
3. Preserve original hashes and store derived audio only in an explicitly enabled, mode-0700 local evaluation workspace protected at least as strongly as source recordings. Every report, diagnostic, crash artifact, and sanitizer artifact unconditionally excludes PCM, transcript text, embeddings, absolute paths, window titles, and speaker labels. Mark the workspace excluded from backup and indexing, default its TTL to 24 hours with a hard seven-day maximum, and destroy derived PCM when the evaluation gate closes or the user cancels.
4. Run identical ASR/VAD evaluation on each arm. An empty residual transcript is not automatically success. Residual-empty plus original speech activity, mixed attribution, exact-repetition evidence, or timing disagreement must become `mixedOrUncertain`, retain recoverable original words, and never become playback-only solely because the residual emitted nothing.
5. Emit valid/unscored coverage by reason, delay/convergence time, path resets, ERL/ERLE, residual energy ratios, ASR deltas, processing cost, and engine identity.
6. Make replay idempotent and resumable only when all source/config/build hashes, CPU feature identity, ABI, and translation mode match.

Exit gate:

- With feature mode `off`, persisted meeting output is byte/semantically identical to the current baseline.
- Engine failure, corrupt source, missing reference, budget exhaustion, and cancellation leave originals and legacy output intact.
- The declared reference build/CPU configuration is bit-identical on replay. Other explicitly supported machines must produce tolerance-bounded metrics and identical interval decisions in a cross-machine replay; their sidecars are never reused across mismatched CPU/ABI/translation identities.

### Stage 4 — strengthen the independent playback-attribution guard

Proposed targets: `MeetingPlaybackDuplicateDetector.swift`, a new multi-band candidate behind `MeetingReferenceAttributionEngine`, and `MeetingMicrophoneEvidence.swift`.

Tasks:

1. Retain the current B1 detector as a fixed baseline; do not tune it in place.
2. Add a separate multiband/log-energy or coherence candidate with robust gain normalization, bounded lag-path tracking, ambiguity controls, repeated stable-delay support, attack/release state, freshness, and epoch resets.
3. Require deliberately mismatched-reference controls and explicit low-excitation/periodic unknowns.
4. Treat attribution and AEC metrics as correlated evidence, not independent probabilities.
5. Add interval outcomes: `likelyPlaybackOnly`, `acceptedNearEndSpeech`, `mixedOrUncertain`, `unscored`, and `scopeLimited`.
6. Keep the guard observational until Stage 5 shows it preserves exact repetition, short replies, and double-talk.

Exit gate:

- The chosen guard materially improves playback-only precision beyond AEC/VAD alone on development data.
- On development data it satisfies the structural speech-preservation invariants and cannot carry support across gaps, routes, epochs, stale references, or conference-room latches. Held-out thresholds are evaluated only in Stage 5 after the recorded one-time unlock.
- No decision can be produced solely from VAD, ASR text, residual energy, or ERLE.

### Stage 5 — corpus acquisition and candidate bake-off

Existing VPIO recordings remain useful regressions but cannot calibrate a raw paired-SCK AEC path. Acquire a topology-matched local corpus only after the Stage 2 wrapper and Stage 4 observational guard are stable.

Required conditions:

- playback-only speech, music, silence, applause, and periodic/ambiguous audio;
- clean normal and quiet near-end speech;
- at least 100 short replies;
- quiet and normal double-talk across multiple echo-to-near-end ratios;
- exact deliberate repetition of far-end words by the local talker;
- multiple nearby speakers and an in-room/no-reference condition;
- selected-app playback plus helper-process and unrelated-process playback;
- system-volume changes, speaker/microphone movement, route changes, gaps, sleep/wake, and CPU pressure;
- built-in speakers plus built-in microphone in at least two acoustic environments, with built-in microphone plus headphones as a negative acoustic-leak control. Bluetooth, HDMI, aggregate, external, and mixed built-in/external routes are separate unsupported domains.

The parent corpus minimums remain binding: at least 12 independent negative sessions across three output configurations and two environments, and at least 30 annotated minutes across three independent recordings for each populated quiet/short/double-talk condition. Split by recording, device, environment, and speaker before tuning. A failed held-out set becomes development data.

Each recording must carry consent provenance appropriate to all participants and the recording jurisdiction before corpus admission. Before the held-out split is opened, record a one-time unlock. Any access to held-out audio, labels, or per-recording outcomes before that unlock reclassifies the affected split as development data and requires a fresh held-out set.

Compare:

- unchanged production baseline;
- Apple VPIO baseline where valid;
- AEC3 linear output;
- AEC3 suppressed output;
- temporal/multiband attribution alone;
- each AEC output combined with the already-implemented observational admission guard.

Accounting rules:

- Count accepted, uncertain, scope-limited, and fail-open original microphone words in every playback-only leak total. A candidate cannot pass by classifying all contaminated intervals unknown or hiding them from the numerator.
- Reject a candidate before ASR scoring if valid actionable coverage is below the pre-registered operational gate, if any individual eligible session falls below it, or if it returns empty residuals while original speech/evidence conflicts.
- Report accepted, mixed/uncertain, unscored, and known-scope-limited duration separately. Do not impose one global cap on legitimate double-talk `mixedOrUncertain`; freeze condition-specific caps before tuning.
- Unknown identity counts against identity coverage. An all-unknown system cannot pass the identity gate.
- Compute playback leak, missed-speech duration, and WER from the one default final-transcript projection in §4, never from different hidden/recoverable artifacts.
- Gate playback leakage with a pre-registered one-sided upper confidence bound on leak events or false words per exposure-hour and a minimum exposure below which the outcome is `insufficientEvidence`, even when zero events are observed.

Reject any candidate that is mostly unscored/inert, bridges gaps, hides incomplete reference scope, damages quiet/double-talk speech beyond the frozen margin, or passes by dropping all microphone text/identities.

### Stage 6 — separately reviewed paired-SCK capture migration

This stage is necessary only if paired-SCK microphone plus AEC3 wins. It is not bundled with dependency or engine work.

Tasks:

1. Add an explicit, default-off capture mode for one `SCStream` emitting selected-app `.audio` and `.microphone`.
2. Preserve both tracks losslessly and retain the current `.unprotected` semantics until offline cancellation for that exact era is validated.
3. Represent successful derived processing in an immutable versioned sidecar/decision record for that capture era. If a new state such as `rawWithValidatedOfflineCancellation` is introduced, it is derived provenance, never an in-place rewrite of the original `.unprotected` era.
4. Keep live microphone admission closed on raw speaker-route eras in the first release. Final offline processing may later derive accepted text from validated residual intervals.
5. Handle exclusive device ownership, permissions, selected-window/application churn, duplicate app records, route changes, interruption, sleep/wake, stream restart, and format changes.
6. Make rollback swap the entire capture runtime back to the current VPIO path. Do not splice capture implementations mid-era without a recorded boundary.
7. Preserve current behavior for headphones, Bluetooth, HDMI, aggregate, external, and unknown routes unless separately evaluated.
8. Inventory and test every current admission consumer before migration: capture-era gates, live track admission, offline `microphoneIntervalIsAdmitted`, ASR retry and whole-chunk fallbacks, `trustedMicrophoneObservationKeys`, global stitching, transcript/UI/export/summary/search, and speaker-profile persistence. All offline consumers must read one persisted interval decision rather than independently interpreting capture protection.
9. Quarantine pre-existing microphone centroids whose provenance cannot prove clean admitted intervals using a reversible, non-destructive flag. Retain original embeddings, bind quarantine decisions to the Stage 0 profile-state hash, and make the kill switch restore the exact pre-migration eligibility state. Reprocessing must never make historical leakage-trained centroids eligible, and original-PCM retry/fallback paths must not bypass the new decision.

Exit gate:

- Hour-long paired capture has no unexplained gaps, backward timestamps, unbounded queues, or format drift.
- Stop/restart/interruption and route transitions create deterministic eras and never open raw live transcript admission.
- The default-off migration does not change ordinary meeting capture.
- A rollback test proves the profile/centroid state hash returns exactly to the Stage 0 baseline.

### Stage 7 — shadow integration and soak

Tasks:

1. Add effective modes `off` and `shadow`, snapshotted at processing-attempt start. Default remains `off`.
2. In `shadow`, run synchronized AEC, residual ASR/VAD, independent attribution, and admission decisions after capture finalization.
3. Keep existing transcript, UI, export, summary, search, and profile output unchanged.
4. Persist a bounded, versioned sidecar keyed by source hashes, capture eras, engine/config/build identity, and policy fingerprint.
5. Record would-change words, segments, intervals, profiles, unknowns, resource use, and baseline disagreements without logging content.
6. Soak cancellation, resume, corrupt sidecars, app upgrades, old sessions, missing dependencies, and repeated processing.

Exit gate:

- `off` remains identical to current behavior.
- `shadow` has no user-visible or profile effect, no callback-path work, and no unbounded storage/CPU growth.
- At least the parent-plan long-call and corpus gates pass with recording-level uncertainty and a frozen configuration.

### Stage 8 — limited offline enforcement

Enforcement is enabled only after a new adversarial code review and held-out acceptance report.

Rules:

1. Apply validated residual ASR only to supported built-in routes and valid intervals.
2. Use one persisted admission decision for transcript, UI, export, summary, search, and profile consumers.
3. Split mixed intervals only at validated frame/word boundaries with frozen padding. Otherwise keep an explicit recoverable uncertain candidate.
4. Exclude playback-only, uncertain, scope-limited, invalid, and unscored intervals from speaker-profile learning.
5. Do not add new speaker-profile enrollment from cleaned paired-SCK speaker-route eras in the first transcript-enforcement release. Existing clean-profile matching may remain read-only. Enrollment yield and residual/original embedding domain behavior move to a separately gated later stage; do not weaken the verified-no-playback original-microphone rule to make identity coverage pass.
6. Unsupported routes and invalid engine/reference states retain the documented legacy/fail-open text behavior but remain excluded from unsafe profile learning. Their false words still count against release metrics.
7. Keep a one-step kill switch back to legacy processing. Do not reinterpret already persisted decisions when the switch changes.
8. Enforce the residual-empty conflict rule from Stage 3: if original speech activity, mixed attribution, exact repetition, or timing evidence conflicts with an empty residual, persist `mixedOrUncertain` and retain recoverable original text; never infer playback-only from silence produced by the canceller.
9. Restrict the first enforcement matrix to built-in output plus built-in microphone. A route/device change closes the current era, resets synchronizer/AEC/guard state, and returns the new era to its route-specific legacy protection until independently supported.

Release gates for transcript enforcement:

- The observed playback-only target is zero accepted microphone words and zero false identities, but passing additionally requires the pre-registered one-sided upper confidence bound on false words/events per exposure-hour and the minimum independent exposure. Zero observations alone never pass.
- At most one percentage point absolute increase in missed-speech duration and speaker-attributed WER for every populated quiet, short-reply, and double-talk held-out condition.
- No increase in false confident identities; no more than one additional fragmentation event per annotated hour.
- Zero known cross-gap, cross-route, cross-epoch, stale-reference, or incomplete-scope suppression events.
- Frozen caps for unscored coverage, CPU, peak memory, processing latency, derived storage, and dependency failures.
- At least 99% valid synchronized timing/reference coverage for each eligible offline session, subject to tightening before tuning; playback-only words in uncertain/scope-limited/fail-open output remain in the leak metric.
- Original audio remains recoverable and deterministic reprocessing/rollback succeeds.
- Identity labeling from existing profiles is non-inferior to the current baseline. New speaker-route profile enrollment and its enrollment-yield gate are explicitly deferred; transcript enforcement cannot mutate profiles merely to satisfy identity coverage.

### Stage 9 — live processing is a separate project

Do not reuse offline approval for live captions. A live design requires a bounded non-real-time worker, render/capture scheduling guarantees, latency UX, stale-reference behavior, interruption and thermal tests, and separate double-talk gates. Until then, live text may differ from the cleaned final transcript and must be documented as such.

## 6. Reviewable delivery units

1. **Signal-domain gate:** acoustic learnability, delay ownership, and reference-scope report; no dependency or app behavior change.
2. **Dependency spike:** pinned AEC3 build, license/SBOM/size report, smoke bridge; no app target linkage.
3. **Engine unit:** wrapper, deterministic fixtures, sanitizers; no meeting pipeline caller.
4. **Offline replay unit:** synchronizer-to-AEC adapter and numeric evaluation; no persisted meeting behavior change.
5. **Attribution unit:** independent multiband guard and evidence policy; offline only and completed before the combined bake-off.
6. **Capture-migration unit:** default-off paired-SCK runtime with immutable originals and closed live admission.
7. **Shadow unit:** versioned sidecar and would-change metrics; output invariant.
8. **Enforcement unit:** offline final transcript only after held-out and code-review approval.

Each unit must include source tests, failure-path tests, resource measurements, a privacy check, and an explicit statement of what remains unproven.

## 7. Required adversarial review questions

The reviewers must try to falsify this plan, specifically:

- Can AEC3 operate correctly with the proposed SCK reference/capture timing, frame order, and reference scope?
- Does paired SCK actually improve the signal domain, or does macOS apply undocumented processing that defeats the assumption?
- Can the plan erase quiet double-talk, exact repetition, or speech immediately after a path change?
- Are `scopeLimited`, missing masks, and fail-open behavior consistent across transcript and profile consumers?
- Does the proposed profile policy prevent shared-centroid contamination and retries/fallbacks from bypassing admission?
- Is the minimal AEC3 dependency/build strategy realistic, reproducible, licensable, and maintainable?
- Are there callback-thread, memory-ownership, exception, sanitizer, signing, or universal-binary hazards?
- Can a candidate pass by abstaining, returning empty residual ASR, or making every identity unknown?
- Is the capture migration sequenced late enough and independently reversible?
- What simpler architecture should replace this one if AEC3 or selected-app reference completeness fails?

## 8. Completion definition

The work is complete only when the chosen topology and engine pass frozen held-out playback-removal and speech-preservation gates; all consumers honor one admission decision; profiles remain uncontaminated; originals and rollback work; dependency/privacy/signing/resource reviews pass; and shadow soak shows no unexplained cross-epoch or incomplete-reference decisions.

Until then, enforcement stays off and paired-SCK speaker-route microphone audio remains unprotected.
