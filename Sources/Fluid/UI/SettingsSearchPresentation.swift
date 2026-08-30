//
//  SettingsSearchPresentation.swift
//  fluid
//
//  Search highlighting and programmatic reveal support for Settings.
//

import AppKit
import SwiftUI

final class SettingsSearchScrollCoordinator {
    private final class WeakAnchor {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    private weak var scrollView: NSScrollView?
    private var anchors: [SettingsSearchTarget: WeakAnchor] = [:]
    private var requestedTarget: SettingsSearchTarget?
    private var requestedID: Int?

    func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        self.scheduleRequestedScroll()
    }

    func register(_ view: NSView, for target: SettingsSearchTarget) {
        self.anchors[target] = WeakAnchor(view)
        if target == self.requestedTarget {
            self.scheduleRequestedScroll()
        }
    }

    func requestScroll(to target: SettingsSearchTarget?, requestID: Int) {
        guard self.requestedTarget != target || self.requestedID != requestID else { return }
        self.requestedTarget = target
        self.requestedID = requestID
        self.scheduleRequestedScroll()
    }

    private func scheduleRequestedScroll() {
        DispatchQueue.main.async { [weak self] in
            self?.performRequestedScroll()
        }
    }

    private func performRequestedScroll() {
        guard let target = self.requestedTarget,
              let scrollView = self.scrollView,
              let documentView = scrollView.documentView,
              let anchorView = self.anchors[target]?.view,
              anchorView.window != nil
        else { return }

        let targetRect = anchorView.convert(anchorView.bounds, to: documentView)
            .insetBy(dx: 0, dy: -16)
        documentView.scrollToVisible(targetRect)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

struct SettingsSearchPresentation {
    let matchedTargets: Set<SettingsSearchTarget>
    let primaryTarget: SettingsSearchTarget
    let scrollCoordinator: SettingsSearchScrollCoordinator
}

private struct SettingsSearchPresentationKey: EnvironmentKey {
    static let defaultValue: SettingsSearchPresentation? = nil
}

extension EnvironmentValues {
    var settingsSearchPresentation: SettingsSearchPresentation? {
        get { self[SettingsSearchPresentationKey.self] }
        set { self[SettingsSearchPresentationKey.self] = newValue }
    }
}

private struct SettingsSearchAnchor: NSViewRepresentable {
    let target: SettingsSearchTarget
    let scrollCoordinator: SettingsSearchScrollCoordinator

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        self.scrollCoordinator.register(view, for: self.target)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        self.scrollCoordinator.register(view, for: self.target)
    }
}

private struct SettingsSearchTargetModifier: ViewModifier {
    let target: SettingsSearchTarget

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.settingsSearchPresentation) private var presentation

    private var isMatched: Bool {
        self.presentation?.matchedTargets.contains(self.target) == true
    }

    private var isPrimary: Bool {
        self.presentation?.primaryTarget == self.target
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if self.isMatched {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(self.isPrimary ? 0.12 : 0.07))
                            .padding(-6)
                    }

                    if let presentation {
                        SettingsSearchAnchor(
                            target: self.target,
                            scrollCoordinator: presentation.scrollCoordinator
                        )
                    }
                }
            }
            .overlay {
                if self.isMatched {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            Color.accentColor.opacity(self.isPrimary ? 0.72 : 0.38),
                            lineWidth: self.isPrimary ? 1.5 : 1
                        )
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .animation(
                self.accessibilityReduceMotion ? nil : .easeOut(duration: 0.16),
                value: self.isMatched
            )
            .accessibilityHint(self.isMatched ? "Matches Settings search" : "")
    }
}

extension View {
    func settingsSearchTarget(_ target: SettingsSearchTarget) -> some View {
        modifier(SettingsSearchTargetModifier(target: target))
    }
}

private final class SettingsPersistentScroller: NSScroller {
    override static var isCompatibleWithOverlayScrollers: Bool {
        false
    }
}

struct SettingsPersistentScrollView<Content: View>: NSViewRepresentable {
    private let theme: AppTheme
    private let colorScheme: ColorScheme
    private let searchScrollCoordinator: SettingsSearchScrollCoordinator
    private let searchScrollTarget: SettingsSearchTarget?
    private let searchScrollRequest: Int
    private let content: Content

    init(
        theme: AppTheme,
        colorScheme: ColorScheme,
        searchScrollCoordinator: SettingsSearchScrollCoordinator,
        searchScrollTarget: SettingsSearchTarget?,
        searchScrollRequest: Int,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.searchScrollCoordinator = searchScrollCoordinator
        self.searchScrollTarget = searchScrollTarget
        self.searchScrollRequest = searchScrollRequest
        self.content = content()
    }

    private var hostedContent: AnyView {
        AnyView(
            self.content
                .appTheme(self.theme)
                .environment(\.colorScheme, self.colorScheme)
        )
    }

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller = SettingsPersistentScroller()
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        let hostingView = NSHostingView(rootView: self.hostedContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.required, for: .vertical)

        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        self.updateSearchScrolling(for: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView = self.hostedContent
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        if !(scrollView.verticalScroller is SettingsPersistentScroller) {
            scrollView.verticalScroller = SettingsPersistentScroller()
        }
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        self.updateSearchScrolling(for: scrollView)
    }

    private func updateSearchScrolling(for scrollView: NSScrollView) {
        self.searchScrollCoordinator.attach(scrollView)
        self.searchScrollCoordinator.requestScroll(
            to: self.searchScrollTarget,
            requestID: self.searchScrollRequest
        )
    }
}
