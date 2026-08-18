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
- VPIO turns are marked **scored clean** — `echoScored` is widened to `true` on every turn, forced
  after the existing text-detector loop runs — because that is what they are: AEC-clean by hardware.
  They therefore count as supporting evidence in `localSpeakerEvidence`
  (`MeetingProcessingPipeline.swift:357`) exactly as a text-examined clean turn does today.
- **This is the whole change.** No branch on cluster count, no bypass. AEC does not make diarization
  unnecessary — it makes it work, by removing the echo clusters that competed with the user's own
  voice and defeated the 1.75× margin rule in the observed failure. A second voice in the room is then
  handled by the election as it always was, which matters because misattribution is
  **uncorrectable in-product**: `mergeSpeakers` refuses any speaker with `isLocalUser`
  (`MeetingModels.swift:542`).
- ~~The text echo detector is not consulted; the signal veto is not applied.~~ **Superseded by Phase 4
  measurement:** a healthy VPIO gate session produced zero `.echo` verdicts (7 `containsLocalSpeech` /
  1 `unknown` / 0 `echo`) — the veto had nothing to veto. Suppressing it bought nothing on working
  hardware and risked bleed-as-"You" on degraded hardware. Phase 4 ships with **both kept**: the text
  detector still runs wherever remote text exists, and the signal veto still demotes
  `signalVerdict == .echo` turns exactly as it does for non-VPIO tracks.
- `MeetingEchoSignalScorer` still runs as a **monitor**: its verdicts are recorded, never applied
  beyond the (retained) veto. This is the only field evidence that AEC worked on hardware we have not
  measured; without it a silently-degraded canceller yields bleed labelled "You", forever undetected.
  Phase 4 adds a per-session log-only summary (verdict breakdown, real scoreable coverage, delay-lock
  info) plus a WARN when coverage is ~0 while the application track carried speech.
- `MeetingLiveEchoFilter` is disabled for VPIO sessions (`MeetingLiveTranscriptionCoordinator.swift:150`).
- The decider now also requires `role == .personal` — the election and near-field gate already did,
  so a role-blind VPIO session captured cleanly but could never attribute.
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
- **Resolved by Phase 0 (see §9): same clock domain.** SCStream PTS regressed against mach at
  −0.133 ppm ± 0.628 over 24k samples — the offset is effectively identity and no drift model is
  needed. The ~6.4 ppm drift this repo previously measured (`MeetingProcessingPipeline.swift:722-724`)
  was between the two *audio device* clocks through their samples, not between SCStream's stamps and
  mach; it remains real for echo-reference alignment, which VPIO sessions no longer perform.

**Budget: ±50 ms**, justified by turn ordering alone. Stated as a claim to be tested, not derived —
v3 wrongly cited the 0.15 s `overlapsRemote` threshold, which is a minimum-overlap predicate.

## 9. Phases and gates

**Phase 0 — clock domain. DONE, 2026-08-15.** Regressed SCStream audio PTS against mach host time
over 8 minutes, 24,027 samples (`ClockDomainProbeTests`, `FLUIDVOICE_CLOCK_PROBE`): slope
**−0.133 ppm, 95% CI ±0.628** — statistically zero, 150× inside the 20 ppm gate. SCStream PTS is
mach-anchored, so both capture paths already share a clock domain: **constant offset only; the
linear model in §8 is not needed.** Residual std 6.9 ms is arrival jitter, confirming that per-sample
arrival deltas would have been the wrong instrument. Caveats: one machine, and the probe needs an
unlocked display in a foreground session (`SCShareableContent` reports zero displays otherwise).

**Phase 1 — `MeetingMicrophoneCapture`, standalone. DONE, 2026-08-15.** Formal gate passed on the
built-in mic, 8 minutes: 4800 buffers, **100%** valid `hostTime`, 48 kHz mono Float32 delivered,
8 chunks at exact 60 s cadence, zero discontinuities / backpressure / live-copy rejections, device
bound and read back verified, non-silence confirmed. Measured findings, each of which changed the
design:

- **Binding and read-back live on element 1.** `kAudioOutputUnitProperty_CurrentDevice` on element 0
  addresses the I/O unit's *render* side — read-back returned the AirPods output (85) against a
  requested built-in mic (78). Element 0 would also have *moved the AEC reference*.
- **The tap must be installed before `start()`.** A tap added to an unconnected input node after the
  active graph is built sits on an inactive node: measured as 10 minutes of zero callbacks with all
  other telemetry healthy. Post-start format renegotiation is handled by reinstalling the tap.
- **VPIO delivers no input when its render route is Bluetooth.** AirPods as output: zero callbacks;
  speakers: perfect stream, same code and mic. §3.2 (VPIO only on speaker routes) is therefore
  enforced by the hardware, not just chosen — and the Bluetooth-mic leg resolves to "structurally
  unsupported; such sessions use the SCStream path".
- The §6.2 escape hatch fired correctly in production (`defaultMatchesRequested` when the AirPods
  bind failed), and `AVCaptureDevice.uniqueID` **equals** the CoreAudio UID for Bluetooth devices
  (`EC-46-54-41-33-11:input`) — the name-collision mapping problem largely retires.
- VPIO exposes a **9-channel** input format on the built-in mic; explicit downmix (never converter
  channel mapping) handled it.
- Open tuning note for Phase 2: the PTS clock's 1-frame anchor-correction tolerance trips on ~97% of
  buffers (device-clock vs mach jitter); widen it — corrections are currently telemetry noise, though
  emitted PTS stayed monotonic and the writer accepted everything.

**Phase 2 — timeline. DONE, 2026-08-15, gate honestly FAILED — with the remedy designed.**

The Phase 1 "corrections on 97% of buffers" finding was a **misdiagnosis**: not HAL jitter but a
latch bug — the correction re-baselined one full accumulation window off (post- vs pre-increment
frame count), so every subsequent stamp re-corrected forever. Reproduced by simulation (drift-only
run predicts first fire at window ~32; field data showed 31 and 34), fixed with one line, and the
first-fire index back-derives the built-in mic's drift as ~6.4 ppm — matching the repo's old
echo-path measurement from an entirely different method.

Cross-path drift gate (8 min, dual capture, guards all zero):
`mic +6.693 ppm (CI ±0.635) | app −0.081 ppm (CI ±0.627) | Δ 6.774, CI_Δ 0.892` → the
budget-derived gate (Δ+CI < 6.9 ppm = ±50 ms over 2 h) **failed by 0.77 ppm**. The mic's sample
clock genuinely runs ~6.7 ppm fast vs mach: 24 ms/hour of skew, 48.8 ms at 2 h — inside budget at
the point estimate, over it with CI, and per-device physics that another machine or a USB mic could
triple.

**Remedy (Phase 3, consumer side):** the clock's correction stream is now a live drift meter
(`cumulativeAbsorbedCorrectionSeconds`, one correction per ~3.2 s, each ≤20.8 µs). The batch
pipeline applies a linear de-drift to mic PTS when mapping onto the shared timeline — one multiply —
holding the budget with ~10× margin for **any** device, which also retires the USB-microphone
concern structurally. Capture-side PTS stays sample-count truth (the invariant: `anchorPTS` is never
moved mid-stream; corrections adjust only the divergence reference and are a no-op on output).

Also built: divergence **step detector** (10 ms threshold; drift moves 0.64 ns/window and cannot
fire it — verified over a simulated 2 h), resync clamp so a backlogged invalid burst can never step
PTS behind emitted audio, timeline reset on `AVAudioEngineConfigurationChange`, and real timebase
values in the probe's track metadata. Absolute cross-path offset remains unmeasured (AEC removes
acoustic stimuli, as reviewed) and is Phase 3's first real-call validation item.

**Phase 3 — integrate behind a flag, default off. DONE 2026-08-17, gate PASSED on a real call.**
Shipped behind `meetingVPIOMicCapture` (Settings → experimental, off): pre-flight capability
decision (pure decision table; flag + `.onlineCall` + CoreAudio UID + built-in-speaker output route,
every decline reason logged to session events); `VoiceProcessingMeetingRuntime` with a commit gate —
mic audio and events buffer in a ring until viability + first-buffer-within-2s + app-only SCStream
are all confirmed, so an aborted attempt leaves writers byte-clean and the fallback needs no
re-stamp (provenance is pessimistic `.screenCaptureKit`, durably promoted to `.voiceProcessing`
before the first flushed byte; flush is serialized ahead of passthrough so PTS order holds); one
10s total start deadline, expiry during fallback fails cleanly; mid-session surface = emitted-only
10s watchdog + output-route listener (same predicate as pre-flight, service-restart re-registration)
+ defaultInputChanged UID check, all mapping to the existing interruption flow. Batch de-drift
(`MeetingMicrophoneDeDrift`, k = 1 + cumulative/elapsed — sign verified against the clock: a fast
mic accumulates NEGATIVE corrections) applies to emitted turn boundaries only, gated on a persisted
eligibility bit (zero resyncs/steps/config-changes), 5ms materiality, 100ppm sanity. No
pipelineVersion bump (no pre-flag `.voiceProcessing` tracks can exist; checkpoints snapshot the
application pass only). Live echo filter untouched — deferred to Phase 4 as an attribution change.
Reviewed adversarially over three rounds (two independent reviewers from BLOCK to PROCEED /
PROCEED WITH CHANGES, all findings folded); 36 new unit tests.
*Gate results (2026-08-17, 15.5-min Zoom call, built-in mic/speakers):* VPIO engaged
(`boundVerified` device 78, settled output BuiltInSpeakerDevice); live mic stream carried ONLY the
user's speech while far-end played on speakers (previously a verbatim mirror of the app stream);
double-talk captured the user cleanly as "You" mid-far-end-monologue; zero drops both streams.
Batch: 53 segments — You 20 (all genuinely the user, `isLocalUser` elected), far end 32 across
Speaker 1-5, ONE 2-word "Microphone / Unknown" fragment ("code and") — a non-local
diarization cluster; deliberately NOT forced into "You" by Phase 4 (indistinguishable from a second
voice's interjection). Drift record: −5.24 ms over 957 s (−5.5 ppm, matching the bench
+6.7 ppm fast-mic sign analysis), eligible, materiality crossed → de-drift executed on a real
session. AirPods-at-start declined correctly ("The output device is Bluetooth", session ran
SCStream path); AirPods mid-recording → route listener fired instantly with the designed message,
clean interrupted state, audio preserved, retry offered. Post-meeting dictation normal.
Not yet measured: start latency p50/p95, `silentForSeconds` under AGC over a long quiet stretch.

**Phase 4 — attribution. BUILT 2026-08-17, gate PENDING.** Marks VPIO turns scored-clean
(`echoScored` widened to every turn, forced after the existing text-classification loop) and lets the
existing election run; text detector and signal veto both kept (measurement-driven reversal of the
original "not consulted / not applied" plan, see §5). Decider now requires `role == .personal`
(`MeetingCapturePathDecider.decide`, decline reason "Microphone role is not set to personal").
`logLocalSpeakerElection` gained `captureMethod` and a widened-turns counter (count + seconds forced
scored with no remote text to examine), since `unscoredOverlap` pins to 0.0s under VPIO. New log-only
per-session echo-monitor summary (verdict breakdown, real scoreable seconds — never fabricated from
turn duration, extended `EchoScoringOutcome`/`computeEchoVerdicts` — delay-lock chunks/confidence) plus
a WARN on ~0 coverage while the app track carried speech. Live: `MeetingLiveTranscriptionCoordinator`
gained `setMicrophoneCaptureMethod`, called from `MeetingSessionCoordinator` right after
`capture.start()` returns; `.voiceProcessing` skips `shouldSuppress`, nil (fail-safe default) keeps it
on, bracketed by `[live/ECHO]` log lines so pre-setter suppressions are countable.
`pipelineVersion` 6 → 7 (checkpoint invalidation only). The classification block was extracted to a
`nonisolated static` pure function, `classifyMicrophoneTurns`, so it and the election are unit-tested
directly; non-VPIO path is byte-identical by construction (the widening branch never executes).
*Gate (attended, not yet run):* a single-voice VPIO session elects "You" with no
`Microphone / Unknown`; a **two-voice** session still elects the owner and demotes the second speaker;
a non-VPIO session produces a transcript identical to today's. The first alone proves nothing — the
second is the real test, and it is only possible because the diarizer was kept.

## 10. Not claimable unattended

Quiet interjections under a loud far end (**a release blocker, not a footnote**); AirPods selection and
mid-session profile switching; the ducking experience; permission prompts; real-call ordering under
load; post-meeting dictation and Bluetooth restoration; AEC on any untested hardware or macOS build;
the 2066 downlink faults, which remain un-root-caused and gate nothing today.

Phases 0–2 are unattended-safe. **Phases 3–4 are not, and have no owner or schedule yet.**
