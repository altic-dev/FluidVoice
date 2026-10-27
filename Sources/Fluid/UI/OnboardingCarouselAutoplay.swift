import AppKit
import Combine
import SwiftUI

/// One pending wakeup; pointer movement only extends the deadline, without redrawing SwiftUI.
final class OnboardingCarouselAutoplay: ObservableObject {
    private static let interval: TimeInterval = 10
    let advance = PassthroughSubject<Void, Never>()
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    private var isRunning = false

    func start() {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.interact()
        self.schedule(after: Self.interval)
    }

    func interact() {
        self.deadline = ProcessInfo.processInfo.systemUptime + Self.interval
    }

    func stop() {
        self.isRunning = false
        self.timer?.invalidate()
        self.timer = nil
    }

    private func schedule(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let remaining = self.deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                self.schedule(after: remaining)
            } else {
                self.interact()
                self.advance.send()
                if self.isRunning { self.schedule(after: Self.interval) }
            }
        }
        timer.tolerance = 0.05
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { self.timer?.invalidate() }
}

/// Observes only this page's events and always returns them unchanged to their controls.
struct OnboardingCarouselInteractionTracker: NSViewRepresentable {
    let autoplay: OnboardingCarouselAutoplay

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(autoplay: self.autoplay)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class TrackingView: NSView {
        private let autoplay: OnboardingCarouselAutoplay
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        init(autoplay: OnboardingCarouselAutoplay) {
            self.autoplay = autoplay
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.stopObserving()
            guard let window else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                .rightMouseDragged, .otherMouseDragged, .scrollWheel,
                .keyDown, .keyUp, .flagsChanged, .magnify, .rotate, .swipe,
            ]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let isKeyboard = [.keyDown, .keyUp, .flagsChanged].contains(event.type)
                if isKeyboard || self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.autoplay.interact()
                }
                return event
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                self.observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.updateActivity()
                })
            }
            self.updateActivity()
        }

        private func updateActivity() {
            if self.window?.isKeyWindow == true {
                self.autoplay.start()
            } else {
                self.autoplay.stop()
            }
        }

        func stopObserving() {
            self.autoplay.stop()
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
            self.observers.forEach(NotificationCenter.default.removeObserver)
            self.observers.removeAll()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
