# Meeting Diarization V2 — Evidence-Driven Implementation Plan

Status: **Revised after adversarial review**
Scope: post-meeting remote/application-audio diarization
Constraints: local-first, bounded resources, recoverable processing, no microphone or dictation regression

## 1. Outcome

Improve speaker separation and identity consistency, beginning with the measured failure where an
8:14 five-speaker recording produced four valid remote identities and absorbed a brief recurring
speaker into a dominant speaker.

The implementation is deliberately conditional. The same visible failure can be caused by five
different stages, and each requires a different fix. No long-window or clustering change begins until
a diagnostic pass identifies the stage that lost the speaker.

## 2. Current pipeline

1. Capture writes application and microphone audio into independent 60-second durability chunks.
2. Each application chunk is diarized independently with FluidAudio's offline pipeline.
3. FluidVoice reduces every local chunk label to one centroid and average quality.
4. `MeetingGlobalSpeakerStitcher` merges those label-level observations across chunks.
5. When the ASR provider supports word timings, each chunk is transcribed once and words are assigned
   to diarizer turns in chunk-local time.
6. Final meeting segments retain paragraph/turn time ranges and text, not individual word timings.

This architecture makes one claim certain: once a brief participant has been absorbed into a local
chunk label, the final stitcher cannot reconstruct that participant from a mixed centroid. It does
**not** establish where the absorption happened.

## 3. Verified dependency behavior

These facts were verified against the currently checked-out FluidAudio fork, but must be re-verified
after the actual build revision is pinned:

- The offline diarizer uses 10-second segmentation windows with a 0.2 step ratio, AHC initialization,
  PLDA/VBx refinement, and final timeline reconstruction.
- The URL path converts audio into a memory-mapped disk-backed source.
- Whole-file processing retains segmentation outputs, embeddings, clustering inputs, and
  reconstruction arrays until completion. Audio is disk-backed, but peak memory still grows with
  meeting duration.
- Final embedding assignments are recomputed using nearest-centroid similarity after VBx-derived
  centroids. The plan must not describe the final timeline as a direct HMM-state output.
- Public `TimedSpeakerSegment.embedding` is the resolved cluster centroid repeated on every segment.
  It is not an independent turn embedding.
- Raw timed embeddings and their cluster assignments exist internally. A debug export path can expose
  them for local diagnosis, but it is not an acceptable production API.
- Default reconstruction uses exclusive segments and can trim overlapping speech. Short remnants can
  disappear during sanitization.
- The embedding extractor can still produce evidence for short speech; the configured minimum affects
  clean-mask selection and reconstruction behavior, so the exact failing stage must be inspected.
- `StreamingAudioSampleSource` and `process(audioSource:audioLoadingSeconds:)` are public in the
  inspected checkout and may support a composed source without creating one monolithic scratch WAV.

### Dependency reproducibility blocker

`Package.swift` tracks the `altic-dev/FluidAudio` fork's moving `main` branch. The revision recorded in
`Package.resolved` and the current local checkout do not match, and the resolved object is absent from
the shallow local checkout. Before collecting a baseline:

1. determine the exact revision used by the installed/test build;
2. pin the package to an immutable reviewed revision or release;
3. clean-resolve and verify that the checkout, resolved file, build metadata, and evaluation report all
   carry the same SHA;
4. re-check every API and behavioral claim in this document against that SHA.

Upstream documentation is research input, not proof of behavior in the pinned fork.

## 4. Competing root-cause hypotheses

| ID | Failure stage | What it would look like | Correct intervention |
|---|---|---|---|
| H1 | Local clustering under-merges | Distinct raw embeddings exist, but a 60-second pass assigns the brief speaker to a dominant cluster | Calibrate clustering or evaluate longer/global context |
| H2 | Overlap/reconstruction deletion | The brief speaker exists before reconstruction but is trimmed/dropped from the final timeline | Fix overlap/exclusive/min-duration policy |
| H3 | Embedding contamination | The brief speech's embedding is already acoustically close/mixed with the dominant speaker | Improve segmentation/masking/embedding model; longer context and downstream prototypes will not help |
| H4 | Cross-chunk stitcher merge | Local chunks preserve the fifth identity, but FluidVoice merges it globally | Fix the application-only stitcher; do not add whole-era processing |
| H5 | Word attribution error | Diarizer turns are correct, but ASR words cross the wrong boundary or are dropped | Fix time mapping and word assignment |

Whole-era diarization is the likely fix only for H1. It may conceal H4, and it does not inherently fix
H2, H3, or H5.

## 5. Design principles

1. **Diagnose before selecting architecture.**
2. **Capture chunks remain durability units, never presumed speaker boundaries.**
3. **Application and microphone behavior are isolated in code and tests.**
4. **A false merge is more destructive than a provisional split**, but weak noise must not become a
   confident person.
5. **Acoustic evidence is authoritative.** Language context may flag ambiguity but cannot identify a
   voice by itself.
6. **No repeated centroid may be presented as turn-level evidence.**
7. **No exact speaker count in product behavior.** Exact counts are evaluation-only oracles.
8. **Embeddings remain session-local and absent from exports, analytics, logs, and production debug
   artifacts.**
9. **Word attribution is part of every diarization intervention**, not a later cleanup phase.
10. **No threshold changes without a development/held-out evaluation split.**

## 6. Phase 0 — Reproducible evaluation foundation

### 6.1 Pin inputs

- Pin the exact FluidAudio fork revision.
- Record the diarization model bundle fingerprint and relevant configuration.
- Record ASR provider/model/version, normalization configuration, pipeline version, and fixture hash.
- Add the diarization fingerprint to checkpoint compatibility checks.

### 6.2 Corpus

Create a local, gitignored evaluation manifest supporting:

- audio/session path;
- RTTM or equivalent reference speaker timeline;
- reference transcript with word times where available;
- expected speaker count;
- recurring-speaker relationships;
- overlap regions;
- capture discontinuities and known missing intervals;
- fixture tags such as short speaker, similar voices, overlap, boundary, and long meeting.

The initial development set must contain more than the measured fixture:

1. five speakers with two brief appearances by one person;
2. two clean speakers;
3. one speaker;
4. similar-sounding speakers;
5. short interjection during overlap;
6. a speaker first appearing at a 60-second boundary;
7. paired application/microphone audio with leakage and genuine local speech;
8. at least one 60–90-minute session for resource measurement.

Create a held-out set before tuning begins. User recordings remain local and gitignored. Commit only
synthetic fixtures or audio with explicit repository rights.

### 6.3 Metrics

Primary product metrics:

- speaker merge count;
- speaker split/fragmentation count;
- recovery recall by total speaking-duration buckets (`<1 s`, `1–3 s`, `3–10 s`, `>10 s`);
- recurring-speaker consistency across distant appearances;
- speaker-attributed word error / cpWER;
- word conservation: assigned once, explicitly ambiguous, or explicitly unassigned;
- microphone You/Unknown/echo classification on paired-track fixtures.

Secondary diagnostic metrics:

- DER with miss, false alarm, and confusion components;
- JER;
- speaker-count error;
- purity and coverage;
- plain WER;
- turn-boundary error.

Report both:

- a comparable diagnostic score with 250 ms collar and overlap ignored;
- a strict product score with zero collar and overlap scored, only when the hypothesis format actually
  represents overlap.

Do not use speaker count, DER, or cpWER alone as a gate. A system can recover the requested count by
splitting the wrong person, while a brief merged speaker contributes little duration to DER.

### 6.4 Harness

- Port or wrap the pinned FluidAudio fork's DER/JER metric implementation into a repository-owned
  evaluation tool.
- Extend the existing opt-in retained-meeting replay without ever rewriting source sessions.
- Emit per-stage reports and hypotheses into a user-selected or protected local temporary directory.
- Add deterministic synthetic unit tests for clustering logic independent of real audio.

Exit gate:

- one command produces repeatable baseline metrics and resource reports;
- the five-speaker failure reproduces;
- the held-out manifest already exists;
- dictation and paired-track microphone baselines are recorded;
- no source/model/revision mismatch remains.

## 7. Phase 0.5 — Decisive failure-stage diagnosis

This phase is mandatory and may stop the rest of the plan.

### 7.1 Diagnostic runs

For the failing fixture, run:

1. each original 60-second application chunk independently;
2. the contiguous application capture era as one diagnostic input;
3. the same inputs with `withSpeakers(exactly: 5)` as an evaluation-only oracle;
4. raw timed-embedding export in a debug/test-only build;
5. pre- and post-reconstruction timeline inspection;
6. current word-to-turn assignment inspection.

The debug embedding export must:

- be impossible to enable in production builds;
- write to a newly created `0700` directory and `0600` files;
- contain no participant names;
- be deleted on success/failure/cancellation and by next-launch stale-artifact cleanup;
- never be committed, uploaded, logged, or included in crash reports.

### 7.2 Evidence captured

- raw embedding count, window time, mask quality, and assignment;
- distance of the brief speaker's observations to every resolved centroid;
- cluster membership before and after final nearest-centroid reassignment;
- speaker timeline immediately before exclusive-overlap handling and sanitization;
- duration removed by overlap trimming/minimum-duration filtering;
- per-chunk local labels and the FluidVoice global stitch merge graph;
- diarizer turns versus chunk-local words, including every dropped/ambiguous word;
- NaN/invalid embeddings and any silent cluster-zero assignment;
- result under the exact-five oracle.

### 7.3 Decision tree

```text
Did the brief speech produce distinct raw embeddings?
  no  -> H3: segmentation/masking/embedding investigation
  yes -> Did it form a distinct local cluster?
           no  -> H1: clustering/global-context experiment
           yes -> Did reconstruction preserve the turn?
                    no  -> H2: overlap/reconstruction fix
                    yes -> Did FluidVoice preserve it globally?
                             no  -> H4: application stitcher fix
                             yes -> H5: word attribution fix
```

Exit gate:

- one hypothesis is supported by stage-local evidence on the target fixture;
- the same diagnostic is run on at least two additional fixtures;
- the selected implementation branch states why the other branches are not being implemented.

## 8. Conditional Branch A — Local clustering/global-context fix (H1)

Choose this branch only if distinct raw evidence exists but local clustering merges it.

### A1. Whole-era experiment

Evaluate one offline pass over each contiguous application-audio era. This is an experiment, not the
default architecture.

Implementation requirements:

- introduce a meeting-only analysis timeline that maps **analysis time ↔ meeting presentation time ↔
  source chunk-local time**;
- extend/reuse existing epoch-boundary logic rather than creating a conflicting `MeetingCaptureEra`
  concept;
- prefer a composed `StreamingAudioSampleSource` over a monolithic decoded scratch file;
- place decoded samples by source PTS, not by assuming encoded AAC frame count equals presentation
  duration;
- measure AAC priming/padding per chunk and prove it cannot accumulate timeline drift;
- derive gaps from adjacent PTS directly, including gaps below the writer's 0.5-second discontinuity
  threshold;
- split around corrupt/unreadable chunks, preserve `skippedChunkIDs`, and process healthy spans;
- never create turns spanning missing or unfinalized audio;
- keep post-meeting-only behavior: live captions remain You/Them and final speaker labels are published
  only after processing completes.

Word attribution is part of A1:

- map global turns back into each chunk's local clock;
- run the current chunk ASR once with word timings;
- assign words to globally resolved turns;
- assert that each word is assigned exactly once or explicitly reported ambiguous/unassigned;
- preserve current zero nearest-turn tolerance on microphone audio.

### A2. Resource experiment before defaulting

Measure 8-minute, 30-minute, 60-minute, and 120-minute sessions:

- peak RSS and memory growth per audio hour;
- segmentation/embedding/clustering/reconstruction allocations;
- AHC and total wall time/real-time factor;
- temporary bytes and stale-artifact behavior;
- cancellation latency and dictation preemption latency;
- crash/retry cost, since the current checkpoint is after the complete application pass.

Whole-era processing may become the default only if resource growth and cancellation are acceptable on
the minimum supported Apple Silicon machine. Disk-backed audio alone is not sufficient evidence.

### A3. Bounded strategy if whole-era fails

If whole-era resource gates fail, design bounded sequential super-windows as the primary architecture,
not as an afterthought:

- select window/overlap duration from measurements rather than assuming 5 minutes/30 seconds;
- process one window at a time;
- reconcile the overlap with acoustic evidence and cannot-link constraints;
- checkpoint after each accepted window;
- freeze resolved IDs deterministically;
- prove no boundary-only label changes or duplicated transcript text;
- demonstrate peak memory independent of meeting duration.

Branch A acceptance:

- brief-speaker recovery improves in its speaking-duration bucket;
- no dominant speaker is merged or fragmented;
- paired-track You/Unknown/echo results are unchanged;
- chunk-local word attribution is correct across every chunk/era boundary;
- corrupt-chunk recovery and retry remain functional;
- dictation can preempt or cancel within a measured product budget;
- resource gates pass on long sessions and minimum hardware.

## 9. Conditional Branch B — Overlap/reconstruction fix (H2)

Choose this branch if clustering finds the speaker but reconstruction deletes or trims the turn.

Tasks:

- measure the effect of `exclusiveSegments`, overlap masks, minimum output duration, onset/offset, and
  gap merging independently;
- preserve overlap when the source model supports multiple active speakers;
- do not lower a minimum globally without measuring false-alarm speakers;
- separate minimum duration for embedding evidence from minimum duration for displayed transcript
  turns;
- preserve a short high-confidence turn even when it cannot yet be promoted to a durable identity;
- attribute overlapping words explicitly rather than forcing all text to one survivor.

Acceptance:

- short-overlap speaker recall improves;
- false-alarm speaker duration and nuisance speaker count do not materially increase;
- strict overlap-scored DER and speaker-attributed WER improve on held-out overlap fixtures.

## 10. Conditional Branch C — Embedding/segmentation fix (H3)

Choose this branch if raw evidence is already contaminated or indistinguishable.

Tasks:

- inspect speech masks and overlap exclusion around the brief turn;
- test shorter/multi-scale embedding windows while retaining longer context for voice quality;
- benchmark an alternative local segmentation/embedding model using the same clustering backend;
- preserve multiple independent observations only after proving they contain distinct information;
- reject long-context clustering and multi-prototype work until acoustic separability improves.

Acceptance:

- same/different-speaker distance distributions separate on the development set and hold out;
- the brief speaker becomes separable before final clustering;
- no material degradation on noisy, similar-voice, and single-speaker fixtures;
- local model, license, memory, and latency remain compatible with the product.

## 11. Conditional Branch D — Application-only global resolver fix (H4)

Choose this branch if local diarization preserves the speaker and FluidVoice merges it later.

Create a new application-only resolver. Do not modify the stitcher instance/type used by microphone
You/Unknown classification in the first change.

Resolver rules:

- consume independent raw observations, never repeated cluster centroids described as turns;
- retain up to four deterministic quality/duration-ranked medoids per speaker;
- different simultaneous local labels are cannot-link;
- labels already distinct in one local diarizer result are cannot-link;
- merge only below a calibrated distance with a first-versus-second ambiguity margin;
- enforce maximum pairwise diameter to prevent centroid chaining;
- weak observations may attach to strong cores but cannot move their prototypes;
- multiple consistent weak appearances may form one provisional speaker;
- unresolved evidence remains explicit rather than being forced onto the nearest dominant speaker;
- output is deterministic under input, chunk, and retry ordering.

Production use requires a stable FluidAudio API exposing raw timed embeddings, assignments, and defined
quality signals. The debug export is diagnostic-only. Decide during Phase 0 whether this is an upstream
change merged into the fork or a maintained pinned-fork patch with contract tests.

Acceptance:

- the fifth identity is preserved without splitting a dominant speaker;
- merge/split metrics improve on held-out sessions;
- a single noisy observation does not create a confident speaker;
- two consistent brief appearances can recover one identity;
- microphone stitcher output is byte-equivalent to baseline fixtures;
- paired-track You/Unknown/echo behavior is unchanged.

## 12. Conditional Branch E — Word-level attribution fix (H5)

Choose this branch if diarizer turns are correct but text is assigned incorrectly.

Tasks:

- preserve processing-time word IDs, text, start/end, and assignment outcome;
- make all three time domains explicit;
- define half-open boundary behavior and overlap ties;
- replace silent word drops with explicit counts and reasons;
- make the allowed dropped-word target relative to measured baseline before setting a stricter target;
- compute speaker-attributed WER/cpWER;
- add boundary tests for encoded-chunk priming, gaps, and diarizer turns spanning a capture boundary;
- decide separately whether product persistence uses `session.json` or a versioned local sidecar.

Acceptance:

- every ASR word is emitted once or explicitly ambiguous/unassigned;
- unexplained word loss improves from baseline;
- speaker-attributed WER improves without material plain-WER regression;
- retry is deterministic for an identical model/configuration fingerprint.

## 13. Shared reliability, privacy, and rollout requirements

### Checkpoints and cancellation

- Bump both processing-pipeline and checkpoint schema versions when compatibility changes.
- Record diarizer model/configuration/dependency fingerprint in checkpoint compatibility.
- Document that the current checkpoint is after the application pass; do not claim finer resume points
  until implemented.
- Add explicit cancellation opportunities around long diarizer phases. Measure worst-case cancellation
  latency because the dependency may not check cancellation internally.
- A failed V2 experiment may fall back only through a typed, recorded technical failure. Never choose a
  result merely because it reports a preferred speaker count.

### Privacy

- Keep remote and microphone tracks separate.
- No cross-meeting profiles or real-name inference.
- No embeddings in session JSON, exports, logs, analytics, crash reports, or UI state.
- Production scratch files, if unavoidable, use protected directories/files, explicit deletion on all
  exits, and stale-artifact cleanup after crashes.
- Debug raw-embedding export remains test-build-only and requires explicit local invocation.
- Any resumable embedding checkpoint requires a separate biometric-adjacent storage review and
  authenticated encryption.

### Dictation and microphone isolation

- Initial implementation changes only post-meeting application-audio processing.
- Do not change capture writers, microphone diarization, echo detection, near-field gating, You
  election, dictation providers, or dictation audio routing.
- Prove isolation with tests rather than relying on type boundaries.
- Run meeting echo, You/Unknown, multi-device dictation, route recovery, deadlock/freeze, and complete
  dictation integration suites for every selected branch.
- Measure ANE/model contention and dictation preemption with a long application diarization pass.

### Rollout

- Put the selected V2 branch behind an internal flag.
- Replay V1 and V2 locally against the same immutable fixture manifest.
- Default new meetings to V2 only after development and held-out gates pass.
- Preserve V1 retry compatibility until retained-meeting replay and dogfooding show no regression.

## 14. Expected file areas

- `Package.swift` and `Package.resolved` for an intentional immutable dependency pin
- `Sources/Fluid/Services/SpeakerDiarizationService.swift`
- `Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift`
- new application-only diagnostic/resolver/time-mapping files under
  `Sources/Fluid/Services/Meeting/`
- `Sources/Fluid/Services/Meeting/MeetingModels.swift` for fingerprint/checkpoint metadata only when
  required
- `Tests/FluidDictationIntegrationTests/SpeakerTurnMergingTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingExistingAudioReplayTests.swift`
- new local evaluation tooling with no committed user recordings or embeddings
- the pinned FluidAudio fork only if a reviewed public raw-observation API is required

## 15. Explicit non-goals

- cross-meeting voice profiles;
- real participant naming from voice;
- full live diarization during recording;
- changing capture chunk duration;
- changing the dictation ASR path;
- exact speaker-count configuration in normal product behavior;
- language-model-only speaker assignment;
- building all conditional branches.

## 16. Adversarial-review disposition

Three independent reviews agreed on the main correction:

- Kimi K3: **approve with revisions**; whole-era remains plausible after dependency pinning and a
  stage-local diagnostic.
- Grok 4.6: **no-go beyond diagnosis**; the original linear plan overfit one fixture and used gameable
  aggregate gates.
- Claude Opus: **do not start the original Phase 1**; the dependency's debug export can identify the
  actual failure stage first, and whole-era memory/timeline assumptions were incomplete.

The revised plan adopts the shared blocking feedback:

1. pin and verify the actual dependency;
2. run a per-stage diagnostic decision tree;
3. make whole-era processing conditional rather than presumed;
4. treat overlap, raw-embedding availability, time mapping, word attribution, corrupt chunks,
   cancellation, and long-session resources as first-class gates;
5. isolate any new application resolver from microphone behavior;
6. use merge/split and short-speaker recovery as primary metrics, with DER/JER as diagnostics.

## 17. Recommended next action

Implement only Phase 0 and Phase 0.5 first. The immediate deliverable is a local diagnostic report for
the failing five-speaker fixture showing exactly where the fifth speaker disappears.

That report—not architectural preference—selects Branch A, B, C, D, or E. This prevents a large,
technically elegant change from fixing the wrong stage.

## 18. Research sources

- FluidAudio documentation and source for the **pinned fork revision** (authoritative after pinning)
- Upstream FluidAudio offline diarization overview:
  https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
- VBx theory:
  https://arxiv.org/abs/2012.14952
- Multi-scale diarization decoder:
  https://arxiv.org/abs/2203.15974
- NVIDIA NeMo diarization model design:
  https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/models.html
- Reproducible DER and diagnostic metrics:
  https://github.com/pyannote/pyannote-metrics-paper/blob/master/paper.tex
- Overlap-aware diarization fusion:
  https://arxiv.org/abs/2011.01997
