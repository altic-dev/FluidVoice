# Microphone speech admission and speaker-profile integrity

Date: 2026-09-08 (local)
Status: revision 7 — Stage A and offline B1/B2 plus eight-recording B3 development evaluation implemented. Five controlled recordings were added on 2026-09-09. Scoped Kimi reviews completed and findings addressed/dispositioned; no production approval is claimed. Current evidence still rejects threshold selection. No transcript/profile enforcement, runtime integration or app reinstall is included.

## Objective and relationship to existing work

Prevent playback remnants and unsupported ASR text from becoming accepted microphone speech or microphone speaker profiles, while preserving genuine quiet speech, short replies, overlap, and multiple people sharing a microphone.

This is a scoped execution plan for the microphone-admission P2/P3 work in `MEETING_RELIABILITY_IMPLEMENTATION_PLAN.md`. It does not replace that plan's corpus or release gates. `MEETING_RELIABILITY_P0_BASELINE.md` remains the baseline reference. Live-caption watchdog recovery is a separate workstream; this plan neither fixes nor gates it on microphone filtering.

Non-goals: lower microphone gain by default; add a hard universal volume cutoff; enforce one microphone speaker; restore a “You” election; change dictation or application-track diarization; replace ASR/AEC models; upload recordings or embeddings; automatically rewrite historical meetings.

## 1. Evidence driving the change

| Local fixture | User ground truth | Current output | Evaluation role |
| --- | --- | --- | --- |
| `3774ED4C…` (~100 seconds) | User did not speak | Seven microphone segments, 143 whitespace-delimited words, two represented microphone speaker identities, no echo flags | Development negative regression |
| `88E3BD44…` (~261 seconds) | User spoke only the supplied script near the end | Eight earlier microphone segments / 167 words; scripted speech retained around 208–250 seconds | Development negative intervals plus positive speech |
| `3B9AC1A8…` (~133 seconds) | User-reported playback-only | Prior false microphone text; live-caption blackout also investigated | Additional development regression; separate live issue |

The latest microphone recording has RMS approximately −56.4 dBFS, versus −27.8 dBFS for digital playback. In 32 of 48 two-second windows, the strongest waveform match occurs 55–70 ms after playback; median absolute correlation is only 0.108, versus 0.045 for a mismatched-reference control. These measurements support residual playback leakage but do not establish microphone gain, acoustic source distance, or the origin of every sound. They are not production thresholds.

The source video's captions around 34:05–35:43 corroborate several garbled playback phrases in the microphone transcript. Caption comparison is supporting evidence, not independently annotated audio truth. Do not use source-caption wording as a runtime whitelist or infer speech identity from semantic similarity alone.

All three recordings have already informed diagnosis and belong in development, never held-out acceptance. No claim of quiet-speech recall or statistical reliability follows from these few fixtures.

### Local competitor implementation findings

These are static observations from unpacked client snapshots, not current-service documentation, a runtime activation audit, or evidence that either product passes our fixtures. No competitor code was executed or sent to an external reviewer.

| Snapshot and inspected files | Verified mechanism | Applicability and limits |
| --- | --- | --- |
| Wispr Flow 1.6.492: `/Users/shreeram/Projects/wispr/reverse-engineering/wispr-flow-v1.6.492/extracted/.webpack/main/index.js` | FFT-based microphone/system comparison; repeated lag-stability checks; attack/release hysteresis; timestamped exclusion spans and epochs; conference-room latch; final encoder receives microphone-zeroing spans while original mic PCM is retained | Strong motivation for a temporal duplicate detector. Feature-dependent activation is unverified. Does not prove double-talk safety or successful detection on our low-correlation residuals. |
| Granola 7.498.1: `/Users/shreeram/Projects/granola/Granola - AI Notepad-unpacked/Granola-app-source/dist-electron/audio_process/index.js` and `main/feature-flags.generated-DtBFb_Zf.js` | Native capture wrapper receives echo-cancellation/headphone and gain-compensation options; separate microphone/system buffers and optional capture timestamps | Native cancellation implementation is not exposed here. Bundled defaults are not live feature settings. Do not infer that a flag means effective cancellation. |
| Granola 7.498.1: same source root, `dist-electron/local_diarization_process/index.js` | Segmentation/clustering, adaptive gain, energy-based activity backend, and a minimum voiced-duration check in the fallback embedding path | Supplied embeddings bypass that duration check; the inspected Community-1 path supplies cluster centroids. This is not independent clean-speech validation for every identity. |

Wispr's inspected defaults include an 8 kHz comparison stream, 16,384-point FFT, five consistent lag observations within an eight-observation history, three attack updates and a two-second release hangover. Its lag sign convention must not be assumed to match our analysis. These are reference implementation facts, **not proposed FluidVoice constants**. Its detector has fail-open and processing-budget safeguards; microphone zeroing is refused when preservation/reference checks fail.

Granola's worker applies bounded adaptive gain before its energy-based activity check. That check is not a neural near-end speech detector. The supplied-centroid bypass reinforces our requirement to validate profile provenance on every path rather than rely on the presence of a VAD-named component.

Design decision: adopt the architectural idea of temporal playback-duplicate evidence, independently implemented and calibrated locally. Do not copy proprietary implementation bodies, transplant thresholds, introduce adaptive gain, or zero original microphone audio. Keep the stricter shared speech-admission/profile contract below.

## 2. Verified code gaps

- `MeetingEchoSignalScorer.verdict` returns `containsLocalSpeech` for a sufficiently long low-explanation run. This measures failure to explain the mic with playback, not positive near-end speech evidence. Its rescue precedes the echo coverage gate.
- `MeetingProcessingPipeline.StagedMicrophoneTurn.effectiveEcho` lets that verdict veto both text and signal echo suppression.
- `trustedMicrophoneObservationKeys` excludes only text-echo turns. Global microphone stitching can therefore consume observations whose speech validity was never established.
- An observation key can represent a chunk-level speaker cluster shared by several turns. Accepting one clean-looking sibling cannot make the shared centroid clean.
- At the pinned FluidAudio revision, offline returned segment embeddings repeat cluster centroids; they are not independent interval embeddings.
- `MeetingModels` persists optional `isLikelyEcho`, and `MeetingTranscriptExporter` consumes echo visibility. A boolean cannot represent uncertain speech separately from echo.
- `MeetingFinalProcessingConfiguration` explicitly describes itself as inert. Adding a field there is not runtime enforcement; configuration must actually be captured and applied by the processing run.

Reconfirm call sites, runtime entry points and active consumers before implementation. Legacy local-speaker-election helpers/comments exist; do not reactivate them or assume they describe the current global-stitch path.

## 3. Contracts to implement

### Evidence, decisions and identity are separate

Introduce proposed `MeetingMicrophoneEvidence` and `MeetingMicrophoneAdmissionPolicy` types. Keep policy evaluation pure and deterministic. Evidence is timestamped in the original capture timeline, with explicit mapping to any adjusted display timestamps.

Evidence fields:

- protected capture era, route discontinuity, and interval coverage;
- playback context: `scoreablePlayback`, `verifiedNoPlayback`, `playbackExpectedButUnscoreable`, or `unknown`;
- local speech-detector output, coverage, model/artifact/version and unknown reason;
- playback explanation, delay confidence/coverage and text similarity as separate signals;
- temporal duplicate state, supporting-window count, lag spread, evidence freshness, transition reason and capture epoch; these are correlated with playback explanation and must not be double-counted as independent confidence;
- ASR provider/model and whole-chunk/per-turn/alignment fallback provenance, preserving failed alignment evidence through retries;
- overlap and interval duration;
- embedding provenance/quality, represented separately from speech validity.

Mandatory identity scope: session ID, chunk ID, turn index/key (`microphone:<chunkID>:<index>`), explicit observation reference (`microphone:<chunkID>:<label>` when available, otherwise unavailable), and capture epoch. One observation can have many sibling turns; the evidence contract must preserve that relationship. Never fabricate an observation key for an unassigned fallback. Temporal evidence additionally carries matching identity and interval scope.

Keep `noDelayLock`, `referenceUnavailable`, `unscoredCoverage`, and `scoredInconclusive` distinct; their Stage A compatibility projection may collapse to legacy `.unknown`, but their detailed reason must remain available to shadow evaluation.

Distinguish measured zero from missing data. No invented ASR confidence when the provider exposes none. Do not multiply correlated scores as independent probabilities. An active application track alone does not prove audible speaker playback; a missing reference does not prove silence.

Proposed decision outcomes:

| Outcome | Default transcript/summary/export after enforcement | Speaker-profile contribution |
| --- | --- | --- |
| `acceptedSpeech` | Included; identity may remain unknown | Only independently supported, clean interval evidence |
| `likelyPlaybackDuplicate` | Excluded; available in local review | None |
| `uncertainCandidate` | Excluded from default text; explicitly reviewable | None |
| `noSupportedSpeech` | No accepted text; evidence retained under retention policy | None |

Unknown identity is not uncertain speech. Accepted speech without usable embeddings remains readable under an unknown-identity label. A missing detector/reference must not cause all legitimate microphone speech to disappear.

### Decision rules before calibration

1. Preserve existing capture-era safety checks; record exclusion reasons and retain original audio.
2. Low playback explanation alone never proves local speech and never automatically rescues a likely echo.
3. Reliable playback-duplicate evidence with no independent near-end support favors `likelyPlaybackDuplicate`.
4. Mixed playback/local speech requires interval-level handling. A short local reply must not rescue the entire contaminated turn, nor must playback evidence erase the reply. Split only where timing evidence supports it; otherwise preserve an explicit uncertain candidate.
5. Speech-detector activity alone cannot distinguish leaked speech from near-end speech. In playback conditions, require jointly evaluated evidence; unresolved conflict stays uncertain.
6. Where playback is absent or reference unavailable, evaluate speech support without requiring an impossible echo match. In-room and reference-failure cases need their own calibrated paths.
7. `noSupportedSpeech` requires adequate negative evidence, not merely a missing model, absent confidence, failed ASR, or low amplitude.

These define semantics, not final score thresholds. Feasibility of separating nonlinear residual speech from quiet local speech remains an experimental gate. If available evidence cannot do it reliably, do not enable automatic suppression.

### Temporal playback-duplicate detector

Add proposed `MeetingPlaybackDuplicateDetector` with bounded state, injectable clock/configuration and deterministic paired-audio input. Implement offline shadow evaluation first; reuse of the component in live capture is a separate integration decision.

- Align microphone and reference using original capture PTS, explicit resampling and valid-sample masks. Account for chunk boundaries, discontinuities, AAC padding and clock drift. Define and unit-test the lag sign. Search a bounded lag range instead of hard-coding the observed 60 ms.
- Compute windowed playback similarity and lag evidence, with checks for available reference, usable energy, periodic/ambiguous peaks and match quality relative to deliberately mismatched reference. Low energy or missing coverage means insufficient evidence, not silence or local speech.
- Proposed states: `insufficientEvidence`, `observing`, `duplicateCandidate`, and `duplicateSupported`. Require repeated support with stable delay before advancing; use separately calibrated entry/release criteria. State is evidence, not an immediate instruction to hide or zero audio.
- Track onset uncertainty and a bounded release hangover. Never extend suppression automatically across an unobserved gap or let a conference-room latch hide an entire microphone track. Short local interruptions and simultaneous playback/speech require the shared policy's mixed-interval handling.
- Reset evidence on route/era/sample-rate changes, gaps and reference loss; require fresh support after reacquisition. Do not freeze a stale duplicate decision indefinitely. Record detector-unavailable/over-budget reasons and disable this evidence contribution on repeated failures; do not manufacture `acceptedSpeech` or `noSupportedSpeech` as a fallback.
  Stage B1 binds capture epochs to the intervals between `MeetingProcessingPipeline.epochBoundaries` (either-track discontinuities), plus explicit route/reference discontinuities where no recorded boundary exists. Reuse the current ±`blockSeconds` discontinuity guard exclusions for initial evaluation; changing that guard policy requires separate tests/review. Invalidate prior evidence and delay state at the same boundaries, and keep samples masked by guards unavailable rather than treating the mask's zero values as silence.
- Preserve original audio. Candidate ranges are sidecar evidence mapped into transcript/profile decisions. Any future derived-ASR-input masking is a separate, reviewed experiment requiring positive-speech gates and recoverable originals; it is not in this implementation scope.
- Bound buffers, FFT/window work, pending jobs and evidence history. Run outside capture callbacks; emit no raw audio or transcript in routine metrics. Select latency/memory budgets from local profiling and freeze them before acceptance testing.

## 4. Incremental implementation sequence

### A — Evidence contract and semantics, behavior unchanged

Targets: `MeetingEchoSignalScorer.swift`, `MeetingProcessingPipeline.swift`; new evidence/policy files; `MeetingEchoSignalScorerTests.swift`, `MeetingEchoVetoTests.swift`.

1. Rename the in-memory verdict to `residualNotExplained` (or equivalently precise name), including thresholds/comments/log labels. This enum is not currently a persisted Codable field; do not invent an enum migration.
2. Preserve existing output behavior in a clearly named legacy mapping. Merely renaming must not silently remove the existing rescue and suppress real speech before validation.
   The scorer body is mechanically renamed, not reimplemented: preserve rescue-before-coverage ordering, short-NaN-gap bridging, and the conjunctive trivial-run exclusion. The legacy mapping simply wraps the unchanged `effectiveEcho` boolean expression; characterization tests pin all these edge cases.
3. Add typed evidence and reason codes; represent unmeasured RMS/coverage explicitly rather than interpreting sentinel zero as a measurement.
   Include the temporal detector's evidence contract and a fake implementation; do not load an audio model or enable suppression in Stage A.
4. Implement a pure shadow decision function with injected evidence. Mark uncalibrated outcomes experimental; no user-visible suppression.
   Stage A invocation is **tests only**. No production call site, runtime flag, persistence, logging, model loading or fake detector wiring. Its deliberately conservative output is `uncertainCandidate` with diagnostic reasons; it does not yet produce accepted/no-speech decisions or calibrated would-suppress counts. Stage B introduces an explicit default-off shadow collection configuration; Stage D alone adds enforcement.
5. Add adversarial unit cases: low explanation with noise, garbled playback, short real reply inside echo, missing reference, empty/NaN coverage, identical real repetition of playback, two near-end people and no playback.

Exit: each test explicitly distinguishes the unchanged legacy result from the experimental shadow reason. In particular, characterize the legacy rescue separately from `legacyRescueDisagreement`, and do not assert aspirational filtering as legacy behavior. Tests compare turns/profile eligibility before and after invoking the pure shadow function; static call-site inspection confirms no production invocation. New scorer labels never describe low explanation as confirmed speech. This is not an end-to-end runtime shadow-mode test; that belongs to Stage B.

### B — Local evidence collection and shadow evaluation

Targets: processing pipeline; proposed `MeetingSpeechActivityDetector` adapter, `MeetingPlaybackDuplicateDetector` and tests; effective processing configuration and tests.

1. Audit the pinned local VAD API, available artifacts, licensing, sample rate, padding/context and probability semantics. Prototype with local cached models; no automatic network fallback during evaluation. Add an injected detector for deterministic tests.
2. Capture one immutable effective runtime configuration per attempt. Wire detector, admission mode and versions into the actual processing path; integration-test enforcement rather than only fingerprint equality.
3. Measure playback-conditioned speech support over bounded windows with monotonic timing and bounded buffers. Preserve chunk-edge context without concurrent unbounded model instances. Check cancellation and specify model-load failure behavior.
4. Attach shadow decisions before global stitching and final assembly; retain all current display/profile behavior. Count would-accept/would-suppress/would-exclude-from-profile outcomes separately.
5. Aggregate reason counts and durations locally. Raw audio/text/embeddings are not new default logs. Store any detailed evaluation sidecars separately from original sessions, with bounded retention and exclusive output creation.
6. Run the existing negative and scripted fixtures locally. Add controlled positives/negatives and annotations before threshold selection. Include comparison with detector-disabled baseline.

Deliver Stage B as three reviewable increments:

- **B1: temporal duplicate detector.** Implement timestamp-aligned paired-window measurements and state transitions above; run local negative fixtures with sidecar outputs only. Report lag distributions, lock/hold/release errors and unknown coverage. A consistent lag in our exploratory analysis is a hypothesis to test, not a sufficient acceptance criterion.
- **B2: speech evidence and combined policy.** Add the validated activity adapter and evaluate mixed-speech conflicts. Keep temporal similarity and existing echo explanation separate but acknowledge their statistical dependence. Do not turn weak correlation into positive local-speech evidence.
- **B3: calibration and ablations.** Compare unchanged baseline, existing echo evidence alone, temporal evidence alone, speech activity alone, and the combined policy on identical development recordings. Report false accepted words/identities alongside lost quiet/short/double-talk speech. Freeze the selected policy before held-out evaluation.

Exit: measurable operating-point tradeoffs, complete unknown/fallback reporting, bounded resource use and no shadow-mode change to persisted transcript or profile contents. If local VAD plus current evidence is insufficient, report that result and review a new detector/dependency scope rather than selecting an unsafe threshold.

### C — Independent speaker evidence and shared admission integration

Targets: `trustedMicrophoneObservationKeys`, pending/staged turns, `MeetingGlobalSpeakerStitcher`, `MeetingSpeakerEmbeddingIndex`, final microphone assembly.

1. Carry one decision identifier plus audio interval and evidence/policy fingerprint through every path. Profile eligibility and final text consumption must refer to the same decision, not recompute conflicting rules.
2. Replace the “any non-text-echo turn admits its observation key” rule. Mixed accepted/rejected siblings must not bless a shared cluster centroid.
3. Evaluate compatible clean-interval extraction. The public legacy `EmbeddingExtractor` is not assumed compatible with the offline model/PLDA space. A dependency extension needs its own reviewed API and compatibility tests.
   Explicitly test supplied-embedding paths: a precomputed centroid must not bypass interval admission, minimum supported duration, overlap constraints or contamination checks. Minimum duration gates identity evidence only, not the visibility of otherwise accepted short replies.
4. Until compatible independent extraction is proven, exclude contaminated shared observations from profile updates while retaining accepted text with uncertain identity. Do not drop all accepted speech just because embeddings are unavailable.
5. Count trusted duration using the union of accepted, supported intervals, excluding overlap/duplication as required by the extractor. Do not count repeated centroids as independent observations.
6. Create speaker identities lazily from eligible evidence; remove unused candidate identities only from the new processing result, never destructively from historical sessions. Profile contributions must be traceable for session-local recomputation.

Exit: no rejected/uncertain interval can contribute through a sibling, retry, whole-chunk fallback or resumed run. Genuine multiple near-end speakers remain supported; the system does not pass merely by assigning everyone unknown.

### D — Versioned enforcement and consistent consumers

Targets: `MeetingModels.swift`, `MeetingProcessingPipeline.swift`, effective configuration/checkpoint logic, `MeetingTranscriptExporter.swift`, all discovered transcript UI/search/copy/summary consumers.

1. Add versioned persisted admission status, reason/provenance references and explicit legacy interpretation. Keep speech admission separate from `isLikelyEcho`; uncertain text must not be mislabeled proven echo.
2. Build a shared visibility/eligibility projection used by UI, copy/export, summaries and search. Review uncertain-candidate UX before enabling suppression. Summaries must not silently ingest hidden candidates.
3. Use explicit `off`, `shadow`, and `enforce` modes, default off/shadow until acceptance. Snapshot mode at attempt start, not midway through a run.
4. Bump processing version when final output semantics change (currently 10; choose the next unused value at implementation). Update mirrored defaults/tests and include actual policy/detector/artifact versions in attempt provenance.
5. Audit checkpoint contents and resume paths. Reuse only with matching effective fingerprints; invalidate/rebuild incompatible derived artifacts. Old sessions lacking new evidence remain legacy, not silently accepted under the new policy.
6. Reprocessing is explicit and transactional: prepare a separate result, preserve the original until success, handle cancellation/failure without partial replacement. No automatic historical migration.
7. Rollback must retain the meaning of previously persisted uncertain/rejected evidence; switching the flag off cannot reinterpret it as accepted. Verify compatibility before offering older binaries as rollback.

Exit: all consumers agree, compatibility/resume/cancellation tests pass, and held-out quality gates pass before enforcement is enabled.

## 5. Validation and release gates

Use the parent reliability plan's minimum corpus and statistical gates; this scope does not relax them:

- At least 12 independent negative sessions across three output configurations and two acoustic environments. Include real active-microphone playback, headphones, silence, noise, distorted playback and reference failure; synthetic zero/noise is a control only.
- Separate held-out quiet, brief-reply and double-talk positives: at least 30 annotated minutes across three independent recordings per condition, with at least 100 labeled short replies for that gate. Add multiple near-end speakers, in-room/no reference and real repeated playback phrases.
- Split by recording/device/speaker before tuning. Freeze policy structure, thresholds and splits before held-out evaluation. A failed held-out set becomes development data; obtain fresh held-out data for a subsequent quality claim.
- Zero accepted microphone words and zero represented false microphone identities on the curated playback-only regression set, with exposure and recording-level uncertainty reported. Extend negative screening to at least two hours per condition before release claims.
- At most one percentage point absolute increase in missed-speech duration and speaker-attributed WER per populated quiet/short/double-talk condition; report paired uncertainty and require upper bounds to meet the parent gates or mark evidence insufficient.
- No increase in false confident identities; at most one additional identity fragmentation event per annotated hour on echo-heavy held-out positives. Report unknown-identity coverage so an all-unknown system cannot pass.
- Separately report uncertain-candidate suppression, false words/minute, false identities/session, retained short replies, embedding coverage, latency/memory and capture drops. No new drops or unbounded growth during hour-long checks.

Required integration matrix: normal aligned output; low word/turn agreement and per-turn retry; whole-chunk fallback; silent/empty output; missing/corrupt reference; detector unavailable; protected/unprotected capture eras; chunk/route boundaries; mixed clean/contaminated cluster; stop/cancel; resume with matching/mismatching fingerprint; old-session read; new-result UI/export/summary parity; transactional reprocess failure; rollback interpretation.

Temporal-detector tests additionally cover positive/negative/zero lag conventions, reference timestamps shifted in both directions, wrong reference, music/periodic signals, nonlinear residuals with weak raw correlation, changing delay/drift, insufficient-energy windows, delayed/missing channels, AAC chunk padding, model-independent clock injection, detector budget exhaustion and freshness reset. Measure lock-onset/release latency and near-end speech lost during hold periods. Test a quiet reply while a duplicate state is already supported, not only isolated clean speech. Never compare competitor score thresholds directly with our exploratory normalized-correlation values without proving equivalent definitions.

## 6. Review, safety and delivery

Review after stages A/B and before enforcement: explicitly challenge all-speech-rejected, all-identities-unknown, repeated-centroid contamination, quiet double-talk loss, stale checkpoint and hidden-summary-leak counterexamples. Kimi K3 reviewed revision 2 through OpenCode in read-only plan mode. The six findings and their scope are recorded in `tools/MEETING_MICROPHONE_ADMISSION_PLAN_REVIEW.md`; revision 3 addresses test-only enablement, exact compatibility boundaries, identity keys, explicit test outcomes, epoch/guard alignment and distinct unknown reasons. That review is not sign-off on this amended document or the implementation. Any later external review receives scoped source/diffs only, not meeting recordings, transcripts, embeddings or secrets.

The existing FluidVoice source-review authorization does not automatically authorize sending Wispr/Granola bundles to an external model. Keep competitor inspection local; any separate disclosure requires appropriate authorization. Review temporal detector stale-state/latch behavior, threshold portability, and supplied-embedding bypass before enabling enforcement.

Preserve unrelated dirty-tree work. Do not install during the plan or shadow-data collection by default. Any later authorized Debug installation must follow AGENTS.md: same bundle ID/destination, valid deep/strict signature, matching designated requirement and Team ID, exact-app replacement, relaunch from `/Applications`. Stop before replacing the app if identity cannot be preserved.

Deliver each stage as a separately reviewable change with test evidence. Recommended first implementation unit: **Stage A only—typed evidence, precise naming with a legacy compatibility mapping, pure shadow decisions and regression tests.** No gain change, profile filtering, transcript suppression or app reinstall in that first unit.

## 7. Stage A execution record

Implemented after the user's review-and-proceed request:

- `MeetingEchoSignalScorer.swift`: renamed the verdict and low-explanation threshold identifiers; numeric thresholds and scorer control flow are unchanged. `legacyEffectiveEcho(textEcho:)` preserves the historical display truth table.
- `MeetingProcessingPipeline.swift`: uses the compatibility mapping and precise verdict name in diagnostics. Text-only profile eligibility is deliberately unchanged at this stage.
- `MeetingMicrophoneEvidence.swift`: non-persisted, immutable evidence/identity types; explicit missing-vs-zero and unknown reasons; temporal source protocol. The conservative pure shadow policy returns experimental uncertainty plus reasons, not calibrated admission or profile eligibility.
- `MeetingMicrophoneAdmissionContractTests.swift`: fake temporal source and characterization tests. Existing integration-test enum references were mechanically updated.

Validation: isolated `FluidASRBaseline` build-for-testing succeeded; 15 admission-contract tests and five existing live diagnostic tests passed, with zero failures/skips (`/private/tmp/fv-admission-stage-a-v1.xcresult`). A normalized source comparison confirmed the scorer's `verdict` body matches HEAD after identifier substitutions and comment removal. Static call-site inspection found shadow evaluation and the fake temporal implementation only in tests. The broader app integration suite and a Release build were not run; existing unrelated compiler warnings remain.

The known generated CTranscribe framework packaging defect required repairing only the isolated host's version symlinks, retaining the replaced build artifacts in temporary backups, then signing and deep/strict verifying that test host. The installed Debug app was not changed. No recording was opened, processed, reclassified, or sent to the external reviewer during Stage A.

Next implementation unit: Stage B1, real temporal duplicate measurements on local development fixtures with sidecar-only results. Stage A does not reduce the false microphone words yet, and its all-uncertain proposals cannot satisfy the release gates.

Post-implementation review attempt: Kimi K3 was asked to inspect the new evidence/test files and the two production diffs in read-only mode. That follow-up timed out at 180 seconds without findings. The completed revision-2 plan review and local verification stand; there is **no completed external code sign-off** for Stage A. Complete that code review before Stage B integration/enforcement.

## 8. Initial Stage B1 execution record

Implemented `MeetingPlaybackDuplicateDetector.swift`, the explicitly invoked offline `tools/meeting_temporal_shadow.swift` evaluator and 11 detector tests. No detector result is projected into turn admission or profile eligibility, and no production caller was added. Detailed configuration, implementation limitations, reproducible commands and numeric results are in `tools/MEETING_TEMPORAL_SHADOW_B1.md`.

The three development recordings produced zero supported locks at the initial experimental operating point: 196 of 244 windows were scored but inconclusive; 48 had insufficient coverage/energy. Unwindowed tails remain unmeasured. This does not establish useful weak-residual detection, speech recall, or a false-caption fix. Thresholds were not tuned downward after seeing these outcomes. Do not enable suppression from this result; B2/B3 and potentially a stronger temporal feature remain necessary.

Validation: final isolated baseline-host build succeeded; 31 targeted tests passed with zero failures/skips (11 detector, 15 Stage A contract, five existing live diagnostics), `/private/tmp/fv-temporal-b1-v3.xcresult`. The offline optimized evaluator compiled and ran locally on all three inputs; final sidecars are the v2 files documented in the report. No full app integration suite, Release build, held-out accuracy test or hour-long capture-load test was run. The existing generated framework packaging repair/signing was confined to the isolated test host, with displaced files retained in temporary backups. Installed Debug app unchanged.

Adversarial code review was retried with authorized Kimi K3 (180-second initial call and 300-second continuation) and Grok 4.6 (180 seconds, embedded scoped source only). All attempts timed out without returned findings. No review completion or sign-off is claimed. The completed earlier plan review is not code approval. Keep B1 offline-only until a completed code review and subsequent evidence gates; do not infer permission to integrate/enforce from this implementation record.

## 9. Initial Stage B2 execution record

After the user's “do it”, added a direct local CoreML speech-activity adapter, an injected model seam, bounded recurrent-state evaluation, and a conservative speech/playback diagnostic combination. The standalone CLI explicitly opts in with a local model argument; no production consumer exists. Cached model schema and aggregate-probability semantics were audited against the pinned source and local model graph. There is no model download, gain adjustment, app install or output suppression.

Three local development recordings yielded 1,916 full speech frames, including 153 active diagnostic windows and 24 unknown frames; all combined proposals remain uncertain. Both user-reported playback-only fixtures contain active windows, while temporal matching still has zero supported locks. This is evidence against enabling this simple combination as a near-end admission gate. No speech recall, false-word reduction, independent-person accuracy or held-out acceptance claim follows from these counts.

Kimi K3 completed three scoped reviews covering B1 core, B2 adapter/evaluator and the Stage A contract. Changes include exact integer lag-spread comparison, session-local failure latches, full-coverage temporal joins across mismatched frame grids, explicit unavailable controls and missing-playback-context diagnostics. Exact Stage A snapshot binding and cleared support counts after release are deliberately retained. Full finding dispositions, model audit, hashes, numeric results and verification are in `tools/MEETING_SPEECH_SHADOW_B2.md`.

The earlier review timeouts remain in the historical records above, but no longer describe the current review status. Post-fix code has not been independently re-reviewed in full and is not approved for enforcement. B3 annotated evaluation/calibration, effective app shadow integration, profile provenance, consumer consistency and release gates remain outstanding. The legacy echo score is not measured by this CLI, so the current two-signal comparison is not the complete planned ablation.

Final verification: isolated baseline-host build succeeded; 46 targeted tests passed with no failures/skips in `/private/tmp/fv-speech-b2-v3.xcresult` (11 speech, 13 temporal, 17 admission-contract, five live diagnostics). Final local fixture sidecars are the v2 files in the B2 report. Full app/Release, capture-load and held-out tests remain unrun. Installed app unchanged.

## 10. Existing-data Stage B3 execution record

After the user's “go”, added a versioned development annotation manifest and aggregate-only B3 evaluator with unit tests. The evaluator binds each sidecar to session bytes, pinned detector/model provenance and independently recomputed audio duration. It explicitly counts unknown/boundary/outside evidence and current transcript words without emitting transcript content or identities. All thresholds are descriptive; there is no selected/frozen operating point or production caller.

The available set has two pure-negative recordings, one mixed-label recording containing a negative interval plus only a coarse script region, and zero independently frame-labelled positives. Current saved output contains 324 visible microphone words and four per-session visible speaker slots in known-negative intervals; one saved echo segment accounts for seven additional hidden words. This is current-output inventory, not a projection of the candidate policies. The coarse script region contains 89 visible words whose accuracy is unverified.

At the cached VAD's 0.85 diagnostic threshold, 31/1,691 known-negative measured frames are still accepted while 121/161 coarse-region frames are accepted. A 0.04 threshold accepts 160/161 coarse-region frames but also 549 negative frames. Because frames are correlated and the coarse region contains unlabelled pauses, neither ratio is speech recall or an independent trial estimate. B1 has no supported locks, making temporal-only identical to accept-all and combined identical to speech-only on these inputs. No threshold is safe or selected.

Kimi K3's B3 review found eight issues across two passes: denominator drift, hard-coded frame duration, silent transcript-boundary exclusions, ambiguous overlapping cohort counts, selection-flavored reporting, empty annotations, unpinned model hashes and sidecar-only duration bounds. All were addressed; final post-fix verification returned no findings, and 11 evaluator unit tests pass. Final report and review dispositions: `tools/MEETING_ADMISSION_B3_DEVELOPMENT_EVAL.md`; aggregate artifact: `/private/tmp/fv-admission-b3-dev-v7.json`. No app build/test was required for evaluator-only changes; the last Swift validation remains B2's 46 passing targeted tests. Installed app unchanged.

## 11. Controlled Stage B3 extension

The user completed five separate development recordings with the installed app: playback only; normal speech without playback; quiet speech without playback; three normal-voice repetitions over the same YouTube playback; and two sequences of five quiet replies over that playback. The user confirmed that YouTube playback used speakers, their speech entered through the microphone, no headphones were used, and nobody else was speaking nearby. The runs ranged from 10 to 159 seconds. Every microphone/application track completed with zero recorded dropped samples, discontinuities or failures.

The existing offline B1/B2 CLI created numeric-only sidecars for all five without modifying the sessions. The playback-only run yielded four visible microphone-attributed segments and 49 words despite user-reported silence. B1 found no `duplicateSupported` window in any controlled run; three isolated candidates in the playback-only run did not satisfy stability. At diagnostic speech threshold 0.85, 10/600 controlled playback-only frames were accepted, while 137/445 frames in coarse user-speech regions were accepted. Those coarse regions contain pauses and playback-only time and are not recall denominators.

Across the eight-recording development set, threshold 0.04 accepts 681/2,291 known-negative frames and 507/606 coarse-region frames; threshold 0.85 accepts 41/2,291 and 258/606 respectively. The temporal ablation remains identical to accept-all because there are no supported locks. No operating point is selected: there is still no independently frame-labelled positive recording or held-out set, and transcript-localized overlap intervals are explicitly non-independent. Current aggregate artifact: `/private/tmp/fv-admission-b3-controlled-v3.json`. Full method, limits and hashes are in `tools/MEETING_ADMISSION_B3_DEVELOPMENT_EVAL.md`. The installed app and runtime behavior remain unchanged.

The next evidence gate requires independently timed quiet, normal, short-reply and double-talk recordings. These become development data; separate recordings remain required for held-out evaluation. Do not proceed to runtime shadow integration, threshold freezing, suppression or profile filtering from this result.
