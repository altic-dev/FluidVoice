# Meeting Detector — Phase 0 Probe: Local Evidence Report

- Date: 2026-08-23
- Environment: macOS 26.5.1 (build 25F80), arm64, Xcode 26.6 (build 17F113)
- App deployment target: macOS 15

## Scope

DEBUG-only feasibility probe plus DEBUG AppDelegate env hook. No production detector or notification behavior; no browser, Accessibility, Apple Events, TCC, or network access; no listeners or observers; no project membership change; no commit.

## Trigger

`FLUIDVOICE_MEETING_PROBE_DURATION_SECONDS` valid only for integer values in `5...300`; absent or invalid values are a no-op. Probe runs at most once per process (lock-guarded check-and-set gate).

## Implementation Evidence

- One utility-QoS serial sampling queue; a separate control queue is the sole owner of file handle, deadline timer, terminal reason, record count, output path, and in-flight flag.
- Exact GCD monotonic deadline timer; `ContinuousClock` records monotonic offsets, and any in-flight sample past the deadline yields `deadlineExceeded`.
- Dynamically sized, bounded HAL process/device list reads: size query then data read with one bounded retry on churn; layout validation (`size % stride == 0`, `<= 4096` objects, `<= 65536` stream-config bytes, `<= 4096` buffers).
- Independent input/output process selector reads (`kAudioProcessPropertyIsRunningInput` / `...Output`) with closed states (`active`/`inactive`/`readError`/`unsupported`).
- Low-level input-device reads (stream configuration, transport, running-somewhere, UID) without device names.
- Per-run salted device token: SHA-256 over 16-byte random salt + device UID, truncated to 128 bits; unlinkable across runs.
- Full non-desktop CG window list (`optionAll`, `excludeDesktopElements`) captured off-main inside `autoreleasepool`; only success flag, count, and latency retained — no window metadata persisted.
- Closed Codable schema: key sets for start/sample/terminal/process/device records validated at setup before any sampling; schema mismatch aborts with `validationFailure`.
- Output: one UUID-named JSONL file under the macOS temp directory, created with `0600` POSIX permissions; path prefix-validated against the temp dir.
- Release builds contain none of this code: entire file is wrapped in `#if DEBUG`, and the AppDelegate call site is `#if DEBUG`-guarded.

## Verification

| Check | Result |
| --- | --- |
| Debug build | Succeeded |
| Release build | Succeeded |
| Release scan for env key and probe-specific symbols | Absent |
| Debug scan for env key and probe-specific symbols | Present |
| Existing `MeetingAutoDetectorTests` | 48 passed, 0 failed |
| Run 1 (5 s) | start + 5 samples + terminal; terminal reason `completed` at exactly 5000 ms; JSON parse/schema passed; forbidden raw field/value scan: no matches; file mode `0600`; window enumeration success, latency <= 4 ms |
| Run 2 (5 s) | start + 5 samples + terminal; terminal reason `completed` at exactly 5000 ms; JSON parse/schema passed; forbidden raw field/value scan: no matches; file mode `0600`; window enumeration success, latency <= 4 ms |
| Leaks run (15 s) | start + 14 samples + terminal; `completed` at 15001 ms; forbidden scan: no matches; file mode `0600`; window latency <= 5 ms |
| Active Zoom call run (60 s, 2026-08-25) | start + 56 samples + terminal; `completed` at 60001 ms; all HAL list reads `ok`; classification failures: 0; every sample contained one Zoom audio-process object at `active`/`active` plus an inactive helper object; built-in input reported `running`; file mode `0600`; forbidden raw field/value scan: no matches; window enumeration succeeded in every sample, latency <= 8 ms |
| Follow-up run (15 s, 2026-08-25) | start + 14 samples + terminal; `completed` at 15001 ms; the same Zoom and device states persisted; file mode `0600`; forbidden raw field/value scan: no matches; window enumeration succeeded in every sample, latency <= 8 ms. The operator's leave action was not explicitly confirmed, so this run is not counted as call-ended evidence. |
| Confirmed joined run (90 s, 2026-08-25) | start + 86 samples + terminal; `completed` at 90001 ms; every sample contained a Zoom audio-process object at `active`/`active`, with built-in input `running`; file mode `0600`; forbidden raw field/value scan: no matches. The leave confirmation arrived near/after the deadline, so this run is counted only as joined-state evidence. |
| Confirmed post-leave run (20 s, 2026-08-25) | start + 19 samples + terminal; `completed` at 20001 ms; the operator had explicitly confirmed leaving while keeping Zoom open; every sample contained only Zoom `inactive`/`inactive`, with built-in input `notRunning`; all HAL list reads `ok`; classification failures: 0; file mode `0600`; forbidden raw field/value scan: no matches; window enumeration succeeded in every sample, latency <= 5 ms. |
| Token unlinkability | 2 unique device tokens in each run, 0 shared across runs |
| Stack-filtered `leaks` pass | App-wide scan reported framework/XPC allocations, but no leak stack matched the probe, session, CF-string reader, or window-capture symbols |
| Code review — initial plan | REVISE (required deadline/CF/buffer/privacy/evidence corrections) |
| Code review — revised plan | APPROVE |
| Code review — final code | APPROVE |
| Code review — post-fix | APPROVE |

Review attribution: Grok 4.6 attempts stalled/timed out without edits or verdict and are explicitly not counted as approval; Kimi K3 provided the explicit approvals.

## Observed Facts

- CoreAudio process enumeration recognized the `selfProcess` and `zoom` coarse families. Both input and output selector reads succeeded independently but observed `inactive`/`inactive` in this short non-active-call run. Duplicate family entries can represent primary/helper audio process objects; no raw mapping leaked.
- Two input devices were stable within each run by token, both `notRunning`; transports `builtIn` and `other`; classification failures: 0.
- Full CG window list succeeded in all samples with <= 4 ms query latency.

### Active-call observation — 2026-08-25

- With an operator-confirmed active Zoom meeting, one Zoom audio-process object reported `active` input and `active` output in every 1-second sample. A second Zoom helper object remained `inactive`/`inactive`; family-level aggregation must therefore tolerate multiple process objects.
- The built-in input device reported `running` for the whole active-call run. The other input-capable device remained `notRunning`.
- The operator explicitly acknowledged entering a muted interval, but neither the active Zoom process state nor the built-in device state changed. These signals establish call activity, not Zoom's UI mute state.
- No call-ended transition was observed before either probe deadline. Because the requested leave action was not explicitly acknowledged, this is ambiguous coordination evidence and cannot establish persistence after leaving.
- A subsequent controlled cycle removed that ambiguity: the joined run showed Zoom `active`/`active` and built-in input `running`; a fresh probe launched only after explicit leave confirmation showed Zoom `inactive`/`inactive` and built-in input `notRunning` in all 19 samples while Zoom remained open.
- Active-versus-post-leave state separation is therefore validated at 1-second cadence. Exact leave-transition latency is not yet measured because the acknowledgement landed near the first probe's deadline and the definitive post-leave evidence came from a fresh process.
- The live runs remained metadata-only: no audio, titles, participant data, raw bundle identifiers, raw device identifiers, paths, or URLs were written.

## Phase-0 Questions — Status

1. Process selector API path and independent input/output reads: **supported**. Active Zoom call and post-leave state separation: **VALIDATED AT 1-SECOND CADENCE**. UI mute-state detection from these signals: **NOT SUPPORTED BY THE OBSERVED EVIDENCE**. Same-process join/leave transition latency remains **NOT YET VALIDATED**.
2. Known primary/helper family mapping works without paths for observed Zoom processes. Other families: **NOT YET EMPIRICALLY VALIDATED**.
3. Input-capable devices stable within a run and unlinkable across runs. External switching, aggregate/removal, and any app-owned loopback: **NOT YET VALIDATED**.
4. HAL enumeration and full window snapshot completed off-main in two bounded runs. Rapid switching and sleep/wake stress: **NOT YET VALIDATED**.

## Residual Gates Before Phase 1

- Same-probe join and explicitly acknowledged leave/relaunch transitions plus application playback at 1 s / 2 s / 5 s sampling cadences. Mute/unmute should be treated as a negative-control test unless a separate local signal is justified.
- External input switching, aggregate-device concurrency, device removal, zero-device/headless runs where feasible; identify whether an app-owned loopback exists.
- Rapid app switching and user-coordinated sleep/wake.
- Separate, explicitly consented browser privacy/TCC spike.
- Lock `DetectorInstant` `ContinuousClock` choice, self-observation exclusion, and actor single-flight contracts after evidence.

## Verdict

First execution slice **IMPLEMENTED AND CODE-APPROVED**, but the full Phase 0 exit gate remains **OPEN**. Phase 1 must not start yet. No heuristics added.

## Artifacts

- Probe source: `Sources/Fluid/Services/Meeting/MeetingDetectorFeasibilityProbe.swift`
- DEBUG hook: `Sources/Fluid/AppDelegate.swift` (`applicationDidFinishLaunching`, `#if DEBUG` block)
- Existing detector tests: `Tests/FluidDictationIntegrationTests/MeetingAutoDetectorTests.swift`
- This report: `MEETING_DETECTOR_PHASE0_PROBE_REPORT.md`
- Raw JSONL outputs: UUID-named files, inspected in the macOS temp directory (exact names and device tokens intentionally not recorded here). They remain only in temp, may be purged by the OS at any time, and are not copied into the repo.

## Rollback

Remove the DEBUG AppDelegate hook and the new probe/report files only. Existing user detector work is unrelated and must not be reverted.
