# Registered recording shortcuts

Recording chords such as Option + Space use Carbon's `RegisterEventHotKey` rather than depending exclusively on keyboard events from a session event tap. Secure Event Input can suppress ordinary keyboard events even when `CGEvent.tapIsEnabled` reports true.

## Routing

- `RegisteredHotkeyChord` selects keyboard shortcuts with ordinary modifiers. Plain keys, modifier-only combinations, Fn combinations, and mouse buttons remain on the existing event-tap path.
- `CarbonHotkeyDriver` owns exclusive native registrations and the pressed/released event handler. Exclusive registration makes competing owners report a failure instead of silently accepting an undeliverable registration. Its lifetime releases both. Registration failures are logged with the OSStatus and retain the event-tap fallback.
- `RegisteredHotkeys` deduplicates identical registrations and repeated pressed events, balances releases, and remembers which physical key events should pass through the event tap to Carbon. Release ownership does not depend on the modifier still being held.
- `GlobalHotkeyManager` sends registered events directly into its existing keyboard routing. The constructed CGEvent is never posted into the system event stream. Toggle, hold, automatic, and mode-selection logic stay shared.
- Editing shortcuts temporarily unregisters chords so the recorder can receive them. Configuration changes complete active registered presses before changing their meaning. Shortcut capture and manual reinitialization mark their releases as interruptions so Automatic mode stops even a short press instead of treating it as a tap to continue recording. Event-tap recovery preserves a held registered shortcut.
- Sleep/wake and session deactivate/reactivate notifications finish held registered presses as interruptions and clear event-tap release bookkeeping. Registrations remain intact, so the next physical press works even if the old key-up was lost.
- Cancel and paste-last remain context-sensitive event-tap actions. They are not newly claimed as unconditional global registrations.

The manager logs Secure Input transitions separately from event-tap health. It does not disable Secure Input in another application or claim that restarting an event tap overrides that protection. Failed/unsupported registrations remain susceptible to Secure Input.

## Automated validation

Run the focused tests without downloading the speech-model dependencies:

```sh
Tests/run_registered_hotkey_tests.sh
```

The same XCTest cases are included in the Xcode integration-test target. They cover eligibility, independent Carbon delivery, repeat suppression, modifier-first releases, registration failures and retry, configuration changes, stale events, interruption cleanup, and actual native registration cleanup. Native registration is skipped if the test session cannot register the uncommon test chord.

## Physical delivery check

```sh
Tests/run_registered_hotkey_tests.sh --live
```

The probe uses the production registration backend and listens only for Option + Space for 90 seconds. It does not record audio, start FluidVoice dictation, or observe ordinary typing. Each received edge reports whether Secure Input is active. It unregisters before exiting. Quit other apps using the same shortcut for an isolated test; use a normal editable field, not a password field.

Validate both with and without Secure Input active. Press twice, hold, and release Option before Space. Expect one down and one up per press, with no repeats. An empty result is inconclusive unless the tester actually pressed the keys. Registration success alone does not establish key delivery.

## App acceptance checks

Before release, test the complete app in toggle, hold, and automatic modes, including quick release while recording is still starting. Check prompt/command/rewrite shortcuts, shortcut editing, external-keyboard modifiers, competing registrations, synthesized typing, sleep/wake, session lock, and VNC connect/disconnect. Repeat on Intel and Apple Silicon, including supported macOS versions where Carbon rejects some modifier combinations. Verify that each shortcut produces exactly one action and that hold recordings stop on release.
