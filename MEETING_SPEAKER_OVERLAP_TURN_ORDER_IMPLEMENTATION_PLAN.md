# Speaker Overlap and Turn Order Implementation Plan

Status: implemented after router adversarial review; focused verification passed
Scope: canonical Parakeet + Nemotron final transcript attribution, product turn construction, and
speaker labels. Timeline normalization is already complete and is not reopened here.

## Problem statement

The latest 78.8-second Chrome recording produced two valid Nemotron speaker slots and 278 Parakeet
word units. Of those, 263 were assigned, 13 were marked ambiguous because both slots intersected the
word, and two were outside all speaker activity. The product then:

1. treats any second-slot intersection larger than the manifest's one-microsecond mapping tolerance
   as real speaker overlap;
2. renders every nil speaker ID as `Unknown speaker`, collapsing genuine overlap, no activity, and
   timing uncertainty into one label;
3. drops outside-activity ASR text from the visible transcript; and
4. groups all segments by speaker/state before merging, so A → B → A can become one long A row with
   B displayed inside its time interval.

## Invariants

- Preserve every admitted ASR word exactly once and in chronological order.
- Never invent a speaker identity when evidence is genuinely ambiguous.
- A segment between two same-speaker segments breaks the turn, even if the gap is small.
- Cross-track segments do not merge with each other and do not reorder either track's local turns.
- Speaker activity intervals for one token are unioned before overlap is measured; duplicates never
  increase evidence.
- Model cadence, overlap thresholds, and dominance thresholds are named, backend-versioned policy,
  not generic manifest tolerances or unexplained literals.
- Sidecar evidence remains word-granular and retains ambiguity candidates and dispositions.
- Existing session JSON remains decodable; no enum case is removed or renamed.

## Phase 1 — Chronological turn construction

Replace `mergeCanonicalSegments`' grouping by full merge key with a per-track chronological fold:

1. group only by track;
2. sort each track by `(start, end, id)`;
3. compare each segment only with the immediately preceding output segment on that track;
4. merge only when the full attribution/state key matches, the gap is at most the named
   `canonicalTurnMergeGapSeconds = 3`, and total turn duration is at most the named
   `canonicalTurnMaximumDurationSeconds = 30`;
5. otherwise append a new turn; and
6. globally sort the completed per-track turns by `(start, end, trackID, id)` for publication.

Add regressions for A → B → A, A → ambiguous → A, overlapping turns, deterministic IDs, adjacent
same-speaker words, maximum gap, maximum duration, and stable global ordering across tracks.

## Phase 2 — Typed product labels

Add an optional, backward-compatible product attribution state and create one shared transcript
speaker-label resolver used by UI rows, accessibility, text export and copy operations:

- known speaker ID / `.assigned`: resolved speaker name;
- `.overlappingSpeakers`: `Overlapping speakers`;
- `.unassigned`: `Unassigned`;
- `.timingUncertain`: `Timing uncertain`.

Row label visibility compares the resolved label, not only `speakerID`, so adjacent nil-speaker rows
with different meanings each show their label. JSON export keeps `speakerID: nil` and the existing
overlap field, preserving machine-readable meaning without a schema break.

Older segments without the field fall back to the existing speaker-ID/overlap interpretation.
Timing-uncertain text remains nil-speaker but changes from `.ambiguous` to `.none`; it is not
evidence of simultaneous speakers and stays distinguishable from ordinary unassigned text.

## Phase 3 — Preserve the existing outside-activity safety policy

Keep `.outsideActivity` text suppressed in this change. Surfacing it could expose silence/noise ASR
hallucinations and requires a separate evidence policy. Echo-suppressed, outside-activity,
inadmissible and invalid-timing units remain excluded and fully accounted for in the sidecar.

## Phase 4 — Backend-specific overlap dominance

Replace token-presence assignment with union-overlap scoring for each word:

1. clip activity intervals to the word and union intervals per speaker token;
2. calculate coverage seconds and coverage fraction for every token;
3. use Nemotron's documented 80 ms output cadence as a named maximum boundary-noise duration;
4. scale the boundary-noise threshold for short words as
   `min(80 ms, 20% of the word duration)`, so 80 ms can never be discarded from a 150 ms word;
5. if every candidate is at or below that threshold, return `.unassigned` rather than creating a
   confident assignment from near-zero evidence;
6. assign the sole candidate above the threshold;
7. with multiple candidates, assign the leader only when it covers at least 50% of the word, the
   runner-up covers at most 20%, and the leader has at least twice the runner-up coverage;
8. otherwise return `.ambiguous` with deterministically sorted above-threshold candidates; and
9. keep whole-epoch utterance fallback conservative: multiple candidates remain ambiguous.

The ratios are conservative initial product policy, isolated in a configuration value and covered
at exact boundaries. Add DEBUG-only structured measurements for multi-candidate words—duration,
leader overlap, runner-up overlap and decision—without transcript text or participant identity.

Increment the Parakeet+Nemotron backend version to `2` and the meeting pipeline version to `12` so
new attribution and turn semantics have explicit lineage.

## Phase 5 — Verification

Required focused tests:

- `MeetingParakeetNemotronBackendTests`: one-frame sliver, sole sub-frame activity, 60/40 overlap,
  full overlap, exact thresholds, duplicate intervals, deterministic ties and utterance fallback;
- `MeetingTranscriptAssemblerTests`: ambiguous, unassigned and timing-uncertain attribution states,
  while outside-activity text remains suppressed;
- canonical merge tests: A/B/A, ambiguous breaker, adjacency, bounds and cross-track order;
- exporter/UI projection tests: Speaker N, Overlapping speakers, Unassigned, alias resolution and
  label transitions; and
- golden replay assertions derived from the latest session: no turn contains an intervening
  same-track turn, product text order matches sidecar word order, and all accepted words appear once.

Run the focused suites, full integration `build-for-testing`, signed Debug build, stable-identity
install preflight, and a real Chrome replay. Existing incorrectly merged sessions require Retry to
re-run backend version 2 scoring and rebuild turn rows from word evidence; label improvements apply
immediately to their retained ambiguous rows through the backward-compatible fallback.

## Explicit non-goals

- Naming anonymous slots from calendar or accessibility metadata.
- Merging speaker identity across epochs.
- Changing Nemotron model weights or quality measurements.
- Reopening timeline normalization, PCM retention, or compression work.
