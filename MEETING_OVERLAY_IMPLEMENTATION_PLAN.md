# Meeting overlay visual unification — implementation plan

Status: **implemented through the code-hardening gates on 2026-08-25. Unsigned test build succeeds,
14 focused meeting/dictation overlay tests pass, and the final adversarial implementation review is
APPROVE. Remaining release gates are manual visual/interaction testing, the VoiceOver checklist,
multi-display/full-screen/screen-share checks, and the two-hour soak.**

## 1. Product decision

FluidVoice keeps dictation and meeting overlays independent at the lifecycle and settings layers,
but both use the same visual primitives. Meeting recording exposes two presentation choices:

- **Pill** — a persistent 84×32 recording control suitable for a long meeting.
- **Captions** — a fixed-size rolling subtitle strip, initially 480×132.

The saved meeting preference is independent from the dictation overlay size. A user can therefore
use Compact/Small for dictation and Pill for meetings. Clicking the meeting Pill temporarily expands
to Captions; collapsing returns to Pill. A preference change applies at the **next meeting start**;
it never overrides temporary presentation choices in an active meeting.

The on-demand resizable full captions window remains a separate destination. It is not a third
meeting-overlay preference.

## 2. Goals and acceptance criteria

### Product

- Pill and Captions use the established dictation overlay as the canonical visual recipe: same black
  surface, border vocabulary, shadow, waveform vocabulary, and spacing scale. Meeting-specific
  differences are limited to content and long-duration motion.
- Meeting and dictation preferences are stored independently.
- The visible Pill remains exactly 84×32 and unobtrusive for the entire meeting; its panel is larger
  only to reserve transparent shadow/hit-test insets. Stop remains immediately available.
- Pill ↔ Captions morphs in place without opening a second panel, jumping screens, or losing the
  user-positioned anchor.
- Captions update without resizing the panel for each partial transcript update.
- Meeting recording lifecycle, stop behavior, degraded states, and full captions remain unchanged.

### Accessibility and platform behavior

- VoiceOver exposes recording state, expand/collapse, Stop, and caption content without duplicate
  announcements for rapidly changing partial text.
- Reduce Motion removes the spring/large geometry interpolation and uses an immediate resize plus a
  short cross-fade, or no animation when cross-fade preference also requires it.
- Controls retain usable hit regions even though the visible Pill is 84×32.
- The panel remains non-activating, movable, visible across Spaces/full-screen apps, and clamped to
  the active display after display changes.
- Screen-share exclusion is **not** an acceptance guarantee. Apple now documents
  `NSWindow.SharingType.none` as a legacy constant macOS no longer uses. Keep it only as best-effort
  compatibility if it produces no warning, and test popular meeting apps manually. The small Pill is
  the dependable mitigation when a whole display is shared.

### Engineering

- Shared primitives have no dependency on `NotchContentState`, `MeetingSessionCoordinator`, or a
  singleton settings store.
- Dictation behavior and dimensions do not change as an incidental result of extraction.
- Meeting presentation is modeled explicitly; it is not another Boolean layered onto `isExpanded`.
- Presentation initializes only on the transition into a new recording, never on degraded/recovered
  state publishes inside the same recording.
- All setting decoding is backward-compatible, including backup import from older builds.

## 3. Current architecture and constraints

### Established dictation overlay

- `BottomOverlayView.swift` owns dictation layout presets (`pill`, `small`, `medium`, `large`), its
  black surface, border, shadow, waveform rendering, and content.
- `BottomWaveformView` cannot be reused directly because it reads `NotchContentState.shared` and
  owns dictation-specific processing/release animation.
- `BottomOverlayWindowController` cannot host meetings because its lifecycle, hit-testing, menus,
  target app state, and dismissal behavior are dictation-specific.

### New meeting overlay from this iteration

- `MeetingRecordingPillController` owns one persistent `NSPanel`, saved placement, display clamping,
  and the current 84×32 ↔ 480×132 resize.
- `MeetingRecordingPillContent` owns recording level, Stop, rolling subtitle composition, and the
  current matched-geometry transition.
- `MeetingFloatingPanelFactory` supplies the correct non-activating, floating, movable panel behavior.
- `MeetingLiveBubbleComposer` and `MeetingLiveBubbleScrollList` already separate caption composition
  from the panel presentation and should remain the caption data/view foundations.

### Important constraints

- AppKit owns the outer panel frame and is the only geometry animation clock. The current AppKit cubic
  resize and independent SwiftUI spring are a confirmed race that the new design must remove.
- The meeting overlay can remain visible for hours. Do not copy the dictation Pill's continuous
  30-fps rotating border into the persistent meeting surface. Share its static visual recipe, while
  audio bars update only when levels change.
- Captions can update many times per second. Their fixed panel dimensions must not cause fitting-size
  recalculation or AppKit frame animation on transcript changes.
- The repository currently has no view/controller tests for meeting overlay presentation.
- The cached panel root currently snapshots theme construction and has no explicit live view model;
  presentation, appearance, and accessibility state need an observable bridge that survives meetings.

## 4. Target architecture

```text
Shared visual layer (stateless)
├── FluidOverlaySurface
├── FluidOverlaySurfaceStyle
├── FluidOverlayShadowMetrics
├── FluidOverlayLevelBars
└── FluidOverlayMotionCurve

Dictation feature (existing lifecycle)
├── BottomOverlayWindowController
├── BottomOverlayView
└── Dictation waveform/state adapter

Meeting feature (independent lifecycle)
├── MeetingRecordingOverlayController
├── MeetingOverlayViewModel
├── MeetingOverlayPreference: pill | captions
├── MeetingOverlayPresentation: pill | captions
├── MeetingOverlayGeometry
├── MeetingOverlayPresentationReducer
├── MeetingRecordingOverlayContent
└── Meeting level/transcript/state adapter
```

### Shared primitives

Create `Sources/Fluid/UI/FluidOverlayPrimitives.swift` containing only stateless visual types:

- `FluidOverlaySurfaceStyle`: fill, border gradient/opacities, line width, corner radius, shadow.
- `FluidOverlaySurface`: renders the background from a supplied style and shape.
- `FluidOverlayLevelBars`: renders supplied normalized bar heights/level using supplied metrics.
- `FluidOverlayShadowMetrics`: visible and hit-test shadow extents.
- `FluidOverlayMotionCurve`: one duration and cubic curve representable as AppKit timing and, where
  needed for opacity only, SwiftUI timing. Geometry never uses a SwiftUI spring.

Do not put feature sizes into the shared visual layer. Dictation retains its current layout presets;
meeting retains 84×32 and 480×132 constants. Sharing appearance must not imply that unrelated
features need identical dimensions.

The canonical compact recipe is the dictation Pill's black fill, white border gradient, radius, and
shadow. The meeting Pill uses the same static recipe; it does **not** copy the dictation Pill's
continuous rotating-border timeline because a meeting may last hours. Captions use the established
larger dictation surface recipe. Recording accent appears in content, not a feature-specific border.

### Meeting state

Add two distinct concepts:

```swift
enum MeetingOverlayPreference: String, Codable, CaseIterable {
    case pill
    case captions
}

enum MeetingOverlayPresentation: Equatable {
    case pill
    case captions
}
```

`MeetingOverlayPreference` is persisted. `MeetingOverlayPresentation` is session UI state. On the
non-visible → recording edge, the controller initializes presentation from the saved preference. A
tap or collapse only changes presentation. A settings or backup-restore change during a recording is
saved for the next recording and does not mutate the active presentation.

Use an enum even though there are two cases; this prevents contradictory `isExpanded`, preferred,
floating-window-visible, and recording-state Booleans as the feature grows.

### Observable state bridge

Create one `@MainActor MeetingOverlayViewModel: ObservableObject` and inject it into the cached panel
root once. It owns current presentation, recording/session identity, appearance inputs, Reduce Motion,
and the precomposed caption string. The controller mutates this model; the root never snapshots a
preference or accent value at panel creation.

Initialize presentation only when a new recording becomes visible. `recording ↔ recordingDegraded`
must preserve the user's temporary Pill/Captions choice.

### Geometry and position

Add pure `MeetingOverlayGeometry` before controller work. Inputs are current visible-content frame,
target visible size, transparent outer insets, and screen visible frames. Output is a clamped panel
frame plus the visible-content frame inside it.

The 84×32 and 480×132 values describe the **visible surface**, not the `NSPanel` frame. The panel adds
transparent insets for shadow and larger control hit regions. A meeting-specific hosting view rejects
hits in transparent shadow-only regions, matching the established dictation approach.

Do not persist a size-dependent window origin. Persist a presentation-independent anchor derived from
the visible surface (center X and bottom Y, with display identity when available), then derive either
presentation frame from it. Preserve `"MeetingRecordingPill"` long enough to migrate the existing
autosaved frame once; renaming Swift types must not lose the user's position.

Expose `currentOverlayFrame` for every visible presentation. Replace `expandedPanelFrame` and the
detection nudge's hard-coded 84×32 fallback so caption-window and nudge placement use the real frame.

### Morph ownership

Keep Pill and Captions in the same `NSPanel` and SwiftUI root. Use one transition coordinator:

1. Resolve target presentation and pre-clamped target frame from the pure geometry layer.
2. Increment a presentation generation token; stale animation completions become no-ops.
3. Let AppKit animate the outer frame with the single cubic timing curve.
4. Disable independent SwiftUI geometry animation. Lay out the persistent surface and controls from
   actual hosting-view bounds so they follow AppKit interpolation on every frame.
5. Keep both content layers in one root. Derive caption opacity/clip progress from actual width rather
   than elapsed time, making panel bounds the single source of morph progress.
6. With Reduce Motion, set the frame directly and use only the system-preferred cross-fade, or no
   transition when cross-fade isn't preferred.

Stop remains interactive throughout. Repeated clicks resolve to the latest target; the generation
token drops stale completion handlers.

Reduce Motion has one source of truth in the observable view model and updates from the macOS display
accessibility-change notification. Controller and view must not read unrelated snapshots.

## 5. Phased implementation

### Phase 0 — Characterization and safety net

Purpose: lock down established dictation behavior before extracting shared visuals.

- Record current dimensions, surface colors/opacities, corner radii, shadow, waveform metrics, panel
  position, and Pill hit-testing as explicit values or focused tests.
- First add pure `MeetingOverlayGeometry` and `MeetingOverlayPresentationReducer` seams; the controller
  continues using old behavior until these seams are characterized.
- Test Pill ↔ Captions frames, shadow-padded panel bounds, pre-animation clamping, display removal,
  anchor migration, and center preservation where space allows.
- Test new-recording edges, preference/restore changes during recording, temporary expand/collapse,
  degraded/recovered state, recording stop, and rapid toggles.
- Capture manual baseline screenshots for dictation Pill and current meeting Pill in light/dark theme.
- Record the canonical dictation surface values and intentional long-duration meeting deltas.

Exit gate: baseline build/tests are green and expected visual metrics are recorded. No production
appearance changes.

### Phase 1 — Extract shared visual primitives

Purpose: establish one visual language without merging feature controllers.

- Extract the dictation overlay's static Pill surface recipe, border, shadow, and low-level bar
  rendering into `FluidOverlayPrimitives.swift`.
- Adapt `BottomOverlayView` and `BottomWaveformView` to consume the primitives while preserving its
  state adapter, processing shimmer, dimensions, and public behavior.
- Replace duplicated meeting surface and bar rendering with the same primitives, configured for the
  meeting dimensions. Keep recording semantics inside content, not the outer surface recipe.
- Add meeting hosting-view insets/hit-testing so the visible 84×32 surface has unclipped shadow and a
  usable Stop hit area without intercepting clicks in transparent padding.
- Keep the meeting panel factory and dictation window controller separate.

Exit gate: pixel/visual comparison shows no unintended dictation change; dictation overlay tests,
build, and manual record/process/dismiss cycle pass. Meeting recording/Stop still works.

### Phase 2 — Independent meeting preference

Purpose: let users select Pill or Captions independently of dictation size.

- Add `MeetingOverlayPreference` to `SettingsStore`, defaulting to `.pill`.
- Rename the established Settings > Overlay row to “Dictation overlay size” and add an independent
  “Meeting overlay” picker there with Pill and Captions. Persist immediately like other overlay
  preferences, avoiding one-off Cancel/Save semantics inside the meeting setup sheet.
- Add the field to `SettingsBackupPayload` as optional so older backups decode, and restore only when
  present. Keep the backup schema major version unchanged because the addition is backward-compatible.
- Rename the controller/content from `MeetingRecordingPill*` to `MeetingRecordingOverlay*` once in
  this phase so names match the two supported presentations. Update detection-prompt anchors.
- Add the observable view model and initialize only on a new-recording edge. Preference/restore
  changes during an active meeting apply next meeting.
- Migrate the saved frame to the presentation-independent anchor; keep the legacy autosave key stable
  during migration.
- Replace `expandedPanelFrame` with `currentOverlayFrame` and update captions-window/nudge anchors.

Exit gate: dictation and meeting selections survive relaunch independently; old settings and old
backup fixtures restore to Pill; changing/restoring preference mid-meeting doesn't disturb the active
presentation; existing position survives rename/migration.

### Phase 3 — Robust Pill ↔ Captions morph

Purpose: preserve the fluid expansion while making transition behavior deterministic.

- Connect the controller to the Phase 0 geometry/reducer seams and fixed visible presentation sizes.
- Replace `isExpanded` with `MeetingOverlayPresentation` and centralize transitions in the controller.
- Keep one surface identity and remove the competing SwiftUI geometry spring. Controls and captions
  lay out/fade from actual panel bounds.
- Coalesce rapid toggles and protect against recording ending, panel hiding, display changes, or full
  captions opening during a transition.
- Captions preference starts expanded; Pill preference starts compact. Manual expand/collapse remains
  temporary and does not rewrite the preference.
- Preserve the current transition into the full resizable captions window, but source it only from a
  stable completed Captions frame; opening it mid-transition first resolves the overlay state.
- Subscribe to/coalesce transcript composition only while Captions is presented (target 5–10 UI
  updates/second). Pill mode must not repeatedly compose rolling caption rows.

Exit gate: no jumps, clipping, orphan panels, or stale `isExpanded` state under normal and rapid
interaction; Reduce Motion path passes; Stop is usable in both modes and during/after transitions.

### Phase 4 — Accessibility, longevity, and platform validation

Purpose: validate a control that may remain onscreen for hours.

- Provide explicit accessibility actions for Show Captions, Hide Captions, Open Captions Window,
  and Stop Meeting Recording.
- Keep partial captions from repeatedly taking VoiceOver focus; finalized content remains reachable
  in the full captions view.
- Use a named manual VoiceOver checklist; ordinary XCTest cannot verify SwiftUI accessibility
  modifiers reliably.
- Verify hit regions, keyboard/menu-bar fallback for Stop, high contrast, Reduce Transparency,
  Differentiate Without Color, and Reduce Motion.
- Run a 2-hour soak: observe CPU/GPU wakeups, memory growth, panel ordering, transcript update cost,
  and behavior across sleep/wake and monitor changes.
- Manually test Zoom, Google Meet in Chrome, Teams, Webex, and macOS full-display/window sharing. Log
  whether the overlay appears in each sharing mode; do not claim reliable exclusion based on
  `sharingType = .none`.

Exit gate: no sustained timeline redraw loop; Pill redraws are bounded by audio-level/state updates;
caption UI publishes no faster than the chosen coalescing rate; memory stays bounded; no focus theft;
VoiceOver checklist passes; screen-sharing behavior is documented.

## 6. Expected files

### Add

- `Sources/Fluid/UI/FluidOverlayPrimitives.swift`
- `Tests/FluidDictationIntegrationTests/MeetingOverlayPresentationTests.swift`

### Modify

- `Sources/Fluid/Views/BottomOverlayView.swift`
- `Sources/Fluid/UI/MeetingRecordingPill.swift` (renamed after Phase 1 safety gate)
- `Sources/Fluid/UI/MeetingFloatingCaptionsPanel.swift`
- `Sources/Fluid/UI/MeetingDetectionPrompt.swift`
- `Sources/Fluid/UI/SettingsView.swift`
- `Sources/Fluid/Persistence/SettingsStore.swift`
- `Sources/Fluid/Persistence/BackupService.swift`
- existing settings/backup tests as appropriate
- Xcode project references if the project does not discover new files automatically

Do not mix detector behavior, calendar integration, notification redesign, or dictation-during-
meeting audio arbitration into this change.

## 7. Test strategy

### Automated

- Presentation reducer/state transitions, including rapid/reentrant requests.
- Frame calculation and clamping on one/multiple displays and near every screen edge.
- Preference default, persistence, invalid raw-value fallback, and independence from dictation size.
- Backup decode with the new field absent; round-trip with Pill and Captions.
- Caption rolling-text composition remains deterministic.
- Observable propagation of presentation, appearance, accessibility, and new-recording edges.
- Existing meeting live-transcription and dictation integration tests stay green.

### Manual visual/interaction matrix

For Pill and Captions, test:

- light/dark appearance and each accent color;
- normal motion and Reduce Motion;
- recording, degraded microphone, stopping, and recording-ended states;
- click expand, collapse, full captions, Stop, dragging, and rapid toggles;
- bottom/side screen placement, Dock/menu-bar changes, multiple monitors, full-screen Spaces;
- live partial captions at high update frequency;
- dictation overlays before and after the primitive extraction;
- major meeting apps' window-share and display-share modes.

### Commands during implementation

- Run focused overlay/settings tests after each phase.
- Run `swift test` after state/settings work.
- Run the signed app build and manual meeting test after Phases 1, 3, and 4.
- Reinstall only through the repository's stable-signing workflow; never replace the installed app
  with an ad-hoc or identity-mismatched build.

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Shared extraction regresses dictation | Characterize first; extract stateless rendering only; visual baseline gate |
| AppKit and SwiftUI animations fight | AppKit frame is the only geometry clock; SwiftUI derives layout/progress from actual bounds |
| Cached panel freezes settings/theme | Inject one persistent observable view model and mutate it explicitly |
| Captions cause resize/layout thrash | Fixed presentation dimensions; transcript updates never request panel fitting size |
| Persistent animation wastes battery | No copied 30-fps glossy-border timeline; event-driven audio level updates; soak test |
| Preference and temporary state diverge | Separate persisted preference from session presentation; reducer tests |
| Stop becomes hard to hit in 84×32 | Preserve visible control and expand its invisible hit region; menu-bar fallback |
| Older backups fail decoding | Optional backup field with Pill fallback and fixture test |
| Screen-share privacy claim is false | Treat legacy sharing flag as best effort; test and document; rely on compact footprint |
| Rename breaks position/anchors | Migrate to a size-independent anchor, freeze the legacy key, expose current-frame semantics |
| Degrade/recover resets presentation | Initialize only on a new-recording edge, covered by reducer tests |

## 9. Rollout and rollback

- Land phases as reviewable slices; do not combine the primitive extraction and animation rewrite in
  one unreviewable change.
- Default everyone to Pill so the new preference does not unexpectedly occupy more screen space.
- Keep the old meeting rendering available behind a temporary debug switch through Phase 3 if visual
  comparison reveals regressions; remove the switch before release.
- Rollback is presentation-only: meeting recording and transcript capture must not depend on the
  overlay being visible or on either preference value.

## 10. Research basis

- Apple documents
  [`matchedGeometryEffect`](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect%28id%3Ain%3Aproperties%3Aanchor%3Aissource%3A%29)
  as synchronizing inserted/removed view geometry in one SwiftUI transaction and warns that its source
  must be unambiguous; it doesn't synchronize an independent AppKit animation context.
- Apple says
  [`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
  should avoid large animations, especially depth-like movement.
- Apple's [motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion)
  recommends purposeful, brief motion and avoiding unnecessary motion for frequent actions.
- AppKit's
  [`nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
  avoids activating the owning app, while
  [`fullScreenAuxiliary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
  allows the panel alongside a full-screen window.
- Apple now labels
  [`NSWindow.SharingType.none`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum)
  a legacy constant macOS no longer uses. ScreenCaptureKit
  [exclusion filters](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init%28display%3Aexcludingwindows%3A%29)
  apply only when FluidVoice owns that capture filter; they can't control another application's
  display-share filter.

## 11. Adversarial review findings and resolutions

Both independent reviewers returned **REVISE** on the initial draft.

### Agreement

- The AppKit resize and SwiftUI spring were unsynchronized; synchronization was asserted, not designed.
- Persisted preference and temporary presentation needed explicit, tested semantics.
- The autosaved size-dependent origin and stale `expandedPanelFrame` contract were unsafe once
  Captions could be the resting presentation.
- Shared visuals needed a canonical recipe rather than an unspecified “same family.”
- Long-lived Pill performance needed to address transcript/coordinator redraws, not only the rotating
  border animation.

### Differences and decision

- Opus recommended AppKit as the sole geometry driver; Kimi proposed matching cubic curves across
  AppKit and SwiftUI. This plan takes the stricter single-driver approach: AppKit bounds drive SwiftUI
  layout and morph progress. A shared cubic curve remains only for AppKit geometry and opacity.
- Opus recommended an observable live-state bridge. Kimi emphasized ambiguous active-meeting setting
  changes. The revised plan adds the bridge but applies preferences only at the next recording edge.
- Kimi challenged putting a draft preference inside a Save/Cancel sheet. The setting now lives in the
  established global Overlay settings and persists immediately.
- Kimi caught that 84×32 couldn't simultaneously be the full panel frame, preserve shadow, and offer
  larger hit targets. It is now explicitly the visible-surface size with transparent panel insets.

Neither reviewer recommended merging dictation and meeting lifecycle controllers. Both accepted
shared stateless primitives plus independent feature state as the correct boundary.

## 12. PE-cycle status

1. Analyse — complete.
2. Plan — complete.
3. Adversarial review — complete through Orchestrate: Opus 5 and Kimi K3; both initial verdicts
   `REVISE`.
4. Revise/lock — reviewer findings incorporated; awaiting user approval.
5. Implement — explicitly out of scope until the plan is approved.
6. Post-implementation review — required after each phase and at completion.
