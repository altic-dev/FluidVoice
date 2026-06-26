# macOS UI Automation Plan (Separate Branch)

## Goal
Build reliable automated test coverage for FluidVoice native macOS UI behavior (overlay, prompt picker, mode switching, context behavior), without blocking release stabilization work.

## Branch Strategy
- Branch name: `B/macos-ui-automation`
- Keep this work isolated from release branch changes.
- No schema/storage migrations in this branch unless explicitly required for testability.

## Scope
- Add stable accessibility identifiers for key UI controls.
- Add macOS `XCUITest` smoke coverage for Dictate/Edit/Command interaction flows.
- Add deterministic app launch mode for UI tests (`--ui-testing`) to reduce flakiness.
- Add targeted logic tests for migration/state synchronization edge cases.

## Out of Scope
- Per-prompt shortcut assignment.
- Product behavior redesign.
- Replacing rewrite internals in this phase.

## Phase 1: Testability Hooks (Accessibility IDs)
### Files likely to touch
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Sources/Fluid/Views/BottomOverlayView.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Sources/Fluid/Views/NotchContentViews.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Sources/Fluid/UI/AISettingsView+AdvancedSettings.swift`

### IDs to add first
- Prompt chip button
- Prompt menu tab: Dictate
- Prompt menu tab: Edit
- Prompt list row (profile)
- Selected checkmark container
- Right-side mode label
- Context toggle (editor)
- Save button (editor)

## Phase 2: UI Smoke Suite (`XCUITest`)
### New target/files
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Tests/FluidVoiceUITests/FluidVoiceUITests.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Tests/FluidVoiceUITests/PromptPickerSmokeTests.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Tests/FluidVoiceUITests/ModeSwitchSmokeTests.swift`

### Initial smoke tests
1. Prompt picker tab switch keeps chip/tab/checkmark aligned.
2. Dictate -> Edit live switch updates right-side label to `Edit`.
3. Edit -> Dictate live switch updates right-side label to `Dictate`.
4. Command mode entry/exit does not corrupt picker mode state.
5. Prompt selection persists after close/reopen of overlay.

## Phase 3: Deterministic UI Test Runtime
### Files likely to touch
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Sources/Fluid/FluidApp.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Sources/Fluid/ContentView.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Sources/Fluid/Services/NotchOverlayManager.swift`

### Additions
- `--ui-testing` launch argument handling.
- Disable or stub fragile external dependencies in test mode where needed (network/transcription side effects).
- Keep prompt composition logic intact; only remove nondeterminism.

## Phase 4: Logic/Concurrency Guard Tests
### Files likely to touch
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Tests/FluidTests/SettingsStorePromptMigrationTests.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Tests/FluidTests/PromptPickerStateSyncTests.swift`
- `/Users/barathwajanandan/Documents/mac_apps/FluidVoice/Tests/FluidTests/LiveModeSwitchTests.swift`

### Assertions
- Legacy write/rewrite prompt modes normalize to edit once.
- Normalized state does not re-write storage repeatedly.
- Live switch preserves context when already present.
- Processing guard blocks unsafe mode switch mutations.

## CI / Execution
- Add UI smoke job (macOS runner) gated on target branch or label.
- Keep runtime short (<= 3-5 minutes).
- Fail fast on first critical smoke failure.

## Performance and Low-Resource Principles
- Prefer small deterministic smoke tests over heavy end-to-end scripts.
- Avoid polling loops and long sleeps; use expectations with short timeouts.
- Reuse shared helpers to reduce startup overhead in tests.

## Definition of Done
1. Accessibility IDs exist for all prompt-picker critical controls.
2. Smoke suite passes locally and in CI.
3. No regression to Dictate/Edit/Command user-facing labels.
4. Migration/state sync tests cover known release-risk edges.
5. Test docs include how to run locally.

## Local Run Commands (to finalize when branch starts)
- Unit tests: `xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -only-testing:FluidTests`
- UI tests: `xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -only-testing:FluidVoiceUITests`

## Notes
- Keep internal compatibility symbols (`rewrite*`) unchanged in this automation branch unless needed for explicit test seams.
- Revisit per-prompt shortcut assignment in a later dedicated branch.
