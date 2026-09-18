# Stage 0.5 signal-domain gate

`meeting_playback_stage05_signal_gate.py` is an offline, fail-closed pre-dependency check. It is
not a capture path, AEC, ASR evaluator, or proof of speaker ownership. Run it only against a
private, topology-matched paired ScreenCaptureKit corpus with explicit consent:

```sh
python3 tools/meeting_playback_stage05_signal_gate.py \
  --manifest /private/corpus/manifest.json \
  --sessions-root /private/corpus \
  --output /private/corpus/stage05-report.json
```

The report destination must already exist under a real, non-symlink directory. Reports are
created exclusively with mode `0600`; an existing report is never overwritten.

The manifest must declare `schemaVersion: 1`, `topology: pairedScreenCaptureKit`,
`route: builtInSpeakerMicrophone`, `consentConfirmed: true`, and exactly two lossless PCM
artifacts per session (`render` and `capture`). AAC, VPIO, synthetic fixtures, metadata-only
inputs, unsafe paths, symlinks escaping the corpus root, hash mismatches, and incomplete reference
scope are excluded. Artifact data is used transiently for numeric measurements and is never
written to the report.

The session entries must also carry render/capture block timing (`presentationSeconds`,
`durationSeconds`, `frameCount`, and `arrivalSeconds`). A WAV header alone cannot establish
chronology, delivery jitter, or drift, so such input is explicitly unscored. At least three timing
blocks and three distributed acoustic-delay observations are required by default. The bounded
analyzer accepts at most 1,000,000 mono PCM samples per track; a larger artifact is reported as
outside the registered analysis resource limit rather than silently truncated.

The report is aggregate and privacy-safe: it contains only schema/outcome, numeric distributions,
bounded reason counts, and numeric session ordinals. It contains no PCM, transcript text, labels,
window titles, URLs, absolute paths, or source identities. `rawPCMRetained`, `transcriptRetained`,
and `pathsRetained` are always false.

The executable delay contract is represented by `MeetingAECDelayContract` in the meeting service:
the synchronizer owns clock/epoch mapping and one frozen render lead; chronological render is
queued before capture; the future candidate engine is the sole adaptive delay owner and may receive
one bounded hint. This stage never enables that engine.

An outcome of `proceedToCandidate` only means that at least one eligible session satisfies the
fully persisted threshold snapshot and every required metric is scored. The delay estimator first
uses the entire common span's non-overlapping 4 ms energy envelope for a coarse vote, then a
mean-removed/first-differenced signal at no more than 4 kHz for a narrow fine search, followed by
native-rate refinement. Every one of five-to-eight scheduled local windows across the analyzable
span must resolve with the registered score and prominence; a weak, ambiguous, boundary, or
outlying window fails the whole track rather than disappearing from a convenient cluster.

Drift uses only multiple long-baseline acoustic-observation pairs. Each pair carries native-sample
lag uncertainty, and its complete uncertainty interval must remain inside the configured drift
ceiling. Missing or unresolved delay, drift, alignment, coverage, or path evidence always prevents
`proceedToCandidate`. Callback PTS and render lead are applied exactly once after acoustic evidence
exists; they cannot fabricate a delay.

Alignment follows the measured affine acoustic lag and retains only contiguous sample-backed
support. It never zero-pads, repeats, or clamps an edge, and valid coverage is the minimum of that
support and both callback timing coverages. RMS and clipping continue to use the original inputs;
complex multiband coherence and path scoring use the same aligned support. The bounded 64 ms path
uses three fixed train-only NLMS passes, then reports the worse normalized residual from disjoint
validation and final held-out regions. A high residual means only that this bounded linear model
did not generalize, not that nonlinear preprocessing has been proven.

This acoustic result is not AEC authorization. `rejected` or `unscored` stops AEC3 dependency work
for the topology. A pair that has no bounded, evidence-bearing correlation is reported as
`delayUnresolved`, not as a zero-delay measurement. Synthetic fixtures exercise the analyzer but
can never satisfy the real evidence gate.

The analyzer accepts an empty top-level `artifacts` array when the Codable manifest uses explicit
`sessions`; a nonempty top-level array remains invalid in that form. Delay observations must have
a bounded, non-boundary, prominent correlation peak. Weak or periodic ambiguity is unresolved,
not adverse delay/drift evidence. Drift stays unscored when its native-sample uncertainty cannot
substantiate the registered ceiling. Per-frequency render power uses window-local mean-square
normalization, so merely extending a recording does not make its excitation shrink.

Private provenance accepts exactly two pinned fixture digests: the original controlled broadband
fixture and the checked-in operator-media descriptor. The latter binds the separately consented
operator-controlled web-speech mode; it is not a wildcard for arbitrary media. A syntactically
valid but unknown 64-hex digest remains `invalidManifest`. This allowlist changes no acoustic,
timing, path, or eligibility threshold.

The implementation and its frozen execution order are described in
`MEETING_STAGE05_DELAY_ESTIMATOR_IMPLEMENTATION_PLAN.md`. Even a passing acoustic replay remains
insufficient while the separately retained callback-adapter result is structurally ineligible.
