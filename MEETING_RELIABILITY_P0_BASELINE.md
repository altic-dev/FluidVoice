# Meeting reliability P0 baseline

Date: 2026-09-08 (local). Status: instrumentation and initial measurement slice; **P0 exit gate remains open**. No recovery/admission policy, dependency revision, installed app, privacy permission, or saved recording was changed.

## Execution plan and scope

1. Preserve the existing recording and fingerprint local source, installed binary, processing metadata and staged models.
2. Add an injectable recognizer/clock and opt-in numeric wrapper diagnostics without changing live rotation policy. Reproduce the no-first-partial blind spot deterministically.
3. Measure digital silence and seeded low noise using the pinned offline ASR, in 60-second and 3-second calls. Keep test completion separate from speech-quality verdicts.
4. Obtain an Orchestrate adversarial review, address evidence/reporting defects, and document remaining controlled-corpus gates before P1.

## Evidence and provenance

Local machine-readable inventory: `/private/tmp/fv-reliability-p0-20260908/inventory-v3.json`. Earlier inventory files are superseded.

- Source HEAD: `b701716177bebba97a82d68aa9aa8f765292a8a2`; dirty tree preserved. Inventory records the tracked-diff hash, not an assertion that untracked files are covered.
- Package declaration, both resolved files, and local FluidAudio checkout agree on `3fd63887eef1dc25edea8263ce4b44aa854d898b`.
- Installed `/Applications/FluidVoice Debug.app`: `com.FluidApp.app`, version 1.6.10, build 22, Team `A8467RRA3D`. Deep/strict signature verification succeeded using host trust access. Launcher SHA256 `14948a43786af513c65fb53c0d4b07c0afdf1e77823321b83d9493278f7d5377`; debug dylib SHA256 `f9907c5e5cb623732c9f76627d1cf38803b4a1e370501f848e16e8988be27000`.
- Exact historical binary-to-source match is **unproven**: no embedded build manifest. A present-day hash does not establish recording-time identity.
- Historical session SHA256 `fbccf8fce03fb83a87643192e47e164a5d588726e2ad45f273d6d6383d3de557`; all six chunk hashes match stored values. Inventory contains aggregate metadata only, no transcript or audio.
- User-reported playback-only, approximately 133 seconds. This report preserves that account; no independent listening/annotation adjudication was performed. Application capture was ScreenCaptureKit, 48 kHz stereo; microphone was voice-processing I/O, 48 kHz mono. No stored capture drops/chunk discontinuities or session failures were found.
- Selected log lines 4825–5004 show app partial count 123 unchanged while audio advances 30.1 seconds over 30.071 seconds of sampled wall time. This is a sampled lower bound, not the full blackout duration or proof of audible speech. A silent microphone having no partials is expected.
- Offline staged model manifest SHA256 `b39baf9bf54a0c70e9821989da9cdde32ca3f1f4e74894efa85f982320affad3`; 22 artifacts checked. Inventory reports both hash agreement and exact repository file-set agreement. Hugging Face artifact revision is unavailable; hashes identify local content, not publisher authenticity. Live/diarizer model provenance is not yet complete.

## Instrumentation and deterministic tests

`MeetingLiveTrackEngine` now accepts a recognizer and monotonic clock. Debug diagnostics are opt-in with `FLUIDVOICE_MEETING_LIVE_DIAGNOSTICS=1`; release diagnostics are forced off. New counters contain numbers only. Existing logging behavior outside this change is not a privacy audit.

Tests exercise the actual engine conversion/append/process/rotation path with a fake recognizer, without capture or model loading:

- 40 seconds of feed with no first partial invokes no reset.
- A forced 20-second boundary followed by 38 seconds without partials does not trigger another recovery, despite continued process returns.
- Explicitly disabled diagnostics do not accumulate counters.
- Injected seven-second processing delay is measured without sleeping.
- A thrown process call is not counted as a successful return.

These characterize the existing recovery blind spot; they do not establish why the real decoder first stopped emitting text. `recognizerResetReturned` means wrapper return only. `wrapperGeneration` is a reset ordinal, not a callback-origin epoch. First-partial latency starts after reset returns. Actor-local counters cannot supervise a blocked actor, measure decoder token/blank progress, establish speech activity, or prove recovery. Activity-detector injection and independently readable watchdog progress remain pending.

## Synthetic negative screen

The isolated `com.FluidApp.ASRBaselineHost` requires app sandboxing and rejects microphone/network entitlements at runtime. It uses direct local CoreML constructors, with no model-download API. It never opens the historical recording. The installed Debug app is not used or replaced.

Default exposure is 600 seconds for each of four condition/mode combinations: digital silence and seeded uniform noise at peak 0.001, each in 60-second and 3-second calls. This is 40 minutes of synthetic ASR exposure, not 40 minutes of independent acoustic recordings. No VAD, AEC, diarization, production provider, or live EOU recognizer is exercised. Three-second calls approximate short segmentation; they are not the production fallback pipeline.

Pinned `ASR/Parakeet/AsrManager.swift:524–548` awaits throwing `resetDecoderState()` before returning a successful array transcription. `initialize(models:)` installs supplied local models. This source check supports sequential state-reset semantics, not universal offline safety; host entitlements enforce the screen's network boundary. Errors abort the screen. The between-call wall budget cannot interrupt a stuck CoreML invocation.

Every report has `verdict: measured_only`. XCTest success means execution/schema checks completed, even if all inputs generated text. Nonempty outputs and whitespace-delimited words are reported; text is not attached. No confidence interval or release-quality conclusion is justified by repeated deterministic silence.

Completed measurement in `screen-v3.xcresult`; JSON attachment `/private/tmp/fv-reliability-p0-20260908/attachments-v3/71D9A149-34D2-4880-9039-A1DD95D5E4DA.json`. Model load took 11.654 seconds.

| Input | Call length | Audio exposure | Calls | Nonempty outputs | Words/minute |
| --- | --- | --- | --- | --- | --- |
| Digital silence | 60 seconds | 600 seconds | 10 | 0 | 0 |
| Digital silence | 3 seconds | 600 seconds | 200 | 0 | 0 |
| Seeded low noise | 60 seconds | 600 seconds | 10 | 0 | 0 |
| Seeded low noise | 3 seconds | 600 seconds | 200 | 0 | 0 |

Zero words in these controls does **not** explain or exclude playback-leakage hallucinations. The v3 test bundle had eight passing tests and one failing path-alias fixture test (nonexistent paths cannot reliably resolve aliases); the inference measurement itself completed. That fixture was corrected to create an actual local directory and alias; final rerun status is recorded below.

Final rerun: `screen-v4.xcresult` — **9 passed, 0 failed, 0 skipped**. Final attachment: `/private/tmp/fv-reliability-p0-20260908/attachments-v4/34F372C3-E600-4570-8255-3C4E97491046.json`. Eight Python inventory regression tests also pass; `git diff --check` is clean. Existing unrelated compiler actor-isolation warnings remain; no production-app test/install or release build was performed.

The final rerun again measured 420 calls / 2,400 audio seconds with zero nonempty outputs and zero words; warm model load was 0.132 seconds. Repeated runs are not independent acoustic exposure.

Final tested file SHA256 fingerprints (supplement the tracked-diff inventory):

```text
8e1e5c0634d9aaa18181b18259d0377ead80772cef52764c1f70c67b9d9c37a0  MeetingLiveTrackEngine.swift
e94f7c8a3d7a0234d26ec3ae7c5bb0d4c5c2b5bc4745f0d27d07410d41f5450c  MeetingLiveP0DiagnosticsTests.swift
d2d920fd5c2db77a71ca67171084ccf74b79b3f09c57f6bf8107bb6a9e62b8eb  MeetingReliabilityNegativeScreenTests.swift
2c35e544313e6a978915fbb75ee26c8e84c571efed04e59a6c346f219e994e06  meeting_reliability_baseline.py
8643d41129b662114a7b626fde122436802b2762d597d6170cf65be928c13abc  test_meeting_reliability_baseline.py
```

## Embedding API audit

At the pinned revision, `Diarizer/Offline/Utils/OfflineReconstruction.swift:337–345` assigns the cluster centroid to each returned `TimedSpeakerSegment.embedding`; trimming/merging retains it. These are not independent clean-turn embeddings.

The offline extraction implementation is internal (`Offline/Extraction/OfflineEmbeddingExtractor.swift`). A separate public `EmbeddingExtractor.getEmbeddings(audio:masks:)` exists, with a fixed `[3,160000]` waveform shape and legacy WeSpeaker model interface. Its existence does not establish compatibility with offline feature/PLDA space or current profile similarity thresholds. No extraction compatibility or independent accepted-duration coverage was measured. P3 must review a compatible interval-extraction extension or an explicit uncertain-identity fallback before trusting independent evidence; this slice chooses neither implementation.

## Adversarial review disposition

Orchestrate standard route completed a read-only Grok 4.6 review of the five scoped code/test/tool files (`editedTree=false`). An earlier route failed; the heavy route was blocked by host policy and was not bypassed. No private meeting audio, transcript, embeddings, or credentials were supplied.

Findings addressed: added an explicit measurement-only verdict; renamed reset return/generation counters and moved latency start after reset return; added exact-tree inventory checks; made missing capture-drop schema fail closed and excluded missing speaker IDs from person counts. Removed hard-coded recording-condition inference from the reusable inventory. Verified the pinned offline transcription reset implementation locally in response to the review's uncertainty. Review occurred before these amendments; it is not external sign-off on the amended tree.

## Reproduction and remaining exit gates

Run inventory regressions with `python3 -m unittest discover -s tools -p test_meeting_reliability_baseline.py`. The inventory CLI requires explicit repo/app/session/model-manifest paths; log parsing additionally requires a caller-selected same-session line range. Output creation is exclusive.

Build the existing `FluidASRBaseline` scheme with staged `FLUID_ASR_BASELINE_INPUTS`, using the stable local signing identity. Then run the two P0 XCTest classes with `TEST_RUNNER_FLUID_RELIABILITY_NEGATIVE_SCREEN=1`. Test-run settings accept `FLUID_RELIABILITY_SECONDS` (60–600, default 600) and `FLUID_RELIABILITY_WALL_SECONDS` (60–1800, default 1200); with xcodebuild forward them using `TEST_RUNNER_`. Retain the xcresult and its JSON attachment. Never install this baseline host over the Debug app.

The packaged CTranscribe framework was copied with broken version symlinks by the current build inputs. Only the generated baseline-host copy was repaired, originals preserved in a temporary backup, then re-signed and deep/strict verified. Rebuilds may recreate this packaging defect. This is not a fix to the upstream framework or production packaging.

P0 is not complete until controlled active-microphone playback/AEC-residual and positive speech fixtures are collected and independently annotated: at least 12 independent negative sessions across three output configurations and two acoustic environments, with separate quiet/brief/overlap held-out positives. The human acoustic setup/speech truth cannot be supplied by synthetic samples. Freeze recording/device/speaker splits before tuning; extend negative exposure to the plan's release minimum before claims. Complete effective runtime options/model provenance, activity instrumentation, embedding coverage and detector-gated development comparisons. The original decoder cause remains open.
