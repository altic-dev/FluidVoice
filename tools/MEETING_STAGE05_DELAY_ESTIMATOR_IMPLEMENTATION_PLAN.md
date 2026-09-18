# Stage 0.5 offline delay-estimator and path-model implementation plan

## Decision

Replace the current single-scale, 1 kHz delay tracker with a bounded two-stage estimator and
make the held-out linear-path check consume the resulting affine delay model. Implement and lock
the estimator against synthetic fixtures before replaying the one retained private corpus.

This is an offline analyzer change only. It does not record audio, change the capture harness,
install an app, add AEC3/WebRTC, alter production Swift, loosen a registered gate threshold, or
turn an ambiguous correlation into a zero-delay observation.

## Why this is the next step

The 2026-09-11 controlled paired-SCK run passed capture provenance, native PCM, callback timing,
route, volume, excitation, clipping, and low/mid/high coherence checks. Its signal gate still
failed closed because the existing delay tracker found no peak with enough prominence, could not
score drift, and aligned the held-out path model with no resolved delay. The resulting linear
residual was 0.777411 against the frozen 0.75 ceiling.

The current tracker downsamples to 1 kHz and independently searches roughly one-second windows
across the full +/-500 ms range. The controlled stimulus contains fixed tones plus seeded
broadband noise. The tones create many strong aliases; the noise is intended to identify the
physical peak, but short, wide-search windows do not accumulate enough of it to distinguish that
peak. Merely trimming the WAVs cannot fix this because the analyzer already uses the common PCM
span.

The retained evidence remains a rejection. These changes are an investigation of whether a
strict estimator can resolve the registered evidence without changing the evidence or its gates.

## Frozen safety and decision boundaries

The following values and meanings stay unchanged:

| Gate | Frozen value |
| --- | ---: |
| Valid timing coverage | at least 0.99 |
| Acoustic delay observations | at least 3 |
| Maximum drift | 100 ppm |
| Maximum uncorrected delay range | 20 ms |
| Acoustic search range | +/-500 ms |
| Search-boundary safety margin | 20 ms |
| Path stability | at least 0.5 |
| Held-out linear residual | at most 0.75 |
| Excitation RMS | at least 0.001 |
| Per-band coherence | at least 0.10 |
| Clipping | at most 0.01 |
| PCM resource ceiling | 1,000,000 samples per track |

Additional estimator confidence checks may only make the result stricter. The implementation must
not tune confidence constants against the retained corpus. Freeze them through synthetic tests
first, then replay the corpus once.

An acoustic `proceedToCandidate` result is necessary but not sufficient for AEC work. The final
authorization predicate is the conjunction of:

1. a fully scored Stage 0.5 acoustic result that passes every frozen threshold;
2. a structurally eligible callback-adapter result; and
3. a separate reviewed implementation decision.

The retained callback-adapter result is currently ineligible because four terminal frames were
masked/frozen around a 555-sample microphone-only stop tail. This plan does not reinterpret that
edge or override it. Therefore even a passing offline acoustic replay cannot authorize AEC3 by
itself.

## Implementation scope

Modify only:

- `tools/meeting_playback_stage05_signal_gate.py`;
- `tools/test_meeting_playback_stage05_signal_gate.py`;
- `tools/MEETING_PLAYBACK_STAGE05_SIGNAL_DOMAIN_GATE.md`;
- `tools/MEETING_STAGE05_EVIDENCE.md`; and
- one new privacy-safe aggregate sidecar, only after all synthetic gates pass and the private
  analyzer report passes a forbidden-key scan.

Do not modify Swift sources, the capture fixture, manifests, WAVs, threshold snapshots, runtime
gates, project dependencies, app signing, or the installed app.

## Design

### 1. Separate estimation facts

Introduce private, immutable analyzer records with explicit units:

- `DelayObservation`: window-center seconds, acoustic array lag seconds, lag-uncertainty seconds,
  absolute correlation, competitor correlation, and prominence;
- `DelayEstimate`: coarse lag, fine intercept, drift slope in ppm, quantization bound, accepted
  observations, fit residual, and a fixed failure category; and
- `AlignedSpan`: render/capture samples plus an explicit valid-support fraction.

Keep three concepts separate:

- **acoustic array lag** aligns the two decoded sample arrays;
- **PTS offset** maps their independently started callback timelines; and
- **render lead** is the already bounded synchronizer contract input.

Only `array lag + PTS offset + render lead` may become the reported signed delay. PTS metadata may
transform and sign-check an acoustic observation, but it must never fabricate one. An unresolved
estimate returns no signed delay, no drift, and no path score—not numeric zero.

### 2. Build a global anchor without letting tones vote repeatedly

Use the entire bounded common span to establish one coarse-to-fine anchor:

1. Remove the mean independently from each input using finite bounded arithmetic.
2. Form a deterministic non-overlapping 4 ms short-time energy envelope at the native rate.
   Center and normalize that envelope, then search the full frozen +/-500 ms range. This makes
   seeded broadband energy variation carry the coarse vote while stationary tones contribute
   little timing identity, without allowing overlapping envelope windows to inflate adjacent
   peak correlation.
3. Require the coarse peak to be non-boundary, have absolute correlation at least 0.10, and exceed
   every competitor outside one coarse bin by at least 0.05. These equal the existing minimum
   correlation and prominence requirements; they are not relaxed.
4. Anti-alias and decimate the mean-removed PCM to at most 4 kHz, first-difference the result, and
   search only +/-12 ms around the coarse anchor. Require the same score/prominence checks, a
   non-boundary result, and agreement with the coarse anchor within one 4 ms envelope bin.
5. Refine the accepted 4 kHz peak at the native rate over the centered local window, within three
   4 kHz samples. A three-second window at the accepted drift ceiling can spread a box-decimated
   physical peak across adjacent bins; a one-bin refinement was demonstrated to reject the
   registered +/-50 ppm synthetic cases. Use a three-point parabolic interpolation only for a
   finite, strictly concave interior peak; otherwise retain the integer native-sample lag. Bound
   the lag uncertainty by at least half a native sample and carry it into every later drift/range
   decision. The wider native refinement does not weaken ambiguity rejection: the preceding 4 kHz
   search still owns the unchanged global score/prominence checks.

The work stays bounded: at most 250 envelope samples per second over 251 coarse lags, at most 4 kHz
PCM over 97 fine lags, and one native-rate search no wider than three 4 kHz samples on either side
over a maximum three-second window. If any level is weak, ambiguous, contradictory, or at its
search boundary, return `delayUnresolved`.

### 3. Track local delay and drift around the anchor

After the global anchor passes, schedule five to eight evenly distributed windows across the
entire analyzable common support. The first and last windows must touch the earliest and latest
possible full-window positions. Use `min(3 seconds, half the common span)` as the window duration,
subject to the minimum correlation geometry. Search each window within +/-24 ms of the global
fine anchor: the frozen 20 ms uncorrected-range allowance plus one 4 ms coarse bin.

Every scheduled window must resolve, satisfy the unchanged 0.10 absolute-correlation and 0.05
prominence requirements, and remain off the local search boundary. A weak, ambiguous, or boundary
peak fails the track; it is not dropped so that a convenient middle cluster can pass. The first
and last observations must span the complete scheduled support. Refine each accepted local peak
at native rate within three 4 kHz samples and carry its conservative lag uncertainty into the fit.

Fit delay versus window-center time using a deterministic Theil-Sen slope over long-baseline
pairs. Exclude pair slopes whose time separation is less than half of the scheduled observation
span; short-baseline quantization must not masquerade as drift. Require:

- every scheduled observation to resolve, with at least five distributed observations even though
  the existing report threshold remains three;
- at least three qualifying long-baseline slopes;
- a one-native-sample-over-total-span quantization bound no greater than the configured drift
  ceiling;
- every retained long-baseline slope's worst-case interval, including both endpoint lag
  uncertainties, wholly within the configured drift ceiling;
- detrended delay residuals within the existing 20 ms uncorrected-offset bound; and
- the existing path-stability fraction after subtracting the fitted drift trend.

Report drift percentiles from the qualifying long-baseline slopes. Do not derive drift from SCK
callback PTS or adjacent quantized delay bins. Do not discard an outlying resolved observation or
its long-baseline slopes: any slope or residual outside the frozen bounds rejects the whole track.

Missing evidence is always ineligible. A null delay, null drift, `driftUnscored`, null alignment,
null coverage, or null path score must prevent `proceedToCandidate`. A recording that is too short
to satisfy its configured drift-resolution bound fails closed; it does not skip the drift gate.
An estimate near the ceiling whose uncertainty crosses the ceiling also fails closed rather than
rounding into acceptance.

### 4. Align only measured, valid support

Map render samples onto capture time with the estimated affine acoustic lag (intercept plus drift)
using deterministic linear interpolation at the native rate. Do not pad either edge with zeros,
repeat samples, or silently clamp source indices. Return only the common supported region and its
coverage fraction.

Combine this acoustic support fraction conservatively with the existing callback-timing coverage;
the reported `validCoverageFraction` is their minimum. A large delay or drift that leaves less
than 0.99 valid support therefore fails the existing coverage gate even if correlation is strong.

Use the same aligned span for band coherence and the linear-path check. RMS and clipping continue
to describe the original bounded inputs. Causal/range checks continue to use the signed delay
after PTS offset and render lead are applied. Perform that signed-clock contract check before
candidate alignment/path scoring; a non-causal or search-margin-violating sum leaves all dependent
candidate metrics unscored.

### 5. Make the path check converge without weakening it

Keep the existing maximum 4 kHz analysis rate, 64 ms/256-tap ceiling, disjoint chronology, and
0.75 residual threshold. Change only the deterministic fitting discipline:

- derive centering constants from the training region and apply those same constants to later
  regions;
- train NLMS for three fixed passes with step sizes 0.50, 0.25, and 0.125;
- never train on validation or held-out samples;
- score one middle validation region and the existing final held-out region; and
- return the worse normalized residual as `heldOutLinearResidualFraction`.

Both regions must have at least 64 scored samples and nontrivial target energy. Otherwise the path
is unscored. This makes convergence more reliable while making acceptance stricter: a model that
works only in one late segment cannot pass.

No tap-length search, threshold search, corpus-specific learning rate, nonlinear model, frequency
domain suppression, or test-set refit is allowed.

### 6. Emit bounded diagnostics without private traces

Keep the existing report free of PCM, paths, hashes, titles, labels, identities, and transcripts.
If implementation diagnosis requires new output, bump the report schema and add only bounded
per-session scalar summaries: coarse/fine score and prominence, accepted observation count,
quantization ppm, fit residual, acoustic support fraction, validation residual, and held-out
residual. Do not emit candidate arrays, observation timestamps, per-window lag traces, filter taps,
or sample-derived fingerprints.

The analyzer output remains exclusive-create mode `0600` under the private evidence root and never
overwrites an earlier result. It is not committed. After the forbidden-key/privacy scan, a
separately constructed aggregate numeric-only sidecar may be added under `tools/`; it must contain
no paths, hashes, candidate arrays, per-window values, filter taps, or source identities. Existing
reports remain immutable.

## Deterministic test matrix

Add pure synthetic tests before touching the retained corpus:

### Delay identity and sign

- seeded broadband plus all registered tones through a fixed 64 ms FIR at known integer and
  fractional delays;
- positive and negative acoustic array lags, with independent positive/negative PTS offsets;
- zero acoustic lag that is genuinely evidenced, distinct from an unresolved estimate;
- delays just inside and outside the frozen search/safety boundaries;
- combinations where acoustic lag is safe but PTS offset or render lead makes the final signed sum
  non-causal, within the negative 20 ms safety margin, or inside the positive search-boundary
  margin;
- evidenced acoustic zero combined with nonzero PTS offset and render lead, proving that every
  term participates exactly once in the final signed check;
- reversed polarity and ordinary fixed gain/DC offset; and
- unequal decoded lengths where only explicit common support may be scored.

### Ambiguity and failure closure

- pure 1 kHz and multi-tone periodic signals remain unresolved;
- two equal competing broadband peaks remain unresolved;
- weak broadband under unrelated capture noise remains unresolved;
- a dominant peak at either search boundary remains unresolved;
- low excitation, clipping, non-finite input, empty input, and resource overflow fail closed; and
- changing PTS offset without acoustic evidence never creates an observation.

### Drift

- deterministic affine delays at 0, +50, and -50 ppm score within quantified error;
- +99 and -99 ppm pass only in fixtures whose carried uncertainty remains wholly inside 100 ppm;
  otherwise they fail closed as unscored rather than being rounded inward;
- +101 and -101 ppm are rejected without rounding into the allowed range;
- short recordings whose quantization bound exceeds 100 ppm remain `driftUnscored`;
- every scheduled window, including the first and last, must resolve; an unresolved/boundary window
  fails instead of shrinking the observation span;
- one resolved local alias/outlier rejects through its long-baseline slope or detrended residual
  rather than being discarded or moving the robust intercept/slope into acceptance; and
- non-affine delay jumps fail stability or the 20 ms delay-range check.

### Linear path

- stable short and 64 ms FIRs pass both validation and held-out scoring;
- gain changes, moving delays, time-varying FIRs, late-only corruption, and unrelated microphone
  noise fail the unchanged residual ceiling when appropriate;
- the final held-out samples are never used to choose or update coefficients; and
- deterministic replay is byte-identical at the JSON layer.

### Existing contracts

- retain every current manifest, privacy, hash, symlink, geometry, timing, no-overwrite, codec,
  threshold, and report-shape test;
- verify report numbers are finite and the forbidden-key/privacy scan still passes; and
- verify the legacy stable delayed fixture still passes without changing its manifest thresholds.

## Execution order and gates

1. Add records and preprocessing helpers with unit tests; do not alter `measure` yet.
2. Add the global anchor and ambiguity fixtures. Stop if periodic/equal-peak cases can pass.
3. Add local observations and robust drift. Stop if +/-101 ppm can pass or a short fixture can
   produce scored drift under the default 100 ppm gate. Stop if any scheduled window can disappear
   while the remaining cluster still passes.
4. Add affine valid-support alignment and the stricter path fit. Stop on any zero padding, hidden
   clamp, train/test overlap, or non-determinism.
5. Integrate with `measure`, preserving every frozen manifest and gate threshold.
6. Run the complete Python Stage 0 and Stage 0.5 suites, bytecode compilation, `git diff --check`,
   and an unsigned Release build to verify that this tools-only change does not affect the app.
   The Release step is build-only: never install or launch that artifact.
7. Route the implementation diff for adversarial review. Resolve every P0/P1 finding and rerun the
   full offline matrix.
8. Freeze the analyzer source hash and test result, then replay the retained private manifest once
   into a new exclusive mode-0600 report inside the private root. Do not copy, transcribe, play,
   upload, expose PCM, or commit that private report.
9. Run the forbidden-key/privacy scan, construct a separate bounded numeric-only sidecar, compare
   it with the frozen 2026-09-11 report, and document the disposition.

## Acceptance criteria

Implementation is complete only when:

- all synthetic identity, ambiguity, drift, path, privacy, and legacy tests pass;
- pure periodic and equally competing peaks still produce no delay observation;
- +/-50 ppm is scored, +/-101 ppm is rejected, and any +/-99 ppm acceptance proves its complete
  uncertainty interval stays inside the unchanged 100 ppm ceiling;
- every scheduled window resolves across the complete scheduled support, at least five
  observations and three long-baseline slopes exist, and no outlier is silently discarded;
- an unresolved estimate cannot populate delay, drift, alignment, or path metrics;
- null/unscored drift, alignment, coverage, or path always prevents `proceedToCandidate`;
- all alignment output is backed by measured samples and combined valid coverage is at least 0.99;
- the path metric is the worse of disjoint validation and held-out residuals and is at most 0.75;
- the analyzer remains bounded, deterministic, dependency-free, and privacy-safe;
- adversarial review returns no P0/P1 blocker; and
- the retained corpus is replayed no more than once after the implementation and tests are frozen.

If the replay still fails, record the unchanged blocker and stop. The next possible step would be a
separately planned fixture redesign; no new capture follows automatically. If it passes, report
only that the acoustic half of the gate is satisfied. The current false callback-adapter
eligibility and a separate reviewed implementation decision still block AEC3.

## Adversarial review disposition

The standard router served Grok 4.6 with the plan text only and reported `editedTree=false`. Its
first review returned `BLOCK` on four gate-integrity issues: the original local search could miss
part of the frozen delay range and pass on a surviving middle cluster; null drift was not stated as
a hard candidate failure; three observations/one long pair could not support the claimed outlier
robustness; and the summed acoustic/PTS/render-lead boundary tests were incomplete.

This revision addresses those findings with mandatory full-span scheduled windows, a +/-24 ms
local search, five-to-eight required observations, three or more long-baseline pairs, uncertainty-
bounded all-pair drift rejection, explicit null-is-ineligible semantics, and signed-clock boundary
fixtures. It also adopts the non-blocking recommendations for non-overlapping energy windows,
standard-library-only implementation, `max(validation, held-out)` scoring, a private uncommitted
mode-0600 replay report, and build-only Release verification.

Two delta-only plan rechecks reached the router's Grok time limit without a verdict and again
reported `editedTree=false`; no unauthorized fallback was used. After implementation, a bounded
contract review containing the exact estimator, alignment, path, test, privacy, and Release
properties was served by Grok 4.6. It returned PASS with no P0/P1 finding and `editedTree=false`.
Its P2 observation that the frozen 0.75 residual ceiling is weak does not change that registered
threshold and does not authorize AEC.

The frozen analyzer and tests were hashed after the full offline matrix passed. The retained
private corpus was then replayed exactly once. It remained `rejected`: delay stayed unresolved,
so drift, aligned coverage, and path evidence remained unscored. The bounded privacy-safe summary
is `meeting_playback_stage05_delay_estimator_builtin_2026-09-11.json`. Per the stop condition,
there is no second replay, threshold change, new capture, or AEC3 work in this phase.

A later, separately authorized operator-media capture is documented in `MEETING_STAGE05_EVIDENCE.md`
and `meeting_stage05_operator_media_2026-09-11.json`. Its first analyzer invocation stopped on an
unrecognized pinned descriptor before signal scoring. After a narrow two-digest provenance
allowlist fix, the corrected invocation performed the corpus's only signal analysis and preserved
the same ambiguity stop. That follow-up neither reopens this plan's retained-corpus replay nor
changes any estimator, path model, threshold, or AEC decision.

## Rollback

This phase is isolated to offline Python and documentation. Rollback removes the new estimator
records/helpers, restores the original `measure` path, and deletes only the newly generated replay
report. It never touches the retained WAVs, manifest, installed app, production runtime, profile
state, or frozen earlier reports.
