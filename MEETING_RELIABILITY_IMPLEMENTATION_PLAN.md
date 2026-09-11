# Meeting reliability: live recovery and evidence-based speaker admission

Date: 2026-09-08
Status: Revision v2 — revised after independent Kimi K3 (OpenCode) and Claude Opus reviews. P0 is ready to scope; P1–P3 behavior changes remain gated on its measurements and the contracts below. Reviewers reviewed v1, not this amended version; this is not a claim of external sign-off.
Scope: implementation plan only; this task does not authorize application changes, deployment, model replacement, or cloud upload of meeting audio.

Execution update (subsequent user authorization, 2026-09-08): the first P0 instrumentation/baseline slice is implemented and locally tested; see `MEETING_RELIABILITY_P0_BASELINE.md`. P0 remains open for controlled acoustic fixtures, annotation and the other documented evidence gaps. No P1–P3 policy change or app reinstall was performed.

## 1. Outcomes and boundaries

Detect sustained live-caption blackouts during audible speech and recover responsive decoder stalls; uninterruptible inference has an explicit degraded/final-reconciliation path, not a live-continuity guarantee. Prevent playback-only microphone artifacts from becoming accepted speech or speaker profiles. Preserve quiet speech, brief acknowledgments, multiple microphone-side people, overlap, local-first processing, and installed macOS privacy grants.

This plan complements MEETING_DIARIZATION_V2_IMPLEMENTATION_PLAN.md. That plan addresses application-track speaker separation and cross-chunk identity. This plan owns live-recognizer health and microphone evidence admission; neither may silently redefine the other's models or thresholds. Existing uncommitted work remains untouched.

Non-goals: restore a "You"/ownership election; equate microphone with one person; force speaker counts; infer acoustic identity from conversational meaning; change dictation; replace AEC or ASR merely on vendor benchmarks; automatically erase ambiguous evidence.

## 2. Evidence and uncertainty

Latest playback-only test: approximately 133 seconds, user reports no microphone-side speech.

- App partials stopped after a forced 20-second utterance reset, at approximately 42 seconds. Count remained 123 while feed advanced; text resumed around 80 seconds. No queue drops were logged. Offline text covers the interval.
- Confirmed source-level recovery defect in the inspected tree: rotateLongUtteranceIfNeeded requires utteranceStartPTS and utteranceTurnID; both are established only by a first partial and cleared on reset. No-first-partial stalls evade it. Binary provenance for this recording remains to be verified.
- Initial decoder failure remains unproven. Other resets recovered quickly. Callback generation races, blank decoder output, reset context loss, conversion effects, and runtime scheduling must be distinguished.
- Live microphone produced no partials. Offline processing retained six microphone phrases, five visible and one marked echo.
- Two microphone chunks had 69/75 and 58/76 words unassigned and fell back to per-turn ASR.
- All six scored turns had 100% scoreable coverage. Five verdicts were unknown; one was containsLocalSpeech. Missing coverage is not the explanation for this fixture.
- The signal scorer's low-explanation run is not a dedicated speech detector. Low correlation can reflect noise, nonlinear residual echo, mismatch, or speech.
- trustedMicrophoneObservationKeys currently excludes text echo only. Observation/profile evidence is chunk-label based; public per-turn embeddings may actually repeat cluster centroids. Do not call those independent clean-turn evidence.

Before claiming causality, pin the exact app build, FluidAudio revision and model artifacts. A currently checked-out source tree is not proof of the binary used in the recording.

## 3. Research basis and limits

The following are public documentation or papers, not independent product benchmarks:

1. Recall.ai separates participant streams when bots/platform support allow it; hybrid processing diarizes within streams. Desktop SDK lacks that separate-stream path: https://docs.recall.ai/docs/diarization
2. Granola uses microphone/system audio and platform speaker tags with shared-device and overlap limitations: https://docs.granola.ai/help-center/taking-notes/speaker-attribution
3. Otter distinguishes generic, known and unknown identity and supports corrections: https://help.otter.ai/hc/en-us/articles/21665587209367-Speaker-Identification-Overview
4. MacWhisper documents local speaker grouping and correction/merging, not perfect identity: https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper
5. Deepgram distinguishes interim text, finalized segments and endpoints. Word-gap endpointing is not an independent first-text watchdog: https://developers.deepgram.com/docs/understand-endpointing-interim-results and https://developers.deepgram.com/docs/utterance-end
6. NN3A jointly models residual echo suppression and near-end speech probability, explicitly balancing suppression and speech distortion: https://arxiv.org/html/2110.08437v1
7. AEC Challenge evaluates single/double talk and recognition quality: https://arxiv.org/abs/2202.13290
8. Coria et al. use overlap-aware embedding weighting and incremental clustering: https://arxiv.org/abs/2109.06483
9. Streaming Sortformer maintains quality-selected speaker memory across chunks; the described four-speaker model is not a drop-in unrestricted desktop solution: https://arxiv.org/html/2507.18446v1
10. WhisperX uses VAD segmentation and alignment; alignment is not proof of speech authenticity: https://arxiv.org/abs/2303.00747
11. Careless Whisper documents non-vocal-duration-associated hallucinations in Whisper, not a measured Parakeet rate: https://arxiv.org/abs/2402.08021
12. pyannote exposes attribution confidence and separate exclusive/overlapping views: https://docs.pyannote.ai/tutorials/confidence-scores and https://docs.pyannote.ai/tutorials/speaker-configuration

Engineering inference: separate capture provenance, speech validity, playback duplication, identity, and word attribution. No cited source proves a competitor solves this exact reset stall or playback fixture.

## 4. Proposed contracts

### 4.1 Live health is separate from utterance formatting

Introduce a testable LiveRecognitionHealth state machine with monotonic clock injection and generation-scoped events. Available wrapper inputs: audio PTS/frames accepted at offer, conversion success, append/process call start/completion, activity-detector output, partial/EOU callback sequence, queue backlog/drop, reset invocation/completion. Decode token/blank progress and reliable reset failure reporting are not public hooks in the inspected dependency; exposing them requires an explicit reviewed dependency patch, not an assumed adapter API. External supervision reads thread-safe progress counters; queue count is available but takeDroppedCount is destructive, so metrics must have one consumer or add a non-destructive snapshot.

States: awaitingSpeech, awaitingFirstText, transcribing, recovering, degraded, stopped. Readiness/loading is explicit and not counted as a post-ready stall. State transitions run in one owner; callbacks carry generation, sequence and originating audio range rather than reading only mutable currentFeedPTS.

Use audio-time for speech exposure and timeline mapping, an explicitly chosen monotonic clock for hangs and user latency. Handle sleep/wake through explicit lifecycle events: invalidate old watchdog deadlines, mark discontinuity, and re-baseline after wake. Verify actual clock semantics; do not infer them from systemUptime's name. Detect capture loss from offer progress versus elapsed time independently of speech. Distinguish no speech, speech without text, slow inference/backlog, callback delivery failure and capture loss. VAD is an imperfect signal: low-confidence activity is not grounds for endless resets or transcript rejection.

Caption segmentation must not automatically imply destruction of the acoustic decoder context. Determine pinned manager capabilities before designing soft-finalize; if unavailable, retain current working endpoint behavior until a tested context-preserving strategy exists.

### 4.2 Evidence-based microphone admission

Introduce per-interval MicrophoneEvidence with typed, independently recorded fields:

- capture protection/era and reference availability;
- playback context: scoreablePlayback, verifiedNoPlayback, playbackExpectedButUnscoreable, or unknownPlaybackContext. In-room mode is not by itself proof of no ambient playback; use the available capture facts and label uncertainty. Missing/zero-filled reference audio must not be interpreted as observed silence;
- speech presence (probability, coverage, detector/version, unknown reason);
- playback explanation (score, confidence, delay/coverage, echo/unknown verdict);
- ASR evidence (timings, alignment agreement, provenance, available model confidence);
- overlap and speaker-embedding quality/provenance;
- admission decision and reason codes.

Do not fabricate confidence for providers that do not expose it. Unknown is distinct from negative evidence. Do not multiply correlated scores as if independent. The same admission function is used before profile construction and final transcript assembly.

Proposed outcomes: acceptedSpeech, likelyPlaybackDuplicate, uncertainCandidate, noSupportedSpeech. Speech confidence and identity confidence remain separate: accepted speech may retain unknown identity. Uncertain text remains locally reviewable with provenance but does not update profiles or silently enter default summaries/exports. Final UI/export semantics require explicit tests and product review; original audio is preserved under existing retention policy.

The policy is not a universal AND gate demanding a valid playback reference: genuine microphone-side speech must remain supportable when reference scoring is unavailable. Conversely, AEC being enabled is not positive proof of speech.

## 5. Phases, deliverables, and exit gates

### P0 — Reproducible baseline and instrumentation (must precede policy tuning)

1. Record installed build identity, code SHA/dirty fingerprint, dependency/model revisions, capture era/route, provider options and processing version. Resolve revision mismatches without silently changing dependencies for the baseline.
2. Preserve original session; use local read-only audio fixtures and separate evaluation outputs. No meeting audio, raw transcript, embeddings or credentials go to reviewers/services without separate authorization.
3. Annotate speech/overlap/speaker truth locally. Preserve the user's report of no speech as evidence; ASR output does not refute it. Label this historical fixture user-reported playback-only, with local audio adjudication and ambiguous intervals flagged separately. Add controlled playback-only captures with the microphone active, known playback and an independently verified silent room, plus synchronized microphone-side speech fixtures. Digital-zero and muted-microphone inputs are ASR controls, not substitutes for acoustic leakage tests. Initial corpus requirement: at least 12 independent negative sessions across three output configurations and two acoustic environments, and separately held-out positive sessions covering quiet/brief/overlap speech; increase coverage if uncertainty remains. Split by recording/device/speaker before policy selection; never reuse held-out data for tuning.
4. Add privacy-safe aggregate metrics to live feed/decode/callback boundaries. Record time-to-first-token, longest speech-without-text interval, decoding latency/backlog, generation changes, dropped frames and recovered audio ranges. Diagnostic raw text is opt-in, local, bounded, and off by default.
5. Add an injectable recognizer adapter, activity detector and clock to permit deterministic state tests without loading CoreML models. Preserve production behavior in this instrumentation change.
6. Measure the pinned ASR on digital silence, low-level noise and controlled AEC residuals, in both whole-chunk and per-turn modes. Begin with bounded 10-minute screening per condition, then at least two hours per negative condition before release claims. Compare detector-gated and ungated processing on development data only. Report false words/phrases per minute; do not infer a Parakeet rate from Whisper research.
7. Verify embedding provenance and supported extraction APIs now, before P3 depends on them. Record independently embeddable accepted-duration coverage by condition, including double-talk. If the necessary independent evidence is unavailable, choose and review a dependency extension or an explicit unknown-identity fallback before P3 implementation; do not discover the limitation at release time. Existing configuration snapshots are inert until runtime enforcement is proven by integration tests.

Exit: reproducible baseline report, exact build provenance or explicit limits, annotated negative/positive fixtures, and deterministic reproduction of the watchdog blind spot. Initial decoder cause must be characterized or explicitly remain open; instrumentation is not a completed fix.

### P1 — Live recovery, independently releasable

Targets: MeetingLiveTrackEngine.swift, MeetingLiveModels.swift, MeetingLiveTranscriptionCoordinator.swift, MeetingLiveBoundedQueue.swift, live test suites; new health/adapter types as needed.

0. Prove reset effectiveness for the reproduced responsive-stall class before selecting reset as the recovery action. The inspected dependency suppresses resetStates errors with try?; expose success/failure via a reviewed patch, or treat reset completion as unverified until a bounded token-progress probe succeeds. A completed reset is never a successful-recovery metric by itself. If reset is ineffective, gate a sequential manager replacement on confirmed retirement, measured load time and memory; do not overlap managers. Cache corruption is a counterexample hypothesis, not the proven incident cause.
1. Implement first-text and in-utterance monitoring from the new state machine; reject stale generation callbacks after resets and stop.
2. Log decode heartbeats independently of callbacks. A watchdog on an actor blocked by inference is insufficient: control/supervision must observe progress without waiting for that actor to finish. Chosen policy: one live manager per track, no quarantined parallel CoreML instance. For responsive decoding without text, perform bounded recovery; for uninterruptible inference, retire outputs by generation, enter degraded state and preserve recording. Full live recovery from a hung backend is explicitly unsupported until a separately reviewed process-isolation design exists. The measured incident had continued consumption, so a 90-second inference hang is an adversarial case, not its established cause.
3. Prototype a timestamped recovery buffer with an initial 60-second cap per track at 16 kHz float mono (3.84 MB per track), enough to retain the observed 38-second interval. P0 may lower or raise the cap based on measured blackout distribution and memory/latency budgets, with a reviewed bounded maximum. Maximum two recovery attempts per minute and at most one live manager per track. Replay work has a wall-time budget and cannot let current audio grow without bound; prioritize current captions and record unreplayed historical ranges. These settings are development proposals, not efficacy claims.
4. Maintain a coverage ledger for original, consumed, committed, replayed, dropped and unresolved audio ranges. Require post-meeting reconciliation of gaps against the existing final-processing result, not blind duplicate ASR work. If final processing does not cover a gap, attempt bounded local catch-up after live model retirement; retain an explicit unresolved marker on cancellation/failure. Report live-only and final coverage separately. A longer ring buffer does not guarantee lossless or fast catch-up.
5. Establish committed versus provisional transcript ranges. Committed live text remains immutable; corrected final text is a separate product. Decode with overlapping audio context, discard only confidently timed replay words wholly before the commit boundary, and retain a provisional reconciliation band for boundary-crossing words. A straddling word must not be blindly discarded. Without reliable word timings, use bounded segment overlap alignment and retain an unresolved boundary rather than asserting lossless deduplication. Test real repeated phrases, changed replay hypotheses and PTS discontinuities. Generation plus source audio range is mandatory; text-only matching is insufficient.
6. Surface recovery/degraded status separately from recording status. Avoid permanent "healthy" based solely on incoming audio.

Exit: deterministic tests for no first partial, token/blank stall, delayed inference, callback reorder, reset completion, stop during recovery, real silence/music and queue loss; replay tests at realistic pacing with no missing/duplicated boundary speech. Proposed target: flag confirmed-speech no-text conditions within 5 seconds after readiness, attempt safe recovery within the next 3 seconds when the backend is responsive. Calibrate and freeze the detector operating point using P0 data; do not promise recovery from an uninterruptible backend.

### P2 — Microphone evidence in shadow mode

Targets: MeetingEchoSignalScorer.swift, MeetingEchoDetector.swift, MeetingProcessingPipeline.swift, MeetingProcessingConfiguration.swift and evidence tests.

1. Add explicit speech-presence evidence using an available local detector after verifying its behavior on AEC-processed residuals. Generic VAD detects leaked speech too; combine with playback-reference evidence and evaluate on transformed/noisy reference cases. A near-end-aware model is an experimental alternative, not a prerequisite or assumed available API.
2. Replace the semantic claim containsLocalSpeech with residual-not-explained evidence internally. The inspected TurnEchoVerdict is Equatable/Sendable in-memory state, not Codable; do not invent an enum migration. Audit all consumers, logs and tests to confirm that scope. Persisted isLikelyEcho and new admission/schema meanings still require versioned compatibility. Revisit its override of text echo only through the new evaluated policy.
3. Carry alignment/fallback provenance and uncertainty across every retry. High word/turn disagreement must not be erased by a successful per-turn text return. Use bounded retries; silence/no-speech remains a valid result.
4. Compute shadow admission alongside existing behavior using the ordered decision contract in section 9. Record aggregate candidate/accepted/uncertain outcomes and reason counts locally; make no user-visible filtering changes yet. Policy structure may be developed on development data only; freeze structure, thresholds and corpus before a single held-out acceptance run. A failed held-out run requires a fresh held-out set for a new quality claim.

Exit: a calibrated policy with false-positive/false-negative trade-offs, including noisy playback, low-volume acknowledgments, no reference, double-talk, route transitions and in-room multi-person capture. No thresholds selected only to remove the five observed phrases.

### P3 — Admission and profile integrity

Targets: trustedMicrophoneObservationKeys, staged/pending microphone turns, MeetingGlobalSpeakerStitcher/embedding index integration, transcript/export/summary consumers, session serialization.

1. Apply evaluated admission before constructing any profile and at transcript finalization. Unit-test all entry paths, including whole-chunk fallback, unreadable reference, word-aligned and per-turn providers, resume/checkpoint and reprocessing.
2. Obtain true independent interval embeddings from validated non-overlap speech. Verify dependency APIs: repeated chunk centroids are not substitutes. If unavailable, conservatively exclude contaminated observations from profile updates and retain accepted text with uncertain identity. Do not gate all valid text on embedding availability.
3. Aggregate trusted duration/quality only over accepted evidence. Profile updates must retain provenance sufficient for session-local recomputation if admission changes; rejected turns must not contaminate siblings through a shared centroid.
4. Lazily create unknown identities; count only identities represented in accepted visible speech. Distinguish unknown person from uncertain speech. Support correcting/merging attribution without overwriting original evidence.
5. Version decision schema and processing cache/checkpoints; old artifacts without evidence are legacy/unknown, never silently trusted. Classification changes bump MeetingProcessingPipeline.pipelineVersion (inspected value 10); coordinate mirrored configuration defaults. Record effective admission-policy/detector versions and flag state in processing-attempt provenance, plus live-policy provenance in the appropriate capture/session record. Checkpoints currently hold the application pass, not microphone evidence; require an exact final-policy fingerprint on resume or explicitly invalidate/rebuild. Existing fingerprints must be proven enforced at runtime. Reprocessing is explicit, transactional, resumable and cancellable. Do not mutate old sessions automatically. Old UI/export reads preserve historical display until explicit reprocessing; rollback cannot reinterpret a new uncertain decision as accepted speech.

Exit: playback-only regression corpus produces zero accepted mic words and zero visible mic identities; genuine short/quiet/overlap speech preservation meets held-out gates. All display/export/summary consumers agree about decision semantics; original evidence remains recoverable.

### P4 — Optional diarization bake-off, not a dependency of P1–P3

Compare current pinned pipeline against overlap-aware alternatives on approved local fixtures. Evaluate pyannote-style segmentation/embedding weighting and streaming cache concepts; any actual model integration requires license, supported speaker count, CoreML/CPU/GPU feasibility, memory and energy checks. Do not add cloud uploads, meeting bots, browser extensions, voice enrollment or persistent voiceprints as an implicit implementation step.

Keep native overlapping timelines separate from exclusive display views. Preserve word attribution uncertainty when multiple speakers overlap; exclusive diarization does not separate voices or recover masked words. Coordinate application-track changes with the existing Diarization V2 plan.

Exit: measured improvement on held-out data justifies cost and migration; otherwise retain current diarizer with P1–P3 controls.

## 6. Evaluation and release gates

Report per-condition results, not only averages:

- Playback-only built-in/external speakers at multiple volumes; headphones; silence; music; fan/keyboard noise; reverberation; nonlinear/distorted playback; missing/wrong reference.
- Quiet microphone-side speech, one-word replies, accents, two nearby people, similar voices, simultaneous playback and speech, real repeated phrases.
- Long continuous speech, onset after silence/reset, hour-long sessions, warmup, system load, queue saturation, route/sample-rate/era changes, stop/resume and cancellation.
- Final metrics: false mic words/minute, false identities/session, missed speech duration, speaker-attributed word errors, speaker confusion/splits/merges and alignment coverage. DER settings must declare overlap handling and boundary collars; silence-only fixtures need false-alarm metrics because DER has no speech denominator.
- Offline live-evaluation metrics: first-text latency from annotated speech onset after readiness, p95/max blackout during annotated speech, omission/duplication at recovery and final coverage reconciliation. Production proxies: time from detector-indicated onset to text, detector-active time without text, decode heartbeat latency/backlog, recovery/degraded duration, CPU/memory/energy and capture drops. Proxies are not ground-truth missed-speech measures.

Proposed gates, to be frozen after baseline and before implementation tuning: zero false accepted mic words/identities on the curated playback-only regression set; at most 1 percentage point absolute increase in missed-speech duration and 1 point speaker-attributed WER on each populated quiet/short/double-talk held-out condition; no new capture drops; no unbounded growth in hour-long runs. Each positive gate condition needs at least 30 minutes annotated audio across three independent recordings, with at least 100 labeled short replies for the short-reply gate; this is a minimum, not sufficient statistical power by itself. Report paired uncertainty intervals and require their upper bounds to meet the non-inferiority margins or report insufficient evidence. Add no increase in false confident mic identities and no more than one additional identity fragmentation event per annotated hour on echo-heavy held-out positives, reporting uncertain-attribution coverage separately so an all-unknown system cannot pass. These are engineering targets, not statistical guarantees.

For the zero-observed-false-positive regression gate, also report an exposure-normalized upper confidence bound and recording-level paired uncertainty; zero on a small corpus is not zero risk. Do not apply a binomial formula directly to words/minute. If using a Poisson rate bound, declare its event/independence assumptions and supplement with session-level results for bursty errors.

Release independently behind liveRecoveryV1 and microphoneAdmissionV1 configuration controls. Test all four flag combinations, not merely all-on/all-off. Roll back behavior independently while retaining compatible evidence records; ensure disabled behavior has regression coverage. Progress from shadow evaluation to opt-in debug to broader rollout only after gates pass. Debug reinstall must preserve com.FluidApp.app, /Applications/FluidVoice Debug.app, verified signature, matching designated requirement and Team ID; stop rather than replace with mismatched signing.

## 7. Work breakdown and review checklist

Suggested implementation slices: (1) provenance/harness, (2) adapter/telemetry, (3) live state tests, (4) bounded live recovery, (5) evidence/shadow policy, (6) independent profile evidence, (7) admission consumers/migration, (8) held-out evaluation/rollout. Each slice has focused tests and a small reversible diff; no broad pipeline rewrite.

Adversarial reviewers should challenge: provenance assumptions; VAD false negatives and leaked-speech false positives; uninterruptible inference/reentrancy; replay boundaries; corrupted sibling embeddings; uncertainty UX; in-room/no-reference policy; migration/rollback; data leakage; hard limits and test feasibility. Demand falsifiable counterexamples and concrete changes. Distinguish confirmed code facts from proposals and unavailable dependency capabilities.

## 8. External review disposition

Both reviewers returned "revise before implementation" on v1. This v2 incorporates adjudicated findings, with empirical questions retained as explicit gates rather than claimed solved. See docs/reviews/meeting-reliability/draft-v1.md, kimi-k3-review.md, claude-opus-review.md and disposition.md. Kimi reviewed relevant source as well as the plan; Claude reviewed only the supplied plan with tools disabled. No reviewer was authorized to implement application changes or access meeting recordings, secrets, credentials or unrelated files.

## 9. Admission decision contract (ordered, shadow-first)

This is a proposed policy structure to freeze on development data before held-out evaluation, not a proven classifier. Numeric operating points remain P2 deliverables. Speech-positive means calibrated acoustic support, not merely ASR text. Speech-negative requires sufficient valid audio and corroborated no-speech evidence, not a single low VAD score. Generic VAD is not independent near-end evidence during playback. ASR conflict includes severe alignment disagreement and uncorroborated fallback; per-turn fallback alone is not automatic rejection when independently supported.

Apply the first matching row; wildcard rows cover remaining combinations:

| Order | Condition | Result/reason |
|---|---|---|
| 1 | Existing online capture-protection admission fails | Excluded by capture policy; preserve evidence. No new AEC-based assumption of speech |
| 2 | No candidate text | No text emitted; if speech evidence exists, record an ASR coverage gap rather than claim silence |
| 3 | Valid corroborated speech-negative audio | noSupportedSpeech; short/quiet duration alone cannot trigger this |
| 4 | Mixed playback/local speech or contradictory evidence | Split only when validated temporal evidence permits; otherwise uncertainCandidate/mixedEvidence, never suppress the whole turn as echo |
| 5 | Strong playback-duplicate evidence, no supported independent speech, no conflict | likelyPlaybackDuplicate; short-text matches alone are insufficient |
| 6 | Speech unknown or ASR conflict remains | uncertainCandidate/insufficientEvidence; no profile update |
| 7 | Speech positive, ASR supported, verifiedNoPlayback | acceptedSpeech; identity may remain unknown |
| 8 | Speech positive, ASR supported, scoreablePlayback AND validated independent microphone-side support | acceptedSpeech; identity evaluated separately |
| 9 | Speech positive during playbackExpectedButUnscoreable or unknownPlaybackContext | uncertainCandidate/referenceUncertain unless separately validated microphone-side evidence satisfies a pre-registered rescue; default policy has no such rescue |
| 10 | Any other combination | uncertainCandidate/unresolved; no profile update |

Unknown context does not silently become accepted. Conversely, in-room/verified-no-playback positives do not require an echo score or an owner voiceprint. This intentionally risks uncertainty for legitimate speech during unscoreable playback; P2 must measure uncertain/missed coverage and cannot ship if positive-speech gates fail. Evaluate the detector's added discrimination within each echo-score/context bucket, not just aggregate AUC. If it adds no useful discrimination, redesign the evidence source instead of counting correlated votes twice.

## 10. Required test artifacts and unresolved decisions

- Annotation format: local interval/word records with recording ID, track, start/end, speaker ID, speech/overlap label and adjudication confidence. Annotator disagreement is retained. Fixture manifests carry provenance and split, not audio in external-review packets.
- Deterministic recovery tests use a fake decoder with exact known tokens/timestamps: each expected token is committed once; overlapping audio may intentionally decode in multiple generations. Audio-range replay across generations is not itself a duplication bug.
- Real replay uses manually verified word-boundary neighborhoods (at least two seconds either side of resets) against annotated speech, not offline ASR as unquestioned ground truth. Report insertions/deletions, genuine repetition preservation and alignment uncertainty. No fixed 0.9 text-containment heuristic is presumed sufficient.
- P0 must settle dependency hooks/reset observability, exact binary/model provenance and independent-embedding feasibility. Missing APIs require a separately scoped patch; their absence is not papered over with fake confidence or repeated centroids.
- P1 must demonstrate responsive-stall recovery and independently demonstrate hang detection/gap reconciliation. Add fake never-returning inference and bounded stop tests; stop/UI return cannot await the hung manager indefinitely. Keep capture ownership and post-meeting handback safe until the worker really retires; mark final processing deferred if model/resource handback is unsafe.
- P2 must validate the proposed decision structure and choose thresholds using development data only. No-reference positives, playback-with-unreadable-reference negatives and mixed-turn short interjections are mandatory adversarial fixtures.
- P3 must settle the clean-embedding API or explicit identity fallback, versioned consumer contract and uncertainty review UI before user-visible activation. Accepted speech must not require a profile; fallback must not create a new person per fragment.
- Product/engineering review must approve uncertain-content visibility/export behavior and revised quantitative gates before implementation activation. No new cloud upload, recording retention expansion, or model download is implied by this planning task.
