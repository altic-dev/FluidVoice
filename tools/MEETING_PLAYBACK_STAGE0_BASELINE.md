# Playback echo cancellation — frozen Stage 0 baseline

Date: 2026-09-10 (local). Status: Stage 0 inventory is frozen; one controlled raw paired-SCK session was acquired and the Stage 0.5 acoustic gate **rejected it**. No AEC dependency, capture migration, suppression, profile quarantine, or runtime behavior is enabled.

## Frozen inventory

`meeting_playback_stage0_baseline_manifest.json` is the checked-in, privacy-reduced baseline. It identifies the eight existing development recordings from `meeting_admission_b3_annotations.json`, their immutable session/chunk hashes, capture topology and format, bounded annotation counts, current legacy evaluator-output hashes, and a canonical digest of the current session-speaker/profile state.

The freeze found:

- eight development-only dual-track recordings;
- selected-application ScreenCaptureKit audio plus a separate VPIO microphone in every recording;
- AAC-LC on both tracks in every recording, so none is a lossless raw paired-SCK fixture;
- five speaker-route recordings established only by the user's controlled-recording report and three whose output route was not persisted;
- zero recorded capture drops, with every retained chunk byte count and SHA-256 matching its session manifest;
- 126 source session manifests in the profile-state snapshot domain, containing 326 session-speaker records and 221 256-dimensional embeddings; private values never enter the checked-in manifest.

The profile baseline is reversible by construction. Stage 0 does not copy or mutate the original session profile state. Any future quarantine must be a separate overlay: the kill switch removes that overlay and verifies the frozen canonical digest. A second artifact containing names, IDs, embeddings, or transcript content was deliberately not created.

The hashes of the nine existing numeric-only development outputs were present and frozen. They may later expire from temporary storage without invalidating the frozen hashes; re-supplying the temporary output root asks the verifier to re-hash them.

## Current production truth table

This table records current source behavior, not an acoustic-quality claim.

| Recording case | Microphone provenance | Live microphone admission | Offline microphone transcript | Speaker-profile eligibility |
| --- | --- | --- | --- | --- |
| Online call, built-in speakers, VPIO starts and settles | `voiceProcessed` era; selected app is a separate app-only SCK stream | Open only after the VPIO commit and route-protection gate | Admitted for protected eras | Existing echo/quality gates may use admitted turns; this is not proof that playback was removed |
| Online call, positively identified headphone route using paired SCK fallback | `acousticallyClosed` raw-mic era after the route listener settles | Open while the closed route remains stable | Admitted for closed eras | Existing echo/quality gates may use admitted turns |
| Online call, built-in speakers with raw paired-SCK microphone fallback or DEBUG C2 force | `unprotected` | Closed | Turns/chunk fallbacks intersecting the era are excluded | No microphone prototype/profile contribution from excluded turns |
| Online call, unknown/Bluetooth/HDMI/aggregate/external/unverified output | `unprotected` unless headphones are positively identified | Closed | Excluded for intersecting eras | Excluded |
| Route/device transition | New conservative era; admission closes before/at the observed boundary and reopens only after a positively safe commit | Closed during unsafe/unsettled eras | Any diarized turn or whole-chunk fallback intersecting an unprotected era is excluded | Same protected-era boundary applies before prototype construction |
| Legacy online session without capture-era metadata | VPIO maps to `voiceProcessed`; other legacy methods map to `legacyUnclassified` | Historical data only | Admitted for backward compatibility, never reclassified as verified | Existing historical behavior; not new positive protection evidence |
| In-room recording | AVCapture microphone; online echo protection is not required | Admitted | Admitted | Existing in-room diarization/profile behavior |

The authoritative implementations are `MeetingCapturePathDecider`, `MeetingRawMicrophoneProtection`, `MeetingMicrophoneTranscriptGate`, `VoiceProcessingMeetingRuntime`, `ScreenCaptureMeetingRuntime`, and `MeetingProcessingPipeline.microphoneIntervalIsAdmitted`. The synchronizer/contracts/replay code remains production-inert.

## Stage 0.5 disposition

The exit gate does not pass. All eight frozen historical recordings are the wrong microphone topology and are lossy. Exact built-in route facts, independent excitation labels, signal-domain corpus consent provenance, and cryptographically bound recording builds are also absent from that inventory.

A separate safety-reviewed DEBUG harness then acquired one five-second, lossless, raw paired-SCK session on the built-in speaker/microphone route. Hashes, consent, native 48 kHz mono float geometry, callback timing, stable route/volume, and capture provenance validated. The privacy-safe result is frozen in `meeting_playback_stage05_builtin_2026-09-10.json`: the only session was excluded for `lowExcitation`, `driftUnscored`, and `linearPathUnlearnable`. The user reported that incidental noise may have occurred, so this session is evidence that the gate did not pass—not a topology-wide claim that paired SCK can never work.

Therefore:

- no current recording passes paired-SCK acoustic learnability analysis;
- C2 delivery metadata, synthetic FIR fixtures, the VPIO recordings, frozen Trial B, and unexcited Trial A are not substitutes;
- the five-second session cannot resolve the frozen 100-ppm drift bound at the registered tracker resolution, and its held-out linear path did not generalize;
- AEC3 dependency work remains unauthorized.

Any next evidence step must be separately safety-reviewed and pre-register a longer, persistently broadband but still low-level stimulus plus enough duration to resolve the frozen drift bound. It must also control incidental microphone noise. Threshold relaxation or AEC3 work is not an allowed response to this rejection.

## Verify

From the repository root, while the frozen source sessions are still available locally:

```sh
python3 tools/meeting_playback_stage0_baseline.py \
  --repo . \
  --sessions-root "$HOME/Library/Application Support/FluidVoice/Meetings" \
  --annotations tools/meeting_admission_b3_annotations.json \
  --verify-manifest tools/meeting_playback_stage0_baseline_manifest.json
```

To re-hash the still-present legacy numeric sidecars too, add `--legacy-output-root /private/tmp`. The verifier fails closed on path escape, malformed/non-finite input, unknown track shape, non-finalized or non-contiguous chunks, byte/hash mismatch, capture-drop schema loss, profile-state drift, private-field leakage, or any attempt by the manifest to authorize AEC3.
