import CoreGraphics

/// The one size every pop-up uses: Settings, the model pickers and any new pop-up.
///
/// A pop-up never gets smaller than `minimumSize`. In a bigger window it grows with the window up to
/// `maximumSize`. While one is open the window may not shrink below `minimumWindowContentSize`, so
/// the pop-up always sits inside the window.
struct FluidPopupLayout: Equatable {
    static let minimumSize = CGSize(width: 880, height: 540)
    /// Wide enough for the sidebar plus a full-width settings page (720) and its scroll bar, and no
    /// wider, so a big window never leaves empty margins beside the page. Height still grows.
    static let maximumSize = CGSize(width: 960, height: 820)
    static let windowMargin = CGSize(width: 50, height: 30)
    static let minimumWindowContentSize = CGSize(
        width: minimumSize.width + windowMargin.width * 2,
        height: minimumSize.height + windowMargin.height * 2
    )

    /// Title bar and toolbar above the content area.
    static let windowChromeHeight: CGFloat = 52
    /// Smallest whole-window size allowed while a pop-up is open. It must fit the smallest
    /// Mac screen the app supports (1280 x 800 with menu bar and Dock), so keep it under 1280 x 700.
    static let minimumWindowSize = CGSize(
        width: minimumWindowContentSize.width,
        height: minimumWindowContentSize.height + windowChromeHeight
    )

    /// True for a click on the window's page area behind the popup. The title bar, toolbar and a
    /// thin band along the edges are left alone so the window can still be moved and resized.
    static func isDismissingClick(at point: CGPoint, windowContent: CGRect) -> Bool {
        windowContent.insetBy(dx: 8, dy: 8).contains(point)
    }

    /// True for a press on the window's top bar, away from the close/minimize/zoom buttons and the
    /// resize edges. A press there may be the start of moving the window, so the caller closes the
    /// popup only if the window did not move.
    static func isTopBarPress(at point: CGPoint, windowFrame: CGRect, windowContent: CGRect) -> Bool {
        let bar = CGRect(
            x: windowFrame.minX + 84,
            y: windowContent.maxY,
            width: windowFrame.width - 84,
            height: windowFrame.maxY - windowContent.maxY
        )
        return bar.insetBy(dx: 8, dy: 0).contains(point) && point.y < windowFrame.maxY - 6
    }

    let width: CGFloat
    let height: CGFloat

    init(windowContentSize: CGSize) {
        self.width = min(Self.maximumSize.width, max(Self.minimumSize.width, windowContentSize.width - Self.windowMargin.width * 2))
        self.height = min(Self.maximumSize.height, max(Self.minimumSize.height, windowContentSize.height - Self.windowMargin.height * 2))
    }
}
