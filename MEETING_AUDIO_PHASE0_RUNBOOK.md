# Meeting Audio Freeze — Phase 0 Evidence Runbook

This runbook classifies the meeting-start freeze before any production behavior is changed. Diagnostics are DEBUG-only and opt-in. They record numeric Core Audio topology events; they do not record audio, device names, meeting titles, window titles, URLs, or transcripts.

## Acceptance rule

A hypothesis may advance to a fix only when all three artifacts agree on the same blocking boundary:

1. the durable `stall-*.jsonl` snapshot identifies the last completed and first incomplete operation;
2. `sample` shows the main-thread waiter and the owning AVFoundation/Core Audio stack;
3. the condition matrix changes the reproduction rate in the predicted direction.

Absence of a stall is not proof of safety. Run each condition at least 20 start/stop cycles, and compare against the pre-rebase revision on the same Mac, OS, microphone, output route, and meeting application.

## Launch

Use the installed, consistently signed Debug app. Do not run an ad-hoc build product because that changes macOS privacy identity.

```sh
mkdir -p /tmp/fluidvoice-audio-evidence
FLUIDVOICE_AUDIO_TOPOLOGY_DIAGNOSTICS=1 \
FLUIDVOICE_AUDIO_TOPOLOGY_TRACE_DIRECTORY=/tmp/fluidvoice-audio-evidence \
FLUIDVOICE_AUDIO_TOPOLOGY_STALL_SECONDS=2 \
"/Applications/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug"
```

The watchdog runs independently of the main thread. After two seconds without a main-runloop heartbeat it immediately writes and `fsync`s:

- `fluidvoice-audio-topology-stall-<pid>-<sequence>.jsonl`
- `fluidvoice-audio-topology-<pid>.stall`

The normal trace is drained at utility QoS without `fsync`; only a stall snapshot is durability-critical.

## Capture a process sample

Keep the frozen process alive. In another terminal:

```sh
tools/capture_audio_topology_stall.sh /tmp/fluidvoice-audio-evidence
```

The script reads the newest marker, validates its PID, and immediately runs Apple's `sample` tool. If `sample` cannot attach, run it from an administrator terminal. For an unresolved kernel/daemon interaction, capture a sysdiagnose immediately afterward with Control-Option-Command-Shift-Period and note its timestamp. Do not attach sysdiagnose archives to the repository; they may contain unrelated private system data.

## Controlled condition matrix

Keep every uncontrolled variable fixed. Record successes, freezes, and failures separately.

| ID | Revision | App path | Purpose |
|---|---|---|---|
| A | pre-rebase | real coordinator | Historical control |
| B | current | isolated microphone capture | VPIO + AVAudioEngine baseline on its actor |
| C | current | B + retained AVFoundation discovery/default lookup | AVFoundation catalog interaction |
| D | current | B + physical-input liveness listeners only | Listener scope interaction |
| E | current | B + all-input liveness listeners | Rebase-introduced ledger interaction |
| F | current | full signed app + real `MeetingSessionCoordinator` | Production ordering after observer, ASR, detector, and UI readiness |
| G | current | B executed on MainActor | Executor sensitivity; never substitute for B |

For C, measure discovery, default lookup, and authorization timing independently rather than treating them as one toggle. For D/E, keep listener registration active through capture quiescence. Condition F begins only after the existing UI gate has opened and the log contains `Audio subsystems initialized`; it must not use a mock coordinator.

## Interpreting the boundary

- Incomplete `vpioEnableBegin`: VPIO creation/configuration is the active boundary.
- VPIO completed but `engineStartBegin` is incomplete: AVAudioEngine start is the active boundary.
- Incomplete listener add/remove or HAL query before the stall: topology listener interaction is implicated.
- Heartbeat stalled with all phases closed: look outside the instrumented topology transition; do not force-fit a Core Audio conclusion.
- A callback marker proves delivery only. All HAL work is separately bracketed so callback arrival is never confused with callback-side querying.

## Promotion gate

Do not ship a fix from a single reproduction. Require at least one clear discriminating A/B result, a matching process sample, and repeated-cycle evidence. Preserve the raw trace, sample, OS/build identifiers, selected input/output transport class, condition ID, and exact commit hashes in a separate evidence folder.
