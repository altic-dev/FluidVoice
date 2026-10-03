import AppKit

/// A custom overlay origin and the display arrangement it was chosen on.
struct OverlayPlacedOrigin {
    let point: NSPoint
    let screenFrames: [CGRect]
}

/// Deciding whether a position the user dragged the bottom overlay to can still be used.
@MainActor
enum OverlayPlacement {
    /// Every attached screen's frame, in screen coordinates.
    static func currentScreenFrames() -> [CGRect] {
        NSScreen.screens.map(\.frame)
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    /// Whether two display arrangements are the same set of screens, regardless of the
    /// order `NSScreen.screens` happens to report them in.
    static func arrangementsMatch(_ lhs: [CGRect], _ rhs: [CGRect]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var unmatched = rhs
        for frame in lhs {
            guard let index = unmatched.firstIndex(where: { self.framesMatch(frame, $0) }) else {
                return false
            }
            unmatched.remove(at: index)
        }
        return true
    }

    /// The least of the overlay that must stay on a screen's visible area after the display
    /// arrangement changes: enough to grab and drag back, clamped to the overlay's own size.
    static let minimumGrabbableSize = CGSize(width: 44, height: 20)

    /// Whether a stored position should still be used on the displays attached now.
    static func originIsUsable(_ placed: OverlayPlacedOrigin, size: NSSize) -> Bool {
        self.originIsUsable(
            placed,
            size: size,
            screens: self.currentScreenFrames(),
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    /// Whether a stored position should still be used.
    ///
    /// On the same display arrangement the position is honoured exactly, so an
    /// overlay deliberately dragged past a screen edge stays there. Once the
    /// arrangement changes it is only reused while enough of the overlay to grab is still
    /// on one attached screen's visible area; otherwise a position chosen on a display
    /// that has since been unplugged would leave the overlay invisible, or a sliver of it
    /// too thin to drag back.
    ///
    /// The test is per screen rather than against their union, so the overlay is not
    /// restored into a gap between displays in an irregular arrangement, where the union
    /// covers desktop that no display draws.
    static func originIsUsable(
        _ placed: OverlayPlacedOrigin,
        size: NSSize,
        screens: [CGRect],
        visibleFrames: [CGRect]
    ) -> Bool {
        guard !screens.isEmpty else { return false }

        // The arrangement is the one this origin was chosen on, never whatever settings
        // happens to hold: mid-drag the write is still queued, so reading settings here
        // would judge a fresh position against the arrangement before it. An empty one —
        // no position yet, or one saved by a build that did not record it — never
        // matches, since `screens` is known to be non-empty here.
        if self.arrangementsMatch(placed.screenFrames, screens) {
            return true
        }

        let overlay = NSRect(origin: placed.point, size: size)
        let minWidth = min(self.minimumGrabbableSize.width, size.width)
        let minHeight = min(self.minimumGrabbableSize.height, size.height)
        return visibleFrames.contains { visibleFrame in
            let onScreen = visibleFrame.intersection(overlay)
            return !onScreen.isNull && onScreen.width >= minWidth && onScreen.height >= minHeight
        }
    }

    /// The persisted origin paired with the arrangement it was stored on.
    static func storedOrigin() -> OverlayPlacedOrigin? {
        guard let origin = SettingsStore.shared.overlayCustomOrigin else { return nil }
        return OverlayPlacedOrigin(point: origin, screenFrames: SettingsStore.shared.overlayCustomOriginScreenFrames)
    }
}
