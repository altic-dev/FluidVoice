# Meeting diarization evaluation

This Phase 0 tool establishes a repeatable local baseline before diarization behavior changes. It
never uploads, rewrites, or copies meeting recordings. User audio, annotations, hypotheses, and
generated reports must stay under the gitignored `benchmark_reports/` directory.

## Set up the corpus

Copy `tools/meeting_diarization_eval_manifest.example.json` to
`benchmark_reports/meeting-diarization/manifest.json`. Add development and held-out fixtures before
tuning. `inventory` fixtures reserve the split without claiming that they are ground truth; change a
fixture to `annotated` only after adding both `referenceRTTM` and `hypothesisRTTM`. An inventory
fixture may record `expectedSpeakerCount`, `observedRemoteSpeakerCount`, a generated
`hypothesisRTTM`, and `runReport`; these reproduce a count defect and fingerprint its artifacts but
remain explicitly unscored until a human reference timeline exists.

RTTM rows use the standard form:

```text
SPEAKER meeting 1 12.340 1.250 <NA> <NA> speaker-1 <NA> <NA>
```

Optional `referenceSpeakerText` and `hypothesisSpeakerText` files are JSON objects mapping speaker
labels to transcript text. When present, the report includes cpWER.

## Run

```bash
python3 tools/meeting_diarization_eval.py self-test
python3 tools/meeting_diarization_eval.py validate benchmark_reports/meeting-diarization/manifest.json
python3 tools/meeting_diarization_eval.py score benchmark_reports/meeting-diarization/manifest.json \
  --output benchmark_reports/meeting-diarization/baseline.json
```

Each scored fixture reports primary merge/split and speaking-duration recovery metrics plus DER, JER,
speaker-count error, coverage, and purity. The `comparable` score uses a 250 ms collar and ignores
reference overlap; the `strict` score uses no collar and scores overlap.

Reports contain aggregate metrics and SHA-256 fingerprints of RTTM inputs, not audio or transcript
content. Record ASR provider/model, pipeline version, and normalization configuration in the manifest
for every baseline run.
