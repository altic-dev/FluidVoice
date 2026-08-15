# Microphone capture migration — SCStream → AVAudioEngine with Voice Processing I/O

Status: **v4, planned, not started.** v1–v3 were each rejected by two independent reviewers. v4 is
smaller than v3, per the reviewers' closing instruction. Written 2026-08-15.

## 1. What v4 changes from v3

v3 was rejected mainly for three self-inflicted errors. Each is corrected by *narrowing a claim*, not
by adding machinery:

| v3 error | v4 |
|---|---|
| "No diarization, no clustering" | **Keep the diarizer.** It is the *segmenter*, not a labeller (`MeetingProcessingPipeline.swift:1385-1391`); every turn boundary, `transcribeTurns`, word alignment, `turnLoudness` and the empty-turn guard depend on it. Deleting it leaves only whole-chunk transcription — the hallucination path fixed earlier today. v4 keeps diarization and **merges its mic clusters into "You"**. |
| "No fallback" | **Pre-flight capability decision, not mid-meeting fallback.** VPIO viability is decided *before* capture starts; the session then runs one way for its whole life. No mixed provenance, and no lost meeting. |
| "Session surfaces a degraded microphone track" | False — capture start is atomic (`MeetingCaptureEngine.swift:88-95`) and a runtime failure stops all writers. v4 does not claim a state the code lacks. |

## 2. Measurements

| question | result |
|---|---|
| Does AEC cancel the far end? | raw mic −23.7 dBFS / 62 words of far-end text; VPIO mic −63.6 dBFS / **zero words** |
| Cancellation vs ducking | ~40 dB total, ~7 dB of it ducking → **~33 dB genuine cancellation** |
| Double-talk | raw: 8 words of mush; VPIO: **51 words of the user's passage, no far-end content** |
| Effect on the user's own voice | ~14.5% WER either way; VPIO ran 12 dB hotter (AGC) |
| Ducking cost at `.min` | −6.9 dB mean on **all** other audio, swing 9.2 → 16.9 dB |
| Downlink-DSP faults | 2066 during the successful run — **not root-caused** |

Shipping config (`VoiceProcessingAsrQualityTests.swift:54-57`). **One machine, one room, built-in mic
and speakers.** Not measured: quiet interjections under a loud far end; any other hardware or macOS
build.

**Competitor precedent is weaker than v3 claimed.** The surveyed competitor ships a thin capture
client with no local models; segmentation and diarization happen server-side, so their client never
had an election to delete. What genuinely transfers: separate dictation/meeting audio configs, source
attribution as the live default, no AEC fallback, logging the *settled* audio constraint rather than
the requested one, and accepting the ducking with no mitigation.

## 3. Activation conditions

VPIO is used only when **all** hold, decided before capture starts:

1. Mode is `.onlineCall` and the microphone role is `.personal`.
2. **Output is not headphones.** With headphones there is no bleed to cancel, so VPIO delivers zero
   benefit and the full ducking cost — pumping the audio the user is hearing the call on. v3 applied
   VPIO unconditionally; the user's accepted trade (§4) was measured on speakers only.
3. The selected microphone can be bound and verified (§6).

Otherwise the session runs today's SCStream path unchanged, with full echo machinery. This is a
**capability decision, not a fallback**: homogeneous for the session's lifetime.

Mid-session output changes (speakers → AirPods) are a known limitation, not handled in v4.

## 4. Product decision — accepted, with a stated boundary

Enabling VPIO ducks **all** other audio by ~7 dB with ±8 dB of pumping that increases while the user
speaks, audible live. **Accepted by the user, 2026-08-15**, after being shown the measured figures and
told it affects live listening rather than only the recording.

That acceptance was given for the **speakers** case and does not extend to headphones — hence §3.2.

## 5. Attribution

For a VPIO session, on the microphone track:

- Diarization runs exactly as today (it is the segmenter), and **the election runs unchanged**.
- VPIO turns are marked **scored clean** — `echoScored = true, isLikelyEcho = false` — because that is
  what they are: examined, and known to contain no far-end audio. They therefore count as supporting
  evidence in `localSpeakerEvidence` (`MeetingProcessingPipeline.swift:357`) exactly as a
  text-examined clean turn does today.
- **This is the whole change.** No branch on cluster count, no bypass. AEC does not make diarization
  unnecessary — it makes it work, by removing the echo clusters that competed with the user's own
  voice and defeated the 1.75× margin rule in the observed failure. A second voice in the room is then
  handled by the election as it always was, which matters because misattribution is
  **uncorrectable in-product**: `mergeSpeakers` refuses any speaker with `isLocalUser`
  (`MeetingModels.swift:542`).
- The text echo detector is not consulted; the signal veto is not applied.
- `MeetingEchoSignalScorer` still runs as a **monitor**: its verdicts are recorded, never applied.
  This is the only field evidence that AEC worked on hardware we have not measured; without it a
  silently-degraded canceller yields bleed labelled "You", forever undetected.
- `MeetingLiveEchoFilter` is disabled for VPIO sessions (`MeetingLiveTranscriptionCoordinator.swift:150`).
- `pipelineVersion` bumps; attribution rules changed.

Unchanged: `.inRoom` (`AVCaptureSession`, not SCStream — `MeetingCaptureEngine.swift:624`), non-VPIO
sessions, and the near-field gate.

## 6. Device selection

`kAudioOutputUnitProperty_CurrentDevice` fails for Bluetooth and aggregate devices, and the existing
binder falls back to the system default on **any** non-zero status (`ASRService.swift:2569-2584`).
SCStream honours `microphoneCaptureDeviceID` exactly today, so this is a real regression.

Order of attempts:
1. Bind, then **read the device back and compare** after voice processing is enabled and the engine is
   running — a successful status is not proof, since enabling VPIO can replace the I/O unit.
2. If binding fails but the **system default input is already the requested device**, proceed unbound:
   identity is correct even though binding is not. This covers most AirPods users, who selected the
   device in System Settings precisely because they are on a call.
3. Otherwise VPIO is not viable → §3, session runs today's path.

Binding order relative to `setVoiceProcessingEnabled` is a **Phase 1 measurement**, not an assumption.
Unresolved: `AVCaptureDevice.uniqueID` → `AudioObjectID` mapping is by display name and yields nil on
collision (`MeetingCaptureEngine.swift:855-866`).

## 7. Provenance

No-fallback removes *mixed* provenance, not provenance itself. A **track-level** `captureMethod` is
required, describing verified capture rather than intended configuration, and read by: batch
attribution (§5), the live coordinator's echo-filter decision, retry after relaunch, checkpoint
resume, and reprocessing of sessions recorded before this change (absence = legacy).

## 8. Timeline

Cross-track timing survives for transcript ordering (batch `MeetingProcessingPipeline.swift:1100-1104`
and live `MeetingLiveModels.swift:39-44`), the `.overlapsOtherTrack` badge, and live origin
establishment. Echo reference alignment is gone.

- Microphone PTS is the tap's `AVAudioTime.hostTime` — acquisition, first frame — as dictation already
  does (`ASRService.swift:4617-4620`). Never `mach_absolute_time()` at callback time.
- Invalid `hostTime`: extrapolate from the last valid stamp plus output duration, **capped at 500 ms**;
  beyond that, record a discontinuity and resync.
- **The constant-offset model is contingent.** This repo measured ~6.4 ppm drift, ~23 ms/hour
  (`MeetingProcessingPipeline.swift:722-724`); a fixed offset is ~46 ms wrong at two hours, consuming
  the whole budget. Phase 0 decides: same clock domain ⇒ offset is identity and no model is needed;
  different domains ⇒ a linear model with periodic re-measurement, not a constant.

**Budget: ±50 ms**, justified by turn ordering alone. Stated as a claim to be tested, not derived —
v3 wrongly cited the 0.15 s `overlapsRemote` threshold, which is a minimum-overlap predicate.

## 9. Phases and gates

**Phase 0 — clock domain (unattended).** Compare *rates*, not arrival deltas: regress SCStream PTS
against wall time and microphone PTS against wall time over 30 minutes. *Gate:* report both slopes in
ppm with confidence intervals. |slope difference| < 20 ppm ⇒ constant offset acceptable; ≥ 20 ppm ⇒
§8's linear model is mandatory. Subtracting `mach_absolute_time()` at arrival is **not** the test — it
conflates queueing jitter with clock domain.

**Phase 1 — `MeetingMicrophoneCapture`, standalone.** *Gate*, over 10 minutes on the built-in mic
**and** one Bluetooth device: valid `hostTime` on ≥99% of buffers; output Float32 LPCM (else the
writer's telemetry silently dies, `MeetingAudioChunkWriter.swift:499-505`); buffers accepted by
`MeetingLiveSampleCopy.copy` and by the writer with zero unexpected rotations
(`MeetingAudioChunkWriter.swift:177-193`); read-back device equals requested, or §6.2/§6.3 fires;
binding order recorded.

**Phase 2 — timeline.** *Gate:* drift within Phase 0's bound over 30 minutes. **Absolute offset cannot
be measured with an acoustic click** — AEC removes it, so a failed correlation would mean cancellation
worked. Use a loud chirp and matched-filter the ~33 dB residual; if the residual is unrecoverable,
record that absolute offset is unmeasured, accept ordering-tolerance validation on a real call, and
say so rather than reporting a number.

**Phase 3 — integrate behind a flag, default off.** *Gate:* a real call whose transcript ordering is
compared turn-by-turn against a human-checked reference. Not a simultaneous old-path capture — two
microphone clients with one enabling VPIO perturbs the system under test.

**Phase 4 — attribution.** One change: mark VPIO turns scored-clean and let the existing election run.
*Gate:* a single-voice VPIO session elects "You" with no `Microphone / Unknown`; a **two-voice**
session still elects the owner and demotes the second speaker; a non-VPIO session produces a
transcript identical to today's. The first alone proves nothing — the second is the real test, and it
is only possible because the diarizer was kept.

## 10. Not claimable unattended

Quiet interjections under a loud far end (**a release blocker, not a footnote**); AirPods selection and
mid-session profile switching; the ducking experience; permission prompts; real-call ordering under
load; post-meeting dictation and Bluetooth restoration; AEC on any untested hardware or macOS build;
the 2066 downlink faults, which remain un-root-caused and gate nothing today.

Phases 0–2 are unattended-safe. **Phases 3–4 are not, and have no owner or schedule yet.**
