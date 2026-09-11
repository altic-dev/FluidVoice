# Meeting VPIO reference probe

Status: read-back slice implemented and exercised on 2026-09-10. This is configuration evidence,
not an acoustic AEC result.

## Scope and routing boundary

The normal meeting architecture is unchanged. Selected-application audio remains captured by
ScreenCaptureKit and is not rendered through VPIO. The probe only inspects the already-running
microphone VPIO. A later, explicitly diagnostic Trial B may render known local PCM through the
same engine; that will not reroute arbitrary application audio and is not part of this slice.

No production capture metadata, transcription, suppression, scoring, or speaker-profile policy is
changed by this probe. The installed app was not replaced.

## Read-back schema

`MeetingVoiceProcessingProbeSnapshot` records:

- input and output `kAudioOutputUnitProperty_CurrentDevice` values;
- each Audio Unit property ID, scope, element, `OSStatus`, and value for VPIO bypass, AGC, output
  mute, and other-audio ducking;
- the corresponding `AVAudioInputNode` voice-processing getters;
- input/output node formats, presentation latencies, last-render host/sample times, engine running
  state, and the input node's explicit output-connection count.

An unsuccessful Audio Unit read serializes its nonzero status and omits its value, preventing a
zero-initialized buffer from masquerading as a successful read. The JSON schema is versioned and
covered by a round-trip test.

## First built-in-route observation

Environment:

- MacBook Pro `Mac17,9`, macOS 26.6.2 (25G83), arm64;
- signed Debug test host using the existing stable Apple Development identity;
- built-in microphone to built-in speakers;
- 3-second capture, no deliberate playback stimulus.

Numeric sidecar:
[`meeting_vpio_reference_probe_builtin_2026-09-10.json`](meeting_vpio_reference_probe_builtin_2026-09-10.json)

Observed configuration:

- CurrentDevice input element 1 read back device 82; output element 0 read back device 87. Both
  reads returned `OSStatus == 0`. The requested and settled UIDs independently identified those as
  the built-in microphone and built-in speaker.
- Voice processing was enabled and not bypassed. AGC was enabled, input/output mute was off, and
  advanced ducking was disabled at the minimum level (raw 10). The AVFoundation getters and raw
  Audio Unit reads agreed.
- The VPIO input-side node format was 48 kHz, 9 channels; the capture tap delivered canonical
  48 kHz mono. The output-side node format was 48 kHz stereo.
- Both I/O nodes had valid last-render host and sample times. The input node had zero explicit
  output connections, consistent with the current graph having no app-owned render source.
- Capture health for the short run was clean: 30 emitted buffers, 100% valid host time, zero
  synthesized timestamps, conversion failures, continuity breaks, writer discontinuities,
  backpressure events, or live-copy failures.

The system VoiceProcessor also logged repeated downlink errors saying its audio timestamp lacked a
valid sample time, followed by downlink DSP I/O faults, before the final snapshot showed valid node
render times. This is actionable configuration evidence, but it does not prove whether other-process
speaker audio is or is not available to Apple's echo reference. The acoustic A/B trials remain
required.

## Isolated harness and teardown finding

The `FluidVPIOProbe` scheme sets `FLUIDVOICE_MIC_PHASE1=0.05`. In that environment only, Debug
startup avoids normal FluidVoice UI/audio-service initialization so the app-hosted XCTest does not
create competing audio activity.

Reading the live output node exposed a macOS 26.6 AVFAudio teardown crash when the diagnostic then
called `setVoiceProcessingEnabled(false)` after stopping the engine. The crash was in
`AVAudioIONodeImpl::AUI()` during that explicit replacement. The probe now skips only that explicit
replacement and lets process exit release the diagnostic VPIO. Ordinary product `stop()` keeps the
existing explicit teardown behavior unchanged.

## Reproduce

Run the hardware-free schema tests:

```sh
xcodebuild -project Fluid.xcodeproj -scheme Fluid -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/fv-vpio-probe test \
  -only-testing:FluidDictationIntegrationTests/MeetingVoiceProcessingProbeTests
```

Run the 3-second signed built-in-route probe:

```sh
xcodebuild -project Fluid.xcodeproj -scheme FluidVPIOProbe -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/fv-vpio-probe test \
  -only-testing:FluidDictationIntegrationTests/MeetingMicrophoneCaptureTests/testPhase1HardwareGate
```

Use the repository's stable signing settings for the hardware command. Changing the value of
`FLUIDVOICE_MIC_PHASE1` in the diagnostic scheme changes the duration in minutes. Do not install the
test product over `/Applications/FluidVoice Debug.app`.

## Remaining Phase 0 work

This result establishes that VPIO is enabled, which devices its two elements use, and that an output
side is rendering despite no explicit app source. It does not establish echo attenuation or a usable
reference path. Next work is:

1. run the controlled external-stimulus Trial A and compare it with the engine-local Trial B below;
2. persist the printed numeric timing, delay, band-coherence, RMS, attenuation, and uncertainty sidecar;
3. compare bypass/AGC variants without changing production defaults;
4. only then compare the paired ScreenCaptureKit topology and decide whether an Apple-only graph fix
   is sufficient.

## Controlled engine-local Trial B

The DEBUG-only `MeetingVPIOAcousticTrialB` renders a deterministic log-sweep plus speech-like
stimulus through an `AVAudioPlayerNode` attached to the existing VPIO engine mixer. A mixer tap is
the engine-local render reference; the microphone tap is the VPIO capture. The probe runs three
short, exclusive variants: default processing, AGC disabled, and voice processing bypassed (a
variant is marked invalid if a public setter/read-back cannot be applied). The signed delay
convention is `capture time - render time`: positive means the VPIO capture lags the local render.

Run it only from the isolated signed Debug scheme. Both explicit environment gates are mandatory:
`FLUIDVOICE_VPIO_ACOUSTIC=1` and a finite `FLUIDVOICE_MIC_PHASE1` duration strictly above zero and
at most 0.25 minutes (15 seconds); the process must be built with `DEBUG`:

```sh
xcodebuild -project Fluid.xcodeproj -scheme FluidVPIOProbe -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/fv-vpio-probe test \
  -only-testing:FluidDictationIntegrationTests/MeetingMicrophoneCaptureTests/testPhase1HardwareGate
```

The test prints one JSON result containing only the stimulus descriptor and, per variant, property
read-backs plus render/capture valid counts, overlap, signed delay, correlation, render/capture RMS,
attenuation in dB, five frequency-band coherence/support values, output-render confirmation, output
connection count, and explicit uncertainty reasons. PCM arrays are not Codable and are released after
reduction; the Trial B collector does not write audio, invoke ASR, or retain a transcript. The current
process does not automatically persist this output, so redirect only the numeric test output to a
local sidecar after inspecting it.

Limits and caveats:

- The stimulus is generated from fixed seed and segment durations, has a peak limit of 0.35, RMS
  bounds of 0.02–0.15, and the player volume is limited to 0.6. These are safe diagnostic bounds,
  not a calibrated speaker level.
- Correlation searches at most ±0.5 seconds and reports split-half delay uncertainty; low excitation,
  mismatched controls, incomplete capture coverage, and unsupported properties carry explicit reason
  codes. Frequency coherence/support is evidence about coupling, not an echo-cancellation score.
- A successful mixer tap/read-back confirms an engine-local render, not that an arbitrary other
  process or selected-app ScreenCaptureKit stream reaches VPIO. Trial B is informational and cannot
  productize ownership of another app's render path.
- The acoustic probe requires DEBUG plus both explicit environment gates: `FLUIDVOICE_VPIO_ACOUSTIC=1`
  and finite `FLUIDVOICE_MIC_PHASE1` with `0 < minutes <= 0.25`. Before rendering, the read-only
  output preflight requires a live output route whose actual device matches the current default,
  a readable nonzero system volume no higher than 0.6, and a combined digital/output peak no higher
  than 0.15; an unsafe or unreadable route refuses the render.
  It intentionally avoids `setVoiceProcessingEnabled(false)` during teardown because macOS 26.6
  can crash in `AVAudioIONode` after a live output read-back; ordinary product teardown is unchanged.
- This slice makes no AEC claim and does not alter normal capture, transcription, profile, export,
  or installed-app behavior. A positive local correlation is evidence about this controlled graph
  only; it is not proof that Apple's VPIO reference contains system-wide output.

### Built-in-device run on 2026-09-10

The first signed, one-shot Trial B run completed without installing an app. The built-in microphone
and built-in output route were confirmed, system volume was 0.25, the bounded combined peak was
0.03125, and the mixer tap confirmed all 139,200 scheduled frames with valid host timestamps. All
three VPIO control variants also matched their raw and high-level read-backs.

Every acoustic result is nevertheless **invalid/unknown**. The capture collector covered only
93.29–94.74% of each requested shared-clock window, with no overlap and no synthesized timing, so
the strict completeness gate correctly withheld delay, correlation, band, and attenuation values.
Apple's VPIO also logged repeated downlink DSP I/O/state faults. This run is evidence of a probe
window-alignment defect and an unstable VPIO graph, not evidence for or against echo cancellation.
The exact reduced report is in `meeting_vpio_acoustic_trial_b_builtin_2026-09-10.json`; it contains
no PCM or transcript.

An audited rerun after adding collector warm-up remained invalid/unknown, with 92.76–93.18%
coverage. That ruled out insufficient pre-render accumulation and exposed a separate 200 ms origin
error: the capture window used the first non-silent mixer sample as stimulus sample zero even though
the generated stimulus begins with 9,600 silent frames. The rerun is preserved in
`meeting_vpio_acoustic_trial_b_builtin_rerun1_2026-09-10.json`. The window-origin correction is a
code change only until it receives a fresh safety review; no additional acoustic result is implied.

After that correction passed a fresh safety review, one final signed rerun improved the two active
VPIO windows to 98.45% and 97.82% coverage, but both still failed the strict gap gate while Apple
logged repeated downlink DSP I/O/state faults. The bypassed VPIO variant reached exactly 100%
coverage with no overlap or synthesized timing, yet its acoustic measurement was also invalid: the
two delay halves disagreed (approximately 0.00002 s versus 0.05285 s), only one frequency band was
coherent, and captured RMS was only 1.20 dB above the measured noise floor. Consequently none of
the three variants provides a valid AEC result. The exact report is
`meeting_vpio_acoustic_trial_b_builtin_rerun2_2026-09-10.json`.

This is enough to stop repeating Trial B on this host: active VPIO is associated with incomplete
capture windows and framework DSP faults, while the complete bypass arm is not sufficiently
delay-locked or broadband-coherent to support a cancellation claim. The remaining Phase 0 evidence
must come from the external-process Trial A and paired ScreenCaptureKit Trial C2 rather than further
engine-local playback.
