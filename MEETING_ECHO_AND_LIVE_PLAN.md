# Meeting echo handling and live transcription — measured plan

Status: **analysis complete, scorer built standalone, integration not started.** Measurements taken
2026-08-14 against a real 3.2-minute Zoom session (both raw tracks on disk).

---

## 1. Corrected root causes

Two separate defects were conflated earlier. They need different fixes.

### 1a. Interjections swallowed by echo classification

`MeetingEchoDetector` scores a whole diarized turn by word containment against the far end. A turn
that is mostly speaker bleed but contains a short local interjection scores as echo, and the user's
words are hidden with it. Observed: "I'm testing." and "Notetaker." absent from our transcript,
present in a competitor's.

### 1b. One utterance split across a chunk boundary, labelled two ways

Observed: `119.09–120.12` → *Microphone / Unknown*, `120.06–127.53` → *You*. Same sentence, split at
the 120 s chunk boundary.

**An earlier diagnosis blaming per-chunk local-speaker resolution was wrong.**
`processMicrophoneTrack` stages turns across all chunks and calls `finishMicrophoneTrack` once, so
resolution is already session-wide. The real cause is cluster identity: the emit rule keys on
`turn.clusterID == localClusterID`, and the 1.04 s fragment was assigned a different cluster.
Diarization runs per chunk; a ~1 s fragment yields a weak embedding, and cross-chunk matching
(max cosine distance 0.35, ambiguity margin 0.08) rejects it.

Consequence: **signal-based echo scoring cannot fix 1b.** A turn in the wrong cluster is not labelled
`You` regardless of its echo verdict. 1b needs its own fix, un-designed as of tonight.

---

## 2. Measurements

All on the real session, raw tracks, `microphone` vs `applicationAudio`.

### Alignment
- Both tracks decode to identical duration (192.400 s) — one shared `SCStream` clock.
- Delay by GCC-PHAT: mic content **leads** app audio by **31.9 ms**, std **0.3 ms** across the session.
- Drift **+6.9 ppm** (~25 ms/hour) — real, above measurement resolution, slow enough to track.
- Per chunk: −32.28, −31.97, −31.62, −31.38 ms. A smooth monotonic progression **through** chunk
  boundaries (6.4 ppm), not discontinuities. AAC priming does **not** shift the tracks differentially.
- The 31.9 ms is a capture-pipeline offset, not an acoustic path. It is hardware-specific, can be
  either sign, and Bluetooth output can invert it by 100–300 ms. **Never hardcode it; always estimate.**

### Cancellation potential
- Per-2 s frequency-domain Wiener filter: **9–11 dB ERLE** in echo-dominant blocks.
- A single session-wide filter achieves only 1.6 dB — drift defeats it. Adaptation is mandatory.
- Overall 3.9 dB, dragged down by blocks where the far end is silent (nothing to cancel).

### Turn-level separability (the decisive measurement)

Per-frame explained fraction = `1 − residual_energy / mic_energy`, 1024-sample frames, 256 hop.

| turn kind | n | mean | median | longest low-run (<0.35) |
|---|---|---|---|---|
| pure echo | 5 | 0.53–0.68 | 0.62–0.82 | **0.24–0.59 s** |
| contains local speech | 1 | 0.43 | 0.38 | **0.98 s** |
| local speech only | 3 | 0.02–0.03 | 0.00–0.02 | **0.96–10.27 s** |

**Mean and median cannot separate the mixed turn** — it sits between the two populations. The
**longest contiguous low-scoring run** does, with a clean gap: echo never exceeds 0.59 s, anything
containing local speech never falls below 0.96 s. This is the rescue statistic the design needs.

Caveat: one recording, one room, ten turns. The gap is real but the sample is small.

### Operating envelope of the rescue rule (found in code review, measured)

The statistic is `1 − residual/mic`. When local speech is **added on top of** echo — which is what
real speakerphone double-talk is — the fraction is approximately `echo / (echo + local)`. To fall
below `localSpeechFractionThreshold` (0.35) the local speech must therefore carry roughly
**1.86× the echo energy at the microphone**.

That holds comfortably for a laptop mic near the speaker's mouth with the far end coming from the
same laptop's speakers — it was satisfied throughout the real recording. It does **not** hold for a
quiet interjection over a loud far end, or a mic far from the user. That is the rule's operating
envelope, and it is a genuine limitation rather than a tuning constant: a louder threshold trades
directly against false rescues of pure echo.

Consequence for calibration: the held-out recordings must include a quiet-interjection case, not
just more of the easy one.

---

## 3. Decisions from adversarial review

Reviewed by two independent external models. Both independently reached the same conclusions.

| decision | reason |
|---|---|
| Signal acts as a **veto only** on text-positive turns | Making it primary creates a new false-positive class that hides user speech |
| **Do not** feed signal evidence into `localSpeakerEvidence` | The purity rule `supporting > echoed` plus the 1.75× winner margin means a misclassification can elect the *far-end* cluster as "You" — a high-amplification failure |
| Three-state verdict: echo / containsLocalSpeech / **unknown** | Absence of reference audio is not evidence of local speech. Headphone users, silent far end, and low delay confidence must abstain, not score 0 |
| Turn aggregation must use the **low-run** statistic, not an average | Measured above; an average reproduces the exact bug being fixed |
| Reference audio must be gathered by **time range across all app chunks**, not chunk N ↔ chunk N | The two tracks' `MeetingAudioChunkWriter`s rotate independently and diverge permanently after a discontinuity on either track |
| Reference-read failure must be **total** (degrade to `.unknown`, never throw) | Today only the mic chunk's own `audioUnreadable` skips a chunk; a sick app track must not take down a healthy mic track |
| Exclude discontinuity-adjacent windows | A shared clock does not make content contiguous after dropped samples |
| Bump `pipelineVersion` when classification changes | Checkpoint reuse would otherwise mix classification rules mid-session |

Open, unresolved: threshold portability across hardware/rooms/volumes (one recording); non-speech
far-end audio (music, video) is a false-positive class today's text detector cannot produce; whether
to persist the score, and if so versioned against the scorer.

---

## 4. Built

**`MeetingEchoSignalScorer.swift`** — pure functions over PCM: GCC-PHAT delay estimation with a
confidence measure, per-frame explained fractions with NaN for unscoreable frames, and a three-state
turn verdict using the low-run rule. Unit tested on deterministic synthetic signals.

**Integrated as a veto** (`pipelineVersion` 3 → 4). The design point both reviewers converged on is
**two separate echo fields**:

- `isLikelyEcho` stays **text-only** and remains the sole input to `localSpeakerEvidence`. Signal
  evidence must never influence the local-speaker election — a misclassification there could elect
  the *far-end* cluster as "You" through the 1.75× winner rule, which is a far worse failure than
  any single mislabelled turn.
- `effectiveEcho = isLikelyEcho && signalVerdict != .containsLocalSpeech` drives **both** loss paths:
  the `isCleanLocalTurn` assignment and the emitted echo flag that the UI and exporter filter on.

Supporting decisions:
- Reference audio is gathered by **presentation timestamp** across all intersecting application
  chunks. Never by chunk index: the two writers rotate independently and diverge permanently after a
  discontinuity, so a mic chunk can straddle two app chunks.
- Gaps are **zero-filled, not masked**. A zero-filled block has no reference energy, so the scorer's
  own floor already forces those frames to NaN — an explicit mask would mean reopening a tested
  module for no behavioural gain.
- Delay falls back to a **rolling median within a capture epoch**, never a session-wide scalar; an
  epoch ends at any discontinuity on either track.
- Every reference failure degrades to `.unknown` and mutates nothing. A sick application track must
  never skip a healthy microphone chunk.

**Known limits, deliberately documented rather than hidden:**
- Turns shorter than ~0.8 s can never be vetoed (`minimumLocalSpeechRunSeconds` is 0.75 s), so a
  standalone backchannel — "yeah", "okay" — stays hidden. The measured failure case survives only
  because those interjections sat inside a 25.9 s turn.
- The 1.86× energy envelope means a quiet interjection over a loud far end is not rescued.

Together these cap how much of the motivating bug this fixes. It is a real improvement, not a
general solution.

---

## 5. Live transcription — shape only

Capture stays on ScreenCaptureKit. Voice Processing I/O is disqualified: instantiating it ducks all
other applications' audio system-wide, which would corrupt the very `applicationAudio` track we
record. Core Audio process taps are a permission-UX decision, not an echo fix, and risk zero-filled
buffers for WebRTC apps (Zoom, Meet, Teams).

**Decision (2026-08-14): no diarization during the meeting.** Live shows only *You* and *Them*,
derived from which track the audio arrived on — not from analysing voices. Speaker identity is
resolved after the meeting by the existing batch pipeline.

- **Live** — streaming ASR on both tracks. Mic = You, application audio = Them. Correct by
  construction in any 1:1. **Depends on echo suppression**, or "You" transcribes the far end.
- **On meeting end** — today's batch pipeline runs unchanged and replaces the live text with the
  word-aligned, properly diarized final transcript, turning *Them* into Speaker 1/2/3.

Why this ordering rather than a live diarizer:
- The streaming diarizer measured **1,011 MB resident** (see below). Deferring it keeps that
  entirely out of the meeting, which removes the model-contention question rather than answering it.
- Streaming diarization is 10–15 % worse DER than the offline path, so deferring *improves* the
  final transcript instead of compromising it.
- Label churn disappears: nothing can retroactively relabel text the user already read, because no
  speaker decision is made live.
- Cost: in a 3+ person call, everyone else reads as *Them* until processing finishes. In a 1:1,
  nothing is lost.

### Measured memory (2026-08-14, this machine)

| component | peak RSS | note |
|---|---|---|
| Streaming diarizer (Sortformer) | **1,011 MB** | real run, 56.7 s for 192 s audio (~3.4× realtime) |
| Nemotron streaming ASR | 688 MB | models loaded, then **failed** before transcribing |

The diarizer's 1 GB is far above its 21 MB on-disk footprint. Contention between the two was **not**
measured: Nemotron aborts with a CoreML `zero shape error` during type inference on ordinary 16 kHz
mono input, both full-length and on a 30 s clip with an explicit chunk size. That failure blocks the
live path itself, not just the measurement, and is the first thing to resolve.

Still open: whether one streaming ASR instance can serve both tracks, or whether two instances
(~690 MB each) are required.

Hard constraints, verified in FluidAudio at the pinned commit:
- Streaming ASR produces **no word timestamps** (zero `TokenTiming` references in the streaming
  path). Our word→turn assignment cannot run live; final quality must come from the batch pass.
- Streaming "partials" only grow — greedy RNNT, never revised. `.provisional` would have meant
  "growing", not "correctable". **As built, `MeetingTranscriptStatus.provisional` stays unused**:
  live text is held in memory and published from the coordinator, never entering
  `session.transcriptSegments`, so there is nothing to mark. That containment is deliberate — it
  makes lowercase, unpunctuated live text unreachable by export and copy by construction rather
  than by filtering, and means a crash or a failed batch pass cannot leave it posing as the
  transcript.
- Streaming diarization is 10–15 % worse DER than the offline VBx pipeline in use today.
- Below ~560 ms chunks, WER degrades sharply (2.1 % → ~10 % at 160 ms).
- Nothing in FluidAudio combines streaming ASR with streaming diarization; we would align them.

---

## 6. First real live run (2026-08-14, headphones, 2.5 min Zoom)

Live transcription ran end to end against a real meeting. Both tracks transcribed; "You" and "Them"
were correct by construction. Four defects found and fixed.

| defect | evidence | fix |
|---|---|---|
| Utterance spans swallow leading silence | mic EOU #1 reported `119.6s`; wall clock shows speech `18:56:32→18:57:11`, EOU at `18:57:13` | anchor `utteranceStartPTS` to the first decoded token, backdated one chunk, clamped to the previous utterance's end |
| ~5s of meeting-opening audio shed | 381 drops between `11.123` and `13.833`, then never again | run CoreML warmup on silence *before* `isModelReady`; queue 24 → 512 slots |
| 255 decoder resets and 255 degraded notifications in one burst | one `handleDrop` per dropped sample | coalesce to one resync per burst, applied by the drain loop |
| `handleEOU` reentrancy on `await manager.reset()` | `consume` could set a stale start during the suspension | dissolves — `consume` no longer touches utterance start |

**The endpointer is not slow.** EOU fires ~1.5–2s after speech stops, matching the model's 1280ms
debounce. An earlier reading of "78–120s latency" was a misinterpretation of the inflated spans.

## 7. Whole-chunk microphone fallback: neither echo classifier can score it

The same run put 60s of garbled far-end bleed in the transcript as `Microphone / Unknown`,
`isLikelyEcho=false`. Root cause: the whole-chunk fallback appends straight to
`accumulator.segments`, bypassing `stagedTurns` — and all echo classification runs over
`stagedTurns`.

Two candidate fixes were **measured and rejected**:

- **Text detector.** The bleed block scores **0.31** containment against its own 60s window
  (threshold 0.5) — it would not be flagged. Genuine user speech from the same session scores
  0.05–0.29 even against the whole-meeting corpus, so widening the window is not the answer either.
- **Signal scorer.** A probe over the real chunks returns **no delay estimate and no verdict** for
  the two bleed chunks (`verdict=nil, delay=none`); GCC-PHAT finds no confident echo path and
  correctly abstains. Only chunk 2 scored, at `containsLocalSpeech`, delay `-50ms`.

Reproduce with `MeetingFallbackEchoProbeTests` (`TEST_RUNNER_FLUIDVOICE_ECHO_PROBE=<session dir>`).

**Actual fix:** `LabeledPassError.emptyTurn` no longer falls through to `transcribeWholeChunk`.
Diarization succeeding while every turn transcribes empty is positive evidence that the microphone
holds no intelligible speech; re-transcribing 60s of near-silence only produces hallucinated text
that is unattributable and unscoreable. Genuine diarization failure — including
`SpeakerDiarizationService.isSupported == false` — still gets the fallback. `pipelineVersion` 4 → 5.

Still open: `wordAttachmentTolerance` is `0` for the microphone (`MeetingProcessingPipeline:1463`),
which disables the nearest-neighbour rescue in `assignWords` and drops any word whose timing
disagrees with a diarizer boundary (observed `29/67`, `8/30` unassigned). Loosening it trades
directly against crediting bleed to the user; needs its own measurement.

---

## 8. Deferred

Fluid One transcript cleanup (measured: ~648 ms/turn on a 1.5 B proxy model with prefix KV caching
on, ~2 min/meeting-hour; Fluid One is 3.3 GB so estimate 5–8 min — a background job, not a blocking
step). Vocabulary biasing for meetings is independent and cheap: the meeting pipeline does not use
`ParakeetVocabularyStore` / `PronunciationDictionaryStore` at all today, which likely explains
"Cloud Code" for "Claude Code".
