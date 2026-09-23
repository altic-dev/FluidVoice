import AppKit
import Combine
import SwiftUI

@MainActor
private final class ReleaseHighlightsCoordinator {
    static let shared = ReleaseHighlightsCoordinator()
    private var policy = ReleaseHighlightsPolicy(seenVersions: UserDefaults.standard.stringArray(forKey: ReleaseHighlightsPolicy.seenKey) ?? [])

    func request(owner: UUID, version: String, release: String, eligible: Bool, manual: Bool) -> ReleaseHighlightsPolicy.Session? {
        self.policy.request(owner: owner, version: version, release: release, eligible: eligible, manual: manual)
    }

    func beginDismiss(id: UUID) -> Bool { self.policy.beginDismiss(id: id, acknowledge: true) }
    func interrupt(id: UUID) { self.policy.interrupt(id: id) }
    func abandon(owner: UUID) { self.policy.abandon(owner: owner) }

    func finishDismiss(id: UUID, eligible: Bool) -> Bool? {
        let result = self.policy.finishDismiss(id: id, eligible: eligible)
        if result == true {
            UserDefaults.standard.set(self.policy.seenVersions, forKey: ReleaseHighlightsPolicy.seenKey)
        }
        return result
    }
}

struct ReleaseHighlightsPresenter: ViewModifier {
    @Binding var requested: Bool
    let isEligible: Bool
    let onExplore: (SidebarItem) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()
    @State private var host = WindowReference()
    @State private var visible = false
    @State private var processing = false
    @State private var refining = false
    @State private var isPresented = false
    @State private var session: ReleaseHighlightsPolicy.Session?
    @State private var pendingDestination: ReleaseHighlightsContent.Destination?
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    private let highlights = ReleaseHighlightsContent.current(hasPrivateAI: PrivateAIProviderFeature.shared.isAvailable)
    private let coordinator = ReleaseHighlightsCoordinator.shared

    private final class WindowReference { weak var window: NSWindow? }

    private var canExplore: Bool { self.isEligible && !self.processing && !self.refining }

    func body(content: Content) -> some View {
        content
            .background(ReleaseHighlightsWindowReader { window in
                self.host.window = window
                self.presentIfNeeded()
            })
            .sheet(isPresented: self.$isPresented, onDismiss: self.didDismiss) {
                ReleaseHighlightsView(canExplore: self.canExplore, content: self.highlights, onClose: self.close)
            }
            .onAppear { self.visible = true; self.presentIfNeeded() }
            .onDisappear {
                self.visible = false
                self.pendingDestination = nil
                self.session = nil
                self.isPresented = false
                self.coordinator.abandon(owner: self.owner)
            }
            .onChange(of: self.isEligible) { _, _ in self.eligibilityChanged() }
            .onReceive(NotchContentState.shared.$isProcessing.removeDuplicates()) { processing in
                self.processing = processing
                self.eligibilityChanged()
            }
            .onReceive(MeetingSummaryActivityCoordinator.shared.$isProcessing.removeDuplicates()) { refining in
                self.refining = refining
                self.eligibilityChanged()
            }
            .onChange(of: self.scenePhase) { _, phase in
                if phase == .active { self.presentIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in self.presentIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in self.presentIfNeeded() }
            .onChange(of: self.requested) { _, requested in
                guard requested else { return }
                self.requested = false
                self.presentIfNeeded(manual: true)
            }
    }

    private func presentIfNeeded(manual: Bool = false) {
        guard self.visible, self.session == nil, let window = self.host.window,
              window.isKeyWindow, window.attachedSheet == nil, NSApp.isActive else { return }
        guard let session = self.coordinator.request(
            owner: self.owner,
            version: self.version,
            release: self.highlights.release,
            eligible: self.canExplore,
            manual: manual
        ) else { return }
        self.session = session
        self.pendingDestination = nil
        self.isPresented = true
    }

    private func eligibilityChanged() {
        if self.canExplore {
            self.presentIfNeeded()
        } else if let session = self.session {
            self.coordinator.interrupt(id: session.id)
            self.pendingDestination = nil
            self.isPresented = false
        }
    }

    private func close(_ destination: ReleaseHighlightsContent.Destination?) {
        guard let session = self.session, self.coordinator.beginDismiss(id: session.id) else { return }
        self.pendingDestination = self.canExplore ? destination : nil
        self.isPresented = false
    }

    private func didDismiss() {
        guard let session = self.session else { return }
        let result = self.coordinator.finishDismiss(id: session.id, eligible: self.canExplore)
        let destination = self.pendingDestination
        self.session = nil
        self.pendingDestination = nil
        if result == true, self.canExplore, self.visible, let destination {
            switch destination {
            case .meetings: self.onExplore(.meetingTranscription)
            case .dashboard: self.onExplore(.welcome)
            case .aiProviders: self.onExplore(.aiEnhancements)
            }
        } else if result == false {
            self.presentIfNeeded()
        }
    }
}

/// Reports only attachment changes. Never inspects hardware or polls windows.
private struct ReleaseHighlightsWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context _: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = self.onWindow
        return view
    }

    func updateNSView(_ view: WindowView, context _: Context) { view.onWindow = self.onWindow }

    final class WindowView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onWindow?(self.window)
            }
        }
    }
}
