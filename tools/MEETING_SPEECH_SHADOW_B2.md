# B2 offline speech activity and playback comparison

Date: 2026-09-08 (local). Experimental evidence collection, not production admission.

## Result

The cached speech-activity model runs locally and produces useful diagnostic variation, but activity still occurs in user-reported playback-only recordings. The B1 matcher still produces no supported locks on these fixtures. **This combination does not establish a safe local-speech classifier.** Every combined proposal remains explicitly uncertain; nothing hides text or filters speaker profiles.

No installed app, original recording, saved transcript or speaker profile was changed. No model was downloaded and no audio/text/embedding was sent to a reviewer. The default CLI path has speech collection off; an explicit fourth argument selects a local compiled model for this standalone run. No app runtime enablement was introduced.

## Model/API audit

The pinned FluidAudio source (`3fd63887eef1dc25edea8263ce4b44aa854d898b`) uses Silero v6's unified 256 ms model: 4,096 new mono 16 kHz samples plus 64 context samples; hidden/cell states each have 128 values. `VadManager`'s normal and directory initializers call download helpers, while its preloaded-MLModel initializer avoids them. Its whole-array helper pads short final chunks by repeating the final sample.

This evaluator instead uses a small direct CoreML adapter with the audited exact feature names/shapes and CPU-only execution. It cannot invoke FluidAudio download helpers. It submits only complete valid frames, with no fabricated tail padding. It keeps the 64-sample context and recurrent state across contiguous valid frames, and resets after invalid coverage, gaps, epoch/route/session changes or model failure. The first valid frame after reset is marked warmup/unknown; this one-frame warmup is an explicit experimental convention, not a validated convergence guarantee.

The cached `model.mil` combines eight internal 32 ms probabilities as `1 - product(1 - p_i)`. Consequently the exported scalar is **not** mean speech probability, voiced duration, near-end confidence or eight independent pieces of evidence. The dependency's 0.85 default is retained only as a diagnostic activity threshold. No gain normalization, energy rescue, segmentation padding or speech suppression was added.

The local FluidAudio repository declares Apache-2.0. The model publisher declares MIT in its [model card](https://huggingface.co/FluidInference/silero-vad-coreml/blob/main/README.md); no new model redistribution/package is performed here. Cached artifact identity is separately fingerprinted rather than assuming the current remote card establishes byte identity.

Cached model: `silero-vad-unified-256ms-v6.0.0.mlmodelc`. Sidecars record hashes of all five files; hashes are checked again after inference. Key SHA-256 values:

```text
model.mil       4f93e2b5920e851fbc0be1c21a2a76e170124467ed7b01125190aa32e795f8af
weights/weight.bin 853cf34740d3f5061f977ebe2976f7c921b064261c9c4753b3a1196f2dba42b4
```

## Evidence, coverage and safety

- The existing B1 paired-audio analysis remains a separate signal. Speech frames join its windows by full interval overlap in the same capture epoch; 256 ms frames crossing the two-second grid are not dropped. Mixed support remains explicit. Missing temporal coverage is not a reliable negative match.
- New combined reason categories distinguish activity with a supported duplicate, activity without a reliable match, negative activity with/without duplicate evidence, and unavailable speech evidence. None establishes near-end speech or absence. The legacy echo score is explicitly `notMeasured` in this CLI; this is not the full three-signal/B3 ablation.
- Original capture PTS, overlapping-chunk rejection, 50 ms conservative decoded edges and ±2 s either-track recorded discontinuity guards are retained. Invalid samples remain unavailable, not silence. Unrecorded route changes and accurate AAC priming remain limitations from B1.
- One model instance and synchronous frame inference; cancellation checked before/after prediction. A CoreML prediction cannot be forcibly preempted. A 100 ms per-frame engineering budget discards over-budget results; three consecutive failures disable the contribution within the session. Unknown frames clear pre-disable strikes; a new session resets the latch. Model load is synchronous and is not covered by the per-frame inference budget.
- The offline runner is capped at 600 seconds/32 chunks and keeps a bounded session raster in memory; it is not a streaming capture implementation. A missing model emits explicit unavailable status and full unmeasured duration, with no network fallback.
- Detailed reports are numeric-only, exclusively created outside original sessions under temporary storage. They are not application logs or persisted admission decisions. Retain only for development review; no automatic deletion/retention automation was created.

## Local measurements

Final reports: `/private/tmp/fv-speech-{3774,88e3,3b9a}-v2.json`. V1 reports predate the improved temporal-grid join and are superseded. All counts below are **256 ms windows**, not speech duration.

| Development recording | Full frames | Measured | Activity ≥0.85 | Unknown full frames | Unknown duration including tail |
| --- | ---: | ---: | ---: | ---: | ---: |
| `3774ED4C…` user-reported no speech | 385 | 380 | 6 | 5 | 1.476 s |
| `88E3BD44…` scripted speech near end | 1,016 | 1,004 | 141 | 12 | 3.299 s |
| `3B9AC1A8…` user-reported playback-only | 515 | 508 | 6 | 7 | 1.822 s |

In the previously identified coarse 208–250 s scripted interval, 121 of 161 measured windows were active (163 total). There were also 19 active windows wholly before 208 s. These boundaries come from prior diagnosis, not independent sample-level annotations; pauses and exact speech onset are unlabelled. The ratio is **not speech recall**, and earlier windows cannot all be labelled individually from this coarse boundary.

The playback-only recordings demonstrate that activity can be leaked speech rather than near-end speech. Conversely, a negative activity window cannot establish absence of a quiet reply. Synthetic tests explicitly retain this distinction. All 1,916 combined frame proposals stay uncertain: 153 activity-without-reliable-match, 1,739 negative-activity-not-absence, and 24 missing-speech-evidence. There are zero supported temporal locks.

Final end-to-end local CPU-only runs took 1.10, 1.48 and 0.77 seconds, with maximum resident sizes about 62.3, 80.9 and 64.7 MB. No model, budget or inference failures occurred in these runs. These are development profiles, not capture-load or held-out acceptance results.

`/private/tmp/fv-speech-3774-off.json` confirms off mode has the same input fingerprint and temporal state counts. `/private/tmp/fv-speech-3774-unavailable.json` confirms a missing model reports all 98.756 seconds unavailable without a fallback download. This does not replace a full baseline/echo/VAD/combined end-to-end admission ablation.

## Adversarial review and dispositions

Three scoped Kimi K3 reviews completed through OpenCode in read-only mode: B1 core, B2 adapter/evaluator, and Stage A evidence seam. Earlier timeouts are historical, not the current review result. Findings were addressed as follows:

1. B1 floating-point lag-spread boundary: fixed using integer-sample comparison; exact 12 ms spread regression added.
2. B1 failure latch/counter scope: new sessions reset the latch; unavailable windows clear pre-disable consecutive strikes. Within-session disabled state intentionally remains latched.
3. B1 release counters: no code change. `released` records the transition; zero supporting windows accurately represents current evidence. Retaining former support in those fields would be misleading.
4. B2 failure reset issues: fixed consistently with B1 and covered by session/unknown-frame tests.
5. B2 256 ms / two-second grid mismatch: replaced single-containing-window lookup with overlap/coverage join and explicit mixed/unavailable state, with boundary tests. The reviewer incorrectly attributed the old nil temporal match to the missing-*speech* reason; that reason depends on missing VAD activity. The temporal coverage problem itself was real.
6. Short-session shifted controls: explicitly report `controlUnavailable` when neither ±8 s control fits. No fabricated fallback. Some later short-session windows can use the backward control, contrary to the review's broader claim; missing control remains an acknowledged measurement limit.
7. Stage A unknown playback context: added `missingPlaybackContext` instead of labelling a valid temporal measurement invalid, with a regression test.
8. Stage A exact interval/observation equality: retained intentionally. This test-only contract binds to an immutable evidence snapshot, not an approximate audio match; callers must reuse/rebind that snapshot explicitly. Two cases pin rejection of a one-ULP interval change and observation change. A future runtime projection must define its own timeline conversion rather than silently relaxing binding. `staleTemporalEvidence` currently includes snapshot mismatch, not just expired epochs.

The scopes above were reviewed; post-fix implementation was locally verified, not independently re-reviewed in full. No claim of production approval, calibration approval or enforcement sign-off is made.

## Verification

Final isolated `FluidASRBaseline` build succeeded and **46 targeted tests passed**, zero failures/skips: 11 speech tests, 13 temporal tests, 17 Stage A contract tests and five existing live diagnostic tests. Result bundle: `/private/tmp/fv-speech-b2-v3.xcresult`. The earlier v1 test attempt failed before tests could launch because the generated CTranscribe framework had an invalid version layout/signature; displaced framework files were retained in temporary backups, the isolated host was repaired/re-signed and deep/strict verified, then v2 (44 tests) and final v3 passed. No installed-app replacement occurred.

The optimized CLI compiled and ran all three local fixtures, speech-off mode and missing-model mode. Source inspection confirms no production caller of the speech adapter or either shadow policy. `git diff --check` passed. The full application integration suite, Release build, hour-long capture load, independently annotated positives, calibrated recall and held-out gates were not run.

## Reproduce / next gate

From the repository root:

```sh
swiftc -module-cache-path /private/tmp/fv-reliability-swift-cache -O \
  Sources/Fluid/Services/Meeting/MeetingPlaybackDuplicateDetector.swift \
  Sources/Fluid/Services/Meeting/MeetingSpeechActivityDetector.swift \
  tools/meeting_temporal_shadow.swift -o /private/tmp/fv-speech-shadow
```

Run with `session.json`, a fresh output path outside the session directory, and the explicitly chosen cached `.mlmodelc` directory. Omit the model argument for speech-off mode. Native codec/CoreML access may require host execution approval; this does not upload audio or grant new application privacy permissions.

Next is annotated development evaluation and feature/calibration work, not enabling suppression. Stronger temporal evidence may be needed for weak nonlinear residuals. Quiet replies, double talk, no-reference speech, multiple near-end speakers and held-out quality remain unvalidated. Any new detector/model dependency needs a separately reviewed scope. B3, app shadow integration and enforcement remain outstanding.

Source SHA-256 for the final fixture runs:

```text
speech adapter 751dea98435493b2c2c3792a6965ed2e3d7eb301634bcd92a71728ec4cba12bb
temporal       429111cce7a90ffec42e84b7f9e7bd9fece6b0c21c8790616de52fc180389d95
evaluator      d254f1e0c309f485d50e93ab146c245ea3457245881a4ff2a1f772ded7465e07
```
