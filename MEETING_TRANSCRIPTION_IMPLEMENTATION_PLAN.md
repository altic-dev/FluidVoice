# Meeting transcription: implementation plan

Status: the canonical backend foundation, FluidAudio Nemotron runtime, and local Parakeet+Nemotron
composite backend are implemented and tested. Release dependency/model delivery and rollout remain.
Default: Parakeet TDT v2 + Nemotron diarization. Live captions retain Parakeet realtime.
Scope: local meeting backend now; Muse/Google adapters and cloud UI later.

This is the execution companion to `MEETING_TRANSCRIPTION_BACKEND_ARCHITECTURE_PLAN.md`.
Where the earlier design differs, the decisions here take precedence. It replaces speculative
requirements with explicit milestones. Shipping is scheduled with the production Nemotron release;
pin and revalidate that artifact at release time.

## 1. Reuse the existing abstractions

`MeetingProcessingControlling.process` remains the entry point used by `MeetingSessionCoordinator`.
`MeetingProcessingPipeline` remains the workflow owner. Do not add another coordinator with the same
responsibilities. `TranscriptionProvider` remains the ASR component interface.

Add `MeetingTranscriptionBackend` beneath the existing pipeline. It computes timed text and anonymous
speaker assignments. The local implementation composes Parakeet and a stateful Nemotron session;
future unified providers can return their own assignments through the same final-result contract.

The pipeline owns selection, activity ownership, input mapping, checkpoints and final publication.
The extracted `MeetingTranscriptAssembler` owns capture admission, existing echo policy, product
speaker IDs and conversion to `MeetingProcessingResult`. The session coordinator continues to save
the final session. Backends cannot bypass product policy or write session JSON.

```text
MeetingSessionCoordinator -> MeetingProcessingPipeline
  -> selected MeetingTranscriptionBackend
       local: TranscriptionProvider(Parakeet) + Nemotron session + aligner
       future: unified provider adapter
  -> MeetingTranscriptAssembler -> MeetingProcessingResult -> coordinator save
```

## 2. Minimal contract and ownership

Names below are proposed interfaces, not existing implementations.

- `MeetingBackendID`: stable string-backed identity; registry of compiled factories, not dynamic plugins.
- `MeetingBackendDescriptor`: identity/version, platform/languages, local or hosted execution,
  supported final-output precision, track topology and known model limits.
- `MeetingBackendRequest`: immutable attempt ID, configuration snapshot, manifest and access to its
  validated audio spans. No global settings or arbitrary session-directory access in the new backend.
- `plan(request)`: validates compatibility and returns an immutable plan before model work.
- `execute(plan, resume, stageSink, progress)`: returns final evidence. `stageSink` is an injected
  asynchronous checkpoint writer owned by the pipeline; it validates attempt generation and hashes,
  atomically persists a stage, and acknowledges completion. Backends never write checkpoints directly.
- Each backend instance owns and drains its executors and models before returning or throwing.
  Final evidence may reference protected immutable stage files rather than copy an entire meeting
  into memory. Execute must await `stageSink` acknowledgements for every referenced stage before
  returning. References are temporary assembly inputs, never pointers in the durable result sidecar.
  Their lifetime ends only after the self-contained result sidecar and session are saved or the
  attempt is cleaned up.

Progress is advisory and bounded; a checkpoint acknowledgement is a separate durable operation.
The pipeline rejects late stage callbacks from a cancelled/superseded generation. Final publication
requires the complete acknowledged stage set and a current generation. Cancellation waits for
in-flight writes/inference, retains acknowledged canonical stages, discards unacknowledged data,
and then releases ownership. Explicit cancellation never publishes a result or starts fallback.

The final-output contract has timed text units (word or utterance), each with a stable source ID,
analysis-span references, precision, anonymous speaker assignment or ambiguity, and provenance.
Speaker activity is optional evidence; no synthetic word times or fake confidence are created for a
provider that only returns utterances. The local aligner runs once inside the local backend. The
assembler does not reassign provider words by rerunning a diarizer.

V1 is final-only. Future adapters may reconcile streaming revisions internally; live incremental
speaker captions will require a separate contract. Two fixture adapters exercise local aligned words
and already-diarized utterances. They prove result compatibility, not future API/network behavior.

## 3. Input, safety and identity rules

Build a source manifest from finalized chunks, with source-file offsets, valid decoded samples,
source PTS, track identity, protection metadata, discontinuities and existing content hashes.
Maintain explicit source -> analysis -> presentation mappings; apply existing VPIO clock correction
once, not again after alignment. Account for actual decoder priming and resampling behavior rather
than guessing a universal AAC delay. Unknown clock-fit data is recorded as unknown, not fabricated.

Keep app and mic streams separate in online calls. Reject future plans that require mixing them and
lose track attribution. A word may reference multiple adjacent files on the same track, but never
bridge a missing/inadmissible span. Split untimed utterance boundaries only with real timing evidence;
otherwise reject the whole affected utterance with a coverage reason.

Use one diarizer state across contiguous admissible durability files. Define a separate
`analysisEpochID`: start a new epoch for missing/unreadable audio, a real clock discontinuity,
microphone-device replacement or an inadmissible microphone interval. Apply the capture admission
mask before feeding Nemotron; unsafe audio must not update its speaker cache. V1 drains and resets
after such a hole rather than assuming skip-frame state remains valid. Metadata changes alone do
not reset an epoch if input remains continuous and admissible. Retain gaps in presentation mapping.
V1 does not automatically merge identities across epochs. Label continuity is a model property to
evaluate, never proof of identity.

Preserve the existing mode-specific admission contract: admitted headphones/acoustically closed,
VPIO-protected and attested AEC3 eras remain usable. For new online-call unsafe microphone intervals,
exclude text from normal transcript/export and record `inadmissibleCaptureEra`; calling it Unknown
does not make it admissible. Retain legacy-era behavior only through the existing explicit legacy
compatibility policy. In-room mic audio does not require echo protection.

Apply the current signal/text echo policy after time mapping. Matching text alone cannot prove echo:
include fixtures where the local person genuinely repeats the remote person. Suppressed mic copies
get a disposition; app copies remain. Residual echo detected after ASR may already have affected
Nemotron state; do not claim that postprocessing can undo it. Exclude echo-only tokens from product
speaker/identity evidence and evaluate future assignment quality on residual-echo fixtures. AEC
protection indicates audio safety, not who owns the voice.

Only the assembler creates product speaker IDs, scoped to attempt, track, analysis epoch and token.
No cross-track equality by slot, no use of Nemotron pre-encoder features as speaker embeddings.
The new backend identifies at most one You only with explicit product identity evidence, such as a
user assignment; otherwise anonymous mic speakers remain available with Unknown identity. Do not
copy the legacy prototype-dependent You election with empty/fabricated embeddings. Keep legacy
election unchanged in the legacy adapter and make this deliberate new-backend behavior visible.

The eight-slot model cannot reliably announce a ninth unseen voice or slot reuse. Display its limit,
test more-than-eight-speaker fixtures, and report measurable slot occupancy as a warning only.
Do not claim guaranteed overflow detection or automatically merge/switch engines based on count.

## 4. Coverage, result persistence and retry

The pipeline maintains receipts per requested input span: processed (including no speech), failed,
skipped or inadmissible. The assembler compares these receipts with the manifest independently of
returned text. This detects missing work; it cannot prove an ASR model recognized every spoken word.
Every recognized text-unit ID has exactly one final disposition: emitted, ambiguous-unassigned,
outside-activity, echo-suppressed, inadmissible, or rejected for invalid timing. Backend truncation
also creates a span-level coverage gap; no invented word represents missing audio.

Persist a versioned result sidecar containing the disposition ledger, ambiguity candidates and
coverage receipts. Session JSON stores its schema/hash/reference and the normal transcript segments.
Ambiguous admitted text renders once as an unassigned segment, so it remains visible in normal
transcript/export. Excluded unsafe/echo text is not resurrected by sidecar export. New fields decode
optionally for old sessions. Sidecar retention/deletion follows its session, not scratch cleanup.

Disposition precedence: validate timing/provenance first and quarantine invalid units from normal
output (no interval arithmetic on invalid bounds); for valid units use inadmissible-capture-era,
then echo-suppressed, outside-activity, ambiguous-unassigned, then emitted. If an indivisible unit
touches an excluded interval, exclude that whole unit and record its admissible portion as incomplete
coverage. Split only with real timing evidence. The same rule applies to words and coarse utterances.
In-room mode bypasses online-call echo admission. Test mixed-safe/unsafe and ambiguous-plus-echo
utterances so ambiguity cannot override exclusion.

Use attempt-scoped checkpoint maps with activity per track/analysis epoch and ASR text per chunk.
Store canonical results, not Nemotron cache embeddings. Mid-epoch interruption therefore replays
that epoch from its beginning, while finished epochs and ASR chunks can resume. Do not promise
arbitrary mid-epoch resume or small replay cost.

The assembler materializes a self-contained sidecar from acknowledged stages, streams it to bounded
storage, and verifies its checksum before the coordinator saves the session reference. No final
sidecar points at disposable stage files. Keep checkpoints until that session save succeeds.
Stage/result writes are atomic and checksummed. On crash, resolve staged/unreferenced files using
the attempt journal; source recordings and the last saved transcript are never overwritten by a
partial attempt. Final publication verifies the attempt is still current, preventing late completions.

Fingerprint actual backend/version, all local model hashes, effective preprocessing/postprocessing,
language, mapping and admission policy, source content hashes, and processing-contract version.
Use stored hashes for identity and verify content when reading; a stored digest alone does not prove
the file is still intact. Retry using acknowledged immutable activity evidence preserves its IDs and
explicit aliases. If an unfinished epoch must be replayed, allocate a new epoch-evidence generation
and invalidate that epoch's speaker tokens/aliases with a visible notice. Include evidence generation
in speaker keys; resumed ASR text-unit IDs can remain stable. Recomputed slots never inherit aliases
just because an ordinal or attempt ID repeats.
Reprocessing with changed settings/backend gets a new attempt; retain old user corrections with the
old result and never transfer them by speaker ordinal. Old checkpoints resume only if their actual
ASR configuration and full fingerprint are representable; otherwise restart explicitly.

V1 legacy backend is a manual rollback/development choice. Automatic runtime fallback is deferred:
it adds checkpoint and identity races without helping the first integration. A failed attempt keeps
recoverable audio and reports a typed failure. No automatic local-to-cloud path exists.

## 5. Model delivery and FluidAudio work

The DMG contains runtime code and a pinned manifest; download weights separately before processing.
FluidVoice owns model readiness, download progress, cache lifetime and atomic installation. FluidAudio
accepts a validated local model URL and owns inference/preprocessing/session state. It does not own
FluidVoice settings, downloads or UI.

Download/readiness is a separate user-visible preparation step before `plan` succeeds. The plan
contains handles to validated pinned artifacts; `execute` performs no downloads. Recheck artifacts
when opening them, and report missing/changed artifacts as a readiness error. For the first local
backend use the existing meeting Parakeet v2 English policy with vocabulary boosting, pronunciation
matching, dictionary rewriting and unified-final features disabled; reject unsupported requested
options explicitly. Multilingual or enhancement options need later model/evaluation support.

Develop in a maintained FluidAudio checkout/branch, never Xcode DerivedData. Pin the resulting commit
in both Xcode and Swift package configuration. Generalize speaker geometry without altering existing
four-speaker Sortformer defaults, or add a dedicated Nemotron host where differences warrant it.
The compiled public API must expose begin/process/finish/reset and explicit state ownership; generic
`processComplete(file:)` resetting for each file cannot implement this workflow.

Before host implementation, inspect the actual CoreML artifact and NVIDIA reference to freeze input
dtypes/shapes, cache geometry, valid-region slicing, activation semantics, left/right contexts,
mel stride and output temporal resolution (including any high-resolution head). The local README
and validation notes disagree on several details. `pred_score_threshold=0.25` in a cache/parity script
does not establish the product activity onset/offset threshold. Freeze both separately from reference
inference configuration and labelled evaluation. Verify the graph already returns probabilities.

Download manifest includes immutable revision, hashes, archive byte limits, supported OS/architecture,
model contract and preprocessing version. Prefer a validated `.mlpackage` compiled locally into a
versioned `.mlmodelc` cache initially; use precompiled distribution only after target OS/architecture
compatibility tests pass. Protect archive extraction against traversal/symlinks and excessive expansion.
Retain the old known-good version until validation and atomic activation complete. Model downloads
are network operations; meeting inference remains local after installation.

## 6. Reviewable implementation sequence

| Change | Deliverable / primary files | Exit condition |
|---|---|---|
| A. Contracts and legacy wrapper | Backend/registry types; existing `MeetingProcessingControlling` and `MeetingProcessingPipeline`; wrap `SpeakerDiarizationService` | Existing golden transcripts, IDs, echo decisions and retry behavior preserved; final-word and utterance fixtures accepted; malformed evidence rejected |
| B. Immutable meeting selection and ownership | `MeetingProcessingConfiguration`, `MeetingASRPreparationOwner`, narrow `ASRService` factory, `SettingsStore`, meeting readiness UI | Dedicated setting independent of dictation; attempt snapshots immutable; cancellation drains; missing/unknown IDs and old settings migrate explicitly |
| C. Timeline and durable evidence | Analysis manifest, assembler, result sidecar, `MeetingModels`, coordinator save/retry/export | Gaps, priming and rate mapping tested; word ledger persisted; crash between sidecar/session save recovers; old sessions decode; unsafe mic text excluded |
| D. FluidAudio Nemotron host | Maintained fork Sortformer/Nemotron runtime and reference fixture tests | Actual artifact contract pinned; mel and cold/warm multichunk parity pass; original Sortformer regression tests pass |
| E. Composite backend and downloader | `ParakeetNemotronMeetingBackend`, local model manifest/download integration | One Nemotron state per analysis epoch; unload then dedicated Parakeet ASR; word alignment; separate tracks and epoch retry verified |
| F. Default and release validation | Meeting backend default, production checkpoint pin, meeting model readiness | Held-out speaker/word quality and resource gates pass; app packages runtime only; installed model works offline |

A precedes B and C. D may proceed independently after the model-contract audit. E depends on B/C/D;
F depends on E and production-artifact revalidation. Preserve general dictation and standalone file
transcription behavior. Keep the first extraction small; required result-schema changes belong in C,
not the output-equivalent A refactor. Each change has its own review and focused regression checks.

B migration table: an absent preference resolves to the legacy wrapper through A–E and to the local
composite only in F. An explicit supported choice is honored; unknown/unavailable IDs remain
unavailable and never silently choose a backend. During A–E the composite is an explicit development
choice. F alone changes the default for new attempts; existing attempts retain their snapshot.
Preserve the actual selected ASR on legacy checkpoints where representable, otherwise restart with
an explicit notice rather than relabeling old results as Parakeet v2.

C makes the manifest the only new source-to-presentation mapper. Remove the corresponding legacy
de-drift application when switching that adapter to mapped evidence; never apply both. A may wrap
the existing final times as an explicit temporary compatibility path. Regression tests at C verify
unchanged timestamps/echo windows for that legacy path, not only A's initial goldens.

D/E isolation exits: two test sessions cannot share mutable diarizer state; preparation/drain leaves
dictation/file-transcription executors untouched; at most one local meeting model is resident in the
measured loaded-set sequence; missing weights fail at readiness with no download during inference.

The coordinator retains the existing exclusive meeting activity policy for v1. Requests to start
dictation during final processing remain blocked with the existing UI behavior. Do not implement
preemption in this refactor: automatic pause/unload/resume needs a separate product decision and
would otherwise repeatedly replay long Nemotron epochs. Own dedicated meeting model instances;
reuse cached weight files, not mutable dictation executors. Loaded-set sequence is none -> Nemotron
-> drained -> Parakeet -> drained. Preparation may validate both artifacts without loading both.

## 7. Acceptance and future extension

- Golden legacy outputs and file/dictation tests pass after extraction; new behavior tested separately.
- Reference audio features and CoreML predictions match declared tolerances over cold/warm/long runs.
  Digital impulse fixtures test the audio mapper only; annotated speech tests ASR/diarizer timing.
- Speaker continuity across 60-second boundaries, actual discontinuities, headphones transitions,
  eight and more-than-eight speakers, short interjections, overlapping/repeated speech are evaluated.
- Every planned span has a receipt, every recognized text unit a disposition, and unassigned admitted
  text remains visible. Test silent spans, missing results, corrupt audio and provider truncation.
- Cancellation is checked between bounded model calls; stale completions cannot save a result or
  unload a newer operation. Measure wall-clock drain and replay cost, including mid-epoch cancellation.
- Test 8/30/60/120-minute sessions on the named minimum supported Apple Silicon Mac. Before F,
  record hardware and freeze numeric p95 time-to-transcript, peak RSS, cancellation and disk budgets
  from baseline measurements. Do not claim a guessed 10x speedup as a verified product requirement.
- Held-out DER, speaker-attributed WER, merge/split counts and short-speaker recall must beat the
  selected legacy baseline targets established before tuning; plain ASR WER must not regress.
  Speaker count agreement alone and conversion parity alone are insufficient quality gates.

Later Muse/Google adapters implement the same final evidence contract using separate inputs for
online calls. Recheck actual APIs and support timed utterances when word precision is unavailable.
Keep backend selection separate from dictation; v1 shows local model readiness, later releases add
a provider picker plus credentials/consent. Cloud transfer, auth refresh, idempotency, regional
processing, deletion and incremental captions remain future adapter work with dedicated tests.

## 8. Review record

The longer architecture draft previously received direct Grok 4.6 and Claude Opus reviews.
This companion received a fresh orchestrate `standard` review served by Grok 4.6 (143.8 seconds).
The reviewer assessed the full inline plan and reported five P1 and three P2 findings. Its verdict
applied to the pre-revision draft, not the corrected document.

| Finding | Disposition |
|---|---|
| P1: durable sidecar might retain disposable stage references | Accepted: self-contained sidecar, checksum verification, session save before stage cleanup |
| P1: backend could return before asynchronous stage acknowledgements | Accepted: execute/publication require full acknowledged stage set; late generations rejected |
| P1: coarse words/utterances lack exclusion precedence | Accepted with correction: validate bounds before interval rules, then conservative whole-unit disposition; no fabricated word timing |
| P1: excluded mic audio can contaminate speaker state | Accepted for known admission gaps: mask before inference and reset epoch; post-ASR echo cannot retrospectively be removed from model state and remains an evaluation risk |
| P1: default might change before rollout gates | Accepted: absent preference stays legacy through A–E; F is the only default switch; unknown values stay unavailable |
| P2: legacy and manifest could both correct timestamps | Accepted: one mapping owner and timestamp goldens at C |
| P2: epoch replay might attach old aliases to new slots | Accepted: epoch-evidence generation invalidates replayed tokens; immutable completed evidence retains aliases |
| P2: model isolation and downloads lack testable exits | Accepted: dedicated state, measured resident model set and zero execute-time downloads |

The router's tree-change flag was true because the main agent updated the architecture-document
header while review ran. Final repository checks showed no tracked source changes. The requested
review was plan-only. A reviewed plan is not an implementation or an end-to-end validation result.

## 9. Implementation progress — 2026-09-12

Completed implementation slice:

- Stage A: production pipeline dispatches through an injectable backend registry. Legacy algorithms
  remain available through an explicit compatibility/rollback backend.
- Canonical word/utterance evidence and structural validation are present. Registered canonical
  fixture backends now pass through C2 assembly/publication; the production registry remains
  legacy-only. No fake model output or fabricated timestamps.
- Registry identity, request/plan scope and legacy callback binding are checked before execution.
- Cancellation before execution and after a non-cooperative backend returns suppresses publication;
  tests prove that the serialization lease is released for the next attempt.
- B1: a dedicated persisted meeting-backend preference is resolved once per processing attempt.
  Missing settings choose the named production default; unknown IDs remain unknown. Injected registries and explicit
  overrides retain precedence. Tests prove a setting change cannot switch an executing attempt.
- B2a: `ASRService.withPreparedMeetingASR` now owns fixed Parakeet-v2 preparation under the exact
  meeting activity lease, retires dictation providers without deleting disk caches, serializes
  meeting inference on a dedicated executor, defers handback lease release until drain, and joins
  an owned scope body during termination. Parent- or shutdown-driven cancellation suppresses a
  non-cooperative body's late success. Dictation readiness/download entry points reject while the
  meeting claim is active. The meeting backend preference is included in backup/restore; missing
  legacy backup values migrate to the phase default and unknown IDs round-trip unchanged.
- C1: canonical backend evidence has an explicit fail-closed Codable schema. A separate versioned,
  self-contained result sidecar defines the closed text-unit disposition ledger and span coverage
  receipts without scratch references. Its session-confined store publishes a 0600 same-directory
  temporary file atomically, makes each attempt's stable sidecar immutable (byte-identical retries
  join; conflicts fail), hashes and reads back the payload, and verifies reference format, byte
  count, checksum, attempt and backend on every read. It is intentionally not referenced by
  `MeetingSession` or accepted by the pipeline until the manifest/assembler publication transaction
  exists. Structural tests cover schema/enum failures, ledger conservation, ambiguity, timing
  quarantine, source/epoch bounds, tampering, path/symlink escape and overwrite conflicts.
- C2a: a versioned analysis manifest, frozen-plan projection, real chunk observation boundary and
  builder now map each planned `(track, chunk)` into an exact cover of admissible spans and typed
  gaps. The observer confines paths, rejects symlinks, rechecks bytes/SHA-256 and reads actual
  AVFoundation format/frame facts; codec priming remains explicitly unknown when the decoder does
  not report it. The builder preserves separate app/mic analysis streams, splits within chunks at
  capture-era and discontinuity boundaries, applies the existing era-local de-drift transform once,
  resets diarizer epochs only for recorded causes, and represents short decoded audio with a backed
  prefix plus an explicit trailing gap. Canonical online-mic admission is positive-proof only;
  in-room mic and application audio follow their distinct rules. This contract remains unwired.
- C2b1: canonical evidence now uses exact analysis-span references and per-track analysis time. The
  pure shared assembler reconciles span receipts independently of text, rejects text that overlaps
  failed/skipped/truncated work, applies echo/activity/ambiguity precedence, maps through the
  manifest once, mints attempt+track+epoch+generation-scoped speaker IDs, and produces deterministic
  segments plus a complete disposition ledger. Invalid/non-finite evidence is durably quarantined;
  sidecar ordering and disposition reasons are canonical and fail closed.
- C2b2: backend plans freeze a legacy-versus-canonical result contract. Canonical execution receives
  the product-owned manifest, obtains echo decisions from a separate fail-closed product provider,
  assembles off the main actor, writes/fsyncs/read-verifies an immutable sidecar containing the full
  manifest, and returns its reference only after cancellation checks. The coordinator saves that
  reference, transcript, lineage and durable completeness together before checkpoint deletion; a
  failed save restores the previously published transcript/reference and leaves the new sidecar
  unreferenced. Legacy execution builds no manifest, requests no echo evidence and writes no
  sidecar. It remains the default/rollback backend.
- D runtime host: the independent FluidAudio branch now adds eight-speaker configuration, strict
  CoreML shape/dtype validation, Float16 decoding, caller compute configuration, local model loading,
  an immutable model-family mel contract, NeMo-valid frame counting, complete-file core-tail
  processing, and guarded FIFO/speaker-cache progression. Source/test changes are preserved in
  `tools/patches/fluidaudio-nemotron-compatibility.patch`.
- E local composite: `MeetingParakeetNemotronBackend` is registered as a selectable canonical
  backend. It materializes verified 16 kHz epoch audio, runs fresh Nemotron state per track/epoch,
  drains Nemotron before one attempt-wide prepared Parakeet scope, maps both model timelines through
  actual resampled span ranges, emits exact receipts/evidence, performs causal word-context echo
  filtering, and publishes turn-sized product segments while retaining word evidence in the sidecar.
  Model lookup supports an injected path, a development environment override and a versioned local
  cache; no hosting URL is guessed and weights are not bundled.

Verification:

- App: 135 selected backend, recovery, global-speaker-stitching and coordinator tests passed in the
  Stage A/B1 pass. A later focused B2a run passed 52 backend/preparation/scope tests, including
  non-cooperative preparation/body cancellation, termination join, deferred lease release, fixed
  provider policy and backup migration.
- App after C1 review fixes: 72 selected sidecar, backend, preparation and scope tests passed with
  zero failures. The new persistence code adds no Swift actor-isolation warnings; existing project
  warnings remain outside this slice.
- C2a focused manifest + C1 sidecar + backend suite: 50 tests passed with zero failures after parent
  fixes for throwing-map compilation, EOF hashing, partial-decoder coverage and mid-chunk
  discontinuity epoch splitting.
- Final C2 publication/assembler/sidecar/manifest/backend/recovery selection: 181 tests passed with
  zero failures after parent and adversarial-review fixes.
- FluidAudio: the 67-test Sortformer/legacy integration selection passed. The 10-test Nemotron suite
  also passed with the supplied CoreML model loaded and run end-to-end across one fixed window plus
  its final core tail. Model-quality and performance measurement are accepted from the completed
  model-validation work and are not repeated here.
- Dependency patch passes reverse-apply validation against its local checkout.
- Composite integration selections: 228 tests passed, one opt-in real-model test skipped, zero
  failures. The opt-in real-model smoke test separately passed with the supplied `.mlpackage`.
- Grok 4.6 adversarial reviews through orchestrate identified cancellation/request binding and
  model-geometry/overflow gaps. Routed corrections plus parent integration/test fixes address them.
  A final scoped Grok review of selection/cancellation completed successfully (180 seconds) and
  found no remaining actionable regressions in that contract. This does not cover unfinished
  assembly, model-preparation or end-to-end parity work.
- The B2a review dispatch was attempted through orchestrate and direct Grok 4.6; both repeatedly
  exhausted the Grok CLI turn limit after reading the files without returning a verdict or editing
  the tree. Direct Claude fallback was unavailable because its account session limit was exhausted.
  Parent review found and fixed shutdown/body ownership and late-success cancellation gaps, but this
  slice therefore still needs an independent adversarial verdict when either review channel recovers.
- C1 implementation ran through authorized Fireworks Kimi K3 after the configured router exposed
  only Claude implementation tiers. A separate review-only Kimi session found no P0/P1 issues and
  two P2 durability defects: overwriting an already-referenced same-attempt result and publishing
  the stable filename before tightening permissions. Parent fixes make attempt results immutable and
  publish only a permission-tightened temporary file; the same pass also applied the review's
  mapped-read, schema-separation, epoch/chunk and comment corrections. Streaming serialization and
  descriptor-relative TOCTOU hardening remain later C work.
- C2a implementation used the user-authorized orchestrator heavy route. Its MCP response timed out,
  but the underlying Claude worker completed the manifest/observer/builder files; parent review
  supplied the missing tests and fixed four reproduced defects. Adversarial review was dispatched
  through both standard and heavy orchestrator routes without tree edits; the standard route ended
  task-failed after reading, and the heavy worker's verdict was lost when the MCP transport expired.
  A bounded retry was unavailable because both recipients entered cooldown; the later read-only
  Kimi C2a+C2b1 review supplied the missing visible verdict.
- C2b implementation used Fireworks Kimi K3 through OpenCode at the user's direction. Two separate
  read-only Kimi adversarial passes reported no P0s. Accepted findings fixed text emitted from
  non-processed receipt regions, missing epoch-evidence generation, invisible quarantine
  completeness, canonical skips poisoning future plans, failed saves persisting a new result under
  `.failed`, main-actor assembly, unchecked echo targets, non-durable rename, non-self-contained
  span references and misleading coverage event/reason labels. The production priming finding is
  accepted as a release blocker; it is not "fixed" by guessing zero.
  Rejected review claims: moving attempt-ID selection outside the gate cannot reread newer state
  because the input session is a value snapshot; Float32 input validation already existed; fixed
  model dimensions were incorrectly described by one review as mutable.
- D frontend/state implementation was attempted through the orchestrate router, but dispatch was
  rejected because the configured fallback could cross to an unapproved recipient. The scoped work
  proceeded through authorized Kimi K3. A read-only adversarial pass verified the frontend, tail,
  prediction-slicing and cache-cadence contracts; its two P3 hardening findings were fixed. A full
  legacy integration run then exposed and drove the fix for model-family framing isolation.
- E implementation was attempted through the orchestrate standard route, but its automatic Claude
  fallback was rejected by the source-disclosure boundary. Authorized Kimi K3 produced the scoped
  implementation; parent review fixed a cross-module generic witness crash, decoder short reads,
  span-resampling time mapping and artifact binding. A later read-only Kimi adversarial pass found
  no P0s. Accepted findings fixed future-audio echo suppression, word-per-row product publication,
  cancellation checks between materialization/model calls, duplicated activity policy and the
  hash/open/read race. The local dependency override remains a P1 merge blocker until a maintained
  FluidAudio fork revision is published and pinned.

Still open:

- Model delivery: add recording-time readiness UI/preflight and the pinned hosted artifact manifest.
- C3: acknowledged per-stage checkpoint maps, attempt journal/orphan-sidecar reconciliation, bounded
  streaming sidecar serialization and sidecar-aware export/recovery verification.
- D release step: commit the completed FluidAudio runtime work to the maintained fork and pin it.
- E release step: replace the development-only local FluidAudio override with the maintained-fork
  revision in both SwiftPM and Xcode. The current override is intentionally not merge-ready.
- F release remainder: production-artifact identity pin. The default rollout now selects the local
  Parakeet + Nemotron composite. Existing model validation is accepted; no new quality/performance
  benchmark is planned.

The supplied folder contains the CoreML packages, conversion scripts and copied NeMo source needed
to implement the runtime contract. The original `.nemo` and numerical fixtures are not required for
the remaining application integration because the separate model-validation work is accepted. The
The development workspace uses the maintained local FluidAudio checkout. A clean clone cannot use
that ignored path, so the fork commit/revision pin is required before these changes are committed.

The production observer truthfully records `.unknown(.decoderDidNotReport)` when decoder/container
priming is unavailable. The accepted model-validation decision permits the Stage F default switch;
the legacy backend remains registered as an explicit rollback selection.

Execution interruption: the router's heavy implementation entry reported a Claude session limit
resetting at 2:30 p.m. Pacific. Grok implementation calls reported failure; a late B1 preference
patch nevertheless arrived and was reconciled, compiled and tested by the parent. Grok read-only
snapshot reviews did succeed. No commit, push or app reinstall performed.
