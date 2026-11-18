import AppKit

/// Local diagnostics: scrolls the open page down from the top and back at a steady, hand-like
/// speed, one frame at a time, so scrolling can be profiled the same way on any page length.
/// Only reachable through the `com.FluidApp.debug.scrollPage` notification, which ContentView
/// ignores unless the `FluidDebugRemoteToggleEnabled` default is set on this machine.
@MainActor
enum PageScrollDriver {
    private static var timer: Timer?
    /// How far one pass goes before turning back, and how fast. A brisk trackpad scroll.
    private static let distance: CGFloat = 3000
    private static let speed: CGFloat = 2000

    /// Runs `cycles` down-and-up passes from the top. A new run replaces a running one.
    static func run(cycles: Int = 3) {
        self.timer?.invalidate()
        self.timer = nil
        guard let scrollView = self.pageScrollView(), let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let scrollable = document.frame.height - clip.bounds.height
        let range = min(scrollable, Self.distance)
        guard range > 0, cycles > 0 else { return }
        let seconds = Double(range / Self.speed) * 2
        let start = Date()
        let total = Double(cycles) * seconds
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < total else {
                    timer.invalidate()
                    self.timer = nil
                    return
                }
                // A triangle wave: top to bottom in the first half of each pass, back in the second.
                let phase = elapsed.truncatingRemainder(dividingBy: seconds) / seconds
                let progress = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let y = document.isFlipped ? range * progress : scrollable - range * progress
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        if let timer = self.timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// The scrollable view in the main window with the most to scroll: the page or its longest
    /// list (History's entries, not its detail panel), never the sidebar.
    private static func pageScrollView() -> NSScrollView? {
        let window = NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let root = window?.contentView else { return nil }
        var found: [NSScrollView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView,
               let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1
            {
                found.append(scroll)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}
