# Meeting Transcription Backend Architecture and Rollout Plan

Execution source of truth: [Meeting transcription implementation plan](MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md).
That shorter companion supersedes conflicting details here about model thresholds, microphone
admission, preemption, automatic fallback, result persistence and model delivery. This document
retains the earlier design rationale and historical review discussion.

Status: reviewed design proposal

Date: 2026-09-12

First-release default: local Parakeet TDT v2 ASR + Nemotron-3 diarization

Future candidates: Meta Muse Voice Transcribe, Google Chirp, and other local or hosted backends

## 1. Decision summary

FluidVoice should introduce a meeting-specific backend abstraction above the existing dictation
`TranscriptionProvider` protocol.

The product-level operation is one request and one result:

```text
MeetingProcessingCoordinator
    -> MeetingTranscriptionBackend
    -> canonical evidence
    -> MeetingTranscriptAssembler
    -> MeetingProcessingResult
```

The first backend is a composed local implementation:

```text
ParakeetNemotronMeetingBackend
    Parakeet TDT v2       -> timestamped words
    Nemotron-3 Sortformer -> speaker activity spans
    local aligner         -> speaker-attributed words and turns
```

Future unified services such as Muse or Google Chirp implement the same backend contract but may
produce diarized text in one provider call. Their adapters still normalize into the same canonical
evidence and pass through the same FluidVoice assembler and safety policy.

Do not extend the general dictation `TranscriptionProvider` with diarization, upload, speaker, or
meeting-persistence concepts. Dictation and meeting transcription have different lifecycles,
privacy boundaries, inputs, outputs, and recovery requirements.

## 2. Product requirements

### First release

- The default meeting backend is `local.parakeet-tdt-v2+nemotron3-fp16`. Development targets the
  preview model contract now; the artifact is replaced and pinned to the production Nemotron release
  before FluidVoice ships.
- Parakeet remains responsible for speech-to-text.
- Nemotron remains responsible for speaker activity only.
- Live captions continue using the existing live-caption path and simple You/Them presentation.
- Final diarization runs after durable meeting audio has stopped.
- Existing application and microphone tracks remain separate evidence sources.
- First release performs no automatic cross-era speaker reconciliation. Era-local speakers remain
  distinct; users can reconcile them through the existing explicit speaker-merge workflow.
- Online-call final processing may refine the simple live You/Them labels. At most one verified
  microphone speaker becomes You; other microphone speakers remain Unknown. In-room processing does
  not infer You automatically.
- Processing remains local, except for any unrelated user-selected AI enhancement that already has
  its own explicit policy.
- The current offline-clustering/cosine implementation remains a hidden local rollback backend until
  Nemotron quality and reliability gates pass.

### Later releases

- Users may select an installed/configured meeting backend independently of their dictation model.
- Hosted backends must require explicit disclosure and consent before any meeting audio leaves the
  Mac.
- Adding a backend must not require changing `MeetingSession`, transcript persistence, export, or UI
  rendering merely because the provider uses a different native response format.
- Backend selection changes apply only to new processing attempts. They never mutate an active or
  resumable attempt.

### Non-goals

- Fusing Parakeet and Nemotron into one CoreML graph.
- Making the meeting backend also control dictation.
- Implementing Muse or Google in the first release.
- Automatically switching from local processing to a hosted service.
- Inferring real names from voiceprints or carrying speaker identity between meetings.
- Treating an expected speaker count as ground truth in product behavior.

## 3. Current-state constraints

The design must account for these properties of the current tree:

- `TranscriptionProvider` is an ASR-oriented protocol and returns text plus optional word timings.
- `MeetingProcessingPipeline` directly obtains `ASRService.fileTranscriptionProvider` and constructs
  `SpeakerDiarizationService` itself.
- `SpeakerDiarizationService` directly owns FluidAudio's `OfflineDiarizerManager`.
- The current meeting pipeline diarizes each durability chunk independently, then uses embeddings and
  cosine-based global stitching.
- `MeetingFinalProcessingConfiguration` has an ASR model and diarization fingerprint but no stable
  meeting-backend identity.
- `MeetingASRPreparationOwner` is a tested but currently unwired ASR-only ownership seam. Do not build
  a second preparation lifecycle beside it; either generalize it or deliberately replace it.
- The processing checkpoint is written after the application-audio pass and is valid only for an
  exact pipeline/model/configuration fingerprint.
- Online-call sessions contain separate application-audio and microphone tracks with capture-era,
  echo-protection, coverage, and provenance rules.
- `MeetingTranscriptSegment` has one optional `speakerID` plus an overlap classification. It cannot
  persist one word as belonging to multiple speakers without a versioned schema change.

## 4. Layered architecture

### 4.1 MeetingProcessingCoordinator

Responsibilities:

- Snapshot the selected backend and all configuration exactly once at attempt creation.
- Hold the exclusive audio/model activity lease.
- Resolve a backend through the registry.
- Validate request compatibility before loading models or uploading audio.
- Own cancellation, retry, fallback authorization, and progress delivery.
- Invoke the backend and then the product-owned assembler.
- Persist attempt lineage and checkpoints.

The coordinator must not interpret model-native tensors, provider speaker tags, or API payloads.

### 4.2 MeetingTranscriptionBackend

This is the product extension point. A backend may be composed or unified, local or hosted.

Conceptual contract:

```text
identity and descriptor
plan(request) -> validated immutable execution plan
prepare(plan, progress)
transcribe(plan, progress) -> MeetingTranscriptionEvidence
```

Requirements:

- `Sendable` ownership with one operation per prepared instance.
- Cooperative Swift task cancellation.
- Receive an immutable `MeetingRuntimeEnvironment` containing every setting, credential handle,
  model path, clock policy, and product dependency the operation may use.
- No implicit access to `SettingsStore.shared` after planning. DEBUG/contract tests install a guard
  that fails if meeting processing reads the singleton during an active attempt.
- No mutation of session persistence.
- No direct creation of product `SessionSpeakerID` values.
- No direct emission of UI events.
- Cleanup on success, error, and cancellation.

The planning call is important. A collection of capability booleans is not enough to decide whether
a particular meeting, language, duration, topology, and privacy policy can be processed. Planning
must either return a complete immutable plan or a typed incompatibility before side effects begin.

### 4.3 MeetingTranscriptionBackendRegistry

The registry maps stable string-backed IDs to factories and descriptors.

Use a string-backed value type rather than a closed persisted enum so a removed or unavailable future
backend can be decoded safely. Unknown IDs resolve to an explicit unavailable state; they must not
silently select a cloud service. A migration may select the local default for a new attempt only.

First-release registrations:

- `local.parakeet-tdt-v2+nemotron3-fp16`
- `local.parakeet-tdt-v2+offline-diarizer-v1` (hidden rollback)

Future registrations may include:

- `meta.muse-voice-transcribe`
- `google.chirp-3`

Do not add unavailable future providers to the shipping picker. Prove extensibility with fixture
backends and contract tests instead of disabled marketing UI.

### 4.4 Backend descriptor and capabilities

The first-release descriptor includes only fields consumed by planning or selection:

- stable backend ID, display name, implementation version, and vendor;
- execution boundary: local or hosted;
- supported languages and language-selection mode;
- accepted input topologies: separate tracks, interleaved multichannel, or composed mono;
- supported meeting modes: online call, in-room, or both;
- maximum duration and speaker capacity, when known;
- timing granularity: utterance, word, or frame; `none` is incompatible with meeting processing;
- one of the valid evidence profiles defined below;
- model/download readiness and required local bytes;
- credential and network requirements.

Hosted retention, region, remote-job, and billing metadata are added with the first real hosted
backend in Phase 6 rather than speculated into the first-release contract.

Capabilities describe facts. The backend's `plan` method decides compatibility and produces a typed
reason when a request cannot be served.

Normal product requests never contain an exact expected speaker count. A provider may receive a
declared capacity as a maximum hint, never attendance truth. Planning rejects an API that requires a
known exact count the product cannot honestly supply.

### 4.5 Canonical evidence

All backends return `MeetingTranscriptionEvidence`, not `MeetingProcessingResult`. Version 1 accepts
two closed evidence profiles:

- `activityPlusWords`: separate timed words plus speaker-activity spans, used by the composed local
  backend. The backend runs the shared aligner and returns final diarized words.
- `diarizedWords`: final words or utterances already carrying run-local speaker tags, used by a
  unified provider. Online-call planning accepts this profile only with separate source-track
  provenance.

Anything else is a typed planning incompatibility. The assembler validates and maps final
attribution; it does not run a second aligner.

Version 1 evidence is final-only. Streaming partials, retractions, delayed speaker tags, and endpoint
revisions remain adapter-internal until the adapter can emit a committed final snapshot. A future
incremental evidence protocol requires its own versioned design; fixture tests must not pretend the
single-return contract proves it.

The canonical evidence model contains:

- a versioned evidence schema and backend lineage;
- one or more analysis streams;
- timed words, or at minimum timed utterances;
- speaker-activity spans when required by the evidence profile;
- backend-local anonymous speaker tokens scoped by run, analysis stream, track, and era;
- zero, one, or multiple active speaker tokens over an activity interval;
- timing precision and confidence semantics;
- a closed disposition for every input word/utterance: emitted, echo-suppressed,
  inadmissible-capture-era, coverage-gap, outside-activity, ambiguous-unassigned,
  provider-truncated, overlap-flattened, or speaker-tag-timeout;
- explicit backend coverage claims over the admissible analysis-manifest intervals;
- source-track and analysis-time mapping references;
- non-secret provider/model/configuration provenance.

Provider speaker labels such as `speaker_0`, `Speaker A`, or Google's numeric tags are scoped to one
backend run. They are not names, not cross-track identities, and not directly persisted as stable
session speaker IDs.

### 4.6 MeetingTranscriptAssembler

The assembler is owned by FluidVoice and is shared by every backend.

Responsibilities:

- Validate all evidence bounds, ordering, finiteness, and source mappings.
- Reconcile evidence against the analysis manifest: every admissible manifest interval must be
  covered by evidence or a typed gap. Backend self-reported gaps are not authoritative. Any
  unaccounted interval is a hard validation failure.
- Convert analysis time to the canonical meeting presentation timeline.
- Apply capture-era admission, AEC provenance, coverage-gap, and echo-safety rules.
- Be the sole owner that mints deterministic `SessionSpeakerID` values from attempt, track, era, and
  backend-token scope. Backends never mint product IDs.
- Apply online-call track semantics: application audio is remote evidence; microphone evidence is
  eligible for You/Unknown only after the existing safety checks.
- Suppress cross-track echo duplicates using the existing clock-compensated signal/text evidence.
  The microphone copy receives a typed `echoSuppressed` disposition; the application-track copy is
  never removed by this rule. Unknown AEC/protection state is fail-closed: the microphone word may
  remain Unknown but can never become You.
- Preserve canonical overlap evidence. Because the v1 persisted segment has one `speakerID`, choose
  at most one primary speaker per word, mark unresolved overlap as ambiguous, and retain the word in
  an explicit unassigned ledger. Do not duplicate it. True multi-owner word persistence is a later
  versioned schema change.
- Produce the existing `MeetingSessionSpeaker`, `MeetingTranscriptSegment`, coverage, and attempt
  structures.
- Reconcile a final word ledger on the presentation timeline so every backend word is emitted once or
  carries exactly one explicit non-emission reason. Per-stream backend conservation is necessary but
  insufficient.
- Convert provider truncation or uncovered admissible audio into explicit coverage gaps and an
  incomplete transcript state. Export remains possible only with a visible incompleteness marker;
  truncation never looks like successful complete processing.

No hosted backend may bypass this layer merely because it returns a polished transcript.

## 5. Canonical time and input topology

### 5.1 Analysis manifest

Before model work begins, FluidVoice builds an immutable `MeetingAnalysisManifest` from finalized
audio chunks.

It records mappings among:

```text
source-file local time <-> analysis-stream time <-> meeting presentation time
```

Each span records the source track, chunk, capture era, valid interval, discontinuity, protection
state, and checksum. Its time transform is piecewise affine and records host-clock anchor, rate
ratio, offset, sample-rate-conversion ratio, codec delay/priming, whether analysis time removes gaps,
and measured fit residual. A span whose residual exceeds the configured bound is `timingUncertain`;
its words remain explicit and ambiguous rather than receiving a confident speaker assignment.
Missing, corrupt, unfinalized, or inadmissible ranges remain explicit gaps.

Every evidence interval must round-trip through source, analysis, and presentation time within one
declared model frame and resolve to exactly one source track. Model time is never inferred from AAC
frame counts or durability-file boundaries.

Durability chunks are never presumed diarization boundaries.

### 5.2 Topology rules

- The local backend receives separate application and microphone analysis streams.
- In-room mode normally has only the microphone stream.
- Online-call hosted backends must accept separate per-track inputs with output provenance for every
  word/utterance. Planning rejects a backend that requires a mono mix or cannot preserve track
  provenance. Mixing would make AEC admission, You/Unknown, and cross-track echo suppression
  unverifiable.
- Composed mono is permitted only for a single-track in-room meeting. Multichannel online-call
  support is deferred until a real provider can return verifiable channel provenance; it requires a
  versioned topology-specific safety design rather than a descriptor flag alone.
- Composition, when permitted by the topology rules, is a product-owned, fingerprinted transform. A provider adapter may not
  invent a mixdown silently.
- Speaker tokens from separately processed streams are never equated by label or slot number.
- Temporary upload artifacts use protected storage and are deleted on all terminal paths and by
  next-launch stale-artifact cleanup.

## 6. Default local backend design

### 6.1 Execution strategy

`ParakeetNemotronMeetingBackend` is one application-level implementation with two model stages.

Recommended order until concurrent memory use is measured:

1. Build and validate the analysis manifest.
2. Prepare Nemotron.
3. Diarize each contiguous capture era statefully across its durability chunks.
4. Persist/checkpoint canonical speaker-activity evidence.
5. Release Nemotron resources.
6. Prepare Parakeet TDT v2.
7. Transcribe each readable source chunk once with word timings.
8. Align words to speaker activity.
9. Return canonical evidence to the assembler.

Loading both models simultaneously is not a requirement of the composite abstraction. Prefer bounded
memory and dictation preemption over nominal parallelism until measurements justify concurrency.
Time-to-final-transcript is also an acceptance gate. If sequential execution misses its latency
budget on the minimum supported Mac, reopen this choice using measured peak RSS and latency together.

### 6.2 Nemotron host

Implement the model host in the pinned FluidAudio fork, reusing its Sortformer pipeline while giving
Nemotron a distinct configuration/variant.

Required model contract:

- eight speaker slots;
- 16 kHz mono host audio;
- 128-bin NeMo-compatible log-mel features with dither disabled;
- 264-entry speaker cache;
- offline profile geometry from the converted model;
- exact FIFO-to-cache promotion behavior from the NeMo reference;
- output names `spkcache_fifo_chunk_preds`, `chunk_pre_encode_embs`, and
  `chunk_pre_encode_lengths`;
- predictions are already sigmoid probabilities;
- reference activity threshold defaults to 0.25, not FluidAudio's current Sortformer default of 0.5;
  it is immutable and fingerprinted for a run, with no per-track tuning or hysteresis in v1.

Do not apply sigmoid twice. Do not merge Nemotron slots post hoc. Do not treat pre-encoder embeddings
as speaker-identity embeddings; the local validation found them unsuitable for that purpose.

One Nemotron state spans all contiguous chunks in one track/era. Reset only at a declared analysis
boundary, not every 60-second file. The backend emits only run-local tokens. The assembler derives
product IDs from attempt, source track, era, and token.

V1 always splits speakers across eras. It performs no automatic reconciliation because label equality
is meaningless and the available pre-encoder representation is not a speaker identity embedding.
The existing user-driven merge/alias operation is the only cross-era reconciliation and must remain
idempotent across retry. If the model reuses a slot for a later voice or exhausts all eight slots,
mark a quality/coverage failure; never silently present the two voices as one identity.

### 6.3 Parakeet host

- Pin Parakeet TDT v2 independently of the user's dictation selection.
- Request model-native word timings once per readable source chunk.
- Preserve vocabulary and pronunciation policy only when the immutable meeting configuration enables
  them.
- Never re-read mutable global language/model settings mid-run.
- Unload or yield resources according to the shared audio/model arbiter.

### 6.4 Word-speaker alignment

Use half-open intervals and deterministic rules:

- Prefer the speaker with the greatest temporal intersection with the word.
- A unique active speaker receives the word.
- If multiple speakers overlap materially and no unique winner exists, preserve explicit ambiguity;
  do not duplicate the word into two transcripts.
- A word outside all activity may attach only within a track-specific measured tolerance.
- Microphone tolerance remains zero unless evaluation proves another value safe.
- Every word is assigned once or counted with a typed reason.
- Alignment belongs to the `activityPlusWords` backend path. The assembler validates the resulting
  final attribution and word ledger but does not align a second time.
- Provider text must not be re-transcribed per diarizer turn unless the word-timing path is technically
  unavailable and the configured fallback explicitly permits it.

### 6.5 Speaker limit

Nemotron has eight output slots. The backend descriptor declares that hard ceiling. Saturation or
unrepresentable speaker evidence produces a quality/coverage warning, not a silent ninth-to-eighth
merge. The system must not run the legacy backend merely to choose whichever result reports more
speakers; fallback is for typed technical failure, not quality arbitration. An echo-only slot does
not become a persisted speaker after suppression, but it still consumed raw model capacity and must
not be excluded from saturation detection.

## 7. Future unified hosted backends

### 7.1 Meta Muse adapter

Muse may return streaming text, speaker tags, and endpoint tokens from one model. For this final-only
v1 contract, its adapter buffers/reconciles provider revisions internally and maps only committed
output:

- emitted text/timing into canonical words or utterances;
- speaker tags into run-local anonymous speaker tokens;
- endpoint tokens into turn boundaries;
- missing precision or confidence into explicit capability metadata.

If a word never receives its delayed tag, the adapter returns it as unassigned with
`speakerTagTimeout`. Incremental UI delivery is a separate future protocol rather than a mutation of
checkpointed final evidence.

Muse remains subject to the same input mapping, product assembler, persistence, and privacy rules.
Its unified output does not make it a `TranscriptionProvider` for meetings.

### 7.2 Google Chirp adapter

Chirp batch diarization may return timestamped words with numeric speaker tags. Its adapter maps those
directly into canonical diarized words. Streaming transcription support does not imply streaming
diarization support; the descriptor and planner represent those capabilities independently.

### 7.3 Hosted-provider invariants

- No implicit local-to-cloud fallback.
- Explicit setup disclosure plus a per-meeting preflight of what audio is uploaded, where it is
  processed, expected cost, and provider retention controls. Processing shows a persistent upload/
  remote-processing indicator.
- API credentials live only in Keychain.
- No credential, signed URL, raw response, or provider job token in analytics or exported sessions.
- Remote job identifiers, if resumability requires them, are stored in a protected coordinator-owned,
  device-local envelope and never treated as transcript provenance. They are excluded from backup,
  export, analytics, and crash logs and are wiped on restore to another device or without matching
  credentials.
- Retry is idempotent where the provider supports it; otherwise the UI warns before creating a second
  billable job.
- Cancellation stops local work, requests remote cancellation when supported, and clearly reports
  when a provider may continue processing.

## 8. Selection and settings

Add a meeting-specific setting; do not reuse `selectedSpeechModel`.

```text
meetingTranscriptionBackendID = local.parakeet-tdt-v2+nemotron3-fp16
```

Persistence rules:

- Store only the stable backend ID in `UserDefaults` through `SettingsStore`.
- Store hosted-provider credentials through `KeychainService`.
- Include the meeting-backend selection in backup/restore, but never credentials.
- Distinguish a missing key from an unknown value: missing means use the local default for a new
  attempt; unknown remains inspectable and unavailable. An existing checkpoint may never resume
  under a substituted backend.
- Existing fingerprint-compatible checkpoints without a backend ID migrate only to
  `local.parakeet-tdt-v2+offline-diarizer-v1`. They never migrate to Nemotron or cloud. Older builds
  ignore the new preference and reject newer checkpoint versions rather than attempting downgrade
  resume.
- Call `objectWillChange.send()` when the future picker needs to react.

UI placement:

- Future picker belongs in Meeting Tools, not Voice Engine, because it controls final meeting
  processing rather than general dictation.
- First release may keep the setting internal while only one public backend is ready.
- Hosted choices display Local/Cloud, language coverage, speaker/timing capabilities, credential
  status, and an upload disclosure before activation.
- A backend is selectable only when registered and supported; do not ship disabled Muse/Google cards.
- Before recording, preflight the selected backend's registration, platform support, local model
  readiness or downloadable size, credentials, consent, and meeting-mode compatibility. Do not wait
  until the post-meeting attempt to reveal a missing credential or unavailable model.
- State clearly that the meeting backend is independent of the dictation model; selecting a different
  dictation engine does not alter final-meeting Parakeet policy.

## 9. Preparation, progress, and resource ownership

Generalize or replace `MeetingASRPreparationOwner` with a single
`MeetingTranscriptionPreparationOwner` that owns the selected backend's entire preparation lifecycle.
Do not retain two overlapping owners.

The owner holds:

- activity lease and attempt ID;
- immutable backend ID and execution-plan fingerprint;
- one preparation task;
- prepared backend instance;
- cancellation/drain task;
- progress relay.

First-release generic progress stages include:

- validating input;
- preparing/downloading components;
- identifying speakers;
- transcribing;
- finalizing.

Hosted upload/waiting states are added with the first hosted adapter in Phase 6. Alignment remains a
backend detail under `activityPlusWords`; it may be exposed as non-persisted detail without forcing a
generic enum case.

Provider-specific progress remains backend metadata and does not become a required UI enum case.

The coordinator is the single lease owner; the serialization gate, preparation owner, and model
stages operate under that lease rather than acting as independent authorities. A backend may not load
large local models while active dictation owns the lease. Document the allowed loaded-model set for
each stage. Cancellation must join the current uninterruptible model call, unload/drain the prepared
instance, and only then release ownership.

If dictation starts during a long final pass, the meeting backend yields at the next bounded chunk,
checkpoints durable work, drains models, releases the lease, and resumes only after reacquiring it.
The cancellation/preemption budget is no more than one model inference chunk plus drain overhead;
tests set a numeric wall-clock target on the minimum supported Mac.

## 10. Provenance, checkpointing, and fallback

### 10.1 Immutable run fingerprint

Every attempt records:

- requested backend ID, actual backend ID, and backend implementation version;
- one processing-contract version covering canonical evidence, assembler, safety policy, and
  persisted result semantics;
- ASR model/revision and options;
- diarizer model SHA, profile, threshold, and mel-front-end version;
- FluidAudio revision;
- analysis-manifest hash and source chunk hashes;
- language and input topology;
- input-topology policy.

Chunk SHA-256 values are computed once during durable chunk finalization and referenced here; attempt
creation must not re-read and hash hours of audio.

Any difference invalidates the checkpoint. User setting changes never rewrite an in-flight
fingerprint.

### 10.2 Checkpoints

The checkpoint is a map keyed by `(actualBackendID, trackID, eraID, stage)`, not one global
`completedStage`. Prefer canonical stage outputs over serialized provider-native objects:

- analysis manifest complete;
- speaker activity complete per track/era;
- ASR words complete per source chunk;
- product assembly complete.

V1 does not persist Nemotron cache/FIFO state because it contains acoustic representations covered by
the no-embedding persistence policy. A crash mid-era reruns Nemotron from the start of that era; this
worst-case cost is measured and disclosed in the resource gate. Alignment is deterministic and
recomputable from durable activity plus words, so it is not a separate durable checkpoint.

Corrupt or incompatible checkpoints are discarded fail-closed and processing restarts from a safe
boundary. Hosted remote-job state, when later supported, uses the separate device-local envelope in
§7.3 rather than canonical evidence.

### 10.3 Fallback policy

Fallback is an explicit policy owned by the coordinator:

- local Nemotron may fall back to the hidden local legacy backend only for model checksum, model
  load/initialization, or typed inference-incompatibility failures. Cancellation, timeout, resource
  exhaustion/OOM, empty diarization, saturation, and quality metrics are not allowlisted;
- fully drain the failed instance under the lease, delete its checkpoint subtree, and then start the
  fallback as a new attempt with a new actual-backend fingerprint;
- persist a bounded fallback-attempt counter so crash/resume cannot loop indefinitely;
- record both requested and actual backend plus the failure code;
- never fall back from local to cloud;
- never select a result by speaker count, transcript content, confidence, or apparent quality;
- never mix evidence from two backends in one final result unless a future version defines and
  validates such a composition explicitly.
- If fallback or a fingerprint-invalidating retry renumbers speakers, never attach existing
  user-assigned names by ordinal/provider token. Preserve them only through an explicit verified
  mapping; otherwise invalidate the association with a visible notice.

## 11. Security, privacy, and model-release readiness

- Keep application and microphone audio separate for online-call processing. Only a single-track
  in-room plan may compose audio under the v1 topology rules.
- Preserve all capture-era and echo-admission checks after every provider response.
- Treat provider output and model metadata as untrusted data: validate sizes, times, text lengths, and
  identifiers before persistence.
- Do not persist speaker embeddings in session JSON, exports, analytics, logs, or crash reports.
- Real participant names require user assignment; backend labels stay anonymous.
- Hosted audio use requires explicit consent and accurate retention/region disclosures.

Release assumption: FluidVoice will ship alongside the production Nemotron release. The preview
checkpoint is used only to implement and validate the model contract. Before FluidVoice ships,
replace it with the production artifact, pin its immutable identity/hash, rerun conversion and parity
gates, and verify that geometry, preprocessing, thresholds, and output semantics have not changed.

Official references checked 2026-09-12:

- NVIDIA model: https://huggingface.co/nvidia/Nemotron-3-Diarization-preview
- Meta Muse Voice Transcribe: https://research.meta.ai/blog/introducing-muse-voice-transcribe
- Google Chirp 3: https://docs.cloud.google.com/speech-to-text/v2/docs/chirp-model

## 12. Test architecture

### 12.1 Backend contract suite

Every backend, including future fixture-only adapters, must pass reusable tests for:

- planning and typed capability rejection;
- immutable configuration after planning;
- canonical time bounds and half-open intervals;
- deterministic token scoping and output ordering;
- overlap, ambiguity, missing timing, and partial coverage;
- cancellation and cleanup at each suspension point;
- malformed/oversized provider output rejection;
- checkpoint fingerprint and resume behavior;
- no settings reads after attempt creation;
- no UI, persistence, or analytics writes from the adapter;
- declared input topology matching actual access.

Create two fixture adapters for the two final evidence profiles:

- `activityPlusWords`, wrapping the current local pipeline shape;
- final `diarizedWords`, representing only the committed output shape of a future unified provider.

These prove that the evidence model and assembler can express well-formed final output. They do not
prove hosted extensibility for authentication, upload, polling, revisions, rate limits, billing,
regions, retention, or cancellation. Those are tested with the first real hosted adapter in Phase 6.

### 12.2 Default-backend tests

- Swift-vs-NeMo mel parity on committed redistributable synthetic audio.
- CoreML-vs-reference cold and warm state parity.
- No second sigmoid; activity threshold fixed at 0.25 in the run fingerprint.
- Stable slot across a 60-second durability boundary.
- Correct reset at a declared era boundary.
- Piecewise clock-rate drift, gap-stripped and gap-preserving model time, AAC priming, SRC ratios,
  corrupt chunks, and unfinalized chunks. An impulse at a known presentation time must round-trip
  through Nemotron activity and Parakeet words within one model frame.
- One, two, overlapping, short-interjection, and eight-speaker fixtures.
- Explicit behavior when all eight slots are active or saturated.
- Parakeet word conservation, speaker alignment, and final disposition-ledger reconciliation against
  the analysis manifest.
- Online-call application/microphone isolation, at-most-one You, fail-closed AEC coverage, and a
  remote utterance present as measured residual echo on the microphone track: one final app copy,
  typed suppression of the mic copy, and no phantom speaker.
- Multi-era sessions always split automatic identities; an explicit user merge is idempotent and
  survives retry.
- Fallback cannot start before failed-backend drain and checkpoint deletion complete; retry cannot
  loop fallback or attach old names by speaker ordinal.
- Cancellation latency, peak RSS, model unload, and dictation preemption on long meetings.
- Local retry produces identical text, token ordering, speaker IDs, and reason codes; numeric spans
  match within one declared model frame rather than requiring bit-identical floating-point output.

### 12.3 Evaluation gates

Before default rollout:

- labelled DER/JER with overlap-aware reporting;
- cpWER or speaker-attributed WER;
- merge/split counts and short-speaker recall;
- word conservation and boundary error;
- held-out sessions not used for threshold tuning;
- 8-, 30-, 60-, and 120-minute memory/cancellation measurements;
- time to final transcript on the minimum supported Mac no greater than
  `max(60 seconds, 0.10 * audio duration)`, with this target frozen before evaluation;
- no regression in plain Parakeet WER, capture safety, or dictation responsiveness.

Parity with the PyTorch reference is necessary but is not an accuracy measurement.

## 13. Implementation phases

All architecture and preview-contract work may proceed immediately. The production artifact swap and
full revalidation must complete before Phase 5 ships.

### Phase 0: model-release and dependency gates

1. Implement against the preview model contract without treating the preview artifact as final.
2. Track the production Nemotron release and replace the preview artifact when published.
3. Pin the exact FluidAudio revision and production model hashes.
4. Rerun conversion, mel, output, drift, and end-to-end parity against the production checkpoint.
5. Freeze a labelled development and held-out evaluation manifest.

Exit for shipping: the production checkpoint is pinned and all reproducible parity/baseline inputs
pass.

### Phase 1: canonical contracts, no behavior change

1. Add backend ID, descriptor, planning result, analysis manifest, canonical evidence, and typed errors.
2. Add the registry, an `activityPlusWords` fixture, and one final `diarizedWords` fixture.
3. Extract the product assembler boundary around existing finalization and safety rules.
4. Add backend contract tests for both final evidence profiles; explicitly reject incremental or
   provenance-free online-call evidence.
5. Keep the existing pipeline as the only production backend.

Exit: the current transcript is byte-equivalent through the new boundary, the evidence schema is
versioned, both valid final profiles validate, and invalid profiles fail closed. This does not claim
that a future provider SDK is already integrated.

### Phase 2: preparation ownership and immutable configuration

1. Add backend ID/configuration to `MeetingFinalProcessingConfiguration`.
2. Stop reading `SettingsStore.shared.selectedSpeechModel` inside an active run.
3. Generalize `MeetingASRPreparationOwner` into the sole backend preparation owner.
4. Wire progress, cancellation, activity lease, and model draining through production.
5. Version attempt lineage and checkpoints.
6. Migrate legacy checkpoints without a backend ID only to the hidden legacy backend; add
   missing-versus-unknown settings tests and recording-time readiness preflight.

Exit: a run is fully determined by its initial snapshot and cannot race settings or dictation model
changes.

### Phase 3: Nemotron host in FluidAudio

1. Add the eight-speaker Nemotron Sortformer variant/configuration.
2. Add exact output-name handling and state geometry.
3. Verify the native mel front end against NeMo.
4. Add cold/warm and multi-chunk parity tests.
5. Add bounded streaming file ingestion and cancellation points.
6. Keep all Nemotron-specific fields out of generic canonical evidence.

Exit: one synthetic and one labelled file match reference behavior within declared tolerances.

### Phase 4: composed local backend

1. Build stateful per-track/per-era Nemotron processing across durability chunks.
2. Produce canonical overlapping speaker activity.
3. Run pinned Parakeet TDT v2 word-timed ASR once per source chunk.
4. Align words and preserve all unassigned/ambiguous outcomes.
5. Pass evidence through the shared assembler and existing echo-safety policy.
6. Add manifest-level coverage reconciliation, cross-track echo suppression, era-local speaker IDs,
   the final word disposition ledger, and stage checkpoint maps.
7. Add deterministic retry, fallback-drain, and user-name invalidation tests.

Exit: complete local meeting transcripts pass functional, safety, and resource gates.

### Phase 5: default rollout

1. Register Parakeet+Nemotron as the default meeting backend.
2. Keep the legacy local backend hidden and allow only typed technical fallback.
3. Persist requested/actual backend lineage and surface fallback in diagnostics.
4. Run retained-meeting replay and held-out evaluation.
5. Remove the fallback only after stability and quality gates are met.

Exit: first-release local default uses the production Nemotron artifact and is stable, deterministic,
and recoverable.

### Phase 6: future hosted providers

For each provider separately:

1. Confirm current API, regions, pricing, limits, retention, and diarization/timing capabilities.
2. Implement one adapter and run the shared contract suite.
3. Add Keychain credentials and explicit audio-upload consent.
4. Add provider-specific idempotency, cancellation, and billing tests.
5. Register and expose the provider only when complete.
6. Add hosted descriptor metadata and, only if required by that provider, design a separate versioned
   incremental evidence protocol for partials/retractions. Do not retrofit revisions into v1 finals.

Do not change canonical persistence or product safety policy merely to accommodate a provider SDK.

## 14. Expected code areas

New meeting-specific files, names subject to implementation review:

- `MeetingTranscriptionBackend.swift`
- `MeetingTranscriptionBackendRegistry.swift`
- `MeetingTranscriptionEvidence.swift`
- `MeetingAnalysisManifest.swift`
- `MeetingTranscriptAssembler.swift`
- `ParakeetNemotronMeetingBackend.swift`
- `LegacyLocalMeetingBackend.swift`
- `MeetingTranscriptionPreparationOwner.swift`

Existing areas expected to change:

- `MeetingProcessingPipeline.swift`
- `MeetingProcessingConfiguration.swift`
- `MeetingModels.swift`
- `MeetingASRPreparationOwner.swift` (generalize or remove)
- `SpeakerDiarizationService.swift` (legacy adapter or replacement)
- `ASRService.swift` only at the narrow provider/model ownership boundary
- `SettingsStore.swift` and backup payloads
- Meeting Tools settings UI in a later provider release
- FluidAudio Sortformer model/configuration/inference/timeline files

## 15. Acceptance criteria

The architecture is ready when:

1. Parakeet+Nemotron is one selectable meeting backend while remaining two internally testable model
   components.
2. Dictation model selection cannot alter an active or future meeting backend unintentionally.
3. Well-formed final `activityPlusWords` and `diarizedWords` fixtures normalize without changing
   session persistence; the claim does not extend to a future provider's transport lifecycle.
4. Every backend word appears exactly once in the final presentation-time ledger as emitted or with
   one closed non-emission reason.
5. Provider labels never become cross-track or cross-meeting identities.
6. The topology-specific safety matrix is enforced: online-call processing retains separate track
   provenance, verified-AEC coverage is required for You, and cross-track echo duplicates are
   suppressed with explicit accounting.
7. Checkpoints reject any backend/model/configuration/input mismatch.
8. No local-to-cloud transition occurs without explicit user selection and consent.
9. Cancellation drains models/jobs and leaves no stale scratch or ownership state.
10. The production Nemotron artifact is pinned and passes conversion parity, labelled quality, and
    long-meeting resource gates.
11. Every admissible analysis-manifest interval is covered by evidence or a typed gap; unaccounted
    audio is a hard failure.
12. Cross-era speakers split by default and can only be reconciled by an explicit idempotent user
    merge in v1.

## 16. Adversarial review disposition

The draft was reviewed independently and read-only by Grok 4.6 and Claude Opus on 2026-09-12. Both
reviewers agreed that the coordinator/backend/canonical-evidence/assembler separation, meeting-only
backend contract, immutable planning, string-backed IDs, no implicit cloud fallback, sequential local
model loading, and production-artifact ship gate are sound.

Accepted changes from both reviews:

- prohibited online-call mixdown without recoverable per-track provenance;
- made coverage conservation start from the analysis manifest and end in a final word ledger;
- added cross-track echo-duplicate suppression and fail-closed AEC handling;
- made v1 cross-era identity explicitly split with user-only reconciliation;
- added piecewise clock-rate/offset/SRC/codec-delay mappings and uncertainty handling;
- constrained v1 evidence to two final-only profiles and deferred streaming revisions;
- made the assembler the sole product speaker-ID owner;
- replaced one global checkpoint stage with a backend/track/era/stage map;
- made fallback a fully drained new attempt with a closed allowlist and loop prevention;
- added recording-time readiness preflight, missing-vs-unknown setting migration, and device-local
  remote-job state;
- scoped fixtures to evidence-shape validation rather than claiming complete future-provider proof;
- added numeric latency/cancellation gates and tolerance-based local determinism.

One recommendation was deliberately tightened rather than copied: echo-only Nemotron slots do not
become product speakers after suppression, but they still consumed one of the model's eight raw slots
and therefore remain part of saturation detection.
