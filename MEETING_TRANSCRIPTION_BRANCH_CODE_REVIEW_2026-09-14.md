# Meeting Transcription Branch Code Review

Date: 2026-09-14
Branch: `meeting/prd-capture-amendments`
Scope: committed diff against `origin/main` plus current tracked and untracked meeting-transcription work.

## Status

The branch is not merge-ready. The application target builds, but clean-checkout reproducibility,
audio durability, long-meeting processing, capability-aware backend selection, and the integration
test target need fixes before release.

No source changes were made during this review.

## P0 — Reproducibility blocker

### Ignored local FluidAudio dependency breaks clean builds

- `Package.swift:14-19` selects `.local-dependencies/FluidAudio`.
- `Fluid.xcodeproj/project.pbxproj:1252-1255` selects the same local package.
- `.gitignore:213-214` excludes the directory, and it contains no tracked files.
- A clean checkout or CI runner cannot resolve the dependency.

Strategic fix: publish the maintained FluidAudio changes and restore an immutable remote revision
and resolved pin before merging.

## P1 — Correctness and release risks

### Chunk ledger has no recovery consumer

- `MeetingAudioChunkWriter.swift:578-609` writes intent before an active chunk is represented in
  `track.json`.
- `MeetingSessionStore.swift:224-237` restores only chunks already listed in `track.json`.
- No production recovery path enumerates `chunk-ledger` records.
- A crash can orphan and omit up to the current 60-second chunk per track.

Strategic fix: reconcile ledger intent/checkpoint/terminal records and partial/final CAF files at
startup, with kill-point tests for every durability boundary.

### Ledger failure deletes authoritative PCM

- `MeetingAudioChunkWriter.swift:653-669` deletes an already finalized, verified, hashed and synced
  CAF if the terminal ledger write fails.
- A metadata/fsync/full-disk failure becomes irreversible loss of otherwise valid audio.

Strategic fix: quarantine the CAF in the session directory and repair or report it during recovery;
never delete the only capture-analysis asset because its metadata publication failed.

### Long two-track meetings exceed the backend cache

- `MeetingEpochAudioMaterializer.swift:90-94` defines a 64M-sample limit and claims it supports a
  one-hour two-track meeting.
- `MeetingParakeetNemotronBackend.swift:128-149` retains all materialized epochs across both tracks.
- Two one-hour 16 kHz analysis tracks contain 115.2M samples, crossing the cap after roughly
  33–35 minutes of continuous online-call audio.
- Native slices, converted buffers and cached materializations also create large transient memory
  amplification.

Strategic fix: use bounded streaming or an immutable disk-backed materialization cache with
eviction between phases. Keep a per-window safety cap rather than a per-attempt full-meeting cap.

### Historical retry races the retention sweep

- `MeetingSessionCoordinator.swift:632-669` loads a historical session and awaits an audio lease
  before reserving or adopting it.
- `MeetingSessionCoordinator.swift:1063-1067` treats every non-active session as safe to sweep.
- An expired retry target can have its manifest cleared and audio removed while retry is suspended.

Strategic fix: reserve the session ID before the first suspension, make retention respect the
reservation, and revalidate the persisted session and files after lease acquisition.

### Capture-start deadline can still hang

- `MeetingCaptureEngine.swift:3842-3850` wraps the start sequence in a ten-second deadline.
- `MeetingCaptureEngine.swift:5966-5978` implements it with `withThrowingTaskGroup`.
- Exiting a structured task group cancels but still awaits a child that ignores cancellation.
- The deadline therefore cannot bound a wedged AVFoundation/ScreenCaptureKit operation.

Strategic fix: supervise the lifecycle operation behind an ownership fence, return the public
deadline independently, and join or quarantine the stale operation during controlled teardown.

### Diarization failure suppresses otherwise valid transcription

- `MeetingParakeetNemotronBackend.swift:237-266` excludes every Nemotron-failed epoch from the
  Parakeet ASR loop.
- A transient diarization failure therefore removes speech rather than merely losing attribution.

Strategic fix: run ASR for every materializable epoch and publish text with an unassigned speaker
plus explicit diarization-degraded evidence.

### Default backend is not architecture/capability aware

- `MeetingTranscriptionBackend.swift:19-24` makes Parakeet + Nemotron the unconditional default.
- `MeetingProductionParakeetNemotronRuntime.swift:175-198` always throws on non-arm64.
- `MeetingTranscriptionView.swift:1761-1765` nevertheless promises a plain transcript on Intel.

Strategic fix: choose the default from a capability policy, retaining the legacy implementation on
Intel or other unsupported configurations, and present truthful UI.

### Meeting backend readiness checks the wrong models

- `MeetingTranscriptionView.swift:1053-1059` derives readiness from the selected dictation model.
- It does not verify fixed Parakeet TDT v2 or the Nemotron artifact.
- `MeetingTranscriptionView.swift:2007-2009` opens Voice Engine, which cannot install Nemotron.
- The Nemotron installer/preparation step is intentionally timed with the Nemotron release, but
  backend-specific readiness must ship with it.

Strategic fix: expose one backend readiness/preparation contract covering architecture, Parakeet,
Nemotron, storage and actionable installation progress.

### Integration test target does not compile

- `MeetingTranscriptionBackendTests.swift:424` calls the now-throwing
  `BackupService.makeBackupDocument()` without `try`.
- `xcodebuild ... build-for-testing` fails at this line, so the meeting tests are not a valid gate.

Strategic fix: repair the test and make the clean dependency setup plus integration test build a
required branch check.

## P2 — Resilience, observability and incomplete architecture

### Post-transcription compression is not implemented

- `MeetingAudioChunkWriter.swift:729-741` always writes `playbackArchiveAsset: nil`.
- No AAC/archive producer exists.
- `MeetingAudioPresentation.swift:5-17` falls back to PCM indefinitely.
- PCM is currently retained at full size or deleted by retention; it is never replaced by a
  verified compressed archive after transcription and diarization.

Strategic fix: after the canonical sidecar and completed session are durably published, create and
verify the archive, atomically publish its asset metadata, and only then remove authoritative PCM.

### Persisted diarization identity is wrong

- `MeetingProcessingConfiguration.swift:39-47` defaults to the legacy diarization fingerprint.
- `MeetingModels.swift:1255-1259` identifies `FluidAudio-offline-v1` and community defaults.
- `MeetingProductionParakeetNemotronRuntime.swift:126-132` actually runs Nemotron using literal
  parameters `300`, `3`, and `0.25`.
- `MeetingProcessingPipeline.swift:1597-1601` persists the legacy fingerprint for the new backend.

Strategic fix: define a composite-specific fingerprint containing the FluidAudio revision, model
artifact/content digest and named Nemotron configuration constants.

### Model recheck does not authenticate weight content

- `MeetingNemotronModelLocator.swift:21-23,187-198` fingerprints model entries using path, size and
  modification time; only `Manifest.json` content is hashed.
- A same-size weight replacement with restored timestamps can pass recheck.

Strategic fix: validate weights against an installation-time or shipped expected content digest.

### History and retention scans repeatedly hash all PCM

- `MeetingSessionStore.swift:100-136` deep-reconciles every loaded session before filtering.
- `MeetingSessionStore.swift:342-387` streams SHA-256 over every ready PCM asset.
- Launch recovery and periodic retention sweeps can reread gigabytes of completed history.

Strategic fix: filter using the lightweight session manifest first, cache validated file identity,
and deep-verify only recovery/processing targets or files whose metadata changed.

### Failed attempts lose backend lineage

- `MeetingSessionCoordinator.swift:1546-1558` records only an error code when planning, readiness or
  runtime fails.
- `MeetingSessionCoordinator.swift:1924-1937` derives unstable-looking domain/code strings from
  `NSError` instead of stable backend failure tokens.

Strategic fix: persist backend ID, backend version and configuration fingerprint before planning,
and map failures to stable typed reason codes.

### Sidecar can be orphaned after cancellation

- `MeetingProcessingPipeline.swift:1550-1563` writes and verifies a result sidecar before its final
  cancellation check.
- Cancellation can leave that sidecar unreferenced by `session.json`.
- The stronger reviewer claim that this permanently poisons retries was rejected: coordinator
  retry closes the old attempt and creates a fresh attempt ID.

Strategic fix: journal/adopt verified sidecars during recovery or garbage-collect unreferenced
attempt artifacts safely.

### Real-model smoke test does not prove useful output

- `MeetingNemotronRealModelSmokeTests.swift:21-29` supplies sine tones rather than speech.
- `MeetingNemotronRealModelSmokeTests.swift:89-119` permits zero speaker activity and adds synthetic
  `smokeCompleted` entries to the failure map.

Strategic fix: retain this structural smoke test, but add an opt-in end-to-end speech fixture that
requires bounded non-empty diarization and real Parakeet output through release-style model paths.

## P3 — Cleanup and debt

- No active `Run in parallel` user setting or dormant parallel-processing flag was found.
  Nemotron and Parakeet are deliberately sequential to avoid simultaneous model residency. The
  resource bug is retained materialization, not an accidentally disabled parallel toggle.
- `MeetingLiveCaptionsConfiguration` in `MeetingProcessingConfiguration.swift:75-115` has no
  production consumer and contains an unresolved `main` model revision.
- Four final-processing feature booleans in `MeetingProcessingConfiguration.swift:32-35` are never
  populated by production and are rejected when enabled, despite appearing in fingerprints.
- Playback-archive schema/UI selection exists without an archive producer.
- Roughly 5,000+ lines of completed DEBUG-only meeting probes/autoruns remain connected to app
  startup. Move them to a diagnostics executable/test target when evidence collection is complete.
- Direct AEC3 is release-enabled as requested, but `MeetingCaptureEngine.swift:2696-2706` still calls
  it pre-production and retains the environment kill-switch TODO; the reason at lines 3055-3060
  still says `DEBUG direct AEC3`. Remove the escape hatch and stale labels after stability testing.
- The `chunk-ledger` directory remains after audio deletion because `deleteAudioFiles` removes
  `tracks/` and `checkpoint.json` only. It contains timing/path metadata rather than audio, but
  retention semantics should explicitly delete or retain it.

## External adversarial review

- Claude Opus agreed that the local dependency, non-compiling tests, destructive ledger failure,
  missing ledger recovery, retry/sweep race, unsupported default and ASR/diarization coupling are
  release blockers.
- Grok 4.6 agreed with the core findings and emphasized the broader systemic issue: several
  independent deletion authorities act on one authoritative PCM copy without one session-level
  lifecycle authority.
- Kimi K3 independently inspected the dependency and PCM/ledger paths and agreed with the central
  durability and default-backend findings.
- Kimi's claims that atomic writes, format versioning, checksums and disk-space admission were
  wholly absent were rejected after source verification; those mechanisms do exist.
- Phi was unavailable in both the configured router and installed OpenCode model catalog. No Phi
  review was fabricated.

## Validation performed

- `git diff --check`: passed.
- Unsigned Debug application build: passed.
- Integration `build-for-testing`: failed at `MeetingTranscriptionBackendTests.swift:424`.
- Signed test execution was unavailable because the current keychain lacks the configured Mac
  Development private key; this was kept separate from source findings.
- `swift test` is not the project test route and fails on the pre-existing SwiftPM executable source
  path mismatch (`Sources/FluidVoice` versus `Sources/Fluid`).

## Recommended repair order

1. Restore a reproducible pinned FluidAudio dependency and repair the test-target compile error.
2. Make PCM non-destructive: retain/quarantine on ledger failure and implement ledger recovery.
3. Fix retry/sweep ownership and the capture deadline.
4. Replace whole-attempt in-memory materialization with bounded/disk-backed processing.
5. Decouple Parakeet ASR success from Nemotron attribution success.
6. Add capability-aware default selection and backend-specific model readiness.
7. Add verified post-processing archive compression.
8. Correct fingerprints, failure lineage and recovery observability.
9. Remove or isolate completed diagnostics, inert configuration and stale labels.
