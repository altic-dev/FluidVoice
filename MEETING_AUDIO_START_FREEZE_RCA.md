# Meeting transcription start freeze — root cause analysis

**Incident:** BUG-001
**Date:** 2026-08-25
**Severity:** P0 / meeting capture unavailable
**Status:** Narrow production mitigation implemented and validated; long-run and queue-ownership hardening remain
**Affected build:** FluidVoice Debug 1.6.9 (20), macOS 26.5.1 (25F80)

## 1. Executive summary

FluidVoice reproducibly freezes while meeting capture enables `AVAudioEngine` voice processing and
Core Audio publishes/tears down virtual aggregate devices. In both incidents, the main thread remained
parked in AVFoundation's device-liveness listener while removing HAL property listeners; concurrently,
HAL's device-teardown notification queue remained parked in `dispatch_sync`.

The samples prove a permanent two-thread wait during the same topology transition. They are strongly
consistent with a circular wait, but they do **not** expose HAL's synchronous target queue or the
complete wait-for graph. Phase 0 eliminated the meeting microphone catalog as a sufficient cause,
then isolated the rebase-introduced broad `DeviceIsAlive` ledger as the strongest empirical inducing
condition. With the normal AVFoundation catalog restored, excluding only aggregate-transport inputs
from that ledger passed normal dictation and three meeting start/stop cycles. This supports a narrow
production mitigation, but it is not a statistical proof that the full private HAL deadlock class is
closed.

The investigation did prove two FluidVoice hazards around that transition:

1. several FluidVoice Core Audio owners register, add, or remove device listeners on the main queue;
   and
2. the current “exclusive activity” lease excludes another transcription job but does not quiesce the
   prepared dictation backend, drain route recovery, suspend topology-driven reconciliation, or own
   meeting backend switches. It is logical exclusivity without audio-hardware exclusivity.

The production mitigation therefore excludes only aggregate transports from
`AudioHardwareObserver`'s broad ledger. Physical, Bluetooth, USB, virtual, and unknown transports are
unchanged; system/default-device listeners, full liveness refreshes, and ASR's selected-device listener
remain active. Moving Core Audio listener lifecycle ownership off main remains mandatory hardening and
the correct long-term seam, but is not required to ship this evidence-scoped mitigation.

The rebase history materially sharpens the leading hypothesis. The pre-rebase meeting branch already
contained the VPIO meeting path, but did not contain the newer multi-device dictation availability
observer. Rebasing onto `origin/main` introduced per-input `DeviceIsAlive` listeners that are added and
removed on `DispatchQueue.main` during device-list churn. VPIO deliberately creates and destroys
temporary aggregate devices, so this new observer is exercised at exactly the incident boundary. Its
remove call is the closest FluidVoice-owned structural match to the frozen AVFoundation/Core Audio
stack. This is now the highest-priority **rebase-introduced FluidVoice suspect**, but not the leading
incident hypothesis: AVFoundation+VPIO remains co-equal because the sampled waiter is AVFoundation's
own listener. The pre/post-rebase and mechanism-isolation rows must reproduce the difference.

## 2. User impact

- Starting meeting transcription beachballs the entire application.
- No stop, cancel, or fallback action remains available because the main thread is blocked.
- Restarting restores the app but starting meeting transcription can reproduce the freeze.
- No evidence indicates transcript or recording corruption because capture never reaches its committed
  recording state; this must still be verified during the eventual recovery-path tests.

## 3. Incident evidence

### 3.1 Reproduction 1

- App PID: `13288`
- Meeting start: `06:41:49.076`
- Aggregate devices appeared by `06:41:49.422`:
  - `CADefaultDeviceAggregate-13288-0`
  - `VPAUAggregateAudioDevice-0xa37144040`
- The prepared direct dictation capture invalidated on `stream_configuration`, `virtual_format`, and
  `physical_format`, then scheduled route-recovery generations 11–13.
- Meeting microphone and application models finished warming, after which logging stopped.

### 3.2 Reproduction 2

- App PID: `46188`
- Meeting start: `06:57:15.100`
- Aggregate devices appeared by `06:57:15.406`:
  - `CADefaultDeviceAggregate-46188-0`
  - `VPAUAggregateAudioDevice-0xaab760040`
- The prepared direct dictation capture again invalidated on the same three format properties and
  scheduled route-recovery generations 1–3.
- Meeting microphone and application models finished warming, after which logging stopped.

The second incident followed a clean app restart and reproduced the same stack and event order.

### 3.3 Identical main-thread stack in both incidents

```text
com.apple.main-thread
  __DeviceIsAliveListener_block_invoke                 AVFCapture
  -[AVCaptureHALDevice _refreshConnectionID:KVONotify:]
  -[AVCaptureHALDevice _removePropertyListeners]
  AudioObjectRemovePropertyListener_mac_imp            CoreAudio
  HALObject::RemovePropertyListener
  CADeprecated::CAGuard::WaitFor
  _pthread_cond_wait
```

### 3.4 Concurrent HAL notification stack in both incidents

```text
HALC_ProxyNotification Call Listener Queue
  HALC_ProxyNotifications::CallListener
  HALC_ShellPlugIn::ProxyObject_PropertiesChanged
  HALSystem::AudioObjectsPublishedAndDied
  HALSystem::ObjectsPublishedAndDied
  HALDevice::Teardown
  HALObject::PropertiesChanged
  _dispatch_sync_f_slow
  __DISPATCH_WAIT_FOR_QUEUE__
```

This proves two permanently parked threads during device teardown/listener removal and is strongly
consistent with a circular wait. It does not reveal HAL's synchronous target queue, prove the complete
wait-for cycle, or identify any FluidVoice callback as a participant.

### 3.5 Rebase/regression timeline

- The meeting branch's pre-rebase tip was `d5b998a` on 2026-08-19 12:00 PDT. It already contained the
  VPIO meeting commits, including Phase 3 from 2026-08-17 and later route-following work.
- The recorded rebase began on 2026-08-19 12:50 PDT by checking out `origin/main` at `6f0684e`; it
  completed at `1f9af82`, followed by reconciliation commit `a029a69`.
- The old meeting branch and rebased upstream share base `8d140fc` from 2026-08-05. Therefore
  `8d140fc..6f0684e` is the relevant upstream delta introduced underneath the meeting work.
- That upstream delta changed approximately 1,400 lines across `ASRService.swift`,
  `AudioDeviceService.swift`, and `DirectCoreAudioInput.swift` and contains a concentrated series of
  microphone-priority, liveness, prewarm-handoff, and Bluetooth recovery changes.
- The user reports meeting start did not freeze before the rebase. Its denominator, exact installed
  revision, macOS version, and route are currently unknown, so it establishes a regression lead—not a
  negative experimental result. Both revisions must be exercised in the same harness and hardware/OS
  configuration.
- Reconciliation commit `a029a69` changed only file-transcription code and tests, not ASR, Core Audio,
  or meeting capture. It remains part of the post-rebase comparison revision but is not a direct audio
  source-change candidate.

### 3.6 Candidate commit analysis

| Confidence | Commit | Change introduced by rebased upstream | Relevance to this freeze |
| --- | --- | --- | --- |
| Medium-high / unconfirmed rebase-introduced suspect | `2dce5cd` — `fix microphone priority routing` | Adds `DeviceIsAlive` listeners on main to **every enumerated input**, with no virtual/aggregate exclusion. A device-list callback reconciles the ledger and removes vanished-device listeners on main. The large commit also changes selection and recovery. | VPIO creates/removes transient inputs; both freezes end in device-liveness listener removal during teardown. This is the closest new FluidVoice source-level match, but the sampled waiter is AVFoundation-owned. |
| Medium / co-dependent amplifier | `03a0cfd` — `fix cache microphone liveness off main` | Moves the first query off main, but makes availability callbacks enumerate and query liveness for every input during topology churn, retains listener add/remove/delivery on main, and adds liveness-driven ASR recovery. | Adds HAL property reads and recovery reactions at the incident boundary. It is not a complete listener-lifecycle mitigation. |
| Medium / co-dependent amplifier | `3e04401` — `fix isolate microphone availability updates` | Adds a separate availability tick and a `ContentView` reaction that refreshes input liveness and reconciles microphone selection on availability/default-input changes. | Adds another churn-driven HAL enumeration/reconciliation consumer. It depends on the availability events introduced by `2dce5cd`, so tests must isolate both the listener ledger and its consumers. |
| Low–medium | `9417cfc`, `405e033`, `77f3573`, `d3f9461`, `9d27956`, `c9eece6`, `7d780f4`, `3789b79` | Expands and hardens Bluetooth/device route-recovery behavior. | Can increase work scheduled after VPIO topology changes. Logs show recovery requests, but not that recovery execution entered the captured wait. |
| Low / negative control | direct Core Audio prewarm and its lifecycle controller | Already existed before common base `8d140fc`; it was not introduced by the rebase. | Still overlaps meeting start and must be quiesced architecturally, but timing alone no longer makes it the leading regression trigger. |

The pre-rebase tip contains none of `inputAvailabilityListenerTokens`,
`listInputDevicesRefreshingLiveness`, or `cachedInputLivenessByUID`; the post-rebase revision contains
all three. Older global ASR/default-device listeners **and** ASR's main-queue per-device
`DeviceIsAlive` listener for the single monitored microphone existed before the rebase. The regression
claim is therefore narrow: the newly introduced **all-input reconciliation that can attach listeners
to transient virtual/aggregate devices**, plus its new recovery reactions, is suspect—not the general
existence of `DeviceIsAlive` on main and not every Core Audio or multi-device change.

### 3.7 Phase 0 shipped-path isolation results

All rows used the same bundle ID, Team ID, designated requirement, installed `/Applications` path,
diagnostics, and current meeting path. The flags are DEBUG-only and are not production fixes.

| Row | Variable changed | Result | Interpretation |
| --- | --- | --- | --- |
| Baseline | Current microphone catalog and full all-input liveness ledger | Frozen | Reproduced the incident with the two-thread wait above. |
| Catalog isolation | Replaced AVFoundation microphone discovery/default lookup with the Core Audio catalog; retained the ledger | Frozen | AVFoundation catalog removal is not sufficient. The trace contains no discovery/default events before VPIO, yet the identical wait remains. |
| Ledger isolation | Held catalog isolation constant; omitted only `AudioHardwareObserver`'s rebase-introduced all-input `DeviceIsAlive` ledger | Normal dictation and three meeting cycles passed | Strongly supports the ledger as an inducing participant, but removes more behavior than a production fix should. |
| Transient-input isolation | Restored physical-device ledger listeners; excluded aggregate, virtual, and unknown transports | Normal dictation and three meeting cycles passed | Narrows the inducing surface to transient-style transports while preserving physical multi-device behavior. |
| Aggregate-only isolation | Restored the normal AVFoundation catalog and retained all non-aggregate transports; excluded only aggregate transports from the broad ledger | Normal dictation and three meeting cycles passed | This is the narrowest passing production-shaped row and the basis of the shipped policy. |

The successful traces completed microphone authorization, VPIO enable, input binding, engine prepare,
and engine start. The frozen rows attached the broad `DeviceIsAlive` ledger to persistent inputs and
then to VPIO aggregate inputs. The aggregate-only trace excluded those aggregate attachments while
retaining physical attachments, the normal catalog, and the active meeting detector. That detector's
separate `DeviceIsRunningSomewhere` ledger remained active—including on aggregate IDs—and the run still
passed; this is evidence that the observed failure is selector/ownership-path specific, not that every
main-queue Core Audio listener is sufficient to freeze. A scoped run executed 185 tests with zero
failures and one expected opt-in hardware skip. The Release configuration also compiled successfully.

Adversarial review of the production diff found the predicate, token-removal ordering, Release
reachability, and dictation-preservation boundary sound. Kimi K3 approved. Claude Opus requested the
evidence wording and detector configuration be made explicit; both are addressed above. Review also
agreed that dedicated off-main listener lifecycle ownership remains mandatory follow-up hardening.
Three clean cycles justify this narrow mitigation after a reproducible incident and controlled A/B,
but do not satisfy the 2,995-cycle statistical gate defined later in this document.

## 4. What is proven, inferred, and still unknown

### Proven

- `MeetingSessionCoordinator` acquires `.meeting` through `AudioActivityArbiter`, but the lease only
  updates ASR state fields. It performs no audio-backend handoff
  (`MeetingSessionCoordinator.swift:31-67`, `ASRService.swift:246-264`).
- Startup leaves a prepared direct Core Audio dictation backend and its format listeners alive
  (`ASRService.swift:1471-1510`, `DirectCoreAudioInput.swift:1207-1354`).
- Neither idle prewarm nor route recovery is suppressed by the active meeting lease
  (`ASRService.swift:880-1007`, `ASRService.swift:3368-3613`).
- Meeting capture calls `input.setVoiceProcessingEnabled(true)`, the observed boundary that creates VPIO audio
  topology, while the prepared dictation backend is still present
  (`MeetingMicrophoneCapture.swift:637-692`).
- VPIO topology changes invalidated the prepared dictation capture in both incidents and caused three
  ASR route-recovery requests.
- Multiple FluidVoice services independently add and remove Core Audio listener blocks on
  `DispatchQueue.main`. At the initial VPIO boundary, the active sets include
  `AudioHardwareObserver`, ASR device monitoring, and meeting auto-detection. Meeting microphone and
  output-route monitoring use the same unsafe pattern elsewhere, but are installed only after VPIO
  microphone startup and therefore cannot trigger this initial-start incident.
- The online-meeting configuration enumerates microphones through
  `AVCaptureDevice.DiscoverySession` before VPIO begins
  (`MeetingCaptureEngine.swift:1257-1284`).
- The installed build predates the meeting-overlay changes. Relevant microphone/VPIO/ASR code has no
  current working-tree diff, so the overlay implementation is excluded from the causal path.
- Runtime logs prove `MeetingAutoDetector` was active in the second incident build even though its
  source is currently untracked. Repository `HEAD` alone is not evidence of installed-build contents.

### Strongly inferred

- Aggregate-device publication/death causes HAL to deliver a main-queue device event. AVFoundation's
  liveness handler removes its HAL listeners while HAL teardown synchronously waits for listener
  delivery. This is the leading wait-cycle hypothesis, not a proven closed graph.
- Main-queue listener concentration and concurrent ASR invalidation/recovery enlarge the hazardous
  topology window. They are architectural contributors even if one Apple-internal AVFoundation
  listener is the immediate deadlock participant.
- Ephemeral AVFoundation discovery before VPIO causes AVFoundation to materialize audio-device
  objects whose lifecycle overlaps the VPIO aggregate-device transition.
- AVFoundation may retain HAL device objects/listeners after the local discovery session is released;
  the captured AVFCapture stack makes this plausible, but only the ephemeral-versus-retained Phase 0
  rows can establish the lifetime.
- The rebased `2dce5cd` per-input listener ledger is the highest-priority new FluidVoice regression
  suspect, co-equal with the pre-existing AVFoundation/VPIO hypothesis rather than ranked above it.
  Its main-queue removal of `DeviceIsAlive` listeners is activated by the same transient VPIO device
  churn seen in both incidents and was absent from the pre-rebase meeting branch.
- The later liveness/priority recovery work can widen or repeat the hazardous topology window, but the
  logs do not yet show it beginning a rebuild before the freeze.

### Not yet proven

- The exact dispatch queue targeted by `HALObject::PropertiesChanged` in the private Core Audio frame.
- Whether AVFoundation discovery plus VPIO alone reproduces the deadlock in a minimal process.
- Whether removing idle direct prewarm alone changes reproduction frequency. That experiment would
  isolate an amplifier, not establish a sufficient production fix.
- Whether this is a macOS 26.5.1 framework regression. FluidVoice must remove its unsafe concurrency
  regardless; a minimal reproduction and sysdiagnose should be submitted to Apple if it persists.
- Whether a scheduled ASR route-recovery task began executing before the deadlock. The logs prove
  three requests were created and that direct-listener invalidation/drain ran; they do not prove the
  debounced recovery reached its rebuild phase before the main thread stopped.
- Whether an older recovery request was still sleeping or executing when reproduction 1 began. Its
  generations 11–13 show prior route events but not the state of generation 10 at meeting start.
- Absence of later app log lines is not proof that background work never began: user-facing logging
  commonly hops through main-actor state, which was already blocked.
- Whether `d5b998a` remains non-hanging under the same macOS, device route, permissions, and repeated
  cycle count, and whether adding `2dce5cd` alone makes it hang.
- Whether the necessary additional participant is the new FluidVoice listener ledger, pre-existing
  AVFoundation device materialization, or their combination. The sampled `DeviceIsAlive` callback is
  AVFoundation-owned, and the pre-rebase meeting path already used discovery and authorization APIs.

## 5. Observed sequence and competing causal hypotheses

```text
Startup
  -> ASR prepares DirectCoreAudio input and installs format listeners
  -> global ASR, hardware, and meeting-detection listeners remain active

User starts online meeting transcription
  -> configuration enumerates AVCaptureDevice microphones
  -> logical .meeting lease is acquired, but audio hardware is not handed off
  -> meeting enables AVAudioEngine voice processing
  -> Core Audio publishes VPIO/default aggregate devices and tears transitional devices down

Observed concurrent reactions
  -> direct dictation input receives three format invalidations
  -> ASR invalidates its prepared backend and schedules idle route recovery
  -> device observers enumerate devices and add/remove per-device listeners
  -> AVFoundation receives device-liveness changes for its HAL device objects

Permanent wait
  -> main queue: AVFoundation removes a HAL listener and waits in Core Audio
  -> HAL notification queue: device teardown waits in dispatch_sync
  -> neither advances across either sample; the UI freezes permanently
```

Three hypotheses fit that sequence and must be isolated:

1. **AVFoundation/VPIO:** AVFoundation audio-device materialization alone leaves a main-queue liveness
   listener that deadlocks with VPIO aggregate teardown. If reproduced, removing AVFoundation catalog
   work from the VPIO path is curative; FluidVoice listener/coordinator work is defense-in-depth.
2. **FluidVoice main-queue listeners:** HAL is synchronously targeting main because a FluidVoice
   registration is delivered there while main is already inside listener removal. The closest source
   match is `AudioHardwareObserver.replaceInputAvailabilityListeners`, which removes and adds
   `DeviceIsAlive` listeners from main during device-list reconciliation. This exact per-input path was
   introduced by upstream commit `2dce5cd` and was absent before the rebase. Auto-detection performs
   the same class of main-queue per-device reconciliation for `DeviceIsRunningSomewhere`.
3. **Prepared dictation overlap:** direct prewarm or recovery is necessary to create the teardown
   ordering. The direct backend already uses dedicated queues and completed its recorded listener
   drain, so current evidence makes it an ownership violation and likely amplifier—not the leading
   immediate participant.

## 6. Root-cause statement

### Confirmed incident mechanism

VPIO aggregate-device publication/teardown overlaps an AVFoundation device-liveness callback on main.
The callback blocks removing HAL listeners while HAL teardown blocks in a synchronous dispatch. The
unresolved target queue prevents claiming the exact closed wait graph.

### Proven architectural root hazard

FluidVoice has no single owner for process-wide audio-topology transitions, and it delivers/removes
multiple Core Audio listeners on main. Its exclusive-activity model arbitrates user operations but not
hardware lifecycle. Consequently, listener reconciliation, dictation prewarm/recovery, AVFoundation
device materialization, and meeting VPIO transitions are permitted to overlap. Phase 0 must determine
which of these permitted overlaps closes this incident's wait cycle.

### Highest-priority rebase-introduced FluidVoice suspect

The strongest new-FluidVoice-source regression explanation is the interaction introduced by rebasing the
reportedly non-freezing meeting VPIO path onto the new multi-device dictation observer from
`2dce5cd`:

```text
VPIO publishes/destroys aggregate input devices
  -> system device-list listener fires on main
  -> FluidVoice enumerates the new list off-main
  -> FluidVoice returns to main and removes DeviceIsAlive listeners for vanished devices
  -> removal overlaps HAL/AVFoundation teardown at the captured freeze boundary
```

This explains the timing and source-level operation without claiming the unobserved final wait edge.
It does not outrank the AVFoundation-retention hypothesis by direct stack evidence: the captured
callback is AVFoundation-owned, and AVFoundation discovery existed pre-rebase. The new ledger may be
the missing sync-edge participant, a timing amplifier, or incidental; only the isolation rows decide.
The proper fix is not to special-case VPIO device names or add delay; it is to establish off-main,
stable listener ownership and suppress reconciliation during topology transitions. The diagnostic
matrix below must first establish whether that slice alone removes the incident.

### Contributing conditions

1. Core Audio listener ownership is duplicated across at least five services. Three pre-existing
   listener owners are active at the initial VPIO boundary; the later-installed meeting listeners are
   additional architectural debt, not the temporal trigger for these two incidents.
2. Many listeners use the main queue directly; some callbacks query Core Audio or add/remove listeners
   from that same delivery queue. `AudioDeviceService.swift:621-658` is the closest FluidVoice-owned
   structural match to the captured removal wait.
3. Route recovery does not respect `.meeting` exclusivity.
4. Meeting auto-detection continues monitoring FluidVoice's own audio-device changes during capture.
5. Microphone selection combines two identity systems—Core Audio UID and
   `AVCaptureDevice.uniqueID`—and eagerly invokes AVFoundation even for the VPIO primary path.
6. Configuration is resolved before the meeting lease, then the microphone is enumerated again inside
   the VPIO transition.
7. `MeetingMicrophoneCapture.start` calls `AVCaptureDevice.authorizationStatus(for:)` immediately
   before VPIO, despite an existing source comment that this API activates AVFCapture/Core Audio.

## 7. Rejected patch fixes

The following may alter timing but do not establish safe ownership:

- adding a sleep/debounce before or after `setVoiceProcessingEnabled(true)`;
- retrying meeting start after a timeout;
- adding only `guard activeExclusiveActivity != .meeting` to one recovery call;
- disabling only startup prewarm;
- moving only the listener seen in the current stack off main;
- catching the VPIO error or falling back after a deadline—the main thread cannot execute fallback
  once deadlocked;
- killing and restarting the app automatically;
- permanently disabling voice processing without evaluating the capture-quality contract.

These are rejected because other listeners and topology owners would remain able to recreate the same
class of race.

## 8. Required invariants

The final architecture is complete only when these invariants are enforced in code and tests. The
Phase 0 decision matrix determines which subset is curative for BUG-001 and therefore must land first.

1. **Single topology writer:** exactly one coordinator owns prepare/start/stop/destroy operations for
   dictation Core Audio, meeting VPIO, and recovery transitions.
2. **True handoff:** `{dictation prepared/running/recovering}` and
   `{meeting preparing/recording/switching/stopping}` never overlap. Meeting admission while dictation
   is active is rejected without preempting or discarding the current utterance; the user may retry
   after dictation completes.
3. **Transition suppression:** hardware events received during meeting start, stop, or backend switch
   are coalesced as a dirty snapshot; they cannot start recovery, prewarm, or listener reconfiguration.
4. **No FluidVoice HAL work on main callbacks:** FluidVoice Core Audio callbacks do constant-time event
   capture only. They do not query Core Audio, add/remove listeners, mutate observable UI state, or
   synchronously cross queues. FluidVoice cannot enforce this inside AVFoundation, so AVFoundation
   materialization must not overlap VPIO transitions.
5. **Stable listener ownership:** every listener has one owner, a retained registration record, and the
   exact same dedicated serial queue argument for matching add/remove. Neither removal nor draining
   executes from that listener's delivery queue; both are owned by a separate control executor.
6. **Backend-specific identity and lifetime:** the VPIO path uses a previously selected Core Audio UID.
   It does not create an AVFoundation discovery session during topology transition. Before SCK→VPIO,
   FluidVoice releases every app-owned AVCapture session/device/discovery object and observes the
   topology/listener barrier. If Phase 0 proves AVFoundation retains hazardous process-global objects,
   SCK→VPIO upgrade is prohibited in that process; the meeting remains on SCK.
7. **Ordered restoration:** meeting stop fully retires VPIO and waits for topology quiescence before one
   reconciled dictation prewarm. It never replays every event received during the meeting.
8. **UI isolation:** MainActor receives immutable topology snapshots and state changes only; it never
   owns Core Audio listener delivery.
9. **Backend switches are transitions:** VPIO→SCK downgrade and SCK→VPIO upgrade remain meeting-owned
   but pass through the same quiescence, listener, identity, and rollback rules as initial start/stop.
10. **Service reset has one owner:** Core Audio service restart during any transition cannot trigger
    independent re-registration in ASR, device monitoring, or meeting capture.
11. **Quarantined failure:** if a HAL call wedges or teardown cannot be proven complete, the state is
   `failedQuarantined`, not stable. No capture, listener reinstallation, or prewarm begins until an
   explicit audio-service reset or app restart establishes a new generation.
12. **Frozen-main distinction:** `failedQuarantined` is an in-process state only while the main heartbeat
    remains alive. An off-main watchdog that observes a dead main loop persists a privacy-safe marker
    and VPIO-disable flag for the next launch; it never attempts in-process audio recovery.

## 9. Proposed architecture

### 9.1 `AudioTopologyCoordinator`

After Phase 0 identifies the curative slice, introduce one process-wide actor with an explicit state
machine for every topology-changing backend operation:

```text
stableDictationIdle
  <-> stableDictationActive
  -> handingOffToMeeting
  -> meetingStarting(vpio | sck)
  -> meetingActive(vpio | sck)
  -> switchingMeetingBackend(vpioToSCK | sckToVPIO)
  -> meetingActive(vpio | sck)
  -> handingBackToDictation
  -> stableDictationIdle

Any state -> rollingBack -> stableDictationIdle | failedQuarantined
```

It owns transition generations and leases. A lease is granted only after the previous owner is fully
quiescent; it is not a Boolean permission flag. In-room SCK microphone capture and online fallback,
downgrade, and upgrade legs are included because they materialize backend-specific audio devices.
`stableDictationActive` rejects meeting admission; it does not preempt the current utterance.

### 9.2 Asynchronous meeting handoff

`beginMeetingCapture` must:

1. close the gate to new ASR prewarm/recovery;
2. reuse `ASRService.cancelAudioRouteRecoveryAndWait()` to cancel and await sleeping or active route
   recovery rather than creating a second barrier;
3. stop/invalidate the prepared direct input, remove its listeners on their registered queue, drain
   callbacks, and retire any dictation `AVAudioEngine` off the main actor;
4. suspend/coalesce `AudioHardwareObserver`, detector, and legacy listener reconciliation so no
   per-device listener add/remove can occur during the transition;
5. snapshot microphone authorization, selected Core Audio UID, and output-route facts before the
   transition without `AVCaptureDevice.DiscoverySession`, `.default`, or `.authorizationStatus` in the
   VPIO window;
6. grant the meeting topology lease;
7. create/start VPIO on the coordinator's audio-control executor;
8. commit `meetingActive(.vpio)` only after first microphone PCM and application capture are healthy.

If any step fails, rollback runs on the control executor—never main and never a listener queue. Every
step has an observed completion boundary. A deadline reports failure but cannot declare topology safe;
if teardown does not complete, enter `failedQuarantined` and keep all new audio work closed.

### 9.3 Ordered handback

`endMeetingCapture` must:

1. stop sample acceptance;
2. stop application capture and VPIO;
3. remove and drain meeting listeners and release the engine on the audio-control executor;
4. wait until observed topology generations are quiet;
5. take one current device snapshot and reconcile selection;
6. reopen ASR event handling and optionally prewarm dictation exactly once.

A bounded deadline may report a failed transition, but it must not permit two owners to proceed. A
dictation hotkey pressed during handback waits for the same barrier or returns a bounded unavailable
result; it never starts a competing backend.

### 9.4 `AudioHardwareEventHub`

Replace service-local Core Audio listener management with one registration ledger and coalescing hub.
The hub is justified by the need for one dirty-generation boundary during transitions; a generic
broadcast framework is not required:

- one dedicated serial listener queue, never `DispatchQueue.main`;
- one registration ledger for system devices/defaults/service restart and necessary per-device facts;
- callbacks capture property addresses and IDs, then enqueue a coalesced event to the topology actor;
- UI, detector, microphone-selection, and health services subscribe to immutable snapshots;
- auto-detection suppresses or tags FluidVoice-owned capture transitions so it does not react to its
  own VPIO devices as evidence of an external meeting.

No listener callback may query additional “necessary per-device facts”; those are read later by the
control executor after the callback returns. I/O-thread properties that Apple documents as synchronously
delivered permit atomic/statistics updates only.

### 9.5 Separate microphone selection from backend binding

Replace the configuration's eager dual-framework lookup with:

- a stable selected microphone value based on Core Audio UID plus display metadata;
- a VPIO binder that resolves the current Core Audio object ID under the topology lease;
- an AVFoundation/SCK resolver invoked only when starting an AVCapture or SCK-microphone backend;
- lazy fallback resolution only after VPIO is fully torn down and topology is quiet.

The online VPIO configuration/catalog path must not call `AVCaptureDevice.DiscoverySession`,
`AVCaptureDevice.default`, or `AVCaptureDevice.authorizationStatus` near the transition. Authorization
is resolved before handoff. If SCK fallback is needed, resolve its required unique ID only after VPIO
teardown is observed complete. Production code does not infer “no aggregate was published” from elapsed
time; it requires a topology-generation observation. Without that observation, fallback follows the
same teardown/quarantine path. Before any SCK→VPIO upgrade, release app-owned AVFoundation objects and
pass the same barrier; if retained AVFoundation state is proven hazardous, do not upgrade in-process.

For ScreenCaptureKit, Apple's SDK header states that `microphoneCaptureDeviceID` is an
`AVCaptureDevice.uniqueID`; that requirement belongs in the SCK adapter, not the shared product model.

## 10. Proof plan before production rollout

### Phase 0 — isolate and instrument

Before production changes, capture one full spindump dispatch-queue section from the frozen app and a
sysdiagnose/Core Audio log window where possible. Resolve HAL's `dispatch_sync` target queue. Build a
minimal signed harness and measure the baseline failure rate for these conditions:

1. VPIO only;
2. main-thread AVFoundation discovery/default lookup followed by VPIO, with ephemeral and retained
   discovery-session variants;
3. direct Core Audio prewarm with its existing off-main listeners followed by VPIO and no AVFoundation
   catalog (negative control for the prewarm hypothesis);
4. FluidVoice-equivalent main-queue Devices/`DeviceIsAlive` listeners followed by VPIO;
5. AVFoundation discovery plus FluidVoice main-queue listeners followed by VPIO;
6. all current FluidVoice conditions together.

Record main-runloop heartbeat, topology generation, listener owner/queue, VPIO begin/end, and route
recovery scheduled/begin/end separately. Run on macOS 26.5.1 and one other supported OS. For every
stall capture a spindump/sysdiagnose; for every non-stall record the denominator. Choose cycle counts
from the observed baseline. The targeted curative harness gate is a per-start residual hang probability
of at most 0.1% at 95% confidence: with zero failures, this requires at least 2,995 independent cycles.

#### Phase 0B — isolate the rebase regression

Use the same signed diagnostic harness, macOS build, microphone/output route, and meeting-start cycle
for every row. Do not replace the installed production-style debug app with a differently signed
historical build; preserve its privacy grants and run historical variants as isolated harnesses.

1. `d5b998a` pre-rebase meeting implementation on its original audio base;
2. `a029a69` post-rebase implementation before later working-tree overlay/detector changes;
3. a synthetic old-base build containing only the `2dce5cd` per-input availability listener ledger,
   without the remainder of that 2,390-line selection/recovery commit;
4. an integration build with full `2dce5cd`, followed by one through `03a0cfd`, then one through
   `3e04401`; replay the real intervening commits in order rather than blind cherry-picks that silently
   resolve conflicts. These are diagnostic states, not claims about shipped revisions;
5. current path with only the `AudioHardwareObserver` per-input listener ledger omitted while the
   `3e04401` default-input/availability consumer remains active;
6. current path with the per-input listener ledger retained while only the `3e04401` availability-tick
   consumer is held inactive;
7. current path with the same listener coverage and consumers retained, but delivery on a dedicated
   serial listener queue and
   add/remove owned by a separate control executor;
8. current path with per-input listeners intact but topology-driven route recovery/prewarm scheduling
   suppressed, separating the immediate listener trigger from the recovery amplifier;
9. current path with the `2dce5cd` ledger retained but AVFoundation discovery/default/authorization
   removed from the VPIO transition, separating AVFoundation materialization from the new ledger;
10. current path with the ledger retained for physical inputs but transient virtual/aggregate inputs
   excluded, while the older ASR monitored-device `DeviceIsAlive` listener remains active as the
   pre-rebase baseline.

Rows 1–4 must use an explicitly identical meeting-detector configuration. Prefer two matched blocks:
detector absent, then the incident-equivalent detector present. A negative detector-absent run is not
binding for the incident configuration because the second frozen build had the detector's main-queue
per-device listener owner active even though that source is absent from the historical commit objects.

For each add/remove record registration ID, owner, object ID, selector, delivery queue, control queue,
generation, transport/virtual classification, and monotonic timestamp. Do not record device names.
Correlate FluidVoice token object IDs with the object IDs published and torn down by VPIO; without that
match, do not claim the ledger participated in the incident. Record route-recovery `scheduled`, `began`,
and `ended` separately so a queued request is not mistaken for an executing rebuild.

Start with randomized, interleaved blocks of 100 cycles per row to reduce ordering, thermal, and audio-
daemon state bias. Any captured matching freeze rules a row in. Zero failures is only preliminary;
before declaring a suspected condition unnecessary or a fix curative, run at least 2,995 independent
cycles for that row, matching the 0.1%/95% gate above. Record the user's approximate historical
pre-rebase start count if recoverable, but never combine it with controlled harness denominators.

Interpretation:

- Rows 1 versus 2 establish whether the rebase reproduces the regression under controlled conditions.
- If row 1 reproduces the same freeze, the rebase-regression claim is falsified: `2dce5cd` cannot be an
  inducing requirement, though later changes may still amplify a pre-existing AVFoundation/VPIO race.
- Row 3 becoming positive identifies the listener ledger as sufficient in the synthetic harness. Row
  4 shows whether the complete commit series changes that result and prevents misattributing another
  part of the large `2dce5cd` commit to the ledger.
- Rows 5 and 6 independently distinguish the listener ledger from its UI/reconciliation consumer;
  neither is interpreted by removing both variables at once.
- Row 7 becoming negative proves queue/lifecycle ownership is the curative slice rather than merely
  deleting multi-device availability support.
- Row 8 affects an amplifier only if the listener rows remain positive while recovery suppression
  changes the failure rate.
- Row 9 distinguishes AVFoundation materialization from the ledger on the real integration path.
- Row 10 tests the unique new mechanism—all-input listener attachment to transient objects—without
  removing physical multi-device availability or the older single monitored-device baseline.
- A positive minimal AVFoundation-discovery+VPIO row with no FluidVoice per-input ledger falsifies the
  ledger as an inducing requirement, even if it remains an amplifier.
- If row 2 is positive but rows 3–4 are negative, automate `git bisect` across the remaining upstream
  audio commits using the harness; do not nominate a commit from log messages alone.

Decision gate:

- If condition 1 hangs, quarantine/disable VPIO on the affected OS and use the supported SCK path while
  filing the minimal reproduction with Apple. Application-side coordination is not the curative fix.
- If condition 2 hangs but 1 does not, identity/AVFoundation isolation is a curative slice.
- If condition 4/5 hangs but 1 does not, listener migration and transition suspension are a curative
  slice. They begin by retargeting the implicated existing owners and moving add/remove to a separate
  control executor; they do not wait for the hub.
- Compare condition 3 with condition 1. If prewarm adds hangs or materially worsens the measured rate,
  async dictation quiescence is a curative slice.
- If only condition 6 hangs, add combinations until the smallest sufficient trigger is identified.
- If multiple isolation rows hang independently, Phase 1 is the union of every positive row's curative
  slices. Re-run every positive row and their combination after each slice; a lower rate is not a pass.
- If no harness row reproduces, do not guess a curative fix or enable VPIO broadly. Escalate to the
  instrumented in-app path/device matrix, ship the two proven hazard repairs (off-main listener
  discipline and transition suppression) behind the VPIO kill switch as defense-in-depth, and keep
  VPIO disabled on the affected OS until the shipped-path gate is met.

### Phase 1 — curative slice selected by Phase 0

Implement only the smallest change that Phase 0 proves removes the trigger: AVFoundation isolation,
off-main listener ownership, or dictation quiescence. Re-run the same isolation condition before
combining architectural changes. Keep a kill switch for the VPIO path so rollback does not require a
new build; never use the switch to bypass incomplete teardown. This phase may retarget existing listener
owners directly and must not wait for the hub/ledger architecture.

### Phase 2 — listener discipline and transition suspension

Move all FluidVoice Core Audio listener delivery off main, prohibit add/remove from the delivery queue,
and suspend per-device reconciliation across start/stop/switch. Migrate one complete owner at a time;
never leave an owner half hub/half legacy. Both listener add and remove paths get runtime diagnostics.

### Phase 3 — real topology ownership and handoff

Add the coordinator state machine and dependency protocols. Make meeting acquisition async: suppress
events, reuse the existing cancel/drain barrier, retire prewarm, then start VPIO. Cover start, stop,
VPIO↔SCK backend switches, service restart, cancellation, and quarantined failure. Reverse the sequence
before exactly one dictation reconciliation/prewarm.

### Phase 4 — identity/backend separation

If not already selected as Phase 1, remove AVFoundation discovery/default/authorization calls from the
online VPIO transition. Resolve AVFoundation IDs only inside in-room or SCK adapters after topology
handoff. Test device replacement where an object ID changes but the Core Audio UID remains stable.

### Phase 5 — system validation and rollout

- statistically justified automated start/stop cycles with idle prewarm and detector enabled;
- input/output matrix: built-in, USB, Bluetooth, and mismatched input/output routes;
- device disconnect, default-route change, sleep/wake, and audio-service restart during every state;
- Zoom desktop, Google Meet in Chrome, and Teams desktop while application audio is active;
- main-runloop stall budget and zero overlap assertions from signposts;
- two-hour meeting soak followed by successful dictation handback;
- fallback and rollback verification with no permission/signing changes.
- forced VPIO→SCK downgrade and dwell-based SCK→VPIO upgrade under Bluetooth/output-route changes;
- hotkey input during post-meeting handback and `failedQuarantined` behavior;
- own VPIO activity produces no meeting-detection prompt;
- listener ledger count returns to baseline after selected-microphone unplug and service restart.
- a privacy-safe off-main main-runloop watchdog is active at meeting start/stop/switch boundaries and
  persists only phase/generation/timing plus a next-launch VPIO-disable marker; it records no audio,
  transcript, meeting title, device name, or application/window title.

## 11. Acceptance criteria

- No main-thread hang on any shipped capture path. A VPIO-only harness hang is an acceptable diagnostic
  outcome only when VPIO is disabled on that affected OS and the shipped SCK path passes its gates.
- Every Phase 0-positive targeted harness row has zero failures in at least 2,995 independent post-fix
  cycles, bounding per-start hang probability to at most 0.1% at 95% confidence; the real-device matrix
  additionally has zero hangs in at least 100 cycles per representative route.
- Runtime instrumentation reports no FluidVoice Core Audio listener add **or remove** using
  `DispatchQueue.main`, and no removal from its listener's delivery queue.
- No ASR prewarm or route-recovery start while the topology coordinator is meeting-owned.
- At most one coalesced dictation reconciliation after meeting handback.
- Meeting start or backend switch either commits healthy capture or returns a bounded error after
  fully observed rollback; incomplete teardown enters `failedQuarantined` and does not reopen audio.
- Dictation behavior before and after a meeting passes its existing integration tests and real-device
  smoke matrix.
- Instrumentation proves zero overlap among dictation prepared/running/recovering and meeting
  preparing/recording/switching/stopping states using matched interval signposts checked by tests.
- The production off-main heartbeat records a next-launch quarantine marker when main stalls during an
  audio transition and never attempts recovery from the frozen process.

## 12. Apple documentation basis

- [`AudioObjectAddPropertyListenerBlock`](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock%28_%3A_%3A_%3A_%3A%29)
  retains the supplied dispatch queue until matching removal and documents asynchronous delivery except
  for I/O-context properties.
- [`AudioObjectRemovePropertyListenerBlock`](https://developer.apple.com/documentation/coreaudio/audioobjectremovepropertylistenerblock%28_%3A_%3A_%3A_%3A%29)
  requires the queue on which the listener was dispatched, supporting an explicit registration ledger.
- [`setVoiceProcessingEnabled`](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled%28_%3A%29)
  is the supported AVAudio I/O-node boundary for enabling voice processing.
- [`AVCaptureDevice.DiscoverySession`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession)
  materializes the currently available capture devices and can monitor device-list changes.
- [`SCStreamConfiguration`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
  supports microphone capture. The installed SDK's `SCStream.h` specifies that
  `microphoneCaptureDeviceID` is an `AVCaptureDevice.uniqueID`.

## 13. Review status

Initial independent verdicts were all **REVISE**:

- Fireworks Kimi K3 through OpenCode: `REVISE`;
- xAI Grok 4.6: the Orchestrate route failed before producing analysis; a direct Grok 4.6 continuation
  then returned `REVISE` without modifying files;
- Claude Opus 5 through Orchestrate: `REVISE`.

### Consensus accepted

- Two parked stacks are consistent with, but do not prove, a closed circular wait. Resolve HAL's sync
  target before naming the final cycle.
- Direct prewarm invalidation and scheduled recovery prove an ownership gap, not participation in the
  observed wait. The direct lifecycle's dedicated listener/control queues are a pattern to preserve.
- FluidVoice's per-device listener add/remove on main is the strongest app-owned participant hypothesis
  and must be isolated before building a coordinator around an assumed cause.
- AVFoundation identity/materialization can be the whole trigger; the VPIO path must be tested without
  it, and authorization lookup inside `MeetingMicrophoneCapture.start` must leave the transition.
- Phase order must follow the isolation result. “Coordinator first” was removed.
- Backend switches, service restart, incomplete rollback, Bluetooth behavior, detector self-activity,
  and post-meeting hotkeys require explicit topology states and tests.

### Review disagreements resolved

- One review inferred that auto-detection was absent because its source is untracked and absent from
  repository `HEAD`. That inference is rejected: the second incident's installed-app log explicitly
  records `MeetingAutoDetector detector-started` before the freeze. It remains an active incident-build
  listener owner. The installed build predating the later overlay work does not imply it predates the
  detector work.
- Reviewers differed on whether a global hub/coordinator is oversized. This revision makes the curative
  BUG-001 slice evidence-dependent and narrows the hub to a registration ledger plus transition-event
  coalescer. The full topology state machine remains required for the already-existing VPIO↔SCK switch
  paths, but it is not allowed to delay the Phase 0-proven curative change.

### Final gate and closure

The first post-revision gate returned Kimi `APPROVE`, Opus `APPROVE` with five blocking clarifications,
and Grok `REVISE`. The final clarifications are incorporated:

- AVFoundation object/listener retention moved from proven to inferred;
- the decision gate now handles multiple positive rows and zero reproduction;
- the Phase 1 listener slice explicitly does not wait for a hub;
- SCK→VPIO requires app-owned AVFoundation release plus an observed barrier and can be prohibited
  in-process when retained framework state is hazardous;
- `stableDictationActive`, next-launch quarantine for a dead main loop, a production off-main watchdog,
  and numerical statistical gates are defined.

Grok's final closure review returned **APPROVE** with no remaining implementation blockers. Final
review state: **Kimi APPROVE, Opus APPROVE, Grok APPROVE**.

### Rebase-regression addendum review

The later rebase analysis initially returned **REVISE** from both Kimi K3 and Grok 4.6. Their accepted
corrections demote `2dce5cd` from a claimed trigger to an unconfirmed rebase-introduced suspect, keep
AVFoundation+VPIO co-equal, add `3e04401`, split the ledger from its consumer, control detector state,
require token-to-dying-object correlation, add transient-device exclusion, and define statistical and
falsification gates. Claude Opus was not rerun for this addendum because the current repository
disclosure policy/tool gate permits relevant source and diffs only to Kimi and Grok; the previous Opus
approval applies to the base RCA, not this addendum.

After those corrections, the final rebase-addendum gate returned **Kimi APPROVE** and
**Grok APPROVE**, with no remaining regression-analysis blockers.

### Production mitigation closure

Subsequent Phase 0 rows isolated aggregate membership in `AudioHardwareObserver`'s broad
`DeviceIsAlive` ledger as the narrowest passing condition. The production implementation now filters
only `kAudioDeviceTransportTypeAggregate` before both the ledger's removal set and add loop. It is
unconditional in Debug and Release; diagnostic flags are not required. Non-aggregate monitoring,
system/default-device listeners, liveness queries, and ASR's selected-device listener remain unchanged.

Final validation completed:

- normal dictation and three meeting start/stop cycles passed on the production-shaped A/B build;
- 185 scoped meeting/dictation/diagnostic tests passed, with one expected opt-in hardware skip;
- the Release configuration and canonical Apple-signed Debug build both compiled successfully;
- Kimi K3 and Grok 4.6 approved the scoped production policy; Claude Opus's requested evidence wording
  and detector-provenance corrections are incorporated here; and
- the installed `/Applications/FluidVoice Debug.app` retained the same bundle ID, Team ID, Apple
  Development identity, and designated requirement, and passed strict deep signature verification.

This closes the reproducible incident with an evidence-scoped mitigation. It does **not** close the
entire private HAL deadlock class or satisfy the 2,995-cycle statistical reliability gate. Dedicated
off-main Core Audio listener lifecycle ownership, live USB/Bluetooth/iPhone hot-plug acceptance, and
the long-run reliability gate remain explicit follow-up work.
