# Phase 0 Trial A — external Chrome reference

Trial A is a DEBUG-only, one-shot diagnostic. It captures selected `com.google.Chrome` audio from
one ScreenCaptureKit stream as a reference while the existing VPIO microphone capture runs in the
same short-lived signed process. It does not play audio, start ASR, retain transcripts, write
sessions, or change production capture behavior.

All three exact gates are required:

```text
FLUIDVOICE_TRIAL_A=1
FLUIDVOICE_TRIAL_A_AUTORUN=1
FLUIDVOICE_TRIAL_A_TARGET_BUNDLE_ID=com.google.Chrome
```

The launch hook performs Screen Recording and microphone permission checks, confirms the live
default input is built-in and the live default output is built-in speakers, reads output volume,
and applies the controlled fixture's 0.08 peak bound. It captures for at most five seconds, has a
12-second operation timeout and a 14-second process watchdog, stops the stream and VPIO on every
path, emits one sorted numeric `[TRIAL_A_AUTORUN]` line, and exits.

The report retains PCM only in memory during the bounded run and releases it immediately after RMS,
peak, timestamp, coverage, gap, overlap, format, and synthesized-timing reduction. It records the
selected Chrome PID and scope. ScreenCaptureKit PTS and the VPIO host-derived PTS are not treated as
a shared clock: acoustic delay, AEC, and attribution remain `unknown` unless a separately validated
clock bridge is added. No C2 or Trial B gate is consulted or triggered.

The deterministic offline harness tests exact gating, numeric-only output, and fail-closed timing
for gaps, overlaps, synthesized timing, malformed geometry, and unknown clock mapping.

## Stimulus readiness and launch order

The browser fixture is now a required readiness handshake. Its window title is `... — READY` until
the Start button is clicked and the `AudioContext` is successfully resumed; it changes to
`... — PLAYING` only while the 12-second fixture is active, then to `... — COMPLETE`. Trial A
requires a selected Chrome window whose title contains the PLAYING marker before it starts VPIO or
ScreenCaptureKit. It also resolves the display from that exact window by maximum positive frame
intersection and fails closed for no-intersection or equal-area multi-display ties. This makes a
not-yet-clicked or already-finished tab, or a window whose audio would be associated with the wrong
display, fail immediately instead of consuming the one-shot capture window. The PLAYING window's
owning `SCRunningApplication` is authoritative; duplicate/stale same-bundle application records are
not consulted for readiness or filtering.

Use this order for any separately authorized future run: open the localhost fixture, click Start,
confirm the browser title says PLAYING, then launch the signed DEBUG app promptly. Launching the app
first and clicking later is intentionally rejected.

## Unlocked built-in-route run — 2026-09-10

One safety-audited signed run completed on the built-in microphone and speakers at system volume
0.25. Route, volume, VPIO readback, selection, process stability, callback timing, and full interval
coverage all passed. The microphone delivered 53 valid callbacks with RMS 0.001411 and peak
0.007458. ScreenCaptureKit delivered 264 structurally valid reference callbacks, but every sample
was silent (RMS and peak 0). Therefore reference excitation was not confirmed and `captureValid`
and `acousticMeasurementValid` are both false. This result establishes microphone-side capture
health only; it provides no AEC, attenuation, delay, or topology-ranking evidence. Do not rerun
Trial A without a fresh safety review. The exact report is preserved in
`meeting_external_reference_trial_a_builtin_unlocked_2026-09-10.json`.

The zero-valued reference in that run is most consistent with fixture readiness/order, not a
ScreenCaptureKit timing or filtering failure: the selected Chrome stream delivered 264 callbacks
with complete, gap-free timing and no stream errors, but every sample was numerically zero. The
filter explicitly enables application audio, selects Chrome, and excludes only FluidVoice's own
process audio. Because the page click occurred after app launch and the old harness had no
cross-process PLAYING handshake, the run did not establish that Chrome was actively rendering the
fixture during the five-second window. A future zero reference would still be an invalid result,
but the readiness gate now prevents spending a run when that precondition is visibly absent.

Run only from the signed DEBUG app/process boundary after Chrome is already showing the controlled
0.08 localhost stimulus:

```sh
FLUIDVOICE_TRIAL_A=1 \
FLUIDVOICE_TRIAL_A_AUTORUN=1 \
FLUIDVOICE_TRIAL_A_TARGET_BUNDLE_ID=com.google.Chrome \
"/Applications/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug"
```
