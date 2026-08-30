# Meeting Detector Phased Implementation Plan

Status: proposed after implementation grounding; pending adversarial PE review
Parent design: `MEETING_DETECTION_NOTIFICATION_DESIGN.md`
Scope: calendar-independent detector, in-app notification lifecycle, and safe meeting-end assistance
Delivery rule: no automatic recording; no system notifications until the in-app path passes dogfood gates

## 1. Objective

Replace the current mixed signal/state/UI pipeline with a trustworthy detector that:

- observes microphone devices and application audio correctly;
- combines only fresh, same-target evidence;
- requires positive stability before suggesting capture;
- models one durable episode instead of emitting isolated prompts;
- withdraws stale reminders and revalidates immediately before recording;
- supports passive menu-bar recovery and explicit user controls;
- fails closed when browser privacy state or required evidence is unreadable;
- keeps all detection and evaluation data local by default.

This plan changes architecture before expanding application coverage. Calendar integration and automatic recording remain out of scope.

## 2. Verified baseline

### 2.1 Current data flow

```text
NSWorkspace / CoreAudio / CGWindow / Accessibility
                         ↓
            MeetingAutoDetector @MainActor
     records + evidence + episodes + policy + polling
                         ↓
        MeetingDetectionPromptController @MainActor
                         ↓
            AppServices start transaction
                         ↓
            MeetingSessionCoordinator
```

Current implementation files:

- `Sources/Fluid/Services/Meeting/MeetingAutoDetectSignals.swift`
- `Sources/Fluid/Services/Meeting/MeetingAutoDetector.swift`
- `Sources/Fluid/Services/Meeting/MeetingAppRegistry.swift`
- `Sources/Fluid/UI/MeetingDetectionPrompt.swift`
- `Sources/Fluid/Services/AppServices.swift`
- `Sources/Fluid/Services/MenuBarManager.swift`
- `Sources/Fluid/Persistence/SettingsStore.swift`
- `Sources/Fluid/UI/MeetingTranscriptionView.swift`
- `Tests/FluidDictationIntegrationTests/MeetingAutoDetectorTests.swift`

The application target uses a file-system-synchronized source group. Test files still require explicit Xcode project membership.

### 2.2 Baseline verification

Focused command:

```sh
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/MeetingAutoDetectorTests \
  CODE_SIGNING_ALLOWED=NO
```

Verified result on 2026-08-22: 48 tests, 0 failures.

### 2.3 Worktree constraint

The detector sources, prompt, tests, and design documents are currently untracked while related application wiring is modified in an already-dirty worktree. Those changes are the working baseline and must not be staged, committed, reset, or cleaned as part of implementation without an explicit user request.

Before the first edit of every phase:

1. record `git status --short --untracked-files=all` and a complete target-file inventory;
2. after one scoped filesystem approval, copy only the phase’s target files into a stable local development archive outside the repository and outside purgeable temporary storage;
3. record SHA-256 hashes plus the pre-phase list of files that do not yet exist;
4. record `project.pbxproj` changes as a targeted patch only; never restore that already-dirty file wholesale;
5. after the phase, review tracked diffs, the targeted project patch, every created file, and full contents of untracked target files;
6. never touch unrelated media, render scripts, or meeting work.

Runtime rollback uses an injected detector policy mode. File rollback is a targeted, reviewed reversal using the stable archive and created-file manifest, never a bulk restore or destructive Git command. Persisted settings migrations must remain readable by the previous runtime mode.

## 3. Non-negotiable invariants

Every phase must preserve these:

1. No recording without an explicit user action.
2. No raw browser URL, window title, participant data, device name, or transcript text in logs or diagnostics.
3. Audio-only, window-only, and generic-browser-only evidence never trigger a floating reminder.
4. Busy dictation, file transcription, or meeting capture is never interrupted or replaced.
5. A candidate and capture target belong to the same canonical application family.
6. Start is single-flight and succeeds only after fresh evidence and capture readiness pass.
7. Loss of one signal never automatically stops an active recording.
8. Lock, sleep, fast-user-switch, and monitor restart clear or demote transient authority.
9. Existing manual meeting capture and transcription behavior remains unchanged.
10. Each phase has an independent disable/rollback path and passes focused tests before the next begins.
11. FluidVoice process audio is never eligible meeting evidence. When FluidVoice holds any exclusive audio lease, aggregate-input fallback loses start/end authority; device-level aggregation cannot distinguish ownership and must not be treated as self-excluded.

## 4. Locked technical decisions

### 4.1 Time model

Live detector ordering uses `DetectorInstant`, a wrapper over `ContinuousClock.Instant`, not `Date`. `ContinuousClock` advances across system sleep, so every pre-sleep fact expires after wake. `SuspendingClock` is forbidden. Reducer events carry detector instants supplied by an injected clock. Wall time is used only for persisted user preferences such as “pause until tomorrow.”

This prevents clock changes, timezone changes, and wake correction from creating false freshness or end decisions.

### 4.2 Signal identity

Process audio observations are not attached directly to a UI process PID. They first map to a canonical application family because helper processes may own audio for a different main application process.

```swift
struct ApplicationAudioObservation {
    let audioObjectID: AudioObjectID
    let processID: pid_t?
    let observedBundleIdentifier: String
    let canonicalFamily: MeetingApplicationFamily
    let inputActive: Bool
    let outputActive: Bool
    let observedAt: DetectorInstant
}
```

The registry owns helper-to-family mapping. Window and browser correlation then resolve the main UI process and exact capture target.

### 4.3 Snapshot and generation model

`MeetingSignalMonitor` is the sole producer of immutable snapshots from Phase 2 onward. Every refresh has a monotonic generation minted inside the actor. Async results carry the generation that requested them and are dropped if superseded.

Generation prevents stale async writes; freshness thresholds still apply within accepted snapshots. Neither replaces the other.

HAL listeners run on one dedicated serial queue and yield ordered events through an `AsyncStream` consumed by the monitor actor; callbacks never create unordered unstructured tasks. The actor permits at most one refresh pass in flight. Concurrent requests coalesce, with a pending-priority bit requesting the next pass. Blocking provider work runs in cancellable child tasks and returns values to the actor; no provider mutates monitor state.

A priority snapshot request races its deadline outside the actor. It may use a completed snapshot only when its relevant facts are no more than one second old. Otherwise it returns `deadlineExceeded` and revalidation fails closed. It never waits indefinitely behind a suspended actor refresh.

### 4.4 Reducer boundary

`MeetingEvidenceReducer` is pure:

```text
old state + timestamped event + policy → new state + effects
```

It does not call CoreAudio, Accessibility, `NSWorkspace`, settings, logging, or capture readiness. Effects such as `candidateConfirmed`, `reminderInvalidated`, and `episodeEnded` are handled outside the reducer.

Capture readiness is notification policy, not meeting identity. A confirmed meeting can exist while capture needs setup.

### 4.5 Rollout modes

Use an internal injected mode, not a remote flag:

- `legacy`: current detector is authoritative;
- `shadow`: legacy is authoritative, new reducer records redacted decisions only;
- `nativeV2Dogfood`: new reducer is authoritative only for explicitly enrolled users and validated native families; other users remain legacy;
- `browserShadow`: native V2 remains authoritative where enabled while V2 browser adapters record counterfactual decisions only;
- `v2`: new reducer is authoritative for every validated adapter.

Policy mode selects the decision engine; the per-family/per-adapter support matrix independently selects eligibility. Both must permit a candidate. Production defaults change only at explicit phase exit gates. The legacy path remains for one dogfood release after default-on native cutover and is never deleted while its only durable copy is untracked.

### 4.6 Document precedence

Where this plan and `MEETING_DETECTION_NOTIFICATION_DESIGN.md` state different implementation values, this plan governs. Amend the design in the same change so both documents state the same value.

## 5. Dependency graph

```text
Phase 0: feasibility probes + contracts
        ↓
Phase 1: correct signal semantics
        ↓
Phase 2: monitor snapshots + pure reducer
        ↓
Phase 3: shadow evaluation + local diagnostics
        ↓
Phase 4: native cutover + fresh start revalidation
        ↓
Phase 5: notification lifecycle + controls
        ↓
Phase 6: browser privacy adapters
        ↓
Phase 7: end assistance + legacy removal
        ↓
Phase 8: optional system notifications
```

Phase 6 may be delayed without blocking the native detector. Phase 8 is a separate release decision.

## 6. Phase 0 — Feasibility probes and contracts

### Goal

Validate public API assumptions before rewriting production state. Produce evidence, not product behavior.

### Work packages

#### P0.1 CoreAudio process probe

Build a debug-only probe that samples the CoreAudio process object list and records redacted transitions for:

- input and output selectors independently;
- primary meeting application and helper-process bundle mapping;
- process object/PID stability across join, mute, unmute, leave, relaunch, and application audio playback;
- observation latency at one-, two-, and five-second polling cadences;
- unavailable selector/error behavior.

No process path or user data may be logged.

#### P0.2 Device aggregation probe

Observe built-in input, external input, device switching, aggregate devices, and device removal. Verify:

- stable device IDs during one run;
- aggregate zero→nonzero and nonzero→zero semantics;
- one device stopping does not emit global inactive while another remains active;
- loopback devices can be excluded by stable UID or owned-device metadata, never display-name matching.

#### P0.3 Background-call probe

Move only probe queries for process objects and window snapshots to a utility executor. Exercise rapid app switching, sleep/wake, and repeated refresh to confirm no deadlock, crash, or main-thread dependency.

#### P0.4 Browser privacy spike

For each intended browser adapter, determine whether a private window can be identified reliably through supported local state. The probe report must name the mechanism and permission boundary for that adapter:

- bounded Accessibility attributes that require existing Accessibility access;
- Apple Events only where a documented browser dictionary exposes the needed state and the user explicitly authorizes the resulting Automation TCC prompt;
- no process-argument scraping, private API, title-string guessing, or UI-language matching.

Return `supported`, `permissionMissing`, or `unsupported`; do not collapse permission denial into an unsupported browser. Test normal/private windows, multiple profiles, PWAs, and minimized windows. A validated browser/version still performs a runtime capability assertion at launch. Unknown/new versions and unknown private state fail closed until revalidated.

Automation probes change real TCC state and are excluded from the first execution slice. They run only in a separately announced, user-consented probe. Fail criterion: if private state cannot be distinguished reliably, that adapter is marked unsupported for V2 notifications. Do not weaken the privacy contract.

#### P0.5 Contract types

Add or draft the core value types and protocols with no production wiring:

- `DetectorInstant` and `MeetingDetectionClock`;
- `MeetingApplicationFamily` and helper mapping;
- `ApplicationAudioObservation`;
- `AggregateInputObservation`;
- `DetectionCapabilities` and `MonitorHealth`;
- `MeetingSignalSnapshot`;
- `MeetingDetectionPolicyMode`.

### Files

Prefer new debug/test files plus narrowly scoped types in `MeetingAutoDetectSignals.swift` and `MeetingAppRegistry.swift`. Do not change confirmation or notification behavior.

### Tests

- selector error/unsupported mapping;
- canonical helper-family mapping;
- monotonic clock fixture;
- capability state mapping;
- probe output redaction;
- no network dependency.

### Exit gate

- Input/output selectors behave independently on the supported deployment target.
- Off-main HAL and window queries complete a repeated stress probe without UI stalls or deadlock.
- Device aggregation and loopback exclusion have stable identifiers.
- Every browser has an explicit supported/unsupported privacy result.
- The supported application deployment target is macOS 15.0; pre-14.4 behavior is not a product path. Availability guards remain defensive and report unsupported health rather than broad fallback.
- Existing 48 detector tests remain green.

If any native API assumption fails, revise the evidence matrix before Phase 1; do not add heuristics to hide the failure.

### Rollback

Phase 0 is additive and unreachable in Release. Disable the debug affordance and reverse only the probe/type additions using the phase manifest. TCC changes are not rolled back by file restoration, which is why Automation probing is a separate user-consented action with its state recorded in the report.

## 7. Phase 1 — Correct signal semantics

### Goal

Fix observation truth while preserving the current authoritative detector behavior.

### Work packages

#### P1.1 Aggregate microphone state

Replace per-device Boolean edges with snapshots or edges containing device identity. `CoreAudioMicActivitySignal` maintains the active eligible-device set and emits only aggregate transitions.

Device list changes perform a resync before emitting. Sleep/wake and service restart reset authority until the resync completes.

#### P1.2 Structured process audio

Replace `AudioProcessActivityProviding.isAudioActive(...) -> Bool` with a structured observation API returning input/output separately, source health, generation, and observation time.

The provider reports every relevant family in one process-list pass rather than enumerating the process list once per candidate PID.

FluidVoice and its helper processes are excluded before canonical-family mapping. Aggregate device state remains observable, but the compatibility adapter cannot use it as meeting evidence while `DetectionActivityGate` reports any FluidVoice audio activity.

#### P1.3 Fresh foreground facts

All activation evidence receives an explicit expiry. Remove the `lastFrontmostAt != nil` shortcut for process audio. Direct same-family input ownership may confirm in the later reducer without requiring foreground state; weaker fallback rules require recent activation.

#### P1.4 Move blocking reads off-main

CoreAudio process enumeration and CG window snapshots execute outside `@MainActor`. Main-actor bridges deliver immutable values only. Keep HAL listener callbacks minimal and never synchronously wait on the main actor.

### Files

- `MeetingAutoDetectSignals.swift`
- `MeetingAppRegistry.swift`
- `MeetingAutoDetector.swift` as a compatibility adapter
- `MeetingAutoDetectorTests.swift`

### Tests first

- device A active + device B stops → aggregate remains active;
- last active device stops → exactly one aggregate inactive edge;
- device added/removed during activity;
- excluded loopback never changes aggregate state;
- input-only, output-only, both, and neither observations;
- helper process maps to the correct canonical family;
- stale activation cannot satisfy an attribution gate;
- one process enumeration serves multiple candidates;
- generation rejects an old completion after resync.

### Exit gate

- Existing visible prompt outcomes remain unchanged for the old fixtures.
- New multi-device and directionality tests pass.
- Thread sanitizer/debug stress shows no cross-actor violation in the signal path.
- No synchronous CoreAudio enumeration or full window snapshot runs on the main actor.
- Focused suite and full application build pass.

### Rollback

Switch policy mode to `legacy` using the compatibility adapter. Reverse Phase 1 signal changes through the reviewed stable archive/targeted patch if the compatibility layer itself is faulty.

## 8. Phase 2 — Snapshot monitor and pure episode reducer

### Goal

Create the V2 state machine without changing which path shows reminders.

### Work packages

#### P2.1 `MeetingSignalMonitor`

Create a background actor that owns:

- relevant running-app state;
- adaptive polling cadence;
- immediate rate-limited refresh after aggregate device edges;
- process audio observations;
- native window and browser correlation requests;
- capability health and watchdog state;
- snapshot generation.

Cadence defaults:

- one second while stabilizing or recording;
- one second while any relevant application is running, unless a proven process-audio push signal supplies equivalent latency;
- thirty seconds only when push listeners are healthy and no relevant application is running.

Relevant-application launch, process-audio edge when available, aggregate-device edge, service restart, and wake request an immediate rate-limited refresh. Detection latency is measured from the first observable valid combination; the probe report also records the worst unobserved interval.

Cadence is injected and testable. It is not a collection of inline sleep literals.

#### P2.2 Canonical candidate identity

Use:

```text
family + process launch identity + ephemeral meeting locator + locator generation
```

PID/window-number reuse cannot reuse an ended episode. Browser locators become session-random digests before entering state.

#### P2.3 Pure reducer

Implement candidate states:

```text
idle → observing → stabilizing → confirmed → presented
                                      ↓          ↓
                                    ending ← accepted/dismissed/timedOut
                                      ↓
                                    ended
```

Encode application-family policies as data. Do not scatter family-specific branches through the reducer.

Initial policies:

- meeting-specific native window + same-family input/output: 4 seconds;
- generic persistent native window + same-family input: 6 seconds;
- generic persistent window + output + recent activation + call marker: 8 seconds;
- fallback aggregate mic + recent activation + qualifying marker: 8 seconds, medium/passive only;
- audio-only, marker-only, or generic browser audio: never confirm.

Pre-capture evidence loss invalidates a confirmed/presented effect after three seconds. Episode end uses a longer independent absence policy.

#### P2.4 Effect adapter

Reducer effects are translated into callbacks by a thin coordinator. In `shadow` mode, visible callbacks are discarded and only redacted comparisons are recorded.

At Phase 2 wiring, the legacy detector stops owning independent CoreAudio/window polling. A compatibility adapter derives its legacy Boolean/window inputs from `MeetingSignalMonitor` snapshots. Shadow mode therefore compares decision engines over one observation stream rather than running two sensor stacks.

### New files

- `MeetingSignalMonitor.swift`
- `MeetingEvidenceReducer.swift`
- `MeetingCandidateModels.swift`
- `MeetingDetectionPolicy.swift`
- `MeetingDetectionTrace.swift`
- `MeetingEvidenceReducerTests.swift`

Update the Xcode test target for every new test file.

### Tests

- table-driven policy cases for every evidence combination;
- stability boundary at threshold minus/at/plus one tick;
- signal flap resets stability;
- negative grace cancels a visible reminder effect;
- duplicate snapshots and out-of-order generations are idempotent;
- PID/window reuse creates a new identity only after end;
- back-to-back same-window meetings rearm;
- two candidates remain independent;
- lock/wake/service restart demotes authority;
- property test: no event sequence emits `startRecording`;
- property test: at most one present effect per episode;
- trace events contain only allowed enums/tokens.

### Exit gate

- Reducer tests are deterministic with no sleeps.
- Legacy and V2 paths run together with only legacy producing UI.
- Every V2 decision has a redacted reason code.
- The new path adds no measurable main-thread polling work.
- Existing detector and capture tests remain green.

### Rollback

Set mode to `legacy` while keeping the shared monitor and compatibility adapter. If the monitor itself is faulty, disable the detector globally and reverse only Phase 2-created files plus targeted compatibility wiring using the phase manifest; do not restart the removed dual poller as an emergency path.

## 9. Phase 3 — Shadow dogfood and local evaluation

### Goal

Measure V2 precision and disagreements before making it authoritative.

### Work packages

#### P3.1 Redacted comparison trace

Record, in memory by default:

- candidate token;
- registry family category;
- evidence classes;
- legacy/V2 decision and transition;
- suppression reason;
- capability/health class;
- monotonic time delta.

Never store raw URL/path, title, bundle path, device name, PID in export, or meeting locator digest.

#### P3.2 Debug diagnostics

Add a debug-only local view to:

- inspect detector health;
- see legacy/V2 disagreement counts;
- label sampled episodes `meeting`, `not a meeting`, or `unsure`;
- clear local diagnostics;
- explicitly export a redacted report.

Production history remains memory-only and clears at launch. Seven-day persistence is allowed only after explicit dogfood enrollment.

Dogfood persistence uses an application-support subdirectory protected by the current user account, bounded by seven days and 5,000 redacted transitions. Disabling enrollment deletes it immediately. Export is an explicit copy action; raw identifiers never enter the stored buffer, so export has no second redaction boundary.

#### P3.3 Replay corpus

Convert redacted labelled transitions into deterministic, content-free fixtures. Include:

- join muted/unmuted;
- ringtone and ordinary app playback;
- waiting room and pre-join test;
- persistent home window;
- background call;
- device switch;
- sleep/wake;
- two simultaneous applications;
- process or audio-service restart;
- app relaunch and ID reuse.

### Files

- `MeetingDetectionTrace.swift`
- new debug diagnostics view/model
- `MeetingEvidenceReducerTests.swift`
- fixture resources and loader
- narrowly scoped settings for dogfood enrollment only

### Preliminary opt-in cutover gate

Per native application family:

- at least 30 labelled V2 counterfactual confirms from the local digest;
- at least 15 labelled V2 non-confirm/passive candidates;
- at least 80% requested-label response rate;
- observed counterfactual precision at least 90%;
- no start-safety, duplicate, privacy, or stale-generation violation;
- p90 confirmation under ten seconds;
- all named replay families pass.

This gate permits only explicit `nativeV2Dogfood`; it does not change production defaults. Labels apply to V2 counterfactual confirms whether or not the legacy path displayed a prompt. Silence and `unsure` are excluded and label-response rate is reported.

### Default-on rollout gate

Per family: at least 150 labelled V2 counterfactual confirms, 75 labelled non-confirm candidates, 70% response, observed precision at least 92%, and 95% Wilson lower bound at least 86%. If volume is unreachable, the family remains opt-in; time alone never relaxes the gate.

If either gate is not met, revise policy data and replay tests, then repeat shadow evaluation. Do not cut over on aggregate accuracy alone.

### Rollback

Disable dogfood enrollment and clear the redacted store. Shadow decisions stop, legacy remains authoritative, and no user-facing setting migration has occurred.

## 10. Phase 4 — Native V2 cutover and fresh start revalidation

### Goal

Make V2 authoritative only for explicitly enrolled dogfood users and validated native families, with a minimal passive/floating choice before any V2 interruption.

### Work packages

#### P4.1 Family-scoped cutover

`nativeV2Dogfood` routes only validated native families through V2 for enrolled users. Enrollment explicitly chooses Passive or Floating; Passive is the default. Add an immediately available Pause control before enabling Floating. Unsupported or degraded families stay silent rather than falling back to broad Boolean logic. Non-enrolled users remain legacy until the default-on gate passes.

Phase 4 includes the minimum passive surface by extending the existing `MenuBarManager`: one neutral possible-meeting item, Start, Not now, and Pause. It does not create a second status item. Phase 5 adds migration, exclusions, multi-candidate menus, explanations, and full presentation policy.

#### P4.2 Prompt invalidation

Reducer `reminderInvalidated` effects call the existing `MeetingDetectionPromptController.invalidateEpisode`. Visible and suppression-pending reminders withdraw within three seconds of invalid evidence.

#### P4.3 Fresh revalidation transaction

Extend the existing `AppServices.startAutoDetectedRecording` seam as a cancellable race between episode liveness, deadline, and capture start:

1. freeze episode and reject duplicate taps;
2. request a priority snapshot with a two-second deadline;
3. require a current start-eligible policy for the same episode identity;
4. resolve the exact live application/window target;
5. recheck capture permissions, storage, and FluidVoice activity;
6. create capture configuration;
7. recheck episode and target once more;
8. start capture while subscribing to episode/target invalidation;
9. if the target dies before the capture engine reports a live exact source, cancel/stop startup, discard any empty provisional session, leave the episode unconsumed, and show “The call no longer appears active”;
10. mark accepted only after the exact source reports success and the episode remains eligible.

The priority refresh API is cooperatively cancellable. Deadline expiry returns `deadlineExceeded` and fails closed; it never falls back to an arbitrarily old cached snapshot.

If evidence ended, close the reminder with “The call no longer appears active.” If the exact target is ambiguous, open source selection with candidates preselected. Never silently fall back to another application.

#### P4.4 Episode outcomes

Change semantics:

- explicit Not now: suppress current episode until end;
- timeout: prevent another floating panel but retain passive eligibility for Phase 5;
- capture failure: do not consume the episode;
- successful capture: accept the episode and suppress other interruptions while busy.

Remove the current bundle-wide 30-minute dismissal from the authoritative V2 path. Preserve it only inside legacy mode until legacy deletion.

#### P4.5 First-capture consent reminder

Before the first capture started from a suggestion, show the one-time local participant-consent/organization-policy reminder. Persist acknowledgment separately from detector mode. Cancellation leaves the episode live and does not start capture.

### Files

- `MeetingAutoDetector.swift` or its new coordinator replacement
- `MeetingDetectionPrompt.swift`
- `AppServices.swift`
- `MenuBarManager.swift` for the minimum passive dogfood surface
- dogfood-only suggestion-mode/Pause settings
- reducer/effect models
- detector and AppServices-focused tests

### Tests

- signal loss during visible reminder invalidates it;
- signal loss during fullscreen suppression invalidates pending state;
- fresh snapshot timeout fails closed;
- target changes before click;
- target disappears during configuration;
- capture failure permits retry while episode remains live;
- repeated click is single-flight;
- Not now and timeout differ;
- busy activity remains untouched;
- native family cutover cannot activate an unvalidated family.

### Exit gate

- Zero capture starts after stale/failed revalidation.
- 100% of starts use the exact validated target.
- Stale visible/pending reminder withdrawal is at most three seconds.
- Existing manual capture tests pass unchanged.
- Runtime rollback to `legacy` is verified in a debug build.
- Explicit dogfood users can choose Passive before V2 activation and Pause immediately.
- Unwanted floating reminders remain at or below one per active enrolled user-week median and two at the 75th percentile.
- Any privacy, accidental-start, exact-target, duplicate, or stale-reminder stop condition returns the affected family to `shadow`.

### Rollback

Set enrolled users back to `shadow`; non-enrolled users were never cut over. Passive/Floating choice, Pause, and consent acknowledgment remain backward-readable but have no authority in legacy. Cancel any V2 prompt or pending start before changing mode.

## 11. Phase 5 — Notification lifecycle, passive recovery, and controls

### Goal

Complete the user-facing in-app notification policy without system notifications.

### Work packages

#### P5.1 Settings migration

Add typed settings for:

- suggestion mode: `passive` or `floating`;
- pause-until;
- excluded native families;
- excluded browser providers;
- “suggest only when my microphone is active”;
- end-nudge preference;
- setup-reminder dismissal by capability.

Migration:

- existing install with detector explicitly enabled → `floating`;
- existing install with detector disabled → preserve disabled state;
- new install → `passive`;
- browser remains separate opt-in;
- migration has an idempotent version marker and tests for absent/corrupt/old values.

#### P5.2 Reuse `MenuBarManager`

Extend the existing `NSStatusItem`; do not create a second status item.

Add a meeting suggestion presentation separate from active recording presentation:

- neutral icon/accessibility status;
- primary possible-meeting item with Start action;
- other candidates submenu;
- Not now, Pause, and source-exclusion actions;
- passive action persists until episode end, explicit Not now, exclusion, or capture start;
- active recording status remains higher priority than suggestions.

#### P5.3 Floating reminder policy

- shown only in floating mode for high-confidence candidates;
- never steals focus;
- one visible panel at a time;
- 30-second panel timeout preserves passive menu recovery;
- hover/keyboard interaction pauses timer;
- fullscreen other app, quiet mode, dictation overlay, or busy activity suppresses panel but preserves passive recovery;
- evidence loss removes both surfaces after the end grace;
- setup reminders follow `notDetermined`/`denied`/`restricted` semantics and never nag after explicit decline.
- place the panel on the display containing the detected application/window when resolvable, otherwise the active display;
- Snooze 10 minutes hides the current panel, preserves passive recovery, prohibits another panel for that episode, and keeps other candidates passive until expiry;
- “Why this appeared” shows only coarse evidence classes from the already-redacted decision record.

#### P5.4 Arbitration

Rank one floating candidate by:

1. confidence band;
2. same-process input ownership;
3. meeting-specific locator;
4. capture readiness;
5. most recent stable transition.

Other candidates remain separately selectable in the menu. Accepting one never merges or ends another episode.

### Files

- `SettingsStore.swift`
- `MeetingTranscriptionView.swift`
- `MenuBarManager.swift`
- `MeetingDetectionPrompt.swift`
- `AppServices.swift`
- new notification policy/controller tests

### Tests

- every settings migration path;
- Pause expiry never re-presents an existing episode;
- timeout keeps passive action; Not now removes it;
- exclusions take effect immediately and persist;
- active recording overrides suggestion icon/menu state;
- simultaneous candidate ranking and selection;
- fullscreen/quiet/busy suppression preserves passive state;
- permission dismissal is sticky until manual setup action;
- Snooze expiry never re-presents the existing episode;
- Why-this-appeared contains no raw observed values;
- multi-display placement follows the detected target with active-display fallback;
- menu actions and labels are keyboard/VoiceOver accessible;
- Reduce Motion path;
- one status item only.

### Exit gate

- Task tests confirm users can identify recording state, capture source, Start, Not now, and Stop.
- No duplicate in-app surfaces for one episode.
- Median unwanted floating reminders is at most one per active dogfood user-week.
- Source exclusions and Pause are immediately effective.
- No permission-repair repeat after denial or explicit decline.
- Existing menu-bar recording/processing states remain correct.

### Rollback

Disable V2 user-facing delivery and return enrolled users to `shadow`. New settings use backward-compatible defaults and remain inert in legacy. Remove suggestion menu items/panel state through targeted wiring reversal without replacing the existing `NSStatusItem` or reverting unrelated `MenuBarManager` work.

## 12. Phase 6 — Browser adapters and privacy cutover

### Goal

Move browser detection to V2 only for adapters that pass the Phase 0 privacy spike.

### Work packages

#### P6.1 Adapter interface

Each adapter returns only:

- supported provider enum;
- allowed meeting-locator classification;
- session-random locator digest;
- private-window status;
- health/availability;
- observation generation and time.

Raw URL/title values stay inside the adapter call and are discarded immediately.

#### P6.2 Fail-closed support matrix

An adapter is enabled only when it can:

- read the current page within a bounded deadline;
- distinguish private state reliably;
- match the allowed provider/path locally;
- reject landing, post-call, media, and unrelated pages;
- avoid all-tab/history scanning;
- pass supported browser-version fixtures.

Unknown private state equals unavailable, not normal browsing.

#### P6.3 Browser policy

- browser process input/output + verified current locator: five-second high-confidence candidate;
- temporary locator loss after verification: continuity for 15 seconds, never a new prompt;
- generic browser microphone ownership: no reminder;
- background/minimized behavior is supported only where the adapter retains a verified locator without broader tab collection;
- browser/native handoff ends or links episodes through explicit policy, never string similarity.

Every adapter begins in `browserShadow` while native V2 behavior remains unchanged. The local digest labels V2 browser counterfactual confirms directly; it does not infer truth from a legacy prompt. Only an adapter that passes the browser-specific preliminary and default-on gates advances to `v2` eligibility.

### Files

- `MeetingAutoDetectSignals.swift` split into adapter files if needed
- `MeetingAppRegistry.swift`
- new browser adapter/protocol files
- reducer policy tables
- browser fixture tests
- settings disclosure and provider exclusions

### Exit gate

Each browser/provider combination independently meets the Phase 3 precision and privacy gates. Failed adapters remain disabled without blocking native V2.

### Rollback

Set the affected adapter to unsupported and clear its ephemeral locator state. Native V2 remains unchanged. Persisted provider exclusions remain inert and backward-compatible; no raw browser state exists to migrate or restore.

## 13. Phase 7 — End assistance, health UX, and legacy removal

### Goal

Finish the detector lifecycle and remove temporary architecture after a stable rollback window.

### Work packages

#### P7.1 Conservative end assistance

While recording, continuation evidence includes any of:

- recent transcript output;
- exact capture target alive;
- same-family process input/output;
- verified meeting locator;
- qualifying native call marker.

After 60 seconds in which none of the above continuation signals is present—any one signal suffices—show one non-modal “Still recording?” nudge with:

- Stop recording;
- Keep recording.

State explicitly that stopping finalizes the local transcript. Keep recording suppresses further end nudges for that recording. No automatic stop.

#### P7.2 Health UX

Expose coarse capability states in Meeting settings:

- process attribution unavailable;
- monitor temporarily degraded;
- native window identity unavailable;
- browser adapter unavailable/private-state unsupported;
- capture permission missing.

Health never appears as evidence and never exposes observed content.

#### P7.3 Remove legacy path

After one stable dogfood release with no rollback:

- require the legacy implementation to have a user-authorized durable archive or Git commit before deletion; if it remains untracked-only, legacy deletion is blocked and the code stays in place;

- remove `legacy`/dual-decision code;
- remove legacy bundle-wide suppression;
- delete obsolete CandidateRecord/attemptConfirm state;
- keep replay fixtures as regression tests;
- retain a global detector disable switch as the operational kill path.

### Exit gate

- end nudge never auto-stops;
- recent transcript or transient mute prevents a premature nudge;
- Keep recording is sticky for that recording;
- degraded health is visible and actionable without prompting;
- full suite passes after legacy deletion;
- no dead legacy settings or migration paths remain.

### Rollback

End-assistance and health UI are independently disableable. Legacy removal has no runtime rollback and therefore occurs only after its durable-recovery precondition and a fresh user-authorized execution plan. Without that authorization, Phase 7 closes with legacy disabled but retained.

## 14. Phase 8 — Optional system notifications

This is deliberately outside initial detector completion.

Proceed only after Phase 5 notification burden and trust gates pass. Add a separate `System meeting notifications` preference, default off. Passive mode alone never opts a user into system delivery.

Reuse the authoritative episode, suppression, exclusion, and fresh-revalidation paths. The system and floating surfaces are mutually exclusive for one episode. Operating-system Focus behavior is inherited rather than inferred by FluidVoice.

### Rollback

Disable the separate system-notification preference, cancel pending detector notification requests by episode identifier, and retain in-app passive recovery. Notification permission state is operating-system state and is never treated as rolled back by code.

## 15. Cross-phase verification

### Per implementation slice

1. Run new unit tests for the slice.
2. Run `MeetingAutoDetectorTests`.
3. Run detector/reducer trace replays.
4. Build the application with code signing disabled.
5. Run `git diff --check` for tracked files and inspect full untracked target files.
6. Run a fresh adversarial code review before moving to the next phase.

### Phase gates

After Phases 1, 2, 4, 5, and 7:

- run the entire `FluidDictationIntegrationTests` target;
- compile detector changes with complete strict-concurrency checking and treat new warnings in changed files as failures;
- run a reentrancy/single-flight stress harness plus Thread Sanitizer; Thread Sanitizer alone does not prove actor isolation or prevent logical reentrancy;
- check CPU/wakeups in idle, relevant-app-running, stabilizing, and recording states;
- verify no detector network activity;
- inspect exported trace for forbidden fields;
- dogfood at least one native join muted, join unmuted, ordinary application playback, dismiss, timeout, capture start, and meeting leave.

### Main performance gates

- no synchronous HAL process enumeration or full window scan on main;
- no unbounded Accessibility traversal;
- no more than one relevant process-list enumeration per monitor refresh;
- no polling faster than one second;
- watchdog detects five missed expected refreshes;
- detector main-actor signposts remain below 4 ms p95 and 16 ms maximum in a 30-minute stress run;
- with no relevant app, average detector CPU delta stays below 0.2 percentage point and attributable wakeups below six per minute versus detector-disabled baseline;
- with a relevant app but no candidate, average CPU delta stays below 0.5 percentage point and attributable wakeups below two per second;
- while stabilizing, average CPU delta stays below 1 percentage point and attributable wakeups below four per second.

Measure with Instruments Time Profiler/Points of Interest and Energy Log, using identical feature-disabled and feature-enabled runs. If hardware noise makes an absolute gate inconclusive, repeat the paired run; do not replace measurement with subjective UI observation.

These budgets are provisional until Phase 0 records paired baselines on the development Mac. Phase 0 may tighten or relax a number only by recording the raw baseline, measurement variance, and an explicit reviewed replacement before Phase 1 begins.

## 16. PE execution protocol

Every phase follows the same cycle:

1. **Analyze:** re-read the phase targets, current diffs, prior phase evidence, and relevant replay fixtures.
2. **Plan:** produce a file/symbol-level implementation checklist and explicit invariants.
3. **Adversarial plan review:** fresh-context PE reviewer plus an external non-Claude review through `orchestrate`; rank findings by severity.
4. **Revise and lock:** resolve every blocker and major finding in the checklist before code.
5. **Execute:** delegate bounded implementation packages through the configured orchestration tier; the primary agent retains architecture and review responsibility.
6. **Verify:** focused tests, build, replay/stress checks, and privacy checks.
7. **Adversarial code review:** fresh-context review of the phase diff for duplication, magic constants, actor violations, stale-event loopholes, missing tests, privacy leaks, and behavior broadening.
8. **Fix and re-review:** a phase does not close on a `REVISE` verdict.

No phase is committed or pushed unless the user explicitly requests it.

## 17. Recommended first execution boundary

Begin with one additive Phase 0 slice only. Do not combine it with Phase 1 and do not request browser Automation permission.

The slice:

1. records the full worktree inventory and focused 48-test baseline;
2. adds one debug-only, Release-unreachable probe source under the file-system-synchronized application group, requiring no `project.pbxproj` edit;
3. performs process input/output and aggregate-device observation through one shared off-main CoreAudio pass;
4. emits append-only redacted JSONL containing reason enums, family categories, salted device-token hashes, and monotonic deltas—never names, PIDs, titles, paths, or URLs;
5. registers no listener that survives probe completion;
6. exercises app switching and sleep/wake stress;
7. records observed behavior and residual uncertainty in a local probe report.

The first deliverable answers:

1. Are process input/output selectors independently reliable on the supported macOS target?
2. Can audio helper processes be mapped to the correct application family without process-path heuristics?
3. Can every active input device and FluidVoice-owned loopback be identified stably?
4. Are HAL process enumeration and full window snapshots safe off-main under stress?

Browser privacy/TCC probing and production contract types are explicitly deferred until the first four answers, clock choice, self-observation rule, and actor single-flight contract have been reviewed. Only then may the remaining Phase 0 work and Phase 1 contracts be locked. This prevents the reducer and notification policy from being built on assumed sensor semantics.
