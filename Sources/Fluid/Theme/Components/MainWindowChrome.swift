import AppKit
import SwiftUI

/// The sidebar and the title-bar strip share one behind-window material. The page
/// sits in an opaque rounded panel inset from that glass, the same relationship
/// as a card floating on the window chrome.
enum MainWindowChrome {
    static let margin: CGFloat = 10
    static let cornerRadius: CGFloat = 12

    /// Solid stand-in for the sidebar material. Light and dark values sit apart
    /// from the content panel so the inset card still reads when translucency is off.
    static func opaqueChromeColor(dark: Bool) -> NSColor {
        if dark {
            return NSColor(srgbRed: 0.22, green: 0.22, blue: 0.22, alpha: 1)
        }
        return NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    }

    static let opaqueChromeColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Self.opaqueChromeColor(dark: dark)
    }
}

struct MainWindowChromeBackground: View {
    var reduceTransparency: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if self.reduceTransparency {
            Color(nsColor: MainWindowChrome.opaqueChromeColor(dark: self.colorScheme == .dark))
        } else {
            MainWindowBehindMaterial()
        }
    }
}

/// Samples the desktop behind the window so the wallpaper tints the chrome.
struct MainWindowBehindMaterial: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
    }
}

/// Lets the shared chrome material show through the title bar, including the
/// toolbar strip, and removes the hard title-bar separator. Onboarding keeps
/// the standard opaque title bar.
struct MainWindowChromeConfigurator: NSViewRepresentable {
    var enabled: Bool
    var reduceTransparency: Bool

    func makeNSView(context _: Context) -> MainWindowChromeConfiguratorView {
        let view = MainWindowChromeConfiguratorView()
        view.enabled = self.enabled
        view.reduceTransparency = self.reduceTransparency
        return view
    }

    func updateNSView(_ view: MainWindowChromeConfiguratorView, context _: Context) {
        view.enabled = self.enabled
        view.reduceTransparency = self.reduceTransparency
    }
}

final class MainWindowChromeConfiguratorView: NSView {
    var enabled = false {
        didSet {
            guard self.enabled != oldValue else { return }
            self.scheduleApply()
        }
    }

    var reduceTransparency = false {
        didSet {
            guard self.reduceTransparency != oldValue else { return }
            self.scheduleApply()
        }
    }

    private var isScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.scheduleApply()
    }

    private func scheduleApply() {
        guard !self.isScheduled else { return }
        self.isScheduled = true
        // Style-mask changes must not happen inside SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.apply()
        }
    }

    private func apply() {
        guard let window else { return }
        if self.enabled {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            if self.reduceTransparency {
                window.isOpaque = true
                window.backgroundColor = MainWindowChrome.opaqueChromeColor
            } else {
                window.isOpaque = false
                window.backgroundColor = .clear
            }
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .automatic
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.isMovableByWindowBackground = false
        }
    }
}

private struct MainWindowContentPanelModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(self.theme.palette.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: MainWindowChrome.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MainWindowChrome.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(self.colorScheme == .dark ? 0.10 : 0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(self.colorScheme == .dark ? 0.28 : 0.08),
                radius: 12,
                y: 2
            )
            .padding(MainWindowChrome.margin)
    }
}

extension View {
    func mainWindowContentPanel() -> some View {
        self.modifier(MainWindowContentPanelModifier())
    }
}
