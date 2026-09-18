# B3 development ablation — existing recordings

Date: 2026-09-08 (local), updated 2026-09-09 with five controlled recordings. Status: **insufficient for threshold selection**.

## Outcome

The available evidence does not support enabling microphone admission. The current temporal detector produces no supported duplicate windows, so its ablation is identical to accepting every measured frame. Speech activity shows a tradeoff but cannot establish near-end speech: settings that preserve nearly all frames in the coarse scripted region admit hundreds of known-negative frames, while stricter settings still admit negative frames and reject many frames inside that coarse region.

No threshold was selected or frozen. The installed app, runtime configuration, original recordings, transcripts and speaker profiles were not changed. This evaluator reads existing saved text locally only to count words and never emits text, speaker identifiers, segment identifiers, audio or embeddings.

## Controlled-recording update

Five user-directed development recordings were captured with the installed app and analyzed locally: playback only; normal and quiet speech without playback; normal speech over playback; and two sequences of quiet replies over playback. The user confirmed that playback used speakers, their speech entered through the microphone, and nobody else was speaking nearby. No headphones were used. All ten audio tracks completed without a dropped sample, discontinuity or recorded failure. The longer playback-only recording produced four visible microphone-attributed segments containing 49 words even though the user reported staying silent. This is a controlled acoustic-playback failure example; it does not by itself identify the exact hardware/software leakage path.

The B1 temporal detector found no `duplicateSupported` window in any controlled recording. The playback-only recording produced three isolated `duplicateCandidate` windows, but never the required stable three-window sequence. Temporal-only admission therefore still accepts every measured negative frame.

At the existing diagnostic speech threshold of 0.85, the controlled playback-only recording admitted 10/600 measured negative frames. The coarse positive regions admitted 137/445 measured frames: 24/42 in clean normal speech, 16/36 in clean quiet speech, 63/135 in normal speech over playback, and 34/232 in the whole-recording quiet-replies-over-playback region. These positive denominators include pauses and, for the overlap recordings, playback-only time; their acceptance is not recall. The transcript localized the three normal-over-playback repetitions into coarse regions, but this is not independent ground truth. The quiet-over-playback recording remains recording-level coarse truth.

Across all eight development recordings, threshold 0.04 admitted 681/2,291 known-negative frames and 507/606 coarse-region frames. Threshold 0.85 admitted 41/2,291 known-negative frames and 258/606 coarse-region frames. This is a real tradeoff, not a calibration result: frames are correlated, coarse regions contain pauses, and there are still zero independently frame-labelled positive recordings. No threshold is selected and suppression remains off.

Current aggregate result after recording the corrected speaker/microphone provenance: `/private/tmp/fv-admission-b3-controlled-v3.json`. The five numeric-only sidecars are `/private/tmp/fv-speech-control-{playback,normal,quiet,normal-overlap,quiet-overlap}-v1.json`. Audio and transcript content stayed local and no installed app was changed.

## Ground truth that is actually available

The development annotation manifest is `meeting_admission_b3_annotations.json`:

- `3774ED4C…`: user reported no near-end speech for the recording.
- `3B9AC1A8…`: user reported playback-only for the recording.
- `88E3BD44…`: user reported speaking only the supplied script near the end. The 0–208 s interval is treated as known-negative. The 208–250 s interval is only a **coarse script region**; its individual speech and pause frames are not labelled. The remaining tail is unlabelled.

These are failure-selected, post-hoc development recordings. There are two pure-negative recordings, one recording containing both a negative interval and a coarse script region, and zero independently frame-labelled positive recordings. The cohort counts intentionally overlap where one recording supplies both kinds of interval.

## Current saved transcript inventory

For microphone segments fully contained in annotated intervals:

| Annotation | Segments | All words | Currently visible words | Visible speaker slots per session |
| --- | ---: | ---: | ---: | ---: |
| Known-negative intervals | 21 | 331 | 324 | 4 |
| Coarse script region | 3 | 89 | 89 | 1 |

“Visible” reuses the saved pipeline's own `isLikelyEcho` output and is reported only as current-output inventory, not as independent validation. The 89 coarse-region words are not verified for correctness. Full-containment is used to avoid assigning a boundary-crossing segment wholesale; boundary/outside exclusions are separately counted in the JSON result. This dataset happened to have no excluded microphone transcript segments.

## Frame evidence and descriptive sweep

There are 1,691 measured 256 ms frames in known-negative intervals and 161 measured frames in the coarse script region. Another 21 labelled frames have explicit unknown speech evidence; two frames straddle annotation boundaries and 39 fall outside annotations. All denominators and exclusions are present in the result.

| Diagnostic VAD threshold | Known-negative frames accepted | Negative acceptance | Coarse-region frames accepted | Coarse-region acceptance |
| ---: | ---: | ---: | ---: | ---: |
| 0.01 | 1,078 / 1,691 | 63.7% | 161 / 161 | 100% |
| 0.04 | 549 / 1,691 | 32.5% | 160 / 161 | 99.4% |
| 0.05 | 464 / 1,691 | 27.4% | 158 / 161 | 98.1% |
| 0.10 | 282 / 1,691 | 16.7% | 145 / 161 | 90.1% |
| 0.50 | 66 / 1,691 | 3.9% | 123 / 161 | 76.4% |
| 0.85 | 31 / 1,691 | 1.8% | 121 / 161 | 75.2% |
| 0.95 | 20 / 1,691 | 1.2% | 121 / 161 | 75.2% |

Coarse-region acceptance is **not speech recall**: some rejected frames can be pauses, and some accepted frames can be leaked playback. Frame observations are recurrent and temporally correlated, so 1,691 frames are not 1,691 independent trials. Recording-level uncertainty cannot be meaningfully estimated from two pure-negative recordings and no independently labelled positive recording.

The “speech plus no supported duplicate” ablation equals speech-only on these inputs because B1 produced zero supported locks. The accept-all control and current temporal-only policy both accept all 1,691 measured negative frames. The full sweep is included for diagnosis only; it does not rank candidates or publish a selection gate. It does not project frame decisions into word removal, WER or speaker identity changes.

## Evaluator integrity

`meeting_admission_b3_eval.py` validates:

- canonical session IDs and safe sidecar basenames;
- session-byte hash agreement with each sidecar;
- pinned B1/B2 versions, 4,096/16 kHz frame geometry, 0.85 diagnostic threshold and identical cached model file hashes;
- finite probabilities, explicit reasons for every unknown probability, known temporal states and annotation ends within recorded duration;
- non-overlapping, finite annotation intervals and exclusive output creation.

It reports measured/unknown/boundary/outside frames explicitly. Transcript segments crossing boundaries or outside annotation are counted separately rather than silently disappearing. Empty sessions/annotations are rejected. The cached model artifact dictionary is pinned to fingerprint `259aec29878cbca1118f4e4fa1db126676286c90b65903266545f50e9ac4512d`, and sidecar duration must agree with an independent calculation from session audio-chunk PTS. Eleven unit tests cover interval containment, overlap/traversal/empty-input rejection, confusion counts, privacy, threshold inventory, unknown probability handling, duration calculation and transcript boundary accounting.

The original three-recording aggregate was `/private/tmp/fv-admission-b3-dev-v7.json`. The controlled eight-recording aggregate `/private/tmp/fv-admission-b3-controlled-v3.json` supersedes it for current development analysis. Reproduce from the repository root:

```sh
python3 tools/meeting_admission_b3_eval.py \
  --annotations tools/meeting_admission_b3_annotations.json \
  --sessions-root "$HOME/Library/Application Support/FluidVoice/Meetings" \
  --sidecar-root /private/tmp \
  --output /private/tmp/fv-admission-b3-dev-new.json
```

The command above is documentation for a human shell; the evaluator itself never expands or emits the sessions path. Use a fresh output filename because overwrite is refused.

## Next evidence gate

The next useful input is an independently timed controlled recording with frame-level labels for:

1. clean normal and quiet speech without playback;
2. playback-only intervals;
3. short quiet replies during playback;
4. sustained normal speech during playback;
5. deliberate pauses and missing/reference-transition intervals.

This first positive must remain development data. After any feature/threshold changes, separate recordings by speaker/device/environment are required for held-out evaluation. Until then, suppression and profile filtering remain off. If a stronger temporal feature or model dependency is proposed, that is a separate reviewed scope.

## Review and artifact identity

Kimi K3 adversarially reviewed the annotation/evaluator/test source in read-only mode. Its first pass found silent denominator drift, hard-coded frame duration, unreported boundary exclusions, overlapping cohort-count ambiguity and selection-flavored output. All were fixed: unknowns/exclusions are counted, frame geometry is schema-derived and pinned, cohort fields explicitly describe overlap, and candidate lists were removed. A second pass found empty annotations, consistency-only model hashes and sidecar-only duration bounds; all were fixed with nonempty-input checks, a pinned model fingerprint and independent session-duration verification. The final post-fix verification returned **no findings**. No audio, transcript content, model weights or secrets were sent to the reviewer.

Original three-recording SHA-256 values are retained below for audit history:

```text
annotations 95a0a11bf12400e22ec8d00de36397d491e90520fcc5b7e61dc3135fa0b4e955
evaluator   886187f58085207802cae8f713d72206f70272d767a9dbb3d15fe16ec7e301b1
tests       93dfb7673a9dbf60775e8e351d5781f4cd940b1a5a09f88eb2e202430d58b5a5
result      26d01f04a558ee88c26bb105451e42a74987048f7b3c923dc3635f98d5ef0c9e
```

Controlled-update SHA-256:

```text
annotations 0837a3d5935a7ca945217c2fe869863ad39268a2ac7a1ce9ea0fbe8b400280cb
evaluator   cc4bfa8647a60c5d7cd3422f0defe8959ffe9fd59a24485fc6f10d0b80d2a108
tests       93dfb7673a9dbf60775e8e351d5781f4cd940b1a5a09f88eb2e202430d58b5a5
result      875437729970fbc763d589a49961cd2045a30153f1a0dc9ea8d72df368e7655d
```
