# FluidVoice PCM-First Meeting Audio Implementation Plan

Status: reviewed; PCM capture and analysis wired for pre-production testing; AAC archive/retention unfinished
Scope: meeting capture, canonical Parakeet + Nemotron processing, durable publication, and post-publication AAC archive
Non-goals: model-quality benchmarking, changing live-caption ASR, weakening attribution safety gates, or retranscribing historical AAC with a guessed delay

## 1. Outcome and hard invariants

For every new-format meeting, PCM is the only authoritative capture and analysis source. FluidVoice
does not create AAC until the canonical transcript and speaker evidence have been durably published.

The required ordering is:

```text
capture separate PCM tracks
  -> finalize and validate PCM chunks
  -> build measured analysis timeline
  -> Nemotron diarization
  -> Parakeet transcription
  -> assemble and durably publish sidecar + session
  -> create and verify AAC archive
  -> retain or evict PCM according to explicit policy
```

Load-bearing invariants:

1. Application and microphone audio remain separate tracks and clock/speaker namespaces.
2. With software AEC active, the authoritative microphone sample is the output committed by
   `MeetingAECOutputCommitter.commitProcessed`. Raw, bypass and warm-up audio remain explicit
   unprotected eras; no pre-AEC copy enters the protected analysis asset.
3. `MeetingAudioChunkWriter` remains the sole ordering, producer-epoch, canonical-retiming,
   format-boundary, gap, splice, and sequenced-metadata authority. A new PCM sink replaces the AAC
   storage behavior; a second competing timeline is forbidden.
4. A model-visible span is backed by a finalized, confined, hash-verified PCM asset and exact frame
   accounting. Every accepted interval becomes durable audio or a typed failure/gap.
5. Linear PCM priming is `notApplicable(linearPCM)` only after the sink's written frames and the
   finalized container's decoded frames agree. It is never inferred from the `.caf` extension.
6. Clock residual, admission, echo, coverage and ambiguity gates remain fail-closed.
7. Nemotron and Parakeet consume the same immutable per-epoch analysis materialization and sample
   mapping. Track-local or epoch-local speaker slots are never equated automatically.
8. Transcript publication does not depend on AAC compression succeeding.
9. AAC is a playback/archive derivative and is never an analysis fallback for new-format sessions.
10. Unknown or partially migrated state preserves PCM and refuses destructive cleanup.

## 2. Durable data model

### 2.1 Versioned assets, not filename inference

Add an explicit, Codable audio-asset schema. Do not infer semantics from `.caf` or `.m4a`.

```swift
enum MeetingAudioAssetRole: String, Codable {
    case captureAnalysis
    case playbackArchive
}

enum MeetingAudioEncoding: String, Codable {
    case linearPCMFloat32CAFV1
    case aacLCM4AV1
    case legacyAACUnknownPrimingV1
}

enum MeetingAudioAssetPresence: String, Codable {
    case partial
    case ready
    case evicted
    case failed
}

struct MeetingAudioAsset: Codable, Equatable, Sendable {
    var role: MeetingAudioAssetRole
    var encoding: MeetingAudioEncoding
    var presence: MeetingAudioAssetPresence
    var relativeFilePath: String
    var byteCount: Int64
    var sha256: String?
    var sampleRate: Double?
    var channelCount: Int?
    var frameCount: Int64?
    var sourceAssetSHA256: String?
}
```

`MeetingAudioChunk` retains immutable identity, sequence, presentation bounds and discontinuities,
and owns:

- one authoritative `captureAnalysisAsset` for new PCM sessions;
- an optional `playbackArchiveAsset` created after transcript publication;
- an explicit `audioSchemaVersion` / capture era.

Existing fields decode through a compatibility initializer into
`legacyAACUnknownPrimingV1`; unavailable historical frame facts remain `nil` and are legal only for
that encoding. Unknown enum values or contradictory combinations fail validation; they do not
silently become PCM or a ready archive. The first schema phase adds optional fields but continues to
encode the byte-identical legacy shape. Writing the new schema begins only at the PCM activation
boundary, with an explicit one-way `audioSchemaVersion`; older binaries are not claimed to read new
PCM sessions. Rollback after activation means disabling new PCM session creation in the new binary,
not installing an old binary over already-created PCM sessions.

The result sidecar snapshots immutable PCM provenance (asset digest, frame facts and mapping) so an
eventual PCM eviction never rewrites evidence already used to publish the transcript.

### 2.2 Session and chunk state

Do not duplicate the session processing state on every chunk. Use:

- existing session processing attempt/stage for capture and transcript publication;
- per-asset `partial`, `ready`, `evicted`, or `failed` presence;
- optional ready/staged AAC asset;
- a session-level archive job state: `notEligible`, `pending`, `running`, `completed`, or `failed`.

AAC becomes eligible only when the saved session references a read-verified canonical sidecar and a
completed Parakeet + Nemotron attempt.

### 2.3 Admission-to-durability ledger

`enqueue` success is not durability. Add a writer-owned append ledger:

- before a new chunk accepts its first sample, durably publish a chunk intent containing chunk ID,
  sequence, canonical start PTS, producer epoch, source format, and partial path;
- on the serialized writer queue, each accepted sample advances expected frames/PTS in memory;
- successful PCM writes advance written frames;
- periodic durable checkpoints and finalization record the written frame prefix and last PTS;
- finalization succeeds only when expected frames equal written frames and the decoded finalized CAF
  reports the same frame count;
- queue overflow, sink failure, invalid/retired samples and crash recovery become typed gaps or a
  failed chunk. A partial is never promoted merely because bytes exist.

No filesystem work occurs on the real-time callback. On crash, the durable chunk intent plus the last
checkpoint conservatively classifies the uncommitted tail as unavailable; initial recovery may
discard the entire partial chunk rather than fabricate a usable prefix.

## 3. Capture architecture

### 3.1 Timeline controller and sink boundary

Extract a sink protocol beneath `MeetingAudioChunkWriter` without moving its ordering logic:

```swift
protocol MeetingAudioChunkSink {
    func begin(...canonicalFormatAndTimeline...) throws
    func append(_ retimedBuffer: CMSampleBuffer) throws -> MeetingPCMAppendReceipt
    func finalize() async -> MeetingPCMFinalization
    func cancel()
}
```

The production new-format sink uses direct `AudioFileWritePackets` with an explicit native-rate,
native-channel Float32 CAF ASBD. The P1a prototype rejected `ExtAudioFileWrite` because it has no
written-frame out parameter and therefore cannot support truthful per-append receipts. Direct packet
writes report their accepted packet count and finalization independently verifies format, packets,
bytes and hashes. `AVAssetWriter`, `ExtAudioFileWrite`, and `AVAudioFile` writing are not used for
authoritative analysis PCM. The legacy AAC sink remains compiled only as an explicit
rollback/migration path; the new production default never falls back to it automatically.

`MeetingPCMAppendReceipt` reports exact frames accepted and written. The writer updates canonical
end PTS from the accepted frame duration, not an unrelated encoder result. Any mismatch fails the
chunk and records coverage loss.

### 3.2 PCM representation

- Application track: preserve accepted ScreenCaptureKit native sample rate and channel layout.
- AEC-active microphone: preserve the 48 kHz mono post-AEC output already synthesized by
  `MeetingAECPCMAdapter` and committed by `commitProcessed`.
- Non-AEC microphone: preserve the admitted producer format; do not add another resampler.
- Store Float32 LPCM as the authoritative reprocessing representation. This preserves the current
  ScreenCaptureKit/AEC sample domain and avoids irreversible clipping or two competing conversion
  rules. Non-finite samples fail the append rather than entering evidence. A future Int16 storage
  optimization requires its own measured-equivalence decision and is outside this migration.
- Remove the AAC-era two-channel clamp from PCM capture. Downmix belongs to analysis.

The prototype validates direct `AudioFile` packet writes by proving exact frame writes, container
finalization, channel-layout preservation and bounded queue latency. Descriptor-relative path
hardening and a forced-process crash harness remain mandatory before production wiring.

### 3.3 Chunk boundaries and gaps

Preserve the existing 60-second rotation, producer-epoch/backward-clock reset, format change,
explicit splice, and greater-than-0.5-second gap rules. A sink error closes the current chunk as
failed and opens no replacement until the writer has recorded the lost interval/era transition.

Files use same-volume staging and atomic rename:

```text
tracks/<kind>/000123.partial.caf
tracks/<kind>/000123.caf
```

Both paths are session-confined, non-symlink, mode 0600; parent directories are 0700. Orphans are
defined narrowly: a staged file whose chunk ID has no ledger intent, or whose intent already names a
different ready asset hash. Ambiguous files are retained.

## 4. Analysis architecture

### 4.1 Observer and timing certainty

Extend `MeetingChunkAudioObserver` to validate the explicit asset encoding and compare:

- stored byte count and SHA-256;
- declared and decoded sample rate/channel count;
- written, stored and decoded frame count;
- PTS duration versus `frameCount / sampleRate` within the existing residual bound;
- capture era and discontinuity scope.

Introduce `MeetingCodecPriming.notApplicable(.linearPCM)`. The certainty rule accepts this as known
only after all PCM invariants pass. Legacy AAC remains `.unknown(.decoderDidNotReport)` unless a
separate, fixture-proven packet-table implementation lands later.

### 4.2 Stateful epoch materialization

Replace per-span `AudioBufferConverter.monoSamples` calls with one converter state per exact key:

```text
(track ID, epoch generation, capture/AEC era, source sample format, channel layout)
```

A key change drains the old converter, attributes its tail to the old side, records the boundary, and
creates a new converter. Gaps are not bridged with invented samples. Materialization returns exact
input/output ranges for every span and validates total output frames.

The existing model-isolation order runs all Nemotron work before the Parakeet lease. Avoid retaining
unbounded `[Float]` buffers by adding a session-confined immutable epoch-materialization store:

- materialize each epoch exactly once to a hashed 16 kHz mono Float32 working asset plus span map;
- Nemotron and Parakeet reopen the same bytes in their separate phases;
- keep at most one decoded epoch buffer resident at a time;
- the working asset is derived and regenerable from authoritative PCM, so partials are never
  recovered as evidence and are deleted after successful publication or on proven orphan cleanup.

This store counts toward disk preflight. If implementation proves deterministic rematerialization is
bit-identical and cheaper, it may replace the store only with a regression test comparing hashes
across both backend phases and bounding memory.

### 4.3 Backend and evidence

Keep one fresh Nemotron state per analysis epoch and drain/unload it before acquiring prepared
Parakeet ASR. Both phases bind their units/activity to the same epoch materialization digest and span
map. Evidence validation rejects mismatched digests.

Attempt lineage records:

- Parakeet model/version and fixed meeting configuration;
- Nemotron model manifest SHA-256, entry metadata SHA-256, geometry/config version, thresholds and
  supported slot count;
- PCM capture schema, materialization schema and backend version.

Remove the legacy `FluidAudio-offline-v1` diarization fingerprint from canonical attempts.

## 5. Publication and post-publication AAC

### 5.1 Publication transaction

The current canonical ordering remains:

1. assemble evidence using fail-closed admission/timing/echo/coverage rules;
2. write, fsync and read-verify immutable result sidecar;
3. atomically save session transcript, speakers, completeness, attempt lineage and sidecar reference;
4. mark the archive job eligible.

No AAC work starts before step 3 succeeds.

### 5.2 Archive job

For each ready PCM chunk:

1. transcode to a unique same-volume staged `.m4a`;
2. verify encoding, decodability, channel/rate expectations, nonzero duration and bounded duration
   difference; hash the result;
3. persist the ready archive asset bound to the source PCM digest;
4. atomically activate it for playback/export;
5. keep PCM until retention policy permits eviction.

Compression failure changes only archive-job state. It never rolls back or invalidates the published
transcript. Playback/export either reads ready PCM or shows an explicit "preparing recording" state;
it never guesses a file representation.

### 5.3 PCM retention and eviction

Do not delete PCM immediately after AAC activation. Default PCM retention follows the recoverable
audio/reprocessing window. A future user setting may shorten or extend it. Disk-pressure eviction is
oldest-first and allowed only when:

- transcript and sidecar are durably published and verify;
- every archive asset is ready and verifies;
- no chunk/span is timing-uncertain, failed, or pending recovery;
- no processing/archive lease is active.

Eviction persists `.evicted` plus timestamp/reason before unlinking through a recoverable staged
deletion. After eviction, reprocessing reports authoritative PCM unavailable and never analyzes AAC.

## 6. Storage and recovery

Replace the flat 512 MB preflight with a calculation based on planned/default maximum duration,
active track formats, Float32 PCM bytes per frame, epoch working-set allowance, AAC staging and
reserve. At 48 kHz, stereo application plus mono microphone Float32 is about 2.1 GB/hour before the
derived epoch working set and AAC staging; the calculation uses actual active formats rather than a
flat estimate.
Re-evaluate during capture. Low space closes/fails the active chunk, records a typed event and stops
capture without naming a partial file finalized.

Startup reconciliation handles:

- intent without ready PCM: fail or conservatively quarantine partial, record missing interval;
- ready PCM without completed transcript: offer/restart canonical processing;
- published transcript with pending/failed archive: retry compression;
- staged AAC without activation: verify against job intent or retain;
- active AAC plus retained PCM: resume retention policy;
- evicted PCM: preserve provenance and disable reprocessing;
- historical AAC-only session: legacy decode and fail-closed timing semantics.

Recovery never updates byte counts from arbitrary filesystem contents and never promotes a partial
solely by extension or size.

## 7. Phased implementation and rollback boundaries

### Phase P1a — Direct AudioFile Float32 sink contract (implemented; harness only)

- Add an injectable sink protocol with an explicit threading contract: real-time producers enqueue;
  the existing serial writer queue owns canonical timing and performs sink I/O.
- Implement a harness-only native-rate/native-channel Float32 CAF sink using packet-counted
  `AudioFileWritePackets`; canonical storage is interleaved and planar input is packed without
  changing sample values or channel order.
- Prove append receipts report written frames, finalized decode counts match, formats/layout survive,
  files are confined and permission-tight, and partials never appear finalized.
- Exercise real `CMSampleBuffer` fixtures and forced process termination of a standalone harness.
- Make no persisted-model, capture-engine, priming, fingerprint, playback or production-wiring change.

Current verification: 6 focused sink tests and the 219-test combined compatibility, recovery and
canonical meeting selection pass with zero failures. Exact interleaved/planar frames, PTS receipts, layout, packet counts, hashes,
permissions, stale partials, zero-frame/cancel and no-overwrite behavior are covered. The subprocess
crash harness and descriptor-relative TOCTOU hardening are explicitly deferred and prohibit
production wiring until complete.
Rollback: delete unreferenced sink/harness code.

### Phase P0a — Additive compatibility types and golden wire tests (implemented)

- Add optional asset/capture-era types and tolerant compatibility decoding while continuing to emit
  the existing wire representation.
- Define legal missing legacy facts explicitly; do not hash or probe files during decode.
- Add old-session/index/track/backup decode and byte-shape encode goldens, including unknown future
  enum values that quarantine only the affected asset.
- Add no new persisted priming case and no lineage change yet.

Current verification: optional fields omit themselves from legacy chunk JSON, legacy chunk/session
round-trips pass, future raw values survive and quarantine only their asset, valid PCM/legacy assets
round-trip, and incomplete ready PCM is rejected by pure metadata validation. The combined sink,
compatibility, recovery and canonical backend selection passed 219 tests with zero failures. Current
app behavior and serialized output remain unchanged; an old-binary compatibility claim is limited to
this omit-empty phase only.
Rollback: remove optional unused types.

### Phase P0b — Recovery and ledger foundation (implemented; default behavior still AAC)

- Replace `reconcileChunkFile` size rewriting with hash/frame-aware, fail-closed reconciliation for
  new assets while preserving the explicit legacy compatibility rule.
- Add writer-queue chunk intent and durable checkpoint records. Define checkpoint cadence and fsync:
  chunk intent before first sink append, checkpoint at bounded one-second audio intervals or chunk
  closure, and fsync at intent/checkpoint/finalization boundaries off the real-time callback.
- Recovery discards/quarantines an uncommitted partial chunk and records its whole intended interval
  unavailable; it does not attempt prefix salvage in v1.
- Assign these rules explicit store/recovery tests. Keep production capture AAC.

Current verification: ledger intent and terminal records are immutable/idempotent, checkpoints are
chunk-bound and monotonic, ready terminals require complete written frames, and reads do not create
ledger directories. New-asset reconciliation requires verified authoritative PCM and quarantines a
broken optional archive without invalidating that PCM; partial/escaping assets never promote. The
combined foundation, compatibility, recovery and canonical backend selection passed 224 tests with
zero failures. Arbitrary file size never overwrites trusted new-asset metadata; legacy meeting
recovery behavior remains regression-tested.
Rollback: new ledger records are optional and ignored while no PCM session exists.

### Phase P2/P3 — Complete PCM path (wired for pre-production testing)

Capture and analysis were activated together so PCM recordings are never stranded. At the user's
explicit pre-production direction, new meetings now select this path directly rather than hiding it
behind a default-off setting.

- Wire the Float32 PCM sink for a session-scoped, default-off capture-format selection.
- Wire application samples and the correct post-AEC/raw era-specific microphone paths.
- Activate the new audio schema for flagged sessions only; add `notApplicable(linearPCM)` in their
  new-version manifests while legacy output remains unchanged.
- Add dynamic storage preflight and mid-session stop before any PCM capture can start.
- Make recovery, temporary playback and export understand ready PCM.
- Implement PCM observer/builder, boundary-keyed stateful conversion and the immutable epoch working
  store; bind both backend phases to its digest.
- Refuse archive/legacy AAC assets in the new analysis path.

Current verification: new capture writes Float32 CAF only, persists schema-2 authoritative PCM and
ledger records, the observer marks verified PCM priming not applicable, materialization is stateful
across compatible spans, and both models reuse the same bounded PCM epoch cache. Storage preflight
and history reveal are PCM-aware. The combined wired selection passed 290 tests with zero failures
and one opt-in real-model skip. Legacy AAC sessions still decode and remain timing-uncertain.

Real-field startup RCA found that `CMFormatDescriptionEqual` in the writer and raw layout-byte
comparison in the sink disagreed for semantically identical 48 kHz mono buffers whose metadata moved
between nil, Mono and DiscreteInOrder representations. A shared `MeetingPCMFormatContract` now owns
both decisions: safe mono/stereo representations canonicalize, custom layouts remain byte-distinct,
and planar/interleaved payloads remain topology-validated before canonical packing. Real
CMSampleBuffer regressions cover nil→Mono→nil→Discrete mono with one exact chunk and zero
writer failures; genuine mono→stereo changes rotate once. The expanded PCM/AEC/canonical selection
passes 328 tests with zero failures and one opt-in model skip.
Rollback for future sessions requires a new-binary capture switch or code rollback; existing PCM
sessions must remain on a binary that understands schema 2.

Remaining before release: replace the bounded in-memory epoch cache with the planned immutable disk
working store, add descriptor-relative path operations and subprocess crash injection, and complete
post-publication AAC activation/recovery.

### Phase P4 — PCM-first publication activation

- Flip new meetings atomically to the already-complete PCM capture+analysis path.
- Persist new audio schema and real Parakeet/Nemotron/capture/materialization fingerprints.
- Explicitly invalidate only incompatible in-progress checkpoints; completed historical attempts
  remain completed and are never relabeled or automatically rerun.
- Keep PCM unconditionally; do not enable AAC archive or eviction in this phase.

Exit: a production-like matrix—not one fixture—publishes assigned speakers across chunk, AEC era,
format, gap and producer-epoch boundaries; defaults create no AAC; recovery and disk gates pass.
Rollback: disable new session creation in the new binary, retain PCM, and keep existing PCM sessions
readable/retryable. Rolling back to an older binary is unsupported for PCM sessions.

### Phase P5 — Post-publication AAC and representation-aware UI/export

- Add a sidecar-style per-session archive job: same-volume staged file, verification, ready asset
  record, atomic session save, and retry. A second global journal is unnecessary.
- Make playback/export use PCM before archive activation and AAC afterward; show pending/failure.
- Add startup reconciliation for every stage. Never delete PCM in this phase.

Exit: no AAC exists before session publication; every crash point preserves a valid transcript and
recoverable PCM; archive failure is non-destructive.
Rollback: disable archive jobs and continue retaining/playing PCM.

### Phase P6 — PCM retention and eviction

- Add configurable retention and conservative oldest-first eviction.
- Update `deleteAudioFiles`, `audioDeletedAt`, recovery predicates and observer/materializer refusal so
  deleting PCM while retaining AAC cannot make AAC an analysis source.
- Add metrics without audio content.

Exit: deletion is impossible for uncertain/failed/active sessions; an evicted session retains
provenance and explicitly disables reprocessing.
Rollback: disable eviction and retain PCM.

No phase combines the schema activation, default capture flip, archive activation and deletion
policy. P2/P3 cannot ship independently; P4 is the one-way audio-schema activation boundary.

## 8. Release-blocking verification matrix

### Capture and durability

- New-format meeting has no `.m4a`/AAC asset before durable transcript publication.
- App and mic remain separate; AEC-active disk mic matches `commitProcessed`, not raw SCK mic.
- Float32 capture preserves finite source samples and native channel layout; NaN/infinity fail the
  append, and no Int16 clipping/quantization is introduced.
- Queue full, sink failure, short write and crash between intent/append/checkpoint/final rename leave
  every interval as verified PCM or typed unavailable coverage; partials are never promoted.
- Producer epoch, backward clock, format/layout change, splice, 60-second rotation and >0.5-second
  gap preserve exact chunk order and mapping.

### Analysis and attribution

- Written/declared/decoded PCM frames match; mismatch stays timing-uncertain.
- Residual remains within bound for continuous fixtures and fails closed when injected outside it.
- Converter key change drains/restarts at epoch, era, format or layout boundary; drained tail belongs
  to the prior side.
- Nemotron and Parakeet evidence references the identical materialization digest and span map.
- Two-speaker application audio publishes two speaker IDs across a chunk boundary.
- App/mic slot labels do not merge; overlap/ambiguity and AEC admission remain conservative.
- Historical AAC-only fixture remains timing-uncertain without guessed priming.

### Publication, compression and recovery

- Crash after sidecar but before session save leaves no falsely published transcript and is
  reconcilable.
- Crash after transcript save but before AAC creates a readable transcript with ready PCM.
- Crash during AAC stage/rename/manifest activation retains either the prior PCM state or a verified
  active archive, never neither.
- Compression failure keeps transcript valid and PCM retryable.
- Playback/export use PCM before AAC activation and AAC afterward without changing transcript time.
- PCM eviction is refused for uncertain, failed, unpublished or leased sessions.
- Low-space start refusal and mid-session exhaustion preserve prior finalized chunks and emit an
  actionable failure.
- Canonical attempt contains Parakeet identity, Nemotron digest/config and PCM/materialization schema;
  it never reports the legacy diarizer fingerprint.

## 9. Closed design decisions from adversarial review

Grok 4.6 and Claude Opus independently accepted PCM-first capture but rejected the original phase
sequence. This revision closes their load-bearing questions:

1. The ledger performs no synchronous callback I/O. Intent/checkpoints run on the serialized writer
   queue; recovery quarantines the whole uncommitted partial chunk in v1.
2. `ExtAudioFileWrite` was rejected because it cannot report a written-frame count. The accepted
   harness uses direct `AudioFileWritePackets` and verifies packet/frame/byte counts on reopen.
3. Float32 CAF is authoritative. Int16 optimization is deferred because it irreversibly clips or
   quantizes the current Float32 ScreenCaptureKit/AEC domain.
4. An immutable epoch working store is required because the current runtime drains Nemotron before
   acquiring Parakeet and cannot hold unbounded meeting audio in memory. Rematerialization is not an
   implementation option in this migration.
5. AAC activation reuses the sidecar pattern: staged same-volume asset, verification, immutable
   archive record and atomic session save. It does not add a second global journal.
6. PCM eviction is a separate final phase. The observer/materializer accept only the capture-analysis
   role, and reprocessing becomes explicitly unavailable after PCM eviction; AAC is never substituted.
7. Removed as over-engineering: six states duplicated per chunk, production dual-write validation,
   capture-time resampling, immediate PCM deletion, a rematerialization fork, and fingerprint changes
   in a no-behavior phase.

Review disposition: both reviewers' phase and recovery objections are accepted. On source format,
Grok preferred Float32 and Opus considered Int16 adequate with clip metrics; the parent chooses
Float32 because correctness and future reprocessing are the stated priority, while dynamic disk gates
make its cost explicit. The implementation must not reopen this choice without a separate decision.
