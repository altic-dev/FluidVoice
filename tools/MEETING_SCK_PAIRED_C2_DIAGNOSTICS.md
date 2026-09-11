# Phase 0 C2 — ScreenCaptureKit paired-output diagnostics

This slice characterizes the existing one-`SCStream` topology that emits selected-application
`.audio` and `.microphone` outputs. It is DEBUG-only and opt-in with:

```text
FLUIDVOICE_C2_DIAGNOSTICS=1
```

In a DEBUG build, this explicit gate also forces the online-call path to use the paired
ScreenCaptureKit topology when the output route is otherwise eligible for voice processing. The
decision detail and debug log identify this as `C2 diagnostic forced paired ScreenCaptureKit`; it
is not a production fallback. Release builds and DEBUG runs without the exact `=1` value retain the
normal voice-processing decision.

The one-shot signed hardware test additionally requires `FLUIDVOICE_C2_HARDWARE=1` and
`FLUIDVOICE_C2_TARGET_BUNDLE_ID=<currently-running-bundle>`. It creates one selected-application
display filter with `.audio` and `.microphone` outputs, runs for five seconds (bounded below the
15-second ceiling), stops cleanly, and prints the sorted numeric report JSON. It skips without all
three explicit values and never launches an application or writes PCM/transcript data.

For an installed DEBUG app, set `FLUIDVOICE_C2_AUTORUN=1` as the fourth exact gate. The app-launch
hook returns before normal topology observers, logging, AppServices, or UI startup, performs the
same no-prompt Screen Recording and microphone preflight, runs the five-second metadata-only stream,
prints one sorted `[C2_AUTORUN]` success/failure JSON line, and exits with status 0/1. All other
launches, including Release builds or any missing/alternate gate value, follow the normal app path.

`MeetingSCKPairedDiagnosticCollector` accepts only callback-boundary metadata: output kind,
presentation timestamp, duration, frame count, sample rate, channel count, and an optional monotonic
arrival timestamp. It retains aggregate numbers in a lock-protected bounded collector. It never
accepts or stores PCM, transcript text, device names, window titles, paths, URLs, or identities.

The report measures per-output sample counts, malformed/non-finite timestamps, format changes,
timestamp gaps/overlaps/backwards movement, delivery jitter, coverage, first/last PTS offset, and
the relative observed timestamp-span difference. The cross-output offset is explicitly
`microphone PTS - application PTS`; it is not an acoustic or processing latency. Independent
ScreenCaptureKit PTS origins mean the report does not establish a shared clock, estimate oscillator
drift, evaluate AEC, or authorize suppression. Timestamp continuity uses a sample-rate-derived
half-sample tolerance, so sub-sample floating-point noise is not reported as a gap or overlap;
missing or malformed data is fail-open and remains numeric.

The DEBUG ScreenCaptureKit runtime now calls the collector at the callback boundary for the selected
application `.audio` and paired `.microphone` outputs. The callback path first checks the explicit
environment gate, copies only numeric metadata, and requires a scope/provenance assertion derived
from the active selected-application filter. At deterministic runtime stop, the bounded report is
serialized with sorted JSON keys and emitted through the DEBUG logger. A provenance/scope mismatch
is rejected, counted in the report, and logged once; it is never silently combined with another
capture scope. The unit tests retain a deterministic harness for synthetic metadata and exercise
the callback seam without hardware.

No production capture, transcription, persistence, profile learning, or installed app behavior is
changed by C2.

## 2026-09-10 built-in-route attempt

The signed installed-app autorun reached both no-prompt privacy preflights, but
`SCShareableContent.current` returned no display. It therefore exited before creating or starting
an `SCStream`; no browser stimulus played and no PCM or transcript was retained. The numeric result
is frozen in `meeting_sck_paired_c2_builtin_2026-09-10.json` as invalid evidence. It neither supports
nor rejects the paired topology. A later rerun requires resolving the macOS ScreenCaptureKit display
availability/permission state; the diagnostic must not request or bypass that permission itself.

## 2026-09-10 unlocked rerun

After the interactive display session was unlocked, the same signed installed-app autorun completed
one bounded five-second capture against the controlled Chrome stimulus. Both selected-application
audio and microphone outputs produced samples; every callback had valid timestamps and stable
formats, with zero collector-bound drops, malformed metadata, backwards timestamps, or provenance
rejections. The application and microphone spans each reported full coverage. The exact reduced
report is frozen in `meeting_sck_paired_c2_builtin_unlocked_2026-09-10.json`; it retains no PCM or
transcript. That sidecar predates the continuity-tolerance and report-field correction (schema 3),
so its nanosecond-scale gap/overlap counts and `relativeSpanDriftPPM` key are historical artifacts,
not current measurements.

This establishes that the selected-application paired topology is viable on this host when a display
session is available. It does not establish a common capture clock or evaluate AEC: ScreenCaptureKit
reported independent PTS origins, a first-PTS offset of approximately 154 ms, a last-PTS offset of
approximately 42 ms, and a pre-correction observed-span difference of approximately -21,538 ppm over
this short window. The unequal start/stop delivery boundaries account for that span difference, so it
must not be interpreted as oscillator drift. These values are diagnostic timing evidence, not acoustic
delay or cancellation scores.
