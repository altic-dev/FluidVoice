# Temporal shadow detector B1 — development evaluation

Date: 2026-09-08 (local). Offline experimental implementation, not a caption fix or release gate pass.

Follow-up: B2 completed the previously pending scoped reviews, fixed temporal lag/budget issues, and added local activity comparison. See `MEETING_SPEECH_SHADOW_B2.md` for current review dispositions and results; historical B1 hashes/measurements below identify the earlier run.

## Outcome

The first normalized-waveform operating point produced **zero duplicate-supported windows** on all three development recordings. This is a negative feasibility result for this particular feature/operating point, not proof that the microphone contains no playback or that speech is safe to accept. Thresholds were not lowered to fit these recordings.

The installed app, legacy admission behavior, saved transcripts, speaker profiles and original audio were not modified. The detector has no production caller; the only executable caller outside tests is the explicitly invoked local evaluator. No new runtime flag, model, network call or persistence schema was added.

## Implementation and limits

- `MeetingPlaybackDuplicateDetector.swift` consumes explicitly resampled mono 2 kHz windows with original PTS and validity masks. Positive lag means microphone follows playback. It searches ±0.5 seconds in 1 ms increments, measures mean-centered absolute normalized correlation and compares its peak with an eight-second-shifted reference control and separated competing peaks.
- Support requires three consecutive two-second windows whose lag spread is at most 12 ms. History is capped at three windows by default (configuration capped at 16). Epoch/session/route changes, gaps, unavailable coverage and failed support clear accumulated evidence. No stale supported state survives reference loss.
- There is no release hangover in this first experiment. Updates still have two-second resolution; zero hold does **not** mean zero detection/release latency. Synthetic perfect-copy lock requires six seconds of observations. Reports do not backdate support into earlier windows or claim sub-window onset precision.
- The 0.25 correlation, 0.08 control margin, 0.025 competing-peak margin, 1e-5 RMS floor and timing settings are experimental engineering constants. Configuration is captured in sidecars. They are neither probabilities nor calibrated speech-admission thresholds.
- The caller uses AVAudioConverter anti-aliased resampling, clips decoded samples to recorded chunk end, linearly maps fractional PTS to a common grid and invalidates overlapping chunk coverage. It masks either-track recorded discontinuities by ±2 seconds, matching the existing pipeline guard. It additionally masks 50 ms at decoded/chunk edges conservatively; this is not an independently verified AAC priming model. Missing-PTS discontinuities fail the offline run rather than invent an epoch.
- Only recorded discontinuities can be reconstructed. Unrecorded route/sample-clock changes remain a limitation; lag instability can reset support but is not a verified clock-drift correction. No live reuse or source-rate-change guarantees are claimed.
- Low-energy mic/reference/control windows remain insufficient evidence. A missing control is not a zero-valued negative control. Periodic signals and equal control matches cannot lock in the synthetic tests.
- A synthetic quiet local signal added while playback is already supported **still leaves a supported match**. This explicitly demonstrates why temporal evidence alone must never hide speech. Nonlinear residual separation, near-end activity and interval admission are not implemented here.
- The evaluator is capped at 600 seconds, 32 chunks, two tracks, 65 seconds per decoded chunk, bounded formats/file sizes and one synchronous job. Per-window scoring has an injectable 0.5-second budget, checked each lag; three repeated budget failures disable the contribution for that detector instance. These local measurements do not constitute an hour-long capture-load test or a hard real-time deadline guarantee.

## Local numeric results

Final sidecars are `/private/tmp/fv-temporal-{3774,88e3,3b9a}-v2.json`; earlier v1 sidecars precede the explicit silent-reference/control check and are superseded. Input session and audio hashes are in each sidecar; no text, embeddings or raw audio is emitted. Durations below are recorded audio PTS spans, not UI session durations.

| Development session | Audio span | Windows | Scored/inconclusive | Invalid coverage | Low energy | Supported | Median diagnostic lag | Median peak correlation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `3774ED4C…` | 98.756 s | 49 | 44 | 5 | 0 | 0 | +70 ms | 0.104 |
| `88E3BD44…` | 260.323 s | 130 | 98 | 18 | 14 | 0 | +86 ms | 0.129 |
| `3B9AC1A8…` | 131.870 s | 65 | 54 | 11 | 0 | 0 | +62 ms | 0.075 |

Unwindowed tails are respectively 0.756, 0.323 and 1.870 seconds and remain unmeasured. Invalid/low-energy windows contribute another 10, 64 and 22 seconds of unknown coverage. Even the scored windows are inconclusive, not negative speech evidence. Diagnostic best-lag ranges are respectively −500…+350, −491…+479 and −491…+469 ms; their medians are **not delay locks**. Peak correlations never reached 0.25 (maxima 0.190, 0.2495 and 0.175).

Maximum measured optimized scoring time per window was 4.72 ms. End-to-end local runs took 0.67, 0.58 and 0.31 seconds, with maximum resident sizes about 40.5, 42.7 and 41.1 MB. These are single-machine development profiles, not frozen acceptance budgets.

No real lock-onset, hold/release error, missed-speech or false-word rate can be estimated from these runs: there were no locks and no independent interval annotations. The scripted portion remains development material. Detector-disabled comparison is structurally unchanged because no production code consumes the reports; an end-to-end policy ablation belongs to B3.

## Reproduce safely

Compile from the repository root:

```sh
swiftc -module-cache-path /private/tmp/fv-reliability-swift-cache -O \
  Sources/Fluid/Services/Meeting/MeetingPlaybackDuplicateDetector.swift \
  Sources/Fluid/Services/Meeting/MeetingSpeechActivityDetector.swift \
  tools/meeting_temporal_shadow.swift -o /private/tmp/fv-temporal-shadow
```

Invoke with an explicitly selected `session.json` and a new output path outside that session directory. Output creation is exclusive. Local macOS codec access may require the normal host execution permission; no network permission or audio upload is involved. Sidecars are temporary development artifacts, not new session data; keep only for the review and remove explicitly when no longer needed (there is no automatic cleanup job).

## Next gate

Do not connect this operating point to suppression or speaker-profile eligibility. B2 needs independently validated speech activity and combined/mixed-interval evidence; B3 needs annotated controls and calibration/ablations. A more robust temporal feature may be needed for nonlinear low-correlation residuals. This document does not broaden implementation scope to a new model or dependency.

## Verification and review status

Final isolated `FluidASRBaseline` build succeeded. All 31 targeted tests passed with zero failures/skips: 11 new detector tests, 15 Stage A contract tests and five existing live diagnostic tests. Result: `/private/tmp/fv-temporal-b1-v3.xcresult`. Tests cover lag sign/shift, repeated support, periodic/wrong/control references, quiet-double-talk confounding, epoch/route/gap resets, masked/missing reference, no-hold release, delay jumps, silent reference, invalid inputs and injected budget exhaustion. Broader app/Release and held-out evaluations were not run.

Kimi K3's code-review call and continuation timed out (180/300 seconds); the scoped Grok 4.6 fallback also timed out (180 seconds). No findings were returned and **external code sign-off is still pending**. Only authorized FluidVoice source was sent; no audio, transcript, embedding, secret or competitor code was sent. The local checks above are not a substitute for the outstanding review.

Source SHA-256 at evaluation:

```text
detector f580cb5857d7b1917e1569f15b10efafc2637740fbe3f72b4f922d0046dcc166
evaluator c607e67e408eb89532ea69f072dd5eec7c64591b2d595795847a8b0502020f48
tests d8ca22c8a759924dc7be6430a424c900ad5a0f4cf9e7540370c5d30a40710520
```
