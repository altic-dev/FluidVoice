import Foundation

/// Serializes access to `NSPasteboard.general` across Fluid's synthetic copy/paste operations.
///
/// Two subsystems mutate the shared pasteboard with snapshot/restore semantics:
/// - `TypingService` paste insertion temporarily writes the to-be-pasted text, posts Cmd+V,
///   then restores the user's clipboard on a background queue *after* a verification window
///   (up to several seconds later) — so its pasteboard "session" outlives the synchronous call.
/// - `TextSelectionService` selection-read fallback snapshots the clipboard, posts Cmd+C,
///   reads the copied selection, then restores the snapshot.
///
/// Without coordination these overlap: a still-pending paste restore bumps `changeCount`
/// (and rewrites the pasteboard) while a selection read is polling for *its* Cmd+C, so the
/// previous insertion text gets mistaken for the freshly-copied selection and the wrong
/// snapshot is restored. This type is the single primitive both paths share to make their
/// pasteboard sessions mutually exclusive (issue #259).
///
/// The session is a counting semaphore with value 1. A paste path holds it from the
/// synchronous setup through the async restore (handing the `signal()` off to `restoreQueue`);
/// the selection-read path holds it only for its own short critical section and always
/// releases before returning.
enum PasteboardSession {
    /// One-at-a-time gate around `NSPasteboard.general` mutations. Mirrors the lock that
    /// previously lived privately in `TypingService`; shared here so the selection-read path
    /// composes with it instead of racing a parallel lock.
    private static let semaphore = DispatchSemaphore(value: 1)

    /// Serial queue on which `TypingService` performs its deferred pasteboard restore and
    /// releases the session. Kept here so the session's lifetime (acquire → async restore →
    /// release) is owned by one type.
    static let restoreQueue = DispatchQueue(label: "PasteboardSession.Restore", qos: .utility)

    /// Acquires the session, blocking until it is free. Used by the paste path, which runs on
    /// a background queue and intentionally serializes behind any in-flight session.
    static func beginExclusive() {
        self.semaphore.wait()
    }

    /// Attempts to acquire the session within `timeoutMicros`. Returns `true` if acquired (the
    /// caller then owns the session and must call `endExclusive()`), `false` on timeout (the
    /// caller did **not** acquire it and must **not** call `endExclusive()`).
    ///
    /// Used by the main-thread selection-read fallback. The bounded timeout is load-bearing for
    /// deadlock-freedom, not just UX: the paste path runs its paste closure *while holding the
    /// session*, and that closure resolves the layout-aware key code, which does
    /// `DispatchQueue.main.sync` when invoked off the main thread (see `LayoutAwareKeyCode`). So
    /// during its brief key-code-lookup window a background paste holds the session *and* is
    /// waiting on the main thread — if the main-thread selection read blocked on the session
    /// forever, the two would wait on each other. The timeout breaks that cycle: on expiry the
    /// selection read skips its clipboard fallback, the main run loop drains, the paste's
    /// `main.sync` completes, and the session is released. Callers must not proceed to mutate
    /// or sample the pasteboard unguarded after a timeout, because that re-opens the
    /// cross-session race this guard exists to prevent. **Do not convert this to an unbounded
    /// blocking wait: the timeout is what prevents the inversion from hanging.**
    static func tryBeginExclusive(timeoutMicros: useconds_t) -> Bool {
        let deadline = DispatchTime.now() + .microseconds(Int(timeoutMicros))
        return self.semaphore.wait(timeout: deadline) == .success
    }

    /// Releases the session previously acquired via `beginExclusive()` or a `true` result from
    /// `tryBeginExclusive(timeoutMicros:)`.
    static func endExclusive() {
        self.semaphore.signal()
    }
}
