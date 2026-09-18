# Orchestrate P0 adversarial review

Captured before amendments; see MEETING_RELIABILITY_P0_BASELINE.md for disposition. Reviewer output is analysis, not implementation instructions or final sign-off.

served-by: standard (grok · grok-4.6)
attempt: standard · ok · 274.8s · editedTree=false

I'll review only the five named files and produce an adversarial pass on production behavior, decoder-proof claims, model-loading network safety, and report schema accuracy.**Verdict:** RELEASE live policy looks unchanged (diagnostics compile out / force off). These files do **not** prove decoder reset, live-pipeline recovery, or a passed negative screen.

### 1. High — Green XCTest is not a negative-screen pass
`Tests/FluidASRBaselineTests/MeetingReliabilityNegativeScreenTests.swift` (`testSyntheticSilenceAndLowNoiseNegativeScreen`, `NegativeScreenReport.status`, class comment).

The opt-in test never asserts on `nonempty` / `whitespaceWordCount`. Any finished run sets `status = "complete"` and the test succeeds.

**Counterexample:** Silence/noise both emit captions every segment → `runs[].nonempty = true`, `status = "complete"`, XCTest green. That is the hallucination case, not a pass.

**Correction:** Keep measurements non-gating, but add an explicit `verdict: "measured_only"` (never `pass`) and refuse to treat XCTest success as evidence. Gate only on schema/host/artifact checks.

### 2. High — Reset/process KPIs are proof-shaped, not decoder-true
`Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveTrackEngine.swift` `resetRecognizer()` (generation / `firstPartialAfterResetSeconds` / `diagnosticResetUptime` **before** `await manager.reset()`, `resetCompletions` **after** return). `MeetingLiveP0DiagnosticsTests.testThrownProcessIsNotCountedAsCompletion` still asserts `resetCompletions == 1`.

**Counterexample:** FluidAudio swallows a failed internal decoder reset (the protocol comment already says this) → `resetInvocations == resetCompletions`, `generation` bumped, later `processCompletions` keep rising (`testForcedBoundaryThen38SecondsWithoutPartialDoesNotRecover`). That is wrapper return, not a new decoder epoch. `firstPartialAfterResetSeconds` also includes reset wait: a 2s hung `reset()` then an immediate partial reports `2`, not `0`.

**Correction:** Rename to `recognizerResetReturned` / `wrapperGeneration`. Start the partial-after-reset clock after `reset()` returns. Never export `resetCompletions` as health.

### 3. Medium — Same model tree, two hash semantics
Python `model_manifest_inventory()` (`tools/meeting_reliability_baseline.py`) vs Swift `validateArtifacts` (`MeetingReliabilityNegativeScreenTests.swift`).

Swift: enumerator, reject symlinks, `actual == Set(paths)`. Python: hash listed artifacts only; extra files do not flip `allHashesMatch`.

**Counterexample:** Manifest-listed files match, plus `Decoder.mlmodelc` sibling `Extra.mlmodelc` → inventory `allHashesMatch: true`; negative screen `ScreenError.invalidInputs`.

**Correction:** Inventory should fail (or set `exactTreeMatch: false`) unless the repository file set equals the manifest, same as the screen.

### 4. Medium — “Local-only” is sandbox + constructors, not a FluidAudio offline proof; live load is still HF
Screen: `MLModel(contentsOf:)` + `AsrManager.initialize` / `transcribe` (`MeetingReliabilityNegativeScreenTests.swift` ~47–90, `networkPolicy`). Host check only rejects `network.client/server` and mic entitlements. Live: `StreamingEouAsrManager.prepareModels()` → `loadModelsFromHuggingFace()` (`MeetingLiveTrackEngine.swift`).

**Counterexample:** Opt-in screen stays sandbox-offline while production live still downloads on cache miss. Comment “Each transcribe resets decoder state” is unverified here; one `AsrManager` is reused for 60s then 3s over the **same** samples — if `transcribe` does not reset, short-turn rows are not independent exposures. `AsrManager` is also not `MeetingLiveTrackEngine` / `StreamingEouAsrManager`.

**Correction:** State in the report that FluidAudio initialize/transcribe internals were not inspected; recreate or explicitly `reset` per segment; never cite this screen for live HF load or live EOU stalls.

### 5. Medium — Session inventory is fail-open on drop schema
`session_inventory()` in `tools/meeting_reliability_baseline.py`: `captureDrops` is `health.droppedSampleCount` via `.get`; missing key → `null`. `sourceTrackID` is fail-closed. `visibleSpeakerCount` is `len({speakerID})`, so a missing id counts as one speaker (`None`).

**Counterexample:** Drops stored as `droppedFrames` (or omitted) → `captureDrops: null` next to real chunk hashes; readers treat it as “unknown/zero drops.” Two visible segments with no `speakerID` → `visibleSpeakerCount: 1`.

**Correction:** Fail if `health.droppedSampleCount` is absent (same as `sourceTrackID`). Count only non-null `speakerID`, or emit `speakerIdPresentCount` separately.

---

**Production preservation (this file):** `#else diagnosticsEnabled = false`; diagnostic APIs are `#if DEBUG`. `consume` / rotate / HF load / reset policy are not altered when diagnostics are off. `uptime` is injectable in RELEASE (default still `systemUptime`) — watchdog clock is no longer a closed production constant.

**Unverified (out of allowed files):** `AsrManager.initialize`/`transcribe` network and reset; `DebugLogger` timestamp vs `FLOW` regex; `BaselinePathSafety` / `ASRBaselineHost` entitlements at runtime.
