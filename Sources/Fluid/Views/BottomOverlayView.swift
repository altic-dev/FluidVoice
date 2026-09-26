//
//  BottomOverlayView.swift
//  Fluid
//
//  Bottom overlay for transcription (alternative to notch overlay)
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Audio level lives outside NotchContentState so ~94 Hz level ticks only
/// invalidate the waveform, not every view observing the shared state.
@MainActor
final class OverlayAudioLevelState: ObservableObject {
    static let shared = OverlayAudioLevelState()
    @Published var level: CGFloat = 0
    /// False from show until the microphone delivers its first buffer.
    @Published var isLive = false
}

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingReleaseTransitionResetWorkItem: DispatchWorkItem?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var targetScreen: NSScreen?
    private var userDragObserver: Any?
    private var pendingOriginSave: DispatchWorkItem?
    /// The dragged origin as of the last pointer movement, ahead of the coalesced write
    /// to settings. A reposition triggered mid-drag — the preview text growing, say —
    /// would otherwise read the pre-drag origin and snap the overlay out from under the
    /// pointer. It carries its own arrangement because settings still holds the previous
    /// one until the write lands.
    private var liveCustomOrigin: OverlayPlacedOrigin?
    private var isApplyingProgrammaticFrame = false
    private var releaseTransitionActiveUntil: Date?
    private var deferredResizePending = false
    private var presentationGeneration: UInt64 = 0
    static let exitDuration: TimeInterval = 0.08
    private var isHideInProgress = false
    private var activeHideGeneration: UInt64?
    private var hideWaiters: [CheckedContinuation<RecordingOverlayHideOutcome, Never>] = []
    private var pendingIgnoreMouseWorkItem: DispatchWorkItem?
    var isVisuallyHiddenForTests: Bool {
        self.window?.isVisible != true || self.window?.alphaValue == 0
    }

    /// Drops the cached panel so a test can exercise the launch-time prepare path.
    func destroyWindowForTests() {
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        self.pendingIgnoreMouseWorkItem?.cancel()
        self.pendingIgnoreMouseWorkItem = nil
        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        self.window?.orderOut(nil)
        self.window = nil
    }

    var isParkedOffscreenForTests: Bool {
        guard let window else { return false }
        return !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    var windowSizeForTests: NSSize? {
        self.window?.frame.size
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayOffsetChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayCustomOriginChanged"), object: nil, queue: .main) { [weak self] _ in
            // Handled on the run loop turn that posted it, as the drag observer is.
            // Deferring into a Task would let a save scheduled for the tail of the
            // debounce window run first and write the dragged origin back over a reset.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only ever an external change — Reset Position, or a restored backup — as
                // this controller's own writes go through `storeDraggedOverlayOrigin` and
                // post nothing. A save still queued from a drag would otherwise land
                // afterwards and undo it, and a live origin left in place would outrank
                // the new one for the rest of the process.
                self.pendingOriginSave?.cancel()
                self.pendingOriginSave = nil
                self.liveCustomOrigin = OverlayPlacement.storedOrigin()
                self.positionWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlaySizeChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSizeAndPositionUpdate(after: 0)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
                if NotchContentState.shared.isBottomOverlayPresented {
                    self.positionWindow()
                } else {
                    // macOS drags fully offscreen windows back onto a screen
                    // after a display change (login, wake, monitor plug).
                    self.parkWindowOffscreen()
                }
            }
        }
    }

    /// Pay the one-time SwiftUI/WindowServer surface cost after launch and keep
    /// the static panel outside the entire desktop so its surface is not evicted.
    func prepare() {
        guard self.window == nil else { return }
        self.createWindow()
        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        guard let window else { return }

        // Alpha 0 like a completed hide: if a later display change pulls the
        // parked panel back onto a screen, it must stay invisible.
        self.parkWindowOffscreen()
        window.alphaValue = 0
        window.orderFrontRegardless()
        CATransaction.flush()
        Self.overlayBench("bottom_prepared")
    }

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var showTrace = OverlayCloseTrace("bottom.show")
        defer { showTrace.finish() }
        Self.overlayBench("bottom_show_start mode=\(mode.rawValue) windowExists=\(self.window != nil)")
        self.cancelInFlightHideForNewPresentation()
        self.presentationGeneration &+= 1

        self.endReleaseTransition(flushDeferredUpdate: false)
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()
        self.ensureMouseDownMonitors()

        // Create window if needed
        if self.window == nil {
            self.createWindow()
        }
        self.cancelExitAnimation()
        OverlayAudioLevelState.shared.isLive = false
        // Keep the previous content invisible while state changes. Parking
        // offscreen instead costs two WindowServer fences (the frame change
        // and the window-moved echo event).
        self.window?.alphaValue = 0

        // Prepare the complete first frame while the cached panel is still
        // offscreen. Revealing the neutral shell first causes a visible flash
        // that reads as the overlay appearing twice.
        NotchContentState.shared.setBottomOverlayPresented(false)
        NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
        NotchContentState.shared.mode = mode
        switch mode {
        case .dictation: NotchContentState.shared.promptPickerMode = .dictate
        case .edit, .write, .rewrite: NotchContentState.shared.promptPickerMode = .edit
        case .command: break
        }
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        OverlayAudioLevelState.shared.level = 0
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(false)

        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        NotchContentState.shared.setBottomOverlayPresented(true)
        showTrace.mark("state")
        self.prepareFirstFrameForNewPresentation(trace: &showTrace)

        // Submit one complete frame to WindowServer.
        self.window?.setAccessibilityChildren(nil)
        self.window?.setAccessibilityElement(true)
        self.pendingIgnoreMouseWorkItem?.cancel()
        self.pendingIgnoreMouseWorkItem = nil
        if self.window?.ignoresMouseEvents == true {
            self.window?.ignoresMouseEvents = false
        }
        self.window?.alphaValue = 1
        CATransaction.setCompletionBlock {
            DebugLogger.shared.debug(
                "SHOW_COMMIT elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "StopTiming"
            )
        }
        self.window?.orderFrontRegardless()
        showTrace.mark("orderFront")
        self.window?.contentView?.displayIfNeeded()
        self.window?.displayIfNeeded()
        showTrace.mark("display")
        CATransaction.flush()
        showTrace.mark("flush")
        Self.overlayBench("bottom_order_front elapsedMs=\(Self.elapsedMs(since: startedAt))")
        Self.overlayBench("bottom_visible elapsedMs=\(Self.elapsedMs(since: startedAt))")

        self.audioSubscription?.cancel()
        self.audioSubscription = audioPublisher
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { level in
                OverlayAudioLevelState.shared.level = level
            }
    }

    func hide() {
        guard SettingsStore.shared.overlayClosingAnimationEnabled else {
            self.hideImmediately()
            return
        }
        guard !self.isHideInProgress else { return }
        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        self.activeHideGeneration = currentGeneration
        let visualStartedAt = ProcessInfo.processInfo.systemUptime
        self.beginDismissalVisualIfPresented(generation: currentGeneration)
        DebugLogger.shared.debug("HIDE_TRACE phase=dismissal_state elapsedUs=\(Int((ProcessInfo.processInfo.systemUptime - visualStartedAt) * 1_000_000))", source: "StopTiming")
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performHideAndWait(generation: currentGeneration)
            self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        }
    }

    /// Minimal compositor-driven fade: one commit, then WindowServer runs the
    /// animation. The window alpha drops to 0 when it completes.
    private func beginExitAnimation() {
        guard let window else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = window.contentView?.layer else {
            window.alphaValue = 0
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let generation = self.presentationGeneration
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.exitDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationGeneration == generation else { return }
                self.window?.alphaValue = 0
                DebugLogger.shared.debug(
                    "EXIT_DONE elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                    source: "StopTiming"
                )
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.exitDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "overlayExitFade")
        CATransaction.commit()
    }

    private func cancelExitAnimation() {
        guard let layer = self.window?.contentView?.layer else { return }
        layer.removeAnimation(forKey: "overlayExitFade")
    }

    /// Stops waveform updates the moment a stop begins so no overlay frame is
    /// committed while final transcription runs. Each commit blocks the main
    /// thread on WindowServer and delays the result hop back to the main actor.
    func freezeForStop() {
        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        if OverlayAudioLevelState.shared.level != 0 {
            OverlayAudioLevelState.shared.level = 0
        }
        Self.overlayBench("bottom_freeze_for_stop")
    }

    /// Removes the completed-dictation overlay before returning. The panel is
    /// parked rather than destroyed so the next presentation keeps its warm
    /// SwiftUI and WindowServer surface.
    func hideImmediately() {
        var trace = OverlayCloseTrace("bottom.hide")
        defer { trace.finish() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration

        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)

        // Window alpha is a plain WindowServer property: it needs no
        // window-management transaction and therefore no fence round trip.
        // orderOut, setFrameOrigin and an explicit CATransaction.flush each
        // block the main thread on a WindowServer fence (70-300 ms on a busy
        // host) while the shortcut is still locked. The panel stays ordered
        // in at alpha 0 so its surface remains warm for the next presentation.
        // ignoresMouseEvents is a window-management transaction (40-80 ms
        // fence); it is applied in the deferred cleanup instead.
        self.window?.alphaValue = 0
        self.window?.setAccessibilityChildren([])
        self.window?.setAccessibilityElement(false)
        // Everything below runs after the transaction carrying alpha 0 has been
        // committed to WindowServer, so SwiftUI state churn and the
        // ignoresMouseEvents fence can never delay the visual removal.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                DebugLogger.shared.debug(
                    "HIDE_COMMIT elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                    source: "StopTiming"
                )
                guard let self, self.presentationGeneration == currentGeneration else { return }
                var cleanupTrace = OverlayCloseTrace("bottom.postCommitCleanup")
                defer { cleanupTrace.finish() }
                self.clearPresentationStateAfterImmediateHide()
                cleanupTrace.mark("clearState")
                self.scheduleIgnoreMouseEventsAfterHide()
            }
        }
        DebugLogger.shared.debug(
            "HIDE_NOW hideUs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000_000)) " +
                "windowVisible=\(self.window?.isVisible == true)",
            source: "StopTiming"
        )
        Self.overlayBench("bottom_hide_alpha_return elapsedMs=\(Self.elapsedMs(since: startedAt))")
        waiters.forEach { $0.resume(returning: .hidden) }

        Self.overlayBench(
            "bottom_hide_immediate_complete elapsedMs=\(Self.elapsedMs(since: startedAt)) visible=\(self.window?.isVisible == true)"
        )
    }

    /// ignoresMouseEvents is a WindowServer fence (70-90 ms), so it is applied
    /// on the pass after the alpha-0 commit rather than inside it. Until it
    /// lands the invisible panel would swallow clicks under the pill, so this
    /// must not be deferred further. Skipped if a rapid restart re-showed the
    /// panel in the meantime.
    private func scheduleIgnoreMouseEventsAfterHide() {
        self.pendingIgnoreMouseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.window?.alphaValue == 0 else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            self.window?.ignoresMouseEvents = true
            DebugLogger.shared.debug(
                "HIDE_NOW deferredIgnoreMouseUs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000_000))",
                source: "StopTiming"
            )
        }
        self.pendingIgnoreMouseWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func clearPresentationStateAfterImmediateHide() {
        var trace = OverlayCloseTrace("bottom.clearState")
        defer { trace.finish() }
        NotchContentState.shared.setBottomOverlayPresented(false)
        trace.mark("presentedFalse")
        self.endReleaseTransition(flushDeferredUpdate: false)
        trace.mark("releaseTransition")
        NotchContentState.shared.setBottomOverlayDismissing(false)
        trace.mark("dismissingFalse")
        if NotchContentState.shared.targetAppIcon != nil {
            NotchContentState.shared.targetAppIcon = nil
        }
        trace.mark("iconClear")
        self.clearPresentationResources()
        trace.mark("resources")
        Self.overlayBench("bottom_hide_immediate_cleanup_complete")
    }

    /// Returns whether the panel finished hiding or a newer presentation
    /// superseded this request.
    func hideAndWait() async -> RecordingOverlayHideOutcome {
        guard SettingsStore.shared.overlayClosingAnimationEnabled else {
            self.hideImmediately()
            return .hidden
        }
        if self.isHideInProgress {
            return await withCheckedContinuation { continuation in
                self.hideWaiters.append(continuation)
            }
        }

        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        self.activeHideGeneration = currentGeneration
        let visualStartedAt = ProcessInfo.processInfo.systemUptime
        self.beginDismissalVisualIfPresented(generation: currentGeneration)
        DebugLogger.shared.debug("HIDE_TRACE phase=awaited_dismissal_state elapsedUs=\(Int((ProcessInfo.processInfo.systemUptime - visualStartedAt) * 1_000_000))", source: "StopTiming")
        let outcome = await self.performHideAndWait(generation: currentGeneration)
        self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        return outcome
    }

    private func completeHideOperation(generation: UInt64, outcome: RecordingOverlayHideOutcome) {
        guard self.activeHideGeneration == generation else { return }
        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private func cancelInFlightHideForNewPresentation() {
        guard self.isHideInProgress else { return }
        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: .superseded) }
        Self.overlayBench("bottom_hide_cancelled_for_new_presentation")
    }

    private func performHideAndWait(generation currentGeneration: UInt64) async -> RecordingOverlayHideOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var previousTraceTime = startedAt
        func traceHide(_ phase: String) {
            let now = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.debug("HIDE_TRACE phase=\(phase) deltaUs=\(Int((now - previousTraceTime) * 1_000_000)) totalUs=\(Int((now - startedAt) * 1_000_000))", source: "StopTiming")
            previousTraceTime = now
        }
        Self.overlayBench("bottom_hide_start windowExists=\(self.window != nil)")
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }

        guard let window = self.window, NotchContentState.shared.isBottomOverlayPresented else {
            self.clearPresentationResources()
            self.endReleaseTransition(flushDeferredUpdate: false)
            NotchContentState.shared.setBottomOverlayDismissing(false)
            NotchContentState.shared.targetAppIcon = nil
            Self.overlayBench("bottom_hide_return reason=no_window")
            return .hidden
        }

        // The content layer owns the fade. Keeping AppKit alpha at 1 until its
        // completion prevents an old implicit window animation from hiding a
        // rapid restart.
        Self.overlayBench("bottom_hide_animation_start")
        self.beginExitAnimation()
        traceHide("before_yield")
        await Task.yield()
        traceHide("after_yield")
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.exitDuration
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        traceHide("sleep_resumed")

        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }

        window.alphaValue = 0
        NotchContentState.shared.setBottomOverlayPresented(false)
        self.endReleaseTransition(flushDeferredUpdate: false)
        NotchContentState.shared.setBottomOverlayDismissing(false)
        NotchContentState.shared.targetAppIcon = nil
        self.clearPresentationResources()
        self.scheduleIgnoreMouseEventsAfterHide()
        traceHide("resources_cleared")
        traceHide("state_cleared")
        Self.overlayBench("bottom_hide_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
        return .hidden
    }

    private func beginDismissalVisualIfPresented(generation: UInt64) {
        guard self.presentationGeneration == generation,
              self.window != nil,
              NotchContentState.shared.isBottomOverlayPresented
        else { return }

        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(true)
        Self.overlayBench("bottom_hide_visual_requested")
    }

    private func clearPresentationResources() {
        var trace = OverlayCloseTrace("bottom.resources")
        defer { trace.finish() }
        self.audioSubscription?.cancel()
        trace.mark("audioCancel")
        self.audioSubscription = nil
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.targetScreen = nil
        self.removeMouseDownMonitors()
        trace.mark("cancelWorkAndMonitors")
        BottomOverlayPromptMenuController.shared.hide()
        trace.mark("promptMenu")
        BottomOverlayModeMenuController.shared.hide()
        trace.mark("modeMenu")
        BottomOverlayActionsMenuController.shared.hide()
        trace.mark("actionsMenu")
        if NotchContentState.shared.isProcessing {
            NotchContentState.shared.setProcessing(false)
        }
        trace.mark("processingFalse")
        if NotchContentState.shared.bottomOverlayAudioLevel != 0 {
            NotchContentState.shared.bottomOverlayAudioLevel = 0
        }
        if OverlayAudioLevelState.shared.level != 0 {
            OverlayAudioLevelState.shared.level = 0
        }
        trace.mark("audioZero")
    }

    func setProcessing(_ processing: Bool) {
        Self.overlayBench("bottom_set_processing processing=\(processing)")
        NotchContentState.shared.setProcessing(processing)
    }

    func refreshSizeForContent() {
        self.scheduleSizeAndPositionUpdate()
    }

    func beginReleaseTransition(duration: TimeInterval = 0.28) {
        let now = Date()
        let deadline = now.addingTimeInterval(max(duration, 0.12))
        if let existingDeadline = self.releaseTransitionActiveUntil, existingDeadline > deadline {
            self.releaseTransitionActiveUntil = existingDeadline
        } else {
            self.releaseTransitionActiveUntil = deadline
        }

        self.pendingReleaseTransitionResetWorkItem?.cancel()

        guard let activeDeadline = self.releaseTransitionActiveUntil else { return }
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.endReleaseTransition()
        }
        self.pendingReleaseTransitionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(activeDeadline.timeIntervalSince(now), 0), execute: resetWorkItem)

        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        OverlayAudioLevelState.shared.level = 0
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
    }

    func endReleaseTransition(flushDeferredUpdate: Bool = true) {
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.pendingReleaseTransitionResetWorkItem = nil
        self.releaseTransitionActiveUntil = nil
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(false)

        let shouldFlush = flushDeferredUpdate && self.deferredResizePending
        self.deferredResizePending = false

        if shouldFlush, self.window?.isVisible == true {
            self.scheduleSizeAndPositionUpdate(after: 0)
        }
    }

    private static func overlayBench(_ message: @autoclosure () -> String) {
        DebugLogger.shared.benchmark("OVERLAY_BENCH", message: message(), source: "OverlayBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private func scheduleSizeAndPositionUpdate(after delay: TimeInterval = 0.08) {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        self.pendingResizeWorkItem?.cancel()
        let scheduledGeneration = self.presentationGeneration

        // Debounce rapid streaming updates to avoid resize thrash.
        let resizeWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.presentationGeneration == scheduledGeneration else {
                Self.overlayBench("bottom_resize_drop reason=stale_generation")
                return
            }
            self.updateSizeAndPosition()
        }
        self.pendingResizeWorkItem = resizeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: resizeWorkItem)
    }

    /// Reset presentation-local SwiftUI measurements and resolve the empty
    /// session geometry before the warm panel moves onscreen. Otherwise the
    /// panel can reveal its previous multiline frame until resize debounce.
    private func prepareFirstFrameForNewPresentation(trace: inout OverlayCloseTrace) {
        guard let window,
              let hostingView = window.contentView as? NSHostingView<BottomOverlayView>
        else { return }

        hostingView.rootView = BottomOverlayView()
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        trace.mark("layout1")
        let firstFrameSize = hostingView.fittingSize
        trace.mark("fittingSize")
        hostingView.frame = NSRect(origin: .zero, size: firstFrameSize)
        window.setFrame(NSRect(origin: window.frame.origin, size: firstFrameSize), display: false)
        trace.mark("setFrame")
        self.positionWindow()
        trace.mark("position")
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        trace.mark("layout2")
    }

    /// Update window size based on current SwiftUI content and re-position
    private func updateSizeAndPosition() {
        var trace = OverlayCloseTrace("bottom.layout")
        defer { trace.finish() }
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        guard let window = window, let hostingView = window.contentView as? NSHostingView<BottomOverlayView> else { return }

        // Re-calculate fitting size for the new layout constants
        let newSize = hostingView.fittingSize
        trace.mark("fittingSize")

        // Avoid redundant content-size updates while AppKit is already resolving constraints.
        // Re-applying the same size can trigger unnecessary update-constraints churn.
        let currentSize = window.contentView?.frame.size ?? window.frame.size
        let widthChanged = abs(currentSize.width - newSize.width) > 0.5
        let heightChanged = abs(currentSize.height - newSize.height) > 0.5

        if widthChanged || heightChanged {
            // Resize from the current origin to avoid AppKit's default top-left anchoring,
            // which can visually push the overlay down before we re-position it.
            let currentOrigin = window.frame.origin
            let resizedFrame = NSRect(origin: currentOrigin, size: newSize)
            window.setFrame(resizedFrame, display: false)
        }

        // Re-position
        trace.mark("setFrame")
        self.positionWindow()
        trace.mark("position")
    }

    /// The window jumps to its new size (its extra area is transparent) while
    /// the pill's content springs into it, anchored at the bottom. A spring
    /// retargets smoothly when the text keeps growing mid-motion.
    static let growthAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.86)

    private func createWindow() {
        let panel = BottomOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = true
        panel.allowsUserDragging = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayView()
        let hostingView = BottomOverlayHostingView(rootView: contentView)

        // Let SwiftUI determine the size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Make hosting view fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()

        self.window = panel
        self.observeUserDrags(of: panel)
    }

    /// Remembers where the user dragged the overlay so the choice survives the next
    /// presentation and the next launch. Programmatic moves must not be recorded,
    /// otherwise the anchored default would immediately overwrite itself.
    private func observeUserDrags(of panel: NSPanel) {
        if let observer = self.userDragObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.userDragObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !self.isApplyingProgrammaticFrame,
                      NotchContentState.shared.isBottomOverlayPresented,
                      let window = self.window
                else { return }
                // didMove fires on every step of a drag; only the write is coalesced,
                // so that the position in memory is never behind the pointer.
                let origin = window.frame.origin
                // Sampled now rather than when the write runs: a display unplugged inside
                // the debounce window would otherwise pair this origin with an arrangement
                // it was never chosen on, which reads as a match and strands the overlay.
                let screens = OverlayPlacement.currentScreenFrames()
                self.liveCustomOrigin = OverlayPlacedOrigin(point: origin, screenFrames: screens)
                self.pendingOriginSave?.cancel()
                let save = DispatchWorkItem {
                    MainActor.assumeIsolated {
                        SettingsStore.shared.storeDraggedOverlayOrigin(origin, screenFrames: screens)
                    }
                }
                self.pendingOriginSave = save
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: save)
            }
        }
    }

    /// Moves the panel without the move being mistaken for a user drag.
    private func setFrameOriginProgrammatically(_ origin: NSPoint) {
        guard let window = self.window else { return }
        self.isApplyingProgrammaticFrame = true
        window.setFrameOrigin(origin)
        self.isApplyingProgrammaticFrame = false
    }

    private var isReleaseTransitionActive: Bool {
        guard let deadline = self.releaseTransitionActiveUntil else { return false }
        if deadline > Date() {
            return true
        }

        self.releaseTransitionActiveUntil = nil
        return false
    }

    private func ensureMouseDownMonitors() {
        if self.localMouseDownMonitor == nil {
            self.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let clickPoint: NSPoint
                if let window = event.window {
                    clickPoint = window.convertPoint(toScreen: event.locationInWindow)
                } else {
                    clickPoint = NSEvent.mouseLocation
                }

                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
                return event
            }
        }

        if self.globalMouseDownMonitor == nil {
            self.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let clickPoint = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
            }
        }
    }

    private func removeMouseDownMonitors() {
        if let monitor = self.localMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMouseDownMonitor = nil
        }
        if let monitor = self.globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMouseDownMonitor = nil
        }
    }

    @MainActor
    private func dismissMenusForClick(screenPoint: NSPoint) {
        guard self.window?.isVisible == true else { return }
        BottomOverlayPromptMenuController.shared.dismissIfNeeded(for: screenPoint)
        BottomOverlayModeMenuController.shared.dismissIfNeeded(for: screenPoint)
        BottomOverlayActionsMenuController.shared.dismissIfNeeded(for: screenPoint)
    }

    private func positionWindow() {
        // Safe check for window and screen availability
        guard let window = window else { return }
        // A hidden panel sits at alpha 0 where it is. Parking it offscreen
        // here would cost WindowServer fences right after a hide.
        guard NotchContentState.shared.isBottomOverlayPresented else { return }
        (window as? BottomOverlayPanel)?.allowsOffscreenParking = false

        // A position the user dragged to wins over the anchored default, including
        // positions past a screen edge. Settings offers "Reset Position" to undo it.
        // The in-memory origin comes first: during a drag it is ahead of settings.
        if let customOrigin = self.liveCustomOrigin ?? OverlayPlacement.storedOrigin(),
           OverlayPlacement.originIsUsable(customOrigin, size: window.frame.size)
        {
            self.setFrameOriginProgrammatically(customOrigin.point)
            return
        }

        let screen = self.targetScreen ?? window.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        guard let screen = screen else { return }

        // Apply position directly to avoid implicit frame animations during hover-driven resizes.
        self.setFrameOriginProgrammatically(Self.origin(for: window.frame.size, on: screen))
    }

    private static func origin(for windowSize: CGSize, on screen: NSScreen) -> NSPoint {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let x = fullFrame.midX - windowSize.width / 2
        let offset = SettingsStore.shared.overlayBottomOffset
        // Keep it above the dock and below the top of the visible frame.
        let minY = visibleFrame.minY + 10
        let maxY = visibleFrame.maxY - windowSize.height - 40
        let y = max(min(visibleFrame.minY + CGFloat(offset), maxY), minY)
        return NSPoint(x: x, y: y)
    }

    private func parkWindowOffscreen() {
        guard let window else { return }
        let parkingStartedAt = ProcessInfo.processInfo.systemUptime
        window.setAccessibilityChildren([])
        window.setAccessibilityElement(false)
        let accessibilityClearedAt = ProcessInfo.processInfo.systemUptime
        (window as? BottomOverlayPanel)?.allowsOffscreenParking = true
        let desktopFrame = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let edge = desktopFrame.isNull ? NSPoint(x: 100_000, y: 100_000) : NSPoint(
            x: desktopFrame.maxX + window.frame.width + 1024,
            y: desktopFrame.maxY + window.frame.height + 1024
        )
        let originStartedAt = ProcessInfo.processInfo.systemUptime
        self.setFrameOriginProgrammatically(edge)
        DebugLogger.shared.debug(
            "HIDE_TRACE phase=parking_detail accessibilityUs=\(Int((accessibilityClearedAt - parkingStartedAt) * 1_000_000)) " +
                "geometryUs=\(Int((originStartedAt - accessibilityClearedAt) * 1_000_000)) " +
                "setOriginUs=\(Int((ProcessInfo.processInfo.systemUptime - originStartedAt) * 1_000_000))",
            source: "StopTiming"
        )
    }
}

@MainActor
final class BottomOverlayPromptMenuController {
    static let shared = BottomOverlayPromptMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayPromptMenuView>?
    var isMenuVisible: Bool { self.menuWindow?.isVisible == true }
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayPromptMenuView(
            promptMode: self.resolvedPromptMode(),
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayPromptMenuView(
            promptMode: self.resolvedPromptMode(),
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func resolvedPromptMode() -> SettingsStore.PromptMode {
        switch NotchContentState.shared.mode {
        case .dictation:
            return .dictate
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return NotchContentState.shared.promptPickerMode.normalized
        }
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class BottomOverlayModeMenuController {
    static let shared = BottomOverlayModeMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayModeMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayModeMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayModeMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class BottomOverlayActionsMenuController {
    static let shared = BottomOverlayActionsMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayActionsMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

private struct BottomOverlayModeMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func modeRow(_ title: String, mode: OverlayMode, rowID: String) -> some View {
        let isSelected = self.normalizedOverlayMode == mode
        let shortcut = OverlayShortcutResolver.shortcutDisplay(for: mode, settings: self.settings)

        Button(action: {
            guard !self.contentState.isProcessing else { return }
            self.contentState.onOverlayModeSwitchRequested?(mode)
            self.onDismissRequested()
        }) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.fluidSystem(size: 15, weight: .semibold))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.modeRow("Dictate", mode: .dictation, rowID: "dictate")
            self.modeRow("Edit", mode: .edit, rowID: "edit")

            Divider()
                .padding(.vertical, 4)

            self.modeRow("Command", mode: .command, rowID: "command")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .bottomOverlaySurface(self.settings.bottomOverlayAppearance, cornerRadius: 8)
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private struct BottomOverlayPromptMenuView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var contentState = NotchContentState.shared

    let promptMode: SettingsStore.PromptMode
    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void
    @State private var hoveredRowID: String?

    /// The pill gets a menu sized like the pill: names only, no captions or shortcut badges.
    private var isCompact: Bool { self.settings.overlaySize == .pill }
    private var rowHorizontalPadding: CGFloat { self.isCompact ? 6 : 8 }
    private var rowVerticalPadding: CGFloat { self.isCompact ? 3 : 6 }
    private var rowCornerRadius: CGFloat { self.isCompact ? 5 : 7 }
    private var checkmarkSize: CGFloat { self.isCompact ? 7 : 10 }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: self.rowCornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: self.rowCornerRadius)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func shortcutDisplay(for selection: SettingsStore.DictationPromptSelection) -> String? {
        guard self.promptMode.normalized == .dictate else { return nil }

        var displays: [String] = []
        if self.settings.dictationPromptSelection(for: .primary) == selection {
            displays.append(self.settings.primaryDictationShortcutDisplayString)
        }
        if self.settings.promptModeShortcutEnabled,
           self.settings.dictationPromptSelection(for: .secondary) == selection
        {
            displays.append(self.settings.promptModeHotkeyShortcut.displayString)
        }
        if let shortcut = self.settings.dictationPromptConfiguration(for: selection).shortcut {
            displays.append(shortcut.displayString)
        }

        let uniqueDisplays = displays.reduce(into: [String]()) { result, display in
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        return uniqueDisplays.isEmpty ? nil : uniqueDisplays.joined(separator: " · ")
    }

    @ViewBuilder
    private func shortcutBadge(for selection: SettingsStore.DictationPromptSelection) -> some View {
        if !self.isCompact, let shortcut = self.shortcutDisplay(for: selection) {
            Text(shortcut)
                .font(.fluidSystem(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 82)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    /// Dictation "Default" needs a configured external provider; other prompt modes always allow it.
    private var isDefaultPromptAvailable: Bool {
        self.promptMode.normalized != .dictate
            || DictationProviderRoute.isDictationDefaultAvailable(settings: self.settings, appBundleID: DictationAppSession.shared.appID)
    }

    @ViewBuilder
    private func offRow() -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let selection = self.settings.resolvedDictationPromptSelection(for: activeSlot, appBundleID: DictationAppSession.shared.appID)
        // A Default that cannot route runs no cleanup, so Basic is what is really active.
        let isSelected = selection == .off || (selection == .default && !self.isDefaultPromptAvailable)
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.off)
            } else {
                self.settings.setDictationPromptSelection(.off)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Basic")
                Spacer(minLength: 12)
                if !self.isCompact {
                    Text("No cleanup")
                        .font(.fluidSystem(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: self.checkmarkSize, weight: .semibold))
                }
                self.shortcutBadge(for: .off)
            }
            .padding(.horizontal, self.rowHorizontalPadding)
            .padding(.vertical, self.rowVerticalPadding)
            .background(self.rowBackground(isSelected: isSelected, rowID: "off"))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? "off" : nil
        }
    }

    @ViewBuilder
    private func defaultRow(selectedID: String?) -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isAvailable = self.isDefaultPromptAvailable
        let isSelected = isAvailable && (
            self.promptMode.normalized == .dictate
                ? (self.settings.resolvedDictationPromptSelection(for: activeSlot, appBundleID: DictationAppSession.shared.appID) == .default)
                : (selectedID == nil)
        )
        Button(action: {
            guard isAvailable else { return }
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.default)
            } else {
                self.settings.setSelectedPromptID(nil, for: self.promptMode)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text(SettingsStore.DictationModeLabels.externalDefault)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: self.checkmarkSize, weight: .semibold))
                }
                self.shortcutBadge(for: .default)
            }
            .padding(.horizontal, self.rowHorizontalPadding)
            .padding(.vertical, self.rowVerticalPadding)
            .background(self.rowBackground(isSelected: isSelected, rowID: "default"))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .help(isAvailable ? "Use your default provider" : "Add an API key to a provider to enable this prompt")
        .onHover { hovering in
            self.hoveredRowID = hovering && isAvailable ? "default" : nil
        }
    }

    @ViewBuilder
    private func privateAIRow() -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        let isSelected = self.settings.resolvedDictationPromptSelection(for: activeSlot, appBundleID: DictationAppSession.shared.appID) == .privateAI
        Button(action: {
            guard isAvailable else { return }
            self.contentState.onDictationPromptSelectionRequested?(.privateAI)
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SettingsStore.DictationModeLabels.smart)
                Spacer(minLength: 12)
                if !self.isCompact {
                    Text(PrivateAIModelRegistry.model(id: PrivateAIIntegrationService.configuredModelID)?.displayName ?? "Fluid-1")
                        .font(.fluidSystem(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: self.checkmarkSize, weight: .semibold))
                }
                self.shortcutBadge(for: .privateAI)
            }
            .padding(.horizontal, self.rowHorizontalPadding)
            .padding(.vertical, self.rowVerticalPadding)
            .background(self.rowBackground(isSelected: isSelected, rowID: PrivateAIProviderFeature.shared.providerID))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .help(isAvailable ? "Use \(PrivateAIProviderFeature.displayName)" : "Select \(PrivateAIProviderFeature.displayName) to enable this prompt")
        .onHover { hovering in
            self.hoveredRowID = hovering && isAvailable ? PrivateAIProviderFeature.shared.providerID : nil
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SettingsStore.DictationPromptProfile, selectedID: String?) -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = (
            self.promptMode.normalized == .dictate
                ? (self.settings.resolvedDictationPromptSelection(for: activeSlot, appBundleID: DictationAppSession.shared.appID) == .profile(profile.id))
                : (selectedID == profile.id)
        )
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.profile(profile.id))
            } else {
                self.settings.setSelectedPromptID(profile.id, for: self.promptMode)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: self.checkmarkSize, weight: .semibold))
                }
                self.shortcutBadge(for: .profile(profile.id))
            }
            .padding(.horizontal, self.rowHorizontalPadding)
            .padding(.vertical, self.rowVerticalPadding)
            .background(self.rowBackground(isSelected: isSelected, rowID: profile.id))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? profile.id : nil
        }
    }

    var body: some View {
        let selectedID = self.settings.selectedPromptID(for: self.promptMode)
        let profiles = self.settings.promptProfiles(for: self.promptMode)

        VStack(alignment: .leading, spacing: 0) {
            if self.promptMode.normalized == .dictate {
                if !self.isCompact {
                    Text("ON-DEVICE")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 3)
                }

                self.offRow()

                if PrivateFeatures.privateAIProvider {
                    self.privateAIRow()
                }
            }

            if self.promptMode.normalized == .dictate {
                Divider()
                    .padding(.vertical, self.isCompact ? 2 : 4)
            }

            if !self.isCompact {
                Text("EXTERNAL")
                    .font(.fluidSystem(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.top, self.promptMode.normalized == .dictate ? 0 : 4)
                    .padding(.bottom, 3)
            }

            self.defaultRow(selectedID: selectedID)

            if !profiles.isEmpty {
                ForEach(profiles) { profile in
                    self.profileRow(profile, selectedID: selectedID)
                }
            }
        }
        .font(self.isCompact ? .fluidSystem(size: 10, weight: .medium) : nil)
        .lineLimit(1)
        .padding(.horizontal, self.isCompact ? 3 : 8)
        .padding(.vertical, self.isCompact ? 3 : 4)
        .bottomOverlaySurface(self.settings.bottomOverlayAppearance, cornerRadius: self.isCompact ? 9 : 8)
        .frame(width: self.isCompact ? 96 : min(self.maxWidth, 250), alignment: .leading)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }

    private func restoreTypingTargetApp() {
        guard let context = NotchContentState.shared.recordingTargetContext else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await TypingService.prepareTargetForDelivery(context)
        }
    }
}

private struct BottomOverlayActionsMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private var canReprocessLast: Bool {
        !self.historyStore.entries.isEmpty && !self.contentState.isProcessing
    }

    private var latestEntry: TranscriptionHistoryEntry? {
        self.historyStore.entries.first
    }

    private var canCopyLast: Bool {
        guard !self.contentState.isProcessing else { return false }
        return self.latestEntry?.clipboardText != nil
    }

    private var canPasteLast: Bool {
        self.canCopyLast
    }

    private var canUndoLastAI: Bool {
        guard !self.contentState.isProcessing else { return false }
        guard let latest = self.latestEntry else { return false }
        let raw = latest.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return latest.wasAIProcessed && !raw.isEmpty
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func actionRow(
        title: String,
        icon: String,
        rowID: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard enabled else { return }
            action()
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.fluidSystem(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: icon)
                    .font(.fluidSystem(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: false, rowID: rowID))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering in
            guard enabled else {
                self.hoveredRowID = nil
                return
            }
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    private func modeRow(_ title: String, mode: OverlayMode, rowID: String) -> some View {
        let isSelected = self.normalizedOverlayMode == mode
        let shortcut = OverlayShortcutResolver.shortcutDisplay(for: mode, settings: self.settings)
        return Button(action: {
            guard !self.contentState.isProcessing else { return }
            self.contentState.onOverlayModeSwitchRequested?(mode)
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.fluidSystem(size: 14, weight: .semibold))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODE")
                .font(.fluidSystem(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 3)

            self.modeRow("Dictate", mode: .dictation, rowID: "mode_dictate")
            self.modeRow("Edit", mode: .edit, rowID: "mode_edit")
            self.modeRow("Command", mode: .command, rowID: "mode_command")

            Divider()
                .padding(.vertical, 4)

            Text("ACTIONS")
                .font(.fluidSystem(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.bottom, 3)

            self.actionRow(
                title: "Process Again",
                icon: "arrow.clockwise",
                rowID: "reprocess_last",
                enabled: self.canReprocessLast
            ) {
                self.contentState.onReprocessLastRequested?()
            }

            self.actionRow(
                title: "Copy Last",
                icon: "doc.on.doc",
                rowID: "copy_last",
                enabled: self.canCopyLast
            ) {
                self.contentState.onCopyLastRequested?()
            }

            self.actionRow(
                title: "Insert Last",
                icon: "arrow.down.doc",
                rowID: "paste_last",
                enabled: self.canPasteLast
            ) {
                self.contentState.onPasteLastRequested?()
            }

            self.actionRow(
                title: "Use Raw Text",
                icon: "arrow.uturn.backward",
                rowID: "undo_ai_last",
                enabled: self.canUndoLastAI
            ) {
                self.contentState.onUndoLastAIRequested?()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .bottomOverlaySurface(self.settings.bottomOverlayAppearance, cornerRadius: 8)
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private struct PromptSelectorAnchorReader: NSViewRepresentable {
    let onFrameChange: (CGRect, NSWindow?) -> Void

    func makeNSView(context: Context) -> AnchorReportingView {
        let view = AnchorReportingView()
        view.onFrameChange = self.onFrameChange
        return view
    }

    func updateNSView(_ nsView: AnchorReportingView, context: Context) {
        nsView.onFrameChange = self.onFrameChange
        nsView.reportFrame(force: true)
    }

    final class AnchorReportingView: NSView {
        var onFrameChange: ((CGRect, NSWindow?) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []
        private var lastReportedFrameInScreen: CGRect = .null
        private weak var lastReportedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.installWindowObservers()
            self.reportFrame(force: true)
        }

        override func layout() {
            super.layout()
            self.reportFrame()
        }

        deinit {
            self.cleanup()
        }

        func cleanup() {
            for observer in self.windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.windowObservers.removeAll()
        }

        private func installWindowObservers() {
            self.cleanup()
            guard let window = self.window else { return }

            let center = NotificationCenter.default
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
        }

        func reportFrame(force: Bool = false) {
            guard let window = self.window else {
                if force || !self.lastReportedFrameInScreen.isNull {
                    self.lastReportedFrameInScreen = .null
                    self.lastReportedWindow = nil
                    self.onFrameChange?(CGRect.zero, nil)
                }
                return
            }

            let frameInWindow = self.convert(self.bounds, to: nil)
            let frameInScreen = window.convertToScreen(frameInWindow)
            let frameTolerance: CGFloat = 0.5
            let hasLastFrame = !self.lastReportedFrameInScreen.isNull
            let frameChanged = !hasLastFrame ||
                abs(frameInScreen.origin.x - self.lastReportedFrameInScreen.origin.x) > frameTolerance ||
                abs(frameInScreen.origin.y - self.lastReportedFrameInScreen.origin.y) > frameTolerance ||
                abs(frameInScreen.size.width - self.lastReportedFrameInScreen.size.width) > frameTolerance ||
                abs(frameInScreen.size.height - self.lastReportedFrameInScreen.size.height) > frameTolerance
            let windowChanged = self.lastReportedWindow !== window

            guard force || frameChanged || windowChanged else { return }

            self.lastReportedFrameInScreen = frameInScreen
            self.lastReportedWindow = window
            self.onFrameChange?(frameInScreen, window)
        }
    }
}

private enum PillShadowMetrics {
    // Keep in sync with the pill shadow in BottomOverlayView.body.
    static let radius: CGFloat = 10
    static let yOffset: CGFloat = 4
    /// Hit-test inset must cover the visible shadow extent (radius + |offset|)
    /// plus a small margin so the shadow region doesn't intercept clicks.
    static let hitTestInset: CGFloat = radius + abs(yOffset) + 12
    /// The window is always as wide as the expanded pill so hover growth never
    /// resizes it; hit testing follows the pill that is actually drawn.
    static let canvasWidth: CGFloat = 236
    static var visibleWidth: CGFloat = 100
}

private final class BottomOverlayHostingView: NSHostingView<BottomOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if SettingsStore.shared.overlaySize == .pill {
            let visibleOverlayBounds = self.bounds.insetBy(
                dx: max((self.bounds.width - PillShadowMetrics.visibleWidth) / 2, PillShadowMetrics.hitTestInset),
                dy: PillShadowMetrics.hitTestInset
            )
            guard visibleOverlayBounds.contains(point) else { return nil }
        }
        return super.hitTest(point)
    }
}

private struct DynamicPreviewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var appServices = AppServices.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringModeChip = false
    @State private var isHoveringPromptChip = false
    @State private var isPillExpanded = false
    @State private var pillHoverWorkItem: DispatchWorkItem?
    @State private var isHoveringActionsChip = false
    @State private var isHoveringSettingsChip = false
    @State private var modeSelectorFrameInScreen: CGRect = .zero
    @State private var modeSelectorWindow: NSWindow?
    @State private var promptSelectorFrameInScreen: CGRect = .zero
    @State private var promptSelectorWindow: NSWindow?
    @State private var actionsSelectorFrameInScreen: CGRect = .zero
    @State private var actionsSelectorWindow: NSWindow?
    @State private var dynamicPreviewMeasuredHeight: CGFloat = 0
    @State private var frozenDynamicPreviewHeight: CGFloat?
    @State private var dynamicPreviewResizeBucket: Int = 0
    @State private var processingStatusVisible = false
    @State private var processingStatusCycleID = 0
    @State private var lastResolvedAppIcon: NSImage?
    @State private var borderAnimationStartedAt: Date?

    struct LayoutConstants {
        let hPadding: CGFloat
        let vPadding: CGFloat
        let waveformWidth: CGFloat
        let waveformHeight: CGFloat
        let iconSize: CGFloat
        let transFontSize: CGFloat
        let modeFontSize: CGFloat
        let cornerRadius: CGFloat
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let minBarHeight: CGFloat
        let maxBarHeight: CGFloat
        let containerWidth: CGFloat
        let overlayWidth: CGFloat
        let overlayHeight: CGFloat
        let previewBoxHeight: CGFloat
        let usesFixedCanvas: Bool
        let showsTopControls: Bool
        let showsPreview: Bool
        let showsModeLabel: Bool

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
            case .pill:
                return LayoutConstants(
                    hPadding: 12,
                    vPadding: 8,
                    waveformWidth: 46,
                    waveformHeight: 30,
                    iconSize: 18,
                    transFontSize: 10,
                    modeFontSize: 9,
                    cornerRadius: 23,
                    barCount: 8,
                    barWidth: 3.0,
                    barSpacing: 2.5,
                    minBarHeight: 4,
                    maxBarHeight: 28,
                    containerWidth: 100,
                    overlayWidth: 100,
                    overlayHeight: 46,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: false,
                    showsModeLabel: false
                )
            case .small:
                return LayoutConstants(
                    hPadding: 10,
                    vPadding: 6,
                    waveformWidth: 90,
                    waveformHeight: 20,
                    iconSize: 16,
                    transFontSize: 11,
                    modeFontSize: 10,
                    cornerRadius: 14,
                    barCount: 7,
                    barWidth: 3.0,
                    barSpacing: 3.5,
                    minBarHeight: 5,
                    maxBarHeight: 16,
                    containerWidth: 200,
                    overlayWidth: 300,
                    overlayHeight: 124,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .medium:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 130,
                    waveformHeight: 32,
                    iconSize: 20,
                    transFontSize: 13,
                    modeFontSize: 12,
                    cornerRadius: 18,
                    barCount: 8,
                    barWidth: 3.5,
                    barSpacing: 4.5,
                    minBarHeight: 6,
                    maxBarHeight: 28,
                    containerWidth: 340,
                    overlayWidth: 380,
                    overlayHeight: 156,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .large:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 180,
                    waveformHeight: 48,
                    iconSize: 26,
                    transFontSize: 15,
                    modeFontSize: 14,
                    cornerRadius: 24,
                    barCount: 11,
                    barWidth: 5.0,
                    barSpacing: 6.0,
                    minBarHeight: 8,
                    maxBarHeight: 44,
                    containerWidth: 600,
                    overlayWidth: 600,
                    overlayHeight: 288,
                    previewBoxHeight: 92,
                    usesFixedCanvas: true,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            }
        }
    }

    private var layout: LayoutConstants {
        LayoutConstants.get(for: self.settings.overlaySize)
    }

    private var isCompactControls: Bool {
        self.settings.overlaySize == .medium
    }

    private var waveformHorizontalOffset: CGFloat {
        self.settings.overlaySize == .medium ? -28 : 0
    }

    private var isPillSize: Bool {
        self.settings.overlaySize == .pill
    }

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Dictate"
        case .edit, .rewrite, .write: return "Edit"
        case .command: return "Command"
        }
    }

    private var displayedAppIcon: NSImage? {
        // ActiveAppMonitor never tracks FluidVoice itself, so dictating into our own window
        // would otherwise show the previous app's icon, or a bare dot after launch.
        if DictationAppSession.shared.appID == Bundle.main.bundleIdentifier {
            return NSApp.applicationIconImage
        }
        return self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon ?? self.lastResolvedAppIcon
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Refining..."
        case .edit, .rewrite, .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    private var showsSpokenSendIndicator: Bool {
        self.contentState.mode == .dictation &&
            self.settings.spokenSendEnabled &&
            self.contentState.spokenSendIndicatorState.isVisible
    }

    private var spokenSendIndicatorSize: CGFloat {
        max(self.layout.modeFontSize + 3, 13)
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    /// ContentView writes transient status strings into transcriptionText while processing
    /// (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.transientOverlayStatusTexts.contains(t) else { return self.processingLabel }
        return t
    }

    private var hasTranscription: Bool {
        !self.transcriptionPreviewText.isEmpty
    }

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private var activePromptMode: SettingsStore.PromptMode? {
        switch self.normalizedOverlayMode {
        case .dictation:
            return .dictate
        case .edit:
            return .edit
        case .command, .write, .rewrite:
            return nil
        }
    }

    private var isPromptSelectableMode: Bool {
        self.activePromptMode != nil
    }

    private var promptResolutionBundleID: String? {
        DictationAppSession.shared.appID
    }

    private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot {
        self.contentState.activeDictationShortcutSlot ?? .primary
    }

    private var isAppPromptOverrideActive: Bool {
        guard let activePromptMode else { return false }
        if activePromptMode.normalized == .dictate {
            return self.settings.isAppDictationPromptBindingActive(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        return self.settings.hasAppPromptBinding(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        )
    }

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if activePromptMode.normalized == .dictate {
            if let label = self.contentState.stopSnapshotLabel { return label }
            return self.settings.dictationOverlayLabel(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        if let profile = self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var promptSelectorBuiltInLabel: String? {
        guard let activePromptMode else { return nil }
        if activePromptMode.normalized == .dictate {
            switch self.settings.resolvedDictationPromptSelection(for: self.activeDictationShortcutSlot, appBundleID: self.promptResolutionBundleID) {
            case .off:
                return "Basic"
            case .privateAI:
                return self.isAppPromptOverrideActive ? nil : SettingsStore.DictationModeLabels.smart
            case .default:
                let hasAppOverride = self.settings.resolvedDictationPromptProfile(
                    for: self.activeDictationShortcutSlot,
                    appBundleID: self.promptResolutionBundleID
                ) != nil
                return hasAppOverride ? nil : SettingsStore.DictationModeLabels.externalDefault
            case .profile:
                return nil
            }
        }

        return self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) == nil ? "Default" : nil
    }

    private var promptSelectorDisplayLabel: String {
        if self.layout.showsTopControls {
            let label = self.selectedPromptLabel
            return label.count > 12 ? "\(label.prefix(11))…" : label
        }
        if self.activePromptMode?.normalized == .dictate {
            let label = self.selectedPromptLabel
            let limit = self.isCompactControls ? 12 : 18
            guard label.count > limit else { return label }
            return "\(label.prefix(limit - 1))…"
        }
        let selectedLabel = self.selectedPromptLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = self.promptSelectorBuiltInLabel ?? selectedLabel
        guard !label.isEmpty else { return "Default" }

        let maxLength: Int
        if self.promptSelectorBuiltInLabel == nil {
            maxLength = 11
        } else if self.isCompactControls {
            maxLength = self.isAppPromptOverrideActive ? 8 : 14
        } else {
            maxLength = self.isAppPromptOverrideActive ? 11 : 16
        }

        guard label.count > maxLength else { return label }
        let prefixLength = max(maxLength - 3, 1)
        return "\(label.prefix(prefixLength))..."
    }

    private var promptSelectorIconName: String? {
        switch self.promptSelectorBuiltInLabel {
        case "Basic"?:
            return "bolt.fill"
        case SettingsStore.DictationModeLabels.smart?:
            return "sparkles"
        default:
            return nil
        }
    }

    private var promptSelectorFontSize: CGFloat {
        if self.isPillSize { return 8 }
        if self.isCompactControls { return 9 }
        return max(self.layout.modeFontSize - 3, 9)
    }

    private var promptSelectorLabelFontSize: CGFloat {
        max(self.promptSelectorFontSize - 1, 8)
    }

    private var promptSelectorVerticalPadding: CGFloat {
        4
    }

    private var promptMenuGap: CGFloat {
        // The pill's chip sits inside the pill, so clear the pill's top edge too.
        if self.isPillSize { return self.layout.vPadding + 12 }
        return max(0, self.layout.vPadding * 0.05)
    }

    private var promptSelectorCornerRadius: CGFloat {
        max(self.layout.cornerRadius * 0.42, 8)
    }

    private var promptSelectorMaxWidth: CGFloat {
        self.isPillSize ? 220 : self.layout.waveformWidth * 1.75
    }

    private var promptSelectorTriggerMaxWidth: CGFloat {
        guard self.layout.showsTopControls else { return 120 }
        // Use 6pt more on each side of the selector while retaining a 6pt
        // clearance from the visible bars and a 12pt outer trailing inset.
        // Keep the waveform and leading app control in place.
        let rowWidth = self.layout.containerWidth - self.layout.hPadding * 2
        let barsWidth = CGFloat(self.layout.barCount) * self.layout.barWidth
            + CGFloat(max(self.layout.barCount - 1, 0)) * self.layout.barSpacing
        let waveformRight = rowWidth / 2 + self.waveformHorizontalOffset + barsWidth / 2
        return max(0, rowWidth + 6 - waveformRight - 6 - 32 - 4)
    }

    private var previewMaxHeight: CGFloat {
        self.layout.usesFixedCanvas ? self.layout.previewBoxHeight : self.layout.transFontSize * 4.2
    }

    private var shouldReservePreviewArea: Bool {
        self.layout.showsPreview &&
            (
                self.settings.enableStreamingPreview ||
                    self.contentState.isAIProcessingFailureVisible ||
                    self.contentState.isTextDeliveryFailureVisible
            )
    }

    private var overlayFrameHeight: CGFloat? {
        guard self.layout.usesFixedCanvas else { return nil }
        return self.shouldReservePreviewArea ? self.layout.overlayHeight : nil
    }

    private var previewMaxWidth: CGFloat {
        if self.layout.usesFixedCanvas {
            return self.layout.waveformWidth * 2.2
        }

        return max(self.layout.waveformWidth * 2.2, self.layout.containerWidth - self.layout.hPadding * 2)
    }

    private var dynamicPreviewBaseMinHeight: CGFloat {
        guard self.shouldReservePreviewArea else { return 0 }
        let verticalPadding = self.settings.overlaySize == .small
            ? max(2, self.transcriptionVerticalPadding - 1)
            : self.transcriptionVerticalPadding
        return self.estimatedPreviewLineHeight + verticalPadding * 2
    }

    private var effectiveDynamicPreviewLockedHeight: CGFloat? {
        guard self.contentState.isBottomOverlayReleaseTransitioning else { return nil }
        guard let frozenDynamicPreviewHeight else { return nil }
        return max(frozenDynamicPreviewHeight, self.dynamicPreviewBaseMinHeight)
    }

    private var effectiveDynamicPreviewMinHeight: CGFloat {
        self.effectiveDynamicPreviewLockedHeight ?? self.dynamicPreviewBaseMinHeight
    }

    private var estimatedPreviewLineHeight: CGFloat {
        max(self.layout.transFontSize * 1.25, self.layout.transFontSize + 2)
    }

    private var currentPreviewSizingText: String {
        guard self.shouldReservePreviewArea else { return "" }
        if self.shouldShowProcessingPreview {
            return self.processingPreviewText
        }
        return self.shouldShowProcessingStatus ? self.processingStatusText : self.transcriptionPreviewText
    }

    private var shouldShowProcessingStatus: Bool {
        self.shouldReservePreviewArea && self.contentState.isProcessing && self.processingStatusVisible
    }

    private var shouldShowAIProcessingFailure: Bool {
        self.shouldReservePreviewArea && self.contentState.isAIProcessingFailureVisible && !self.contentState.isProcessing
    }

    private var shouldShowTextDeliveryFailure: Bool {
        self.shouldReservePreviewArea && self.contentState.isTextDeliveryFailureVisible && !self.contentState.isProcessing
    }

    private var shouldSuppressPreviewDuringRelease: Bool {
        if self.shouldShowProcessingPreview {
            return false
        }
        return self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    private func previewResizeBucket(for previewText: String) -> Int {
        guard self.shouldReservePreviewArea else { return 0 }
        if self.shouldShowAIProcessingFailure || self.shouldShowTextDeliveryFailure { return 1 }
        let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.shouldShowProcessingStatus ? 1 : 0 }

        if self.settings.overlaySize == .small {
            return 1
        }

        let newlineCount = trimmed.filter { $0 == "\n" }.count
        let estimatedCharacterWidth = max(self.layout.transFontSize * 0.56, 1)
        let characterCapacity = max(Int((self.previewMaxWidth / estimatedCharacterWidth).rounded(.down)), 12)
        let estimatedWrappedLines = max(1, (trimmed.count + characterCapacity - 1) / characterCapacity)
        let maxVisibleLines = max(Int((self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)).rounded(.down)), 1)
        return min(max(estimatedWrappedLines + newlineCount, 1), maxVisibleLines)
    }

    private func refreshDynamicPreviewSizeIfNeeded(for previewText: String) {
        guard self.shouldReservePreviewArea else { return }
        guard !self.layout.usesFixedCanvas else { return }
        let nextBucket = self.previewResizeBucket(for: previewText)
        guard nextBucket != self.dynamicPreviewResizeBucket else { return }
        self.dynamicPreviewResizeBucket = nextBucket
        BottomOverlayWindowController.shared.refreshSizeForContent()
    }

    private var transcriptionVerticalPadding: CGFloat {
        max(4, self.layout.vPadding / 2)
    }

    private var transcriptionPreviewText: String {
        let preview = self.contentState.cachedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.contentState.isProcessing else { return self.contentState.cachedPreviewText }
        guard Self.transientOverlayStatusTexts.contains(preview) else { return self.contentState.cachedPreviewText }
        return ""
    }

    private var processingPreviewText: String {
        guard self.contentState.isProcessing else { return "" }
        let preview = self.transcriptionPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(preview) else { return "" }
        return self.transcriptionPreviewText
    }

    private var shouldShowProcessingPreview: Bool {
        !self.processingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func richPreviewText(_ previewText: String) -> Text {
        Text(previewText)
            .foregroundColor(.white.opacity(0.96))
    }

    private var overlayAnimatedOffsetY: CGFloat {
        if self.contentState.isBottomOverlayDismissing {
            return self.contentState.bottomOverlayDismissOffsetY
        }
        return 0
    }

    private var overlayAnimatedScale: CGFloat {
        self.contentState.isBottomOverlayDismissing ? 0.985 : 1.0
    }

    private var overlayAnimatedOpacity: Double {
        1.0
    }

    private func chipBackground(isHovered: Bool, disabled: Bool) -> some View {
        let fillColor: Color
        if disabled {
            fillColor = Color.black.opacity(0.95)
        } else if isHovered {
            fillColor = Color(red: 0.13, green: 0.13, blue: 0.16)
        } else {
            fillColor = Color.black
        }

        let topStrokeOpacity: Double = disabled ? 0.10 : (isHovered ? 0.36 : 0.14)
        let bottomStrokeOpacity: Double = disabled ? 0.06 : (isHovered ? 0.22 : 0.08)
        let hoverShadowColor: Color = (isHovered && !disabled) ? Color.white.opacity(0.16) : .clear

        return RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(topStrokeOpacity),
                                Color.white.opacity(bottomStrokeOpacity),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: hoverShadowColor, radius: 6, x: 0, y: 1)
    }

    private func closePromptMenu() {
        BottomOverlayPromptMenuController.shared.hide()
    }

    private static let pillExpansionAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.9)

    /// Expands after a short dwell so a passing pointer never moves the pill, and
    /// collapses late so the trip from pill to menu does not close it.
    private func handlePillHover(_ hovering: Bool) {
        guard self.isPillSize else { return }
        self.pillHoverWorkItem?.cancel()
        let shouldExpand = hovering && self.isPromptSelectableMode && !self.contentState.isProcessing
        guard shouldExpand != self.isPillExpanded else { return }
        let work = DispatchWorkItem {
            if !shouldExpand, BottomOverlayPromptMenuController.shared.isMenuVisible {
                self.handlePillHover(false)
                return
            }
            self.setPillExpanded(shouldExpand)
        }
        self.pillHoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (shouldExpand ? 0.06 : 0.25), execute: work)
    }

    private func collapsePillImmediately() {
        self.pillHoverWorkItem?.cancel()
        self.pillHoverWorkItem = nil
        PillShadowMetrics.visibleWidth = self.layout.containerWidth
        self.isPillExpanded = false
    }

    private func setPillExpanded(_ expanded: Bool) {
        guard self.isPillExpanded != expanded else { return }
        PillShadowMetrics.visibleWidth = expanded ? PillShadowMetrics.canvasWidth : self.layout.containerWidth
        withAnimation(self.reduceMotion ? .easeOut(duration: 0.15) : Self.pillExpansionAnimation) {
            self.isPillExpanded = expanded
        }
    }

    private func rememberAppIcon(_ icon: NSImage?) {
        guard let icon else { return }
        self.lastResolvedAppIcon = icon
    }

    private func handlePromptSelectorHover(_ hovering: Bool) {
        // Hover-open disabled by design.
    }

    private func handlePromptSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.promptSelectorFrameInScreen = frameInScreen
        self.promptSelectorWindow = window
        guard self.layout.showsTopControls || self.isPillSize, self.isPromptSelectableMode, !self.contentState.isProcessing else {
            BottomOverlayPromptMenuController.shared.hide()
            return
        }

        BottomOverlayPromptMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private func requestModeSwitch(_ mode: OverlayMode) {
        guard !self.contentState.isProcessing else { return }
        self.contentState.onOverlayModeSwitchRequested?(mode)
        BottomOverlayModeMenuController.shared.hide()
    }

    private func closeModeMenu() {
        BottomOverlayModeMenuController.shared.hide()
    }

    private func closeActionsMenu() {
        BottomOverlayActionsMenuController.shared.hide()
    }

    private func handleModeSelectorHover(_ hovering: Bool) {
        guard !self.contentState.isProcessing else {
            self.closeModeMenu()
            return
        }
        BottomOverlayModeMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleModeSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.modeSelectorFrameInScreen = frameInScreen
        self.modeSelectorWindow = window
        guard self.layout.showsTopControls, !self.contentState.isProcessing else {
            BottomOverlayModeMenuController.shared.hide()
            return
        }

        BottomOverlayModeMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private func handleActionsSelectorHover(_ hovering: Bool) {
        let actionsDisabled = self.contentState.isProcessing
        guard !actionsDisabled else {
            self.closeActionsMenu()
            return
        }
        BottomOverlayActionsMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleActionsSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.actionsSelectorFrameInScreen = frameInScreen
        self.actionsSelectorWindow = window
        let actionsDisabled = self.contentState.isProcessing
        guard self.layout.showsTopControls, !actionsDisabled else {
            BottomOverlayActionsMenuController.shared.hide()
            return
        }

        BottomOverlayActionsMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private var modeSelectorTrigger: some View {
        HStack(spacing: 5) {
            if !self.isCompactControls {
                Text("Mode:")
                    .font(.fluidSystem(size: self.promptSelectorFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(self.modeLabel)
                .font(.fluidSystem(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.fluidSystem(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .fluidDropdownSurface(cornerRadius: self.promptSelectorCornerRadius)
    }

    private var modeSelectorView: some View {
        self.modeSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleModeSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringModeChip = hovering && !self.contentState.isProcessing
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !self.contentState.isProcessing else { return }
                self.closePromptMenu()
                self.closeActionsMenu()
                BottomOverlayModeMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.modeSelectorFrameInScreen,
                    parentWindow: self.modeSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayModeMenuController.shared.toggleFromTap()
            }
    }

    private var promptSelectorTrigger: some View {
        HStack(spacing: self.layout.showsTopControls ? 7 : 5) {
            if !self.isPillSize, !self.layout.showsTopControls, let promptSelectorIconName = self.promptSelectorIconName {
                Image(systemName: promptSelectorIconName)
                    .font(.fluidSystem(size: max(self.promptSelectorFontSize - 1, 9), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Text(self.promptSelectorDisplayLabel)
                .help(self.selectedPromptLabel)
                .accessibilityLabel(self.selectedPromptLabel)
                .font(.fluidSystem(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            if self.isAppPromptOverrideActive {
                Text("App")
                    .font(.fluidSystem(size: max(self.promptSelectorFontSize - 2, 8), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                    )
            }
            Image(systemName: "chevron.down")
                .font(.fluidSystem(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .frame(
            width: self.layout.showsTopControls ? self.promptSelectorTriggerMaxWidth : nil,
            alignment: .trailing
        )
        .help(self.selectedPromptLabel)
        .background(
            RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius, style: .continuous)
                .fill(
                    self.isHoveringPromptChip && self.isPromptSelectableMode && !self.contentState.isProcessing
                        ? Color.white.opacity(0.10)
                        : Color.clear
                )
        )
        .overlay(alignment: .top) {
            if self.isHoveringPromptChip, self.isPromptSelectableMode, !self.contentState.isProcessing, !self.isPillSize {
                Text("Select dictation mode")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Select dictation mode")
    }

    private var promptSelectorView: some View {
        Group {
            if self.isPromptSelectableMode {
                self.promptSelectorTrigger
                    .background(
                        PromptSelectorAnchorReader { frameInScreen, window in
                            self.handlePromptSelectorFrameChange(frameInScreen, window: window)
                        }
                        .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        self.isHoveringPromptChip = hovering && !self.contentState.isProcessing
                    }
                    .onTapGesture {
                        guard self.layout.showsTopControls || self.isPillSize, self.isPromptSelectableMode, !self.contentState.isProcessing else { return }
                        self.closeModeMenu()
                        self.closeActionsMenu()
                        BottomOverlayPromptMenuController.shared.updateAnchor(
                            selectorFrameInScreen: self.promptSelectorFrameInScreen,
                            parentWindow: self.promptSelectorWindow,
                            maxWidth: self.promptSelectorMaxWidth,
                            menuGap: self.promptMenuGap
                        )
                        BottomOverlayPromptMenuController.shared.toggleFromTap()
                    }
            } else {
                self.promptSelectorTrigger
                    .opacity(0.6)
                    .onHover { _ in
                        self.isHoveringPromptChip = false
                    }
            }
        }
    }

    private var actionsSelectorTrigger: some View {
        let actionsDisabled = self.contentState.isProcessing
        return HStack(spacing: 0) {
            Image(systemName: "ellipsis")
                .font(.fluidSystem(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(actionsDisabled ? 0.3 : 0.78))
        }
        .frame(width: 32, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.isHoveringActionsChip && !actionsDisabled ? Color.white.opacity(0.1) : Color.clear)
        )
        .overlay(alignment: .top) {
            if self.isHoveringActionsChip, !actionsDisabled {
                Text("Actions")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Actions")
    }

    private var actionsSelectorView: some View {
        let actionsDisabled = self.contentState.isProcessing
        return self.actionsSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleActionsSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringActionsChip = hovering && !actionsDisabled
                self.handleActionsSelectorHover(hovering)
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !actionsDisabled else { return }
                self.isHoveringActionsChip = false
                self.closePromptMenu()
                self.closeModeMenu()
                BottomOverlayActionsMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.actionsSelectorFrameInScreen,
                    parentWindow: self.actionsSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayActionsMenuController.shared.toggleFromTap()
            }
    }

    private var settingsChip: some View {
        let disabled = false
        return HStack(spacing: 0) {
            Image(systemName: "gearshape")
                .font(.fluidSystem(size: max(self.promptSelectorFontSize + 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringSettingsChip,
                disabled: disabled
            )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHoveringSettingsChip = hovering
        }
        .onTapGesture {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.contentState.onOpenPreferencesRequested?()
        }
        .help("Open Preferences")
    }

    private func failureIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.fluidSystem(size: max(self.layout.transFontSize - 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var aiProcessingFailureView: some View {
        HStack(spacing: 8) {
            Text(self.contentState.aiProcessingFailureMessage)
                .font(.fluidSystem(size: self.layout.transFontSize, weight: .semibold))
                .foregroundStyle(
                    self.contentState.canRetryAIProcessingFailure
                        ? Color.white.opacity(0.9)
                        : Color.orange.opacity(0.9)
                )
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if self.contentState.canRetryAIProcessingFailure {
                self.failureIconButton(systemName: "arrow.clockwise", help: "Try again") {
                    self.contentState.clearAIProcessingFailure()
                    self.contentState.onReprocessLastRequested?()
                }
            }

            self.failureIconButton(systemName: "xmark", help: "Dismiss") {
                self.contentState.clearAIProcessingFailure()
                NotchOverlayManager.shared.hide()
            }
        }
        .frame(maxWidth: self.previewMaxWidth, alignment: .leading)
    }

    private var targetAppIconView: some View {
        let appIcon = self.displayedAppIcon
        let showModelLoading = self.layout.showsModeLabel && !self.appServices.asr.isAsrReady &&
            (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
        return VStack(spacing: 2) {
            if showModelLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if let appIcon = appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
            } else if !self.layout.showsModeLabel {
                Circle()
                    .fill(self.modeColor.opacity(0.9))
                    .frame(width: max(self.layout.iconSize * 0.45, 7), height: max(self.layout.iconSize * 0.45, 7))
            }
        }
        .frame(width: self.layout.iconSize, height: self.layout.iconSize)
        .opacity((appIcon != nil || showModelLoading || !self.layout.showsModeLabel) ? 1 : 0)
    }

    private var leadingAppContextView: some View {
        HStack(spacing: self.isPillSize ? 4 : 8) {
            if self.showsSpokenSendIndicator {
                SpokenSendIndicatorView(
                    state: self.contentState.spokenSendIndicatorState,
                    color: self.modeColor,
                    size: self.isPillSize ? 14 : self.spokenSendIndicatorSize
                )
                .id(self.contentState.spokenSendCountdownID)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            self.targetAppIconView
        }
        .animation(
            self.reduceMotion ? nil : .easeOut(duration: 0.14),
            value: self.contentState.spokenSendIndicatorState
        )
    }

    private var textDeliveryFailureView: some View {
        let message = self.contentState.textDeliveryFailureMessage
        return DeliveryFailureCard(
            title: message,
            detail: TextDeliveryFailure.userFacingDetail(forMessage: message),
            transcript: self.contentState.textDeliveryFailureTranscript,
            fontSize: self.layout.transFontSize,
            compact: self.layout.usesFixedCanvas,
            maxWidth: self.previewMaxWidth
        ) {
            self.contentState.clearTextDeliveryFailure()
            NotchOverlayManager.shared.hide()
        }
    }

    private func scrollablePreviewText(_ previewText: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                self.richPreviewText(previewText)
                    .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .onChange(of: previewText) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func dynamicPreviewText(_ previewText: String) -> some View {
        if self.settings.overlaySize == .small {
            self.richPreviewText(previewText)
                .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
        } else {
            self.richPreviewText(previewText)
                .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .padding(.vertical, self.transcriptionVerticalPadding)
        }
    }

    var body: some View {
        VStack(spacing: max(4, self.layout.vPadding / 2)) {
            if self.layout.showsTopControls, !self.isCompactControls {
                HStack {
                    Spacer(minLength: 4)
                    self.settingsChip
                }
                .padding(.horizontal, self.layout.hPadding)
            }

            VStack(spacing: self.layout.vPadding / 2) {
                if self.shouldReservePreviewArea {
                    if self.layout.usesFixedCanvas {
                        // Transcription text area (fixed-height in large mode)
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowTextDeliveryFailure {
                                self.textDeliveryFailureView
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.scrollablePreviewText(self.processingPreviewText)
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .fluidSystem(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else if self.hasTranscription {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    ScrollViewReader { proxy in
                                        ScrollView(.vertical, showsIndicators: false) {
                                            Text(previewText)
                                                .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.96))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Color.clear.frame(height: 1).id("bottom")
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .clipped()
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                        .onChange(of: previewText) { _, _ in
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                            }
                        }
                        .padding(.vertical, self.transcriptionVerticalPadding)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: self.previewMaxHeight,
                            maxHeight: self.previewMaxHeight,
                            alignment: .topLeading
                        )
                    } else {
                        // Original dynamic preview behavior for small/medium
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowTextDeliveryFailure {
                                self.textDeliveryFailureView
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.dynamicPreviewText(self.processingPreviewText)
                            } else if self.hasTranscription && !self.contentState.isProcessing {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    if self.settings.overlaySize == .small {
                                        Text(previewText)
                                            .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.96))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
                                    } else {
                                        Text(previewText)
                                            .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.96))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                                            .truncationMode(.head)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(width: self.previewMaxWidth, alignment: .leading)
                                            .padding(.vertical, self.transcriptionVerticalPadding)
                                    }
                                }
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .fluidSystem(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else {
                                Color.clear
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: DynamicPreviewHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            maxWidth: self.previewMaxWidth,
                            minHeight: self.effectiveDynamicPreviewMinHeight,
                            maxHeight: self.effectiveDynamicPreviewLockedHeight
                        )
                        .animation(
                            self.reduceMotion ? nil : BottomOverlayWindowController.growthAnimation,
                            value: self.dynamicPreviewResizeBucket
                        )
                    }
                }

                // Waveform + Mode label row
                HStack(spacing: self.isPillSize ? 4 : self.layout.hPadding / 1.5) {
                    if !self.layout.showsTopControls {
                        self.leadingAppContextView
                    }

                    // Waveform visualization
                    BottomWaveformView(
                        color: self.modeColor,
                        layout: self.layout,
                        visibleBarCount: self.isPillSize && self.showsSpokenSendIndicator ? 6 : nil
                    )
                    .frame(
                        width: self.isPillSize && self.showsSpokenSendIndicator
                            ? 32
                            : self.layout.waveformWidth,
                        height: self.layout.waveformHeight
                    )

                    if self.isPillSize, self.isPillExpanded {
                        self.promptSelectorView
                            .fixedSize()
                            .transition(self.reduceMotion ? .opacity : .pillChip)
                    }

                    // Compact overlays still need a visible mode because they have no selector.
                    if self.layout.showsModeLabel, !self.layout.showsTopControls {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(self.modeLabel)
                                .font(.fluidSystem(size: self.layout.modeFontSize, weight: .semibold))
                                .foregroundStyle(self.modeColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if !self.appServices.asr.isAsrReady &&
                                (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                                && self.settings.overlaySize != .small
                            {
                                Text("Loading model…")
                                    .font(.fluidSystem(size: max(self.layout.modeFontSize - 2, 9), weight: .medium))
                                    .foregroundStyle(.orange.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .animation(
                            self.reduceMotion ? nil : .easeOut(duration: 0.14),
                            value: self.contentState.spokenSendIndicatorState
                        )
                    }
                }
                .offset(x: self.waveformHorizontalOffset)
                .frame(maxWidth: self.isPillSize ? nil : .infinity, alignment: .center)
                .overlay(alignment: .leading) {
                    if self.layout.showsTopControls {
                        self.leadingAppContextView
                    }
                }
                .overlay(alignment: .trailing) {
                    if self.layout.showsTopControls {
                        HStack(spacing: 4) {
                            self.promptSelectorView
                            self.actionsSelectorView
                        }
                        .offset(x: 6)
                    }
                }
            }
            .padding(.horizontal, self.layout.hPadding)
            .padding(.vertical, self.layout.vPadding)
            .frame(
                minWidth: self.isPillSize ? self.layout.containerWidth : nil,
                maxWidth: self.isPillSize ? nil : .infinity,
                alignment: .center
            )
            .bottomOverlaySurface(
                self.settings.bottomOverlayAppearance,
                cornerRadius: self.layout.cornerRadius,
                castsShadow: self.isPillSize,
                showsBorder: !self.isPillSize
            )
            .overlay {
                if self.isPillSize, self.settings.overlayEdgeLightEnabled {
                    // Preserve the pill's existing state animation above the shared material.
                    if self.reduceMotion || !self.contentState.isBottomOverlayPresented || (self.settings.overlayMaterial != .original && self.settings.overlayHighlight == 0) {
                        RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                            .strokeBorder(
                                AngularGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: .white.opacity(0.06), location: 0.00),
                                        .init(color: .white.opacity(0.55), location: 0.13),
                                        .init(color: .white.opacity(0.10), location: 0.30),
                                        .init(color: .white.opacity(0.03), location: 0.55),
                                        .init(color: .white.opacity(0.22), location: 0.80),
                                        .init(color: .white.opacity(0.06), location: 1.00),
                                    ]),
                                    center: .center,
                                    angle: .degrees(0)
                                ),
                                lineWidth: 1.2
                            )
                            .opacity(self.settings.overlayMaterial == .original ? 1 : self.settings.overlayHighlight)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                            let seconds = max(
                                0,
                                timeline.date.timeIntervalSince(self.borderAnimationStartedAt ?? timeline.date)
                            )
                            let angle = (seconds.truncatingRemainder(dividingBy: 6.0) / 6.0) * 360.0
                            RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .white.opacity(0.06), location: 0.00),
                                            .init(color: .white.opacity(0.55), location: 0.13),
                                            .init(color: .white.opacity(0.10), location: 0.30),
                                            .init(color: .white.opacity(0.03), location: 0.55),
                                            .init(color: .white.opacity(0.22), location: 0.80),
                                            .init(color: .white.opacity(0.06), location: 1.00),
                                        ]),
                                        center: .center,
                                        angle: .degrees(angle)
                                    ),
                                    lineWidth: 1.2
                                )
                                .opacity(self.settings.overlayMaterial == .original ? 1 : self.settings.overlayHighlight)
                        }
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: self.layout.cornerRadius, style: .continuous))
            .onHover { hovering in
                self.handlePillHover(hovering)
            }
            // Bottom-anchored so a growing pill rises into the enlarged window
            // instead of dropping its lower edge mid-animation.
            .frame(maxWidth: .infinity, alignment: .bottom)
            .transaction { transaction in
                if self.shouldSuppressPreviewDuringRelease {
                    transaction.animation = nil
                }
            }
        }
        .frame(
            width: self.isPillSize
                ? PillShadowMetrics.canvasWidth
                : (self.layout.usesFixedCanvas ? self.layout.overlayWidth : self.layout.containerWidth),
            height: self.overlayFrameHeight,
            alignment: .top
        )
        // Reserve space around the pill so its drop shadow isn't clipped by the (content-sized) window.
        .padding(self.isPillSize ? 26 : 0)
        .onChange(of: self.contentState.isBottomOverlayPresented) { _, presented in
            self.borderAnimationStartedAt = presented ? Date() : nil
            if !presented { self.collapsePillImmediately() }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            if processing { self.handlePillHover(false) }
        }
        .onChange(of: self.settings.enableStreamingPreview) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.cachedPreviewText) { _, _ in
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.mode) { _, _ in
            if !self.isPromptSelectableMode || self.contentState.isProcessing {
                self.closePromptMenu()
            }
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            switch self.contentState.mode {
            case .dictation: self.contentState.promptPickerMode = .dictate
            case .edit, .write, .rewrite: self.contentState.promptPickerMode = .edit
            case .command: break
            }
            if !self.layout.usesFixedCanvas {
                self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            self.processingStatusVisible = processing
            if processing {
                self.processingStatusCycleID &+= 1
                self.closePromptMenu()
                self.closeModeMenu()
                self.closeActionsMenu()
            }
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            if !self.layout.usesFixedCanvas {
                self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
            }
        }
        .onChange(of: self.contentState.isAIProcessingFailureVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.isTextDeliveryFailureVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.processingStatusVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.isBottomOverlayReleaseTransitioning) { _, transitioning in
            guard self.shouldReservePreviewArea else {
                self.frozenDynamicPreviewHeight = nil
                return
            }
            guard !self.layout.usesFixedCanvas else { return }
            if transitioning {
                let measuredHeight = self.dynamicPreviewMeasuredHeight > 0
                    ? self.dynamicPreviewMeasuredHeight
                    : self.effectiveDynamicPreviewMinHeight
                self.frozenDynamicPreviewHeight = max(measuredHeight, self.dynamicPreviewBaseMinHeight)
            } else {
                self.frozenDynamicPreviewHeight = nil
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onPreferenceChange(DynamicPreviewHeightPreferenceKey.self) { measuredHeight in
            guard !self.layout.usesFixedCanvas else { return }
            guard measuredHeight > 0 else { return }
            self.dynamicPreviewMeasuredHeight = measuredHeight
        }
        .onAppear {
            self.rememberAppIcon(self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon)
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
        }
        .onReceive(self.contentState.$targetAppIcon) { icon in
            self.rememberAppIcon(icon)
        }
        .onDisappear {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
        }
        // TODO: Add tap-to-expand for command mode history (future enhancement)
        // .contentShape(Rectangle())
        // .onTapGesture {
        //     if contentState.mode == .command && !contentState.commandConversationHistory.isEmpty {
        //         NotchOverlayManager.shared.onNotchClicked?()
        //     }
        // }
    }
}

/// The chip resolves out of a soft blur while the pill widens, so the growth
/// reads as one gesture instead of a width change followed by a pop-in.
private struct PillChipTransitionModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(self.progress)
            .blur(radius: (1 - self.progress) * 5)
            .scaleEffect(0.94 + 0.06 * self.progress, anchor: .leading)
    }
}

private extension AnyTransition {
    static var pillChip: AnyTransition {
        .modifier(
            active: PillChipTransitionModifier(progress: 0),
            identity: PillChipTransitionModifier(progress: 1)
        )
    }
}
