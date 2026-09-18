# Meeting Detection and Notification Design

Status: proposed
Scope: calendar-independent runtime detection, in-app reminder, and meeting-end assistance
Product posture: local-first, privacy-first, user-initiated recording

## 1. Outcome

FluidVoice should recognize a likely live call quickly enough to prevent a missed transcript, while treating every detection as a suggestion rather than permission to record.

The system must:

- notify only when independent, current signals identify the same application or browser meeting;
- never begin recording without an explicit user action;
- revalidate the meeting and exact capture target when the user acts;
- withdraw a stale reminder when the evidence disappears;
- identify likely meeting end conservatively without automatically stopping by default;
- keep raw URLs, window titles, audio, and detection history on the device;
- remain useful when optional permissions or newer CoreAudio attribution APIs are unavailable.

Calendar events may enrich a candidate later, but are neither required nor authoritative for this design.

## 2. Current implementation

The current detector already has several strong properties:

- Recording is prompt-only and requires an explicit click.
- Native applications and browser meetings use separate tiers.
- A native confirmation requires audio plus a qualifying application window.
- Browser confirmation requires audio plus a fixed meeting-domain/path match.
- Browser URL values and native window titles are not logged.
- Exact application and, when known, window identifiers are passed to capture.
- The detector remains separate from the lazily created recording coordinator.
- Busy recording or dictation state suppresses new reminders.
- Prompts deduplicate within an episode and explicit dismissals suppress repeats.
- Sleep, screen lock, and user switching clear transient state.
- The prompt supports VoiceOver announcements, Reduce Motion, keyboard actions, hover pause, and no auto-start.

The implementation is currently a two-second polling state machine on the main actor. It combines:

1. known running applications;
2. device-wide microphone start/stop edges;
3. per-application CoreAudio input or output activity on macOS 14.4 and later;
4. native application window presence;
5. a frontmost browser tab URL for supported meeting sites;
6. capture readiness and existing FluidVoice activity.

## 3. Root gaps

These are correctness gaps in the signal model, not UI polish issues.

### G1. Device activity is per device, but consumed as global activity

The device listener emits an edge whenever any monitored input device changes. Its consumer treats each inactive edge as if all microphones became inactive. With two microphones, a loopback device, an aggregate device, or a device transition, one device stopping can incorrectly end evidence while another remains active.

Required correction: maintain a set of currently active input device IDs and publish only aggregate transitions from zero to nonzero and nonzero to zero. Explicitly classify or exclude FluidVoice-created loopback devices.

### G2. Process input and output are collapsed

The process provider returns one Boolean when either application input or output is active. These signals mean different things:

- input activity means the application owns a microphone path;
- output activity may mean remote participants, a ringtone, media preview, or ordinary application sound.

Required correction: expose input and output independently, with bundle identifier, CoreAudio process object, PID when resolvable, observation time, and source quality.

### G3. Process attribution can use stale foreground history

Device-wide evidence requires a recent foreground event, but process-attributed evidence only requires that the application has been foreground at least once during its lifetime. An application activated hours earlier can therefore satisfy this gate.

Required correction: every foreground-dependent rule must have an explicit freshness window. Direct microphone ownership can reduce the need for foreground evidence, but must not silently turn an old timestamp into current intent.

### G4. Confirmation is instantaneous

Once audio and window/URL evidence coincide, the detector immediately creates an episode. A ringtone, pre-join test, transient microphone probe, or one polling sample can therefore produce a reminder. The queued/visible reminder is not promptly cancelled when those signals disappear.

Required correction: add positive stability, negative hysteresis, and cancellation while stabilizing or prompting.

### G5. Start validates readiness, not current meeting identity

At click time, `canStart` checks that the episode is unconsumed and FluidVoice is ready. It does not require fresh live evidence. A user can act on a stale reminder after the call has ended or the browser has navigated away.

Required correction: perform a fresh, bounded revalidation of the candidate, exact application, browser meeting locator when applicable, and capture source immediately before recording.

### G6. Native window evidence has uneven specificity

The Zoom path recognizes meeting-specific titles, but any layer-zero Teams or Webex window qualifies. Persistent home windows can combine with unrelated output activity and old activation history.

Required correction: application-specific evidence policies. When a reliable meeting-window marker is unavailable, require stronger process ownership, current activation, and longer stability.

### G7. Browser detection observes only the frontmost tab

This avoids scanning private browser state broadly, but it misses a background or minimized call and can lose identity when the user presents from another tab. Browser process audio cannot identify which tab owns audio.

Required correction: retain the last verified meeting locator ephemerally and refresh it opportunistically. Treat a different foreground tab as loss of visible correlation, not immediate proof that the call ended. Do not broaden to full-history or all-tab collection.

### G8. Detector health is too narrow

Only unreadable Zoom titles are surfaced. Process attribution availability, device-listener health, browser URL access, Accessibility timeouts, permission degradation, and stale polling are not represented coherently.

Required correction: publish a capability snapshot and operational health state, separate from candidate confidence.

### G9. Notification outcomes do not match user intent precisely

“Not now” suppresses the whole application for 30 minutes, while timeout suppresses only the current episode. There is no direct permanent per-application control, pause control, explanation of why the reminder appeared, or persistent place to recover an auto-dismissed action.

Required correction: model episode dismissal, time snooze, and source exclusion as different product actions.

## 4. Design principles

1. **Explicit rules before opaque scoring.** Use a small evidence-policy matrix whose outcomes can be explained and tested. A confidence band is an output, not an uninspectable weighted score.
2. **Current evidence only.** Every fact has an observation time, freshness limit, source, and health quality.
3. **Stable identity.** Evidence must refer to the same canonical application family and candidate locator.
4. **Positive stability and negative hysteresis.** Starting a suggestion needs sustained evidence; losing it needs a shorter cancellation window before recording and a longer safety window during recording.
5. **Asymmetric safety.** Prompt false positives damage trust; automatic recording is forbidden. Meeting-end false positives can lose content, so end detection only nudges by default.
6. **Graceful degradation.** Missing optional permissions lower the available confidence; they do not masquerade as a healthy detector.
7. **Minimal observation.** Read only the processes and windows already in the fixed registry. Reduce browser URLs immediately to an allowed provider plus opaque meeting locator.
8. **One episode, one interruption.** A dismissal or timeout suppresses the current episode until it genuinely ends.

## 4.1 User controls and sensitive contexts

Detector accuracy is not consent to interrupt. A technically correct meeting match may still be a conversation the user never wants to transcribe.

Launch controls are therefore part of the notification safety boundary, not later personalization:

- **Suggestion mode:** `Passive` or `Floating reminder`. New installations default to Passive. Existing installations preserve their current explicit detector preference. A passive meeting indicator can explain the feature and offer to enable floating reminders, but it never changes the mode automatically.
- **Pause all suggestions:** one hour, until tomorrow, or indefinitely from the menu bar and Meeting settings.
- **Application exclusions:** never suggest for a selected native application or browser.
- **Provider exclusions:** never suggest for a selected browser meeting provider without excluding the whole browser.
- **Suggest only when I use my microphone:** optional stricter mode for users who do not want muted/listen-only calls suggested.
- **End reminders:** independently enabled or disabled; default on only while FluidVoice is actively recording.

Private browser windows are excluded by default. A browser adapter may participate only if it can reliably identify private-window state and fail closed. If that distinction is not reliable for a browser/version, browser meeting suggestions are unavailable for that adapter rather than inspecting the window optimistically.

Only the active macOS login session is observed. Lock, fast-user-switch, logout, or sleep clears transient candidates and private locator digests. FluidVoice does not infer who is physically operating a shared Mac; the reminder always says that nothing is recording and requires an action in the active session.

The first successful capture started from a suggestion shows a concise, one-time local reminder that the user is responsible for following participant-consent and organization rules. Managed organization policy can make that reminder recurring or disable suggested capture, but cannot enable automatic recording.

## 5. Architecture

```text
Workspace events       CoreAudio process observations
Device aggregate       Window / browser correlation
        \                 /
         MeetingSignalMonitor  (background actor)
                    |
             timestamped facts
                    |
          MeetingEvidenceReducer  (pure)
                    |
          MeetingCandidateStore
                    |
             PromptPolicy
                    |
       InAppMeetingReminderCoordinator
                    |
       explicit Start -> fresh revalidation
                    |
          MeetingSessionCoordinator
```

### 5.1 MeetingSignalMonitor

This component owns observation and health, off the main actor.

It publishes immutable snapshots:

```swift
struct MeetingSignalSnapshot: Sendable {
    let observedAt: DetectorInstant
    let applications: [ApplicationAudioObservation]
    let aggregateInput: AggregateInputObservation
    let windows: [ObservedMeetingWindow]
    let browserCorrelations: [BrowserMeetingCorrelation]
    let capabilities: DetectionCapabilities
    let generation: UInt64
}
```

`DetectorInstant` wraps `ContinuousClock.Instant`. Sleep advances this clock so every pre-sleep fact fails freshness checks after wake; `SuspendingClock` is forbidden in detector policy.

Properties:

- Process input and output are separate facts.
- Snapshots have a monotonic generation and timestamp; stale async AX results are discarded.
- CoreAudio enumeration runs off-main.
- A device edge requests an immediate process refresh, rate-limited to avoid storms.
- Normal cadence is one second while a candidate is stabilizing or recording, one second while relevant apps are running unless a proven process-audio push signal supplies equivalent latency, and thirty seconds only when push listeners are healthy and no relevant application is running.
- A watchdog marks the monitor degraded after five missed expected observations.
- Device changes temporarily lower confidence instead of creating false start/end edges.

### 5.2 Canonical identities

Do not key candidates only by PID and window number. Both can be reused.

```text
application family = canonical supported application or browser
process identity    = PID + launch timestamp when available
meeting locator     = native window token or provider + one-way in-memory locator digest
episode identity    = application family + process identity + meeting locator generation
```

The digest is session-random and is never persisted. Raw URLs and titles never enter logs, analytics, or notification copy.

### 5.3 MeetingEvidenceReducer

The reducer is a pure state machine. It accepts snapshots and user outcomes and emits candidate transitions. This makes timing deterministic in tests.

Candidate states:

```text
idle
  -> observing
  -> stabilizing
  -> confirmed
  -> reminderPresented
  -> accepted | dismissed | timedOut
  -> ending
  -> ended
```

Rules:

- `observing`: at least one relevant signal exists.
- `stabilizing`: a valid application-specific evidence combination exists.
- `confirmed`: the same combination remains valid for its stability threshold.
- `reminderPresented`: PromptPolicy authorizes an interruption.
- `accepted`: the user requested capture and fresh revalidation passed.
- `dismissed` or `timedOut`: no more reminders for this episode.
- `ending`: required evidence weakened; negative grace is running.
- `ended`: application exited, meeting locator disappeared and audio ceased, or the absence threshold elapsed.

Any loss of the required combination during `stabilizing` returns to `observing`. Before capture, a confirmed or visible reminder is invalidated after three seconds without a valid combination. During capture, signal loss never automatically stops the recording by default.

### 5.4 Evidence policy matrix

| Context | Required evidence | Stability | Result |
|---|---|---:|---|
| Native, meeting-specific window | same app has input or output activity + meeting window | 4 s | high-confidence reminder |
| Native, generic persistent window | same app owns input; recent activation is supporting evidence | 6 s | high-confidence reminder |
| Native, generic persistent window, muted | same app has sustained output + recent activation + app-specific call marker | 8 s | high-confidence reminder |
| Browser | browser input or output + currently verified supported meeting locator | 5 s | high-confidence reminder |
| Browser, locator temporarily unreadable after verification | same browser audio continues and locator was verified recently | no new reminder; preserve existing candidate for 15 s | continuity only |
| Legacy/degraded OS attribution | aggregate mic + recent foreground + qualifying window/URL | 8 s | medium confidence, passive in-app status only initially |
| Audio only | any | — | no reminder |
| Window/URL only | any | — | no reminder |
| Generic browser mic with no supported meeting locator | any | — | no reminder |

The exact thresholds are launch defaults, not remote feature flags. They may be adjusted only through a versioned local policy after trace evaluation.

“Recent activation” means no more than 30 seconds old and is supporting evidence only. A direct same-process input owner does not require the app to remain frontmost; background calls must work.

### 5.5 Capability and health model

```swift
struct DetectionCapabilities: Sendable, Equatable {
    let processInputAttribution: Availability
    let processOutputAttribution: Availability
    let aggregateInputActivity: Availability
    let nativeWindowIdentity: Availability
    let browserMeetingCorrelation: Availability
    let capturePermission: CapturePermissionState
    let monitorHealth: MonitorHealth
}
```

Availability is `available`, `permissionRequired`, `unsupported`, or `temporarilyDegraded`. Health is not evidence. The UI can explain why detection is limited without accidentally increasing confidence.

## 6. Fresh start revalidation

Clicking “Start transcript” executes the cancellable start transaction defined in Phase 4 of `MEETING_DETECTOR_PHASED_IMPLEMENTATION_PLAN.md`. That transaction owns the authoritative ordering, deadline, target-liveness race, and acceptance semantics.

Failure leaves the user in control:

- Evidence ended: “The call no longer appears active.”
- Target changed or ambiguous: open source selection with the detected application preselected.
- Permission missing: show the exact missing capability and a direct repair action.
- FluidVoice busy: keep the current work untouched and explain that another audio task is active.

No episode is consumed before capture succeeds. Repeated clicks are single-flight.

## 7. In-app notification design

### 7.1 Presentation policy

The first user-facing phase uses only FluidVoice-owned surfaces. A high-confidence candidate always receives passive menu-bar status and receives a floating reminder only when the user has enabled Floating-reminder mode.

It must:

- use the display containing the detected meeting application when known, otherwise the active display;
- never activate FluidVoice or steal keyboard focus;
- remain keyboard and VoiceOver accessible;
- respect Reduce Motion and avoid appearing over another application’s full-screen presentation;
- keep a recoverable “Meeting suggestion” action in the menu bar while the transient panel is hidden;
- withdraw within three seconds when pre-capture evidence becomes invalid;
- show only once per episode.

The menu-bar state is a first-class surface, not a fallback implementation detail:

- Passive mode shows a neutral meeting-suggestion indicator without animation or sound.
- Floating-reminder mode shows the same indicator whenever the panel is visible, suppressed, or timed out.
- The menu item reads “Possible meeting in Zoom — Start transcript” and exposes the same source and privacy status to VoiceOver.
- It persists until the episode ends, the user selects Not now, the source becomes excluded, or capture begins. Short correlation gaps use the episode’s end grace rather than removing it immediately.
- A dot/badge may be enabled later; sound is default-off and outside the initial release.

Recommended copy:

```text
Meeting may have started
Zoom is using call audio. Nothing is being recorded.

[Not now] [Start transcript]
```

Use “Call may have started” for call-oriented applications when the registry knows that distinction. Do not display a URL, window title, participant, or calendar subject in the calendar-free reminder.

The panel remains available for 30 seconds; hover or keyboard interaction pauses the countdown. Panel timeout suppresses another floating interruption for that episode but preserves the passive menu-bar action until the episode ends. Timeout is therefore distinct from an active decline even though neither causes another panel.

### 7.2 Actions are distinct

- **Start transcript:** fresh revalidation followed by user-initiated capture.
- **Not now:** actively decline and suppress this episode until it ends; remove its passive menu-bar action.
- **Snooze 10 minutes:** hide the current panel, preserve only its passive menu-bar recovery, and prohibit another floating reminder for that episode. Other candidates may be detected but remain passive until the snooze expires. Expiry never re-presents an existing episode; only a different episode that becomes stable after expiry may show a panel.
- **Don’t suggest for this app:** optional overflow action; persist a reversible local source exclusion.
- **Why this appeared:** opens a local explanation using coarse evidence labels such as “meeting window” and “call audio,” never raw observed values.
- **Pause suggestions:** menu-bar control with one hour, until tomorrow, and indefinite choices.

Automatic timeout suppresses further floating interruptions for the episode but does not remove passive menu-bar recovery and does not count as negative feedback. An explicit “Not now” may contribute to a local suggestion to mute that source after repeated occurrences, but FluidVoice must not change settings automatically.

### 7.3 Setup reminders

A confirmed meeting can expose that capture is unavailable, but permission status determines whether FluidVoice may interrupt:

- `notDetermined`: one contextual setup reminder may appear. If the user chooses Not now, persist that setup-reminder decline and do not ask again until a manual meeting-capture or settings action.
- `denied`: passive settings/menu-bar status only. After the user declines a repair action, do not prompt again until they manually revisit meeting capture or re-enable setup reminders.
- `restricted`: passive explanation only, with no misleading System Settings action.
- `unsupported` or temporarily unavailable: passive explanation and retry status only.

The auto-detected online-call path does not offer microphone-only capture when application/system audio permission is missing. A mic-only transcript would omit remote participants and violate the promise of a meeting transcript. If a separate mic-only mode is introduced later, it requires explicit source copy and its own product design.

When a contextual setup reminder is allowed, it should name one repair action rather than sending the user to a generic setup screen:

```text
Meeting may have started
Allow Screen Recording to capture Zoom audio. Nothing is being recorded.

[Not now] [Open System Settings]
```

Show at most once per episode. Returning from System Settings triggers a fresh capability check. If permission remains absent, keep passive status and offer “Try again” in settings; never loop or immediately reopen System Settings. Detection settings must show the same capability state persistently.

### 7.4 Interruption suppression and passive recovery

Full-screen presentation, user-configured quiet mode, dictation, active recording, and another prompt can suppress the floating panel. macOS does not provide arbitrary applications a general Focus-state API, so FluidVoice must not claim to read Focus state; later system notifications inherit the operating system’s Focus delivery behavior. Suppression never produces a second toast explaining the first suppression. Instead, the menu-bar indicator changes to the neutral “possible meeting” state and remains accessible for the episode.

Source exclusions produce no candidate indicator because the user explicitly requested silence. A diagnostics/settings row may show that a source is excluded without revealing a live meeting. Busy FluidVoice activity may show “Meeting suggestion available after current task” passively, but must never stop or replace the current task.

### 7.5 Simultaneous-candidate arbitration

Only one floating panel is allowed. Rank eligible candidates deterministically by:

1. high confidence over medium confidence;
2. exact same-process microphone input ownership;
3. meeting-specific locator over generic application evidence;
4. capture readiness;
5. most recent transition into a stable candidate.

Do not replace a visible panel or an in-progress Start transaction. Other valid candidates appear as menu-bar choices under “Other possible meetings.” If the user selects one, source selection clearly names each viable application before capture. Accepting one candidate suppresses interruptions while FluidVoice is busy but does not end or merge distinct episodes; they remain passive and may become actionable after the recording ends if still live.

### 7.6 Browser observation contract

Before browser detection is enabled, show this user-facing disclosure:

> FluidVoice checks the current page only in supported browsers to recognize supported meeting sites. Matching happens on this Mac. It does not scan history or all tabs, and it does not store page addresses or titles. Private windows are excluded.

Initial adapters are Chrome, Safari, Arc, Edge, Brave, and their supported meeting PWAs. Each browser/version must pass fixtures for current-page access and private-window exclusion. If Accessibility or page access is unavailable, that adapter reports degraded/unavailable and produces no browser reminder. The session-random meeting-locator digest is regenerated at launch and never appears in exported traces, so it cannot link meetings across sessions.

### 7.7 System notifications later

System notifications are a later phase behind a separate “System meeting notifications” setting, default off. Passive suggestion mode never escalates to a system notification unless the user independently enables this setting. When enabled, system delivery is considered only when FluidVoice is not visible or the floating reminder cannot be presented. Copy remains generic, and actions route through the same fresh revalidation transaction. System notifications never bypass source exclusions, episode suppression, pause, operating-system Focus delivery, or the no-auto-start rule.

## 8. Meeting-end assistance

Start and end use different policies.

Before capture:

- invalidate the reminder after three seconds without a valid start combination;
- end the episode after 30 seconds of both missing application audio and missing meeting locator, or immediately when the process exits;
- tolerate short browser correlation loss and device transitions.

During capture:

- never stop solely because the microphone is muted, the window is minimized, or one audio direction stops;
- treat recent transcript output, application audio, a verified meeting locator, an alive exact capture target, or a qualifying native call marker as continuation evidence;
- after 60 seconds in which none of the continuation-evidence signals above is present, show one non-modal, non-focus-stealing “Still recording?” nudge positioned away from detected presentation controls;
- offer “Stop recording” and “Keep recording,” and state that stopping will finalize the local transcript;
- choosing “Keep recording” suppresses every further end nudge for that recording, including after later source fluctuations;
- default to no automatic stop.

A future automatic-stop preference may be designed separately, with an explicit opt-in and substantially longer absence window. It is outside this phase.

## 9. Privacy and local diagnostics

### 9.1 Data handling invariants

- Raw URLs and window titles are processed in memory and immediately reduced to provider, allowed-path classification, and ephemeral locator digest.
- No participant names, content, titles, raw process paths, device names, audio, or transcript text enter detection diagnostics.
- Candidate history is memory-only by default. Explicitly enrolled dogfood diagnostics may persist only the redacted bounded trace described below.
- Persisted operational state is limited to user-facing preferences: suggestion mode, pause, source exclusions, end-nudge preference, setup-reminder dismissal, and consent acknowledgment.
- No detector telemetry leaves the device without a separate, explicit opt-in design.

### 9.2 Local decision trace

Add a bounded, redacted circular buffer suitable for testing and support export:

```text
time delta | candidate token | transition | evidence classes | policy result | health
```

Example evidence classes are `processInput`, `processOutput`, `meetingWindow`, `meetingURL`, `recentActivation`, and `aggregateMicFallback`. Tokens are random per launch. Raw bundle identifiers, PIDs, device identifiers, locator digests, URLs, paths, and titles are never written into the trace buffer; redaction happens at write time, not at export.

The in-memory default buffer holds at most 5,000 transitions and clears at launch. Explicitly enrolled dogfood diagnostics may retain the same redacted records for at most seven days. Users can inspect detector health, export the redacted trace explicitly, or select “Clear detection diagnostics.” Export never includes the session locator digest. A test gate verifies that detector operation and trace review make no network requests.

Dogfood enrollment is explicit. Enrolled builds provide a local review inbox containing coarse candidate time, registry application label, outcome, and evidence classes. Review data remains on device unless the user exports it.

Local aggregate counters may include:

- candidates created, confirmed, cancelled during stability, and ended;
- reminders shown, suppressed, timed out, dismissed, and accepted;
- time from first valid combination to reminder and from reminder to capture;
- start revalidation failures by coarse reason;
- end nudges accepted or rejected;
- capability and monitor degradation counts.

## 10. Product decisions

This design resolves the following defaults:

| Decision | Default |
|---|---|
| Automatic recording | Never |
| New-install suggestion mode | Passive menu-bar status; user enables floating reminders |
| Existing-install suggestion mode | Preserve the user’s current detector setting |
| High-confidence candidate | Menu-bar status, plus floating reminder when enabled |
| Medium-confidence candidate | Menu-bar status only during initial rollout |
| Explicit “Not now” | Suppress current episode |
| Timeout | No second panel; preserve passive recovery; no negative-feedback count |
| Permanent source exclusion | Explicit, reversible local setting |
| Private browser windows | Excluded; unsupported adapter fails closed |
| Missing denied/restricted permission | Passive status only; no recurring repair prompt |
| Likely meeting end | Ask once; never auto-stop by default |
| End nudge preference | Independent toggle; default on during active recording |
| Consent reminder | One-time on first suggestion-started capture; policy may require recurring |
| Raw URL/title retention | None |
| External detector telemetry | None |
| System notification | Later, separate explicit opt-in; default off even in Passive mode |

One-hour/until-tomorrow pause, application exclusions, and browser-provider exclusions ship with the first strengthened reminder release. Browser-profile-specific exclusions and organization-policy management remain later extensions.

## 11. Phased implementation rationale

The authoritative phase numbering, work packages, and gates are in `MEETING_DETECTOR_PHASED_IMPLEMENTATION_PLAN.md`. This section is retained only as the original rollout rationale; references to implementation phases must use the detailed plan.

### Rationale A — Correct signal semantics

- Aggregate device state across all input devices.
- Exclude known FluidVoice loopback devices.
- Split process input and output observations.
- Add observation generations, health, and a watchdog.
- Move CoreAudio enumeration off-main.
- Add freshness to every timestamp-dependent rule.
- Build deterministic trace-replay tests.

Exit gate: multi-device and stale-attribution tests pass; observation does not block the main actor; no product behavior is broadened.

### Rationale B — Candidate reducer in shadow mode

- Implement the pure evidence reducer and application-specific policies.
- Run old and new decisions side by side locally without showing additional reminders.
- Make redacted trace export available in debug builds.
- Dogfood native applications first, then opt-in browsers.

Exit gate: the labelled-evaluation sample and confidence-bound requirements in Section 13.1 pass for each supported application family, no duplicate episode reminders occur, and p90 confirmation remains under ten seconds for high-confidence joins.

### Rationale C — Strengthened in-app reminder

- Route visible reminders through the new candidate/prompt policy.
- Add positive stability, live invalidation, current-episode dismissal, menu-bar recovery, and fresh start revalidation.
- Add exact capability repair CTAs.
- Add Passive/Floating mode, global pause, application/provider exclusions, and end-nudge preference.
- Add deterministic simultaneous-candidate arbitration and the private-browser fail-closed contract.
- Retain no-auto-start.

Exit gate: zero starts after failed live revalidation; stale reminders withdraw within three seconds; exclusions and pause act immediately; menu-bar recovery and source identification pass task-based usability tests; median unwanted reminders no more than one per active user per week during dogfood.

### Rationale D — Explanation and coverage

- Add local “Why this appeared?” evidence explanation.
- Expand application-specific policies only with trace fixtures and precision evidence.
- Handle browser/native handoff, reconnects, waiting rooms, breakout transitions, and simultaneous candidate applications.

Exit gate: each added source meets the same per-source precision target; exclusions take effect immediately and survive restart.

### Rationale E — System notifications

- Request notification permission contextually and only after user opt-in.
- Add a separate System meeting notifications preference; never infer it from Passive/Floating suggestion mode.
- Use system notifications only when the in-app surface is unavailable.
- Reuse the same episode suppression, actions, privacy copy, and start revalidation.

“In-app surface unavailable” means no eligible floating panel was presented because the panel was suppressed by presentation policy, or a passive menu-bar action remained unactivated for the configured system-notification delay. FluidVoice does not claim to know whether the user visually noticed the menu item. It never means source exclusion, explicit Not now, pause, denied permission, or an invalid candidate. When the system surface is selected, the floating panel is cancelled so the two surfaces never duplicate.

Exit gate: system and in-app surfaces never duplicate; Focus and permission states degrade to menu-bar recovery; notification opt-out does not disable detection.

## 12. Test strategy

### Reducer and invariants

- Audio-only and window-only never confirm.
- A candidate cannot confirm before its stability interval.
- Loss during stability cancels without a reminder.
- Every reminder maps to one live episode.
- Dismiss, timeout, and exclusion have distinct persistence semantics.
- No recording begins without explicit action and successful fresh revalidation.
- A consumed episode cannot re-prompt until it ends.
- Monotonic generation rejects stale async observations.

### Signal fixtures

- Two microphones where only one stops.
- Aggregate and loopback device appearance/disappearance.
- Input active without output; output active without input.
- Ringtone or notification audio in a persistent meeting application window.
- Stale foreground activation followed by unrelated output.
- Muted join with remote output.
- Waiting room, pre-join device test, reconnect, and breakout transition.
- Browser meeting moved to background or minimized.
- Browser navigates away before and after reminder presentation.
- Application PID and window ID reuse.
- Same-count replacement of one active application by another.
- Detector startup during an already-running meeting.
- Sleep, wake, lock, fast user switch, audio service restart, and device change.
- Two simultaneous meeting candidates with deterministic prompt arbitration.

### Notification fixtures

- Full-screen presentation suppresses interruption but preserves menu-bar recovery.
- Dictation overlay and active recording suppress new reminders.
- Incoming candidates cannot replace a Start transaction.
- VoiceOver can discover status and invoke both primary actions.
- Keyboard navigation never focuses the underlying application unexpectedly.
- Reduce Motion and increased contrast render correctly.
- Setup reminder deep-links to the correct capability.
- Denied and restricted permissions never produce recurring contextual repair prompts.
- Passive mode, timeout, full-screen suppression, and user-configured quiet mode preserve accessible menu-bar recovery.
- Application/provider exclusions, private-window exclusion, and global pause produce no live candidate indicator.
- Simultaneous candidates remain separately selectable and accepting one does not merge their episodes.
- Evidence loss silently withdraws visible and pending reminders.

## 13. Launch metrics and stop conditions

Metrics are calculated locally during dogfood unless users explicitly export a diagnostic report.

### 13.1 Labelled evaluation protocol

Dogfood users review a local periodic digest rather than receiving an extra interruption after every reminder. Each sampled episode can be labelled `meeting`, `not a meeting`, or `unsure`. The digest samples across every outcome: panel shown, Not now, timeout, passive recovery opened, capture started, candidate suppressed by presentation policy, and eligible shadow candidate not shown. Silence and `unsure` are never counted as confirmation.

Report separate denominators and label-response rates for each outcome. Prompt precision is `labelled meeting / (labelled meeting + labelled not a meeting)` among reminders actually shown; passive and shadow precision are reported separately. Manual online-call recordings with no eligible suggestion are counted as missed-opportunity proxies, not automatically as detector false negatives.

An application family may enter explicit opt-in V2 dogfood after the preliminary gate in the implementation plan. Default-on rollout uses the larger sample and confidence-bound gate defined there. Expansion decisions use per-family results, never only an aggregate average. Unreachable sample volume keeps a family opt-in; it never relaxes the gate automatically.

An active user-week for burden metrics is a local calendar week in which FluidVoice ran on at least three days and observed at least one eligible candidate. This avoids diluting interruption burden with inactive installations.

Launch targets:

- Prompt precision: meet the labelled-evaluation gate above for every supported application family.
- Prompt burden: median no more than one unwanted reminder per active user per week.
- Detection latency: p90 under ten seconds from a valid high-confidence combination.
- Stale reminder latency: at most three seconds after pre-capture evidence becomes invalid.
- Duplicate rate: zero duplicate reminders within one episode.
- Start safety: 100% of starts have explicit action, live revalidation, and an exact viable capture target.
- Accidental auto-starts: zero by construction.
- Main-thread impact: no synchronous CoreAudio enumeration or unbounded AX work on the main actor.
- Missed-value proxy: track manual online-call recordings lacking a prior eligible suggestion, segmented by source, without weakening the precision gate.
- Trust: track local suggestion disablement, pause, and source exclusion shortly after a reminder.
- Permission burden: no repeat contextual setup prompt after denied/restricted status or an explicit repair dismissal.
- User comprehension: in moderated task tests, at least 95% of participants correctly identify whether recording started, which source is captured, how to stop, and why the suggestion appeared.
- Accessibility: keyboard and VoiceOver users can discover passive status and complete Start, Not now, source choice, Keep recording, and Stop recording without focus loss.
- Privacy: automated integration tests observe no detector or diagnostics network traffic and exported traces contain no raw URL, title, path, participant, device name, or cross-session token.

Stop rollout and return to shadow mode for an application family if:

- labelled precision falls below 85%;
- unwanted reminders exceed two per active user per week at the 75th percentile;
- any recording starts after failed or stale revalidation;
- a privacy invariant is violated;
- monitor degradation produces repeated or unwithdrawn reminders.

## 14. Recommended implementation slice

The first implementation should not add application coverage or system notifications. It should deliver one coherent vertical slice:

1. correct aggregate device state;
2. structured per-process input/output observations off-main;
3. pure candidate reducer with four- or six-second stability;
4. visible reminder cancellation on evidence loss;
5. current-episode “Not now” semantics;
6. fresh start revalidation;
7. redacted local trace and deterministic tests.

This slice fixes the detector’s root semantics and makes the existing in-app reminder trustworthy. Coverage, personalization, calendar enrichment, and system delivery can then build on a stable episode model rather than adding exceptions to the current Boolean pipeline.
