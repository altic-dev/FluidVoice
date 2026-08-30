# Local Calendar Meeting Reminder Plan

**Status:** Deferred / ready for implementation planning
**Last revised:** 2026-08-22
**Product direction:** Local-first EventKit integration with FluidVoice in-app reminders first. System notifications are a later phase after dogfooding.

## 1. Objective

Add an optional local calendar integration that reads meeting events already available through macOS Calendar and reminds the user through FluidVoice's existing in-app notification surfaces.

The first release does not use OAuth, a sync backend, meeting bots, automatic recording, or macOS system notifications. Calendar data is context for reminders and later post-confirmation metadata; it is never evidence that independently creates or confirms a live meeting episode.

### Initial user flow

1. The user enables **Calendar meeting reminders** in Meeting Settings.
2. FluidVoice explains why macOS labels the permission as Full Access even though FluidVoice performs no calendar writes.
3. FluidVoice activates its Settings window and requests EventKit access.
4. The user selects calendars. Nothing is selected automatically.
5. FluidVoice fetches eligible meetings from those calendars.
6. At approximately one minute before an eligible meeting, FluidVoice shows its nonactivating reminder HUD.
7. The reminder offers:
   - **Join** — revalidate and open the conference URL.
   - **Prepare** — open Meeting setup with an ephemeral title seed; never start recording.
   - **Not now** — suppress only that occurrence.
8. After 20 seconds, an unhandled HUD collapses into an actionable Upcoming Meetings section in the existing FluidVoice menu.

## 2. Non-negotiable invariants

1. Calendar access is optional and off by default.
2. FluidVoice never writes through EventKit.
3. Calendar data never creates or confirms a `MeetingAutoDetector` episode.
4. Calendar data never changes live-detection thresholds or confidence.
5. No calendar path calls recording or capture-configuration APIs.
6. Exact PID/window capture targeting remains unchanged.
7. Denied, revoked, unavailable, stale, or malformed calendar data cannot reduce existing live-detection behavior.
8. EventKit objects remain inside one serialized provider and never escape into the application.
9. Calendar event payloads are not cached on disk in v1.
10. Titles, notes, locations, raw URLs, meeting codes, passcodes, and attendees never enter logs or analytics.
11. No new status item is introduced; reminders use the existing FluidVoice HUD and menu.
12. No meeting-related `UNUserNotificationCenter` permission, category, or request is introduced before the in-app dogfood gate passes.

## 3. Apple platform constraints

- EventKit has no read-only authorization. Reading events requires `requestFullAccessToEvents()` and `NSCalendarsFullAccessUsageDescription`, even when application code never writes.
- Sandboxed macOS apps require the calendar entitlement. FluidVoice is currently not sandboxed, so the entitlement should not be added until App Sandbox is actually enabled.
- `events(matching:)` is synchronous and must not run on the main actor.
- `EKEventStoreChanged` means previously fetched objects may be stale. Refetch the current range and replace the complete snapshot set.
- Do not automatically call `EKEventStore.reset()` for store-change notifications. Apple documents `reset()` as reverting unsaved state and invalidating store-created objects; notification guidance requires a refetch.
- Event and calendar identifiers can change after synchronization or account removal/re-add. They are hints, not permanent primary keys.
- A predicate with `nil` calendars searches every calendar. FluidVoice must skip the fetch entirely when zero selected identifiers resolve to calendars.

Primary references:

- [Accessing the Event Store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
- [Retrieving Events and Reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders)
- [Updating with Notifications](https://developer.apple.com/documentation/eventkit/updating-with-notifications)
- [`EKEventStore.reset()`](https://developer.apple.com/documentation/eventkit/ekeventstore/reset%28%29)
- [`calendarItemIdentifier`](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier)

## 4. V1 product policy

### Eligible meeting

An event is eligible when all of the following are true:

- It belongs to a resolved, user-selected calendar.
- It is timed and not all-day.
- It is not canceled.
- Its duration is between 5 minutes and 8 hours.
- A directly validated conferencing HTTPS URL is found in `event.url`, location, or notes.
- The current user has not explicitly declined, when that state can be reduced to a transient Boolean without retaining the roster.

Tentative events remain eligible. Attendees, organizer, busy/free state, and attendee count are not required.

### Reminder window

- Opens at `start - 60 seconds`.
- Closes at `start + 2 minutes`.
- The actionable menu entry remains available until `event end + 2 minutes`.
- Ending a recording after the event start never triggers a catch-up HUD; the event remains menu-only.

### Calendar selection

- Permission grant selects zero calendars.
- The picker appears immediately after grant.
- Missing or re-added calendar identifiers remain visibly unresolved.
- FluidVoice never silently substitutes all calendars.
- If the resolved selection is empty, no predicate is constructed and no event fetch occurs.

### Sensitive UI

The floating HUD uses generic copy by default, such as **Meeting starts in 1 minute**, with time and provider icon. It does not render the raw event title, reducing accidental disclosure during screen sharing.

The event title may appear in the explicit Upcoming Meetings UI/menu and Prepare flow. It becomes ordinary persisted meeting metadata only after the user explicitly starts or saves a meeting.

## 5. Target architecture

```text
EventKitCalendarProvider
        |
        v
LocalCalendarEventSnapshot[]
        |
        +--> CalendarConferenceLinkParser
        |
        v
CalendarReminderReconciler
        |
        +--> CalendarPromptCoordinator --> existing FluidVoice HUD
        |
        +--> UpcomingMeetingsModel -----> existing FluidVoice menu/settings UI
        |
        `--> CalendarMeetingCorrelator (later, post-confirmation only)
```

### Proposed responsibilities

#### `EventKitCalendarProvider`

- Own exactly one long-lived `EKEventStore`.
- Serialize every store operation.
- Request permission on the main actor.
- Run event predicates off-main.
- Convert EventKit objects immediately into immutable `Sendable` snapshots.
- Check authorization before and after a fetch.
- Discard a result if authorization changed during the fetch.
- Replace snapshots wholesale rather than merging framework objects.

#### `LocalCalendarEventSnapshot`

V1 fields:

- Volatile local/external identity hints.
- Selected calendar identifier.
- Sensitive, non-`Codable` title value with redacted textual description.
- Start and end dates.
- All-day and canceled flags.
- Transient `isCurrentUserDeclined` Boolean.
- Normalized provider and meeting identity.
- Ephemeral actionable URL.

No attendee, organizer, notes, location, or raw URL persistence.

#### `CalendarConferenceLinkParser`

- Pure and independently testable.
- Scan `event.url`, location, then notes; continue past non-meeting URLs.
- Bound the number of notes bytes inspected.
- Extract bounded HTML `href` candidates where necessary.
- Accept direct provider HTTPS URLs only in v1.
- Reject redirect wrappers, userinfo, non-HTTPS schemes, non-ASCII hosts, malformed hosts, and incorrect subdomain boundaries.
- Share a data-driven provider host table with live detection while keeping invite and strict in-call policies separate.
- Preserve existing `MeetingInCallURLMatcher` results exactly.

#### `CalendarReminderReconciler`

Derive reminder state rather than incrementally mutating independent timers:

```text
snapshots
    -> eligible occurrences
    -> desired HUD/menu state
    -> reconcile against presented/terminal aliases
```

- Use an injected clock.
- Use one rescheduled wall-clock timer for the next reminder boundary, expiry, or fetch horizon.
- Revalidate selection, snapshot, URL, recording state, expiry, and suppression immediately before presentation or action.
- Inspect only existing materialization-safe activity properties; never instantiate the lazy meeting coordinator merely to check recording state.

#### Source-neutral prompt coordinator

Semantic identity is typed:

```swift
enum MeetingPromptIdentity {
    case live(LiveEpisodeID)
    case calendar(CalendarOccurrenceKey)
}
```

An independent internal presentation token retains async race/cancellation protection.

Calendar and live prompts have separate typed action closures. A calendar code path must be unable to call detector dismissal, timeout, adoption, or start methods.

The coordinator treats both a visible live prompt and the detector's hidden suppression-retrying prompt as live occupancy.

Priority:

1. Active recording.
2. Visible or pending live prompt.
3. Calendar reminder.

Outcomes:

- `acted`
- `dismissed`
- `displaced`
- `collapsed`
- `expired`

## 6. Reminder presentation behavior

### Calendar HUD

- Calendar bypasses bundle/frontmost matching because the meeting application may not yet be running.
- It yields to active recording and active dictation/command overlays.
- It is visible for `min(20 seconds, expiresAt - now)`.
- Hover and accessibility interaction pause the visible countdown without extending the absolute eligibility deadline.
- Accessibility announcements use generic provider/time copy rather than the sensitive title.
- After 20 seconds it collapses into the existing FluidVoice menu.

### Displacement

- Live prompt arrives before calendar becomes visible: no presented alias; calendar may requeue until expiry.
- Live prompt arrives after calendar becomes visible: write/retain the presented alias, collapse calendar to menu, and do not re-show its HUD.
- Calendar presentation never traverses the detector's existing replacement-timeout callback path.

### Wake and restart

- Wake/restart inside the eligibility window with no presented alias: show the HUD.
- Wake/restart after presentation: restore the menu entry, not the HUD.
- Wake after expiry: no HUD.
- If the HMAC secret is temporarily unavailable, fail closed for HUD presentation until it becomes readable; do not generate a replacement secret or rewrite aliases.

### Multiple meetings

- At most one calendar HUD is visible.
- Choose among newly eligible, unpresented occurrences by `(startDate, occurrenceAlias)`.
- If several become eligible in one reconciliation, show one HUD and put the others directly in the menu to avoid a burst.
- Meetings whose windows open later remain independently eligible for their own HUD.

### Existing menu

- Add an independent Upcoming Meetings section; do not reuse or instantiate meeting-session UI state to populate it.
- Derive entries lazily when the menu opens from current snapshots and opaque reminder state.
- Entries expose Join, Prepare, and Not now using the same revalidation pipeline as the HUD.

## 7. Identity and persistence

Use HMAC-SHA256 with a per-install secret stored as `AfterFirstUnlockThisDeviceOnly` and cached once per process.

```text
primary alias = HMAC(
    selectedCalendarID
    + external/server identifier
    + original occurrence date or start
    + scheduled UTC start
)

fallback alias = HMAC(
    selectedCalendarID
    + normalized conference identity
    + scheduled UTC start
)
```

Including scheduled start deliberately re-arms a rescheduled meeting.

Rules:

- Generate the secret only on definitive item-not-found.
- On any other Keychain error, enter fail-closed reminder mode.
- Never use raw identifiers as persistent fallback keys.
- Never delete or rewrite stored aliases merely because the secret could not be read.
- Persist a presented alias only once the HUD is actually visible.
- Join, Prepare, and Not now create terminal occurrence state.
- Prune aliases after `event end + 2 minutes + 7 days`.

## 8. Refresh and lifecycle

Fetch range:

```text
now - 5 minutes ... now + 48 hours
```

All refresh triggers feed one coalescing coordinator:

- UI-ready startup.
- Permission or selection change.
- Debounced `EKEventStoreChanged`.
- Application activation.
- Wake/session activation.
- Timezone or system-clock change.
- `lastSuccessfulFetch + 6 hours`.

The six-hour horizon boundary prevents a continuously running Mac from missing meetings that were outside the previous 48-hour fetch range. It is scheduled through the same one-shot timer, not an independent polling loop.

On an EventKit change notification:

1. Treat existing EventKit objects as stale.
2. Refetch the full current range.
3. Convert to new value snapshots.
4. Atomically replace the old snapshot set.
5. Reconcile reminder state.

## 9. Prepare and Join actions

### Prepare

Navigation needs an atomic, memory-only seed:

```swift
case meetingTranscription(seed: EphemeralMeetingSetupSeed?)
```

- Apply only when setup is pristine.
- Never overwrite a visible dirty draft.
- Never write the seed to `SettingsStore`.
- Clear it at event end or after consumption.
- Calendar invokes navigation only; it never invokes recording APIs.

### Join

- Refetch/reconcile current state as necessary.
- Confirm the calendar remains selected.
- Confirm the event remains eligible.
- Reparse and revalidate the URL.
- Open only the validated in-memory URL after the user's click.
- On failure, keep the reminder/menu available with a content-free error; never open a fallback URL.

## 10. Phased implementation

### Phase 0 — Contract and build prerequisites

- Amend the PRD requirements described above.
- Add the calendar usage description.
- Add educational permission UI and activated-window flow.
- Lock privacy and persistence rules.

**Gate:** no EventKit API is reachable without the usage string and explicit user action.

### Phase 1A — Source-neutral HUD

- Introduce typed semantic identity and source-specific callbacks.
- Preserve live prompt behavior exactly.
- Treat visible and suppression-retrying live prompts as occupancy.
- Move detector-invariance Cartesian tests into this phase.

**Gate:** existing live tests retain identical results; calendar identities cannot reach detector APIs.

### Phase 1B — Calendar HUD policy

- Add calendar payload, priority, displacement, collapse, fullscreen-safe generic copy, and in-memory reminder state behind the feature flag.
- Do not introduce EventKit persistence keys here.

**Gate:** fake calendar requests cannot mutate detector state or start recording.

### Phase 1C — EventKit provider and parser

- Add permission/status provider, calendar selection, bounded fetch, snapshots, conference parser, refresh coordinator, and HMAC secret service.

**Gate:** empty resolved selections perform zero event fetches; malicious parser corpus passes; revocation clears UI and snapshots.

### Phase 2 — Upcoming Meetings UI

- Show selected/unresolved calendars, eligible/ineligible events, reasons, last refresh time, and repair actions.
- Add the actionable Upcoming Meetings status-menu section.

**Gate:** users can diagnose permission, selection, freshness, and parser eligibility before reminders are enabled.

### Phase 3 — In-app reminder reconciler

- Add deterministic scheduler, one-shot timer, durable opaque aliases, wake/restart behavior, and HUD/menu coordination.

**Gate:** automated timing/churn suite and real-meeting dogfood criteria below pass.

### Phase 4 — Post-confirmation calendar correlation

Only after reminder dogfood:

- Consume an already-confirmed live candidate plus snapshots.
- Strong match: normalized conference identity.
- Medium match: provider, time overlap, and captured application.
- Title-only or ambiguous: no enrichment.
- Never change detector confidence or exact capture target.

### Phase 5 — System local notifications

Only after Phase 3:

- Request notification permission separately.
- Add deterministic opaque request identifiers.
- Use minimal lock-screen content.
- Add Join and Prepare actions.
- Reconcile pending/delivered requests.
- Refetch and revalidate on action.
- Select exactly one surface: FluidVoice HUD or system notification.

### Phase 6 — Attendee-assisted naming

Separate explicit opt-in:

- Fetch roster only for an unambiguous matched event.
- Reduce and discard raw participant data.
- Require confirmation for every proposed name.
- No cross-meeting voice identity.

## 11. Test strategy

### Detector isolation

Run the Cartesian product of calendar actions against live states:

- No live prompt.
- Visible live prompt.
- Suppression-retrying live prompt.
- Live prompt starting.
- Active recording.
- Dictation/command overlay.

Assert detector episode, consumption, bundle suppression, and dismissal-counter state is identical to the calendar-absent baseline.

### Permission and EventKit

- Feature disabled creates no event store and no TCC prompt.
- Grant followed by zero selection performs no event fetch.
- Denial and restriction.
- Revocation before, during, and after a fetch.
- Account/calendar removal and re-add.
- Empty and unresolved calendar selection.
- Store-change storms and stale-generation cancellation.
- Manual signed Debug and Release TCC matrix.

### Scheduler

- Reminder boundary and expiry.
- 20-second collapse.
- Wake before and after presentation.
- Restart inside and outside eligibility.
- DST fold/gap.
- Timezone and clock change.
- Six-hour fetch horizon.
- Edit, delete, cancel, reschedule, recurring detach, and identifier churn.
- Overlap, equal-start ties, back-to-back events, and several newly due events.
- Recording ends before and after event start.
- Keychain locked, unavailable, item-not-found, and transient error.

### URL security

- Non-HTTPS and custom schemes.
- Userinfo.
- Non-ASCII and malformed hosts.
- Dot-boundary attacks.
- Redirect wrappers.
- HTML notes and scan-size limits.
- Multiple source fields where an earlier value is not a meeting URL.
- Join-time revalidation and stale-link failure.

### Privacy

Run a fixture calendar containing distinctive titles, attendee names, notes, URLs, codes, and passcodes. Capture:

- Logs.
- Analytics payloads.
- UserDefaults.
- Keychain values.
- Meeting setup state before explicit start/save.

Assert that only selected calendar identifiers, opaque aliases, provider enums, and content-free counters persist or leave the calendar subsystem.

## 12. Phase 3 dogfood gate

Use at least 20 real eligible meetings.

- At least 95% of first HUD presentations occur within ±5 seconds of the first schedulable moment.
- Zero calendar-caused detector-state mutations.
- Zero duplicate HUDs in one process lifecycle.
- Zero wake bursts.
- Zero wrong Join targets.
- Zero raw calendar content in logs, analytics, or persistence.
- Correct reminders after reschedule and recurring detach.
- Fetch latency and energy impact recorded using content-free metrics.

Do not begin system-notification work until this gate passes.

## 13. Suggested first implementation slice

Start only with Phase 0 and Phase 1A:

1. Amend the PRD and add the usage description.
2. Add educational permission UI scaffolding without calling EventKit yet.
3. Introduce source-neutral prompt identity and callbacks.
4. Preserve live behavior.
5. Add the detector-invariance interleaving suite.

Do not combine this slice with EventKit fetching or reminder scheduling. Keeping the first change narrow makes any live-detection regression attributable to the HUD refactor.

## 14. Deferred product choices

- Whether users may opt into showing meeting titles in the floating HUD.
- Whether redirect wrappers are common enough in real EventKit data to justify bounded offline unwrapping.
- Whether the six-hour horizon should change after energy measurements.
- Whether overlapping meetings eventually need a chooser rather than menu-only secondary entries.
- Whether system notifications should replace or complement the in-app HUD when FluidVoice is running.
