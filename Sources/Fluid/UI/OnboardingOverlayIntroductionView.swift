import AVKit
import SwiftUI

/// A silent, one-shot introduction. Practice copy and the configured shortcut stay native.
struct OnboardingOverlayIntroductionView: View {
    let onComplete: () -> Void

    private static let edgeStops: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .white, location: 0.12),
        .init(color: .white, location: 0.88),
        .init(color: .clear, location: 1),
    ]

    var body: some View {
        OnboardingIntroductionPlayer(onComplete: self.onComplete)
            .aspectRatio(1560.0 / 1096.0, contentMode: .fit)
            .mask {
                LinearGradient(stops: Self.edgeStops, startPoint: .leading, endPoint: .trailing)
                    .mask {
                        LinearGradient(stops: Self.edgeStops, startPoint: .top, endPoint: .bottom)
                    }
            }
            .accessibilityLabel("Basic opens the mode menu. The pointer selects Smart, then the overlay returns to the bottom and disappears.")
    }
}

private struct OnboardingIntroductionPlayer: NSViewRepresentable {
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: self.onComplete)
    }

    func makeNSView(context: Context) -> IntroductionPlayerView {
        let view = IntroductionPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_: IntroductionPlayerView, context: Context) {
        context.coordinator.onComplete = self.onComplete
    }

    static func dismantleNSView(_ view: IntroductionPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player = nil
    }

    final class Coordinator {
        var onComplete: () -> Void
        private var player: AVPlayer?
        private var observers: [NSObjectProtocol] = []
        private var statusObservation: NSKeyValueObservation?
        private var playbackObservation: NSKeyValueObservation?
        private var completed = false
        private var startupTimeout: DispatchWorkItem?
        private var recoveryTimeout: DispatchWorkItem?
        private var isRecovering = false
        private weak var view: IntroductionPlayerView?

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func start(in view: IntroductionPlayerView) {
            self.view = view
            view.onVisibilityChange = { [weak self] in self?.updatePlayback() }
            guard let url = Bundle.main.url(forResource: "OnboardingSmartMode", withExtension: "mp4") else {
                DispatchQueue.main.async { [weak self] in self?.finish() }
                return
            }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            self.player = player
            view.player = player
            let center = NotificationCenter.default
            for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime] {
                self.observers.append(center.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                    self?.finish()
                })
            }
            self.observers.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                guard let self, !self.completed else { return }
                self.isRecovering = true
                self.updatePlayback()
            })
            self.playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.completed, self.player?.timeControlStatus == .playing else { return }
                    self.isRecovering = false
                    self.cancelRecoveryTimeout()
                }
            }
            // A bundled movie should load quickly, but decoding failure must not trap onboarding.
            let timeout = DispatchWorkItem { [weak self] in self?.finish() }
            self.startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
            self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.completed else { return }
                    if status == .readyToPlay {
                        self.startupTimeout?.cancel()
                        self.startupTimeout = nil
                        self.updatePlayback()
                    } else if status == .failed {
                        self.finish()
                    }
                }
            }
            self.observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updatePlayback()
            })
            self.observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updatePlayback()
            })
            self.updatePlayback()
        }

        private func updatePlayback() {
            guard !self.completed else { return }
            if NSApp.isActive, self.view?.window?.occlusionState.contains(.visible) == true {
                self.player?.play()
                if self.isRecovering, self.recoveryTimeout == nil {
                    // A stall may recover on its own. Bound visible recovery without
                    // counting time spent in another app or a hidden window.
                    let timeout = DispatchWorkItem { [weak self] in self?.finish() }
                    self.recoveryTimeout = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
                }
            } else {
                self.player?.pause()
                self.cancelRecoveryTimeout()
            }
        }

        private func cancelRecoveryTimeout() {
            self.recoveryTimeout?.cancel()
            self.recoveryTimeout = nil
        }

        private func finish() {
            guard !self.completed else { return }
            self.completed = true
            self.isRecovering = false
            self.cancelRecoveryTimeout()
            self.playbackObservation = nil
            self.startupTimeout?.cancel()
            self.startupTimeout = nil
            // Retain the final background frame while native practice appears over it.
            self.player?.pause()
            self.statusObservation = nil
            for observer in self.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.observers.removeAll()
            self.onComplete()
        }

        func stop() {
            self.completed = true
            self.isRecovering = false
            self.cancelRecoveryTimeout()
            self.playbackObservation = nil
            self.startupTimeout?.cancel()
            self.startupTimeout = nil
            self.player?.pause()
            self.player?.replaceCurrentItem(with: nil)
            self.player = nil
            self.statusObservation = nil
            for observer in self.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.observers.removeAll()
        }

        deinit { self.stop() }
    }
}

private final class IntroductionPlayerView: AVPlayerView {
    var onVisibilityChange: (() -> Void)?
    private var visibilityObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        self.visibilityObserver = nil
        if let window {
            self.visibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onVisibilityChange?() }
        }
        self.onVisibilityChange?()
    }

    deinit {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }
}
