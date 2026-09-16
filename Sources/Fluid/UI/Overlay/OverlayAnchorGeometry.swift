//
//  OverlayAnchorGeometry.swift
//  Fluid
//
//  Pure placement math for the floating recording pill.
//

import CoreGraphics

extension SettingsStore.OverlayPosition {
    /// Transparent margin the pill view reserves around itself for its own drop
    /// shadow and aura. Keep in sync with the padding applied in
    /// BottomOverlayView.body and with PillShadowMetrics.hitTestInset.
    static let pillCanvasPadding: CGFloat = 26

    /// Gap between the visible pill and the top or bottom screen edge.
    static let verticalEdgeInset: CGFloat = 10
    /// Gap between the visible pill and the left or right screen edge.
    static let horizontalEdgeInset: CGFloat = 16
    /// Legacy buffers kept from the original bottom-overlay clamping.
    static let lowerSafetyBuffer: CGFloat = 10
    static let upperSafetyBuffer: CGFloat = 40

    /// Screen origin for the panel that carries this anchor.
    ///
    /// - Parameters:
    ///   - windowSize: full panel size, including the transparent canvas padding.
    ///   - screenFrame: the target screen's full frame, used for centering.
    ///   - visibleFrame: the target screen's visible frame, which already
    ///     excludes the menu bar, the Dock and the notch area.
    ///   - bottomOffset: the user's bottom offset preference. It drives the
    ///     bottom-centered anchor exactly as it did before.
    ///   - canvasPadding: transparent margin included in `windowSize`.
    func windowOrigin(
        windowSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        bottomOffset: CGFloat,
        canvasPadding: CGFloat
    ) -> CGPoint {
        let x = self.horizontalOrigin(
            windowSize: windowSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            canvasPadding: canvasPadding
        )
        let y = self.verticalOrigin(
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            bottomOffset: bottomOffset,
            canvasPadding: canvasPadding
        )
        return CGPoint(x: x, y: y)
    }

    private func horizontalOrigin(
        windowSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        canvasPadding: CGFloat
    ) -> CGFloat {
        switch self {
        case .topCenter, .bottomCenter:
            // Preserved verbatim from the original bottom overlay placement.
            return screenFrame.midX - windowSize.width / 2
        case .topLeft, .bottomLeft:
            return visibleFrame.minX + Self.horizontalEdgeInset - canvasPadding
        case .topRight, .bottomRight:
            return visibleFrame.maxX - Self.horizontalEdgeInset + canvasPadding - windowSize.width
        }
    }

    private func verticalOrigin(
        windowSize: CGSize,
        visibleFrame: CGRect,
        bottomOffset: CGFloat,
        canvasPadding: CGFloat
    ) -> CGFloat {
        if self.isBottomAnchored {
            // Pin the bottom edge of the *visible* overlay, not the transparent
            // shadow canvas around it. That canvas padding scales with the user
            // scale, so anchoring the window instead of the content made the pill
            // float away from the bottom edge whenever the scale slider moved -
            // the diagonal glide the polish pass reported.
            let contentHeight = max(windowSize.height - canvasPadding * 2, 0)
            let minimumBottom = visibleFrame.minY + Self.lowerSafetyBuffer
            let maximumBottom = max(
                visibleFrame.maxY - Self.upperSafetyBuffer - contentHeight,
                minimumBottom
            )
            let contentBottom = min(max(visibleFrame.minY + bottomOffset, minimumBottom), maximumBottom)
            return contentBottom - canvasPadding
        }

        // Top anchors pin the top edge, so the overlay grows downwards exactly as
        // it always did: land the visible pill a few points below the menu bar,
        // the way a small macOS status indicator sits.
        let maximumY = visibleFrame.maxY - Self.verticalEdgeInset + canvasPadding - windowSize.height
        let minimumY = visibleFrame.minY + Self.lowerSafetyBuffer
        let preferredY = maximumY
        return min(max(preferredY, minimumY), max(maximumY, minimumY))
    }
}
