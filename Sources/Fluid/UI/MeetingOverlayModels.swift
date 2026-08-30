import CoreGraphics
import Foundation

enum MeetingOverlayPreference: String, Codable, CaseIterable, Equatable, Sendable {
    case pill
    case captions
}

enum MeetingOverlayPresentation: Equatable, Sendable {
    case pill
    case captions

    init(_ preference: MeetingOverlayPreference) {
        switch preference {
        case .pill:
            self = .pill
        case .captions:
            self = .captions
        }
    }

    var toggled: MeetingOverlayPresentation {
        switch self {
        case .pill:
            return .captions
        case .captions:
            return .pill
        }
    }

    /// Visible surface size for this presentation. Panel geometry and SwiftUI
    /// surface frames must both use this value; it is not the NSPanel frame.
    var visibleSize: CGSize {
        switch self {
        case .pill:
            return CGSize(width: 84, height: 32)
        case .captions:
            return CGSize(width: 340, height: 156)
        }
    }

    /// Canonical bottom footer height within the captions surface. Fixed so the footer never
    /// moves as caption content grows or shrinks.
    static let captionsFooterHeight: CGFloat = 35

    /// Canonical caption text viewport height: the remainder of the captions canvas above the
    /// footer. viewport + footer must equal `captions.visibleSize.height`.
    static let captionsViewportHeight: CGFloat = MeetingOverlayPresentation.captions.visibleSize.height
        - MeetingOverlayPresentation.captionsFooterHeight

    /// Canonical horizontal inset on both sides of the caption text content, inside the 340pt canvas.
    static let captionsHorizontalInset: CGFloat = 16

    /// Canonical inset above the caption text content, inside the caption viewport.
    static let captionsTopInset: CGFloat = 12

    /// Canonical inset below the caption text content, inside the caption viewport.
    static let captionsBottomInset: CGFloat = 7

    /// Caption text content width: the captions canvas width minus both horizontal insets.
    static let captionsContentWidth: CGFloat = MeetingOverlayPresentation.captions.visibleSize.width
        - (2 * MeetingOverlayPresentation.captionsHorizontalInset)

    /// Caption text content height: the viewport height minus the top and bottom insets. The live
    /// text and empty state are clipped to exactly this rectangle so an overflowing fixedSize Text
    /// can never consume the top or bottom inset.
    static let captionsContentHeight: CGFloat = MeetingOverlayPresentation.captionsViewportHeight
        - MeetingOverlayPresentation.captionsTopInset
        - MeetingOverlayPresentation.captionsBottomInset
}

struct MeetingOverlayVisibleAnchor: Equatable, Sendable {
    var centerX: CGFloat
    var bottomY: CGFloat
}

struct MeetingOverlayPadding: Equatable, Sendable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static func uniform(_ value: CGFloat) -> MeetingOverlayPadding {
        MeetingOverlayPadding(top: value, left: value, bottom: value, right: value)
    }
}

struct MeetingOverlayLayout: Equatable, Sendable {
    var panelFrame: CGRect
    var visibleSurfaceFrame: CGRect
}

enum MeetingOverlayGeometry {
    static func layout(
        anchor: MeetingOverlayVisibleAnchor,
        visibleSize: CGSize,
        padding: CGFloat,
        screenVisible: CGRect
    ) -> MeetingOverlayLayout {
        self.layout(
            anchor: anchor,
            visibleSize: visibleSize,
            padding: .uniform(padding),
            screenVisible: screenVisible
        )
    }

    static func layout(
        anchor: MeetingOverlayVisibleAnchor,
        visibleSize: CGSize,
        padding: MeetingOverlayPadding,
        screenVisible: CGRect
    ) -> MeetingOverlayLayout {
        let visible = self.clampedVisibleSurface(
            proposedOrigin: CGPoint(
                x: anchor.centerX - visibleSize.width / 2,
                y: anchor.bottomY
            ),
            proposedSize: visibleSize,
            screenVisible: screenVisible
        )
        let panel = CGRect(
            x: visible.minX - padding.left,
            y: visible.minY - padding.bottom,
            width: visible.width + padding.left + padding.right,
            height: visible.height + padding.top + padding.bottom
        )
        return MeetingOverlayLayout(panelFrame: panel, visibleSurfaceFrame: visible)
    }

    private static func clampedVisibleSurface(
        proposedOrigin: CGPoint,
        proposedSize: CGSize,
        screenVisible: CGRect
    ) -> CGRect {
        let width = min(max(proposedSize.width, 0), max(screenVisible.width, 0))
        let height = min(max(proposedSize.height, 0), max(screenVisible.height, 0))
        let minX = screenVisible.minX
        let maxX = screenVisible.maxX - width
        let minY = screenVisible.minY
        let maxY = screenVisible.maxY - height
        let x = min(max(proposedOrigin.x, minX), max(minX, maxX))
        let y = min(max(proposedOrigin.y, minY), max(minY, maxY))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

enum MeetingOverlayPresentationEvent: Equatable, Sendable {
    case recordingStarted(sessionID: UUID)
    case recordingStateChanged
    case recordingDegraded
    case recordingStopped
    case preferenceChanged(MeetingOverlayPreference)
    case toggleRequested
}

struct MeetingOverlayPresentationReducer: Equatable, Sendable {
    private(set) var preference: MeetingOverlayPreference
    private(set) var presentation: MeetingOverlayPresentation?
    private(set) var sessionID: UUID?

    init(preference: MeetingOverlayPreference = .pill) {
        self.preference = preference
        self.presentation = nil
        self.sessionID = nil
    }

    mutating func apply(_ event: MeetingOverlayPresentationEvent) {
        switch event {
        case .recordingStarted(let sessionID):
            guard self.sessionID != sessionID else { return }
            self.sessionID = sessionID
            self.presentation = MeetingOverlayPresentation(self.preference)
        case .recordingStateChanged, .recordingDegraded:
            break
        case .recordingStopped:
            self.sessionID = nil
            self.presentation = nil
        case .preferenceChanged(let preference):
            self.preference = preference
        case .toggleRequested:
            guard self.sessionID != nil, let presentation else { return }
            self.presentation = presentation.toggled
        }
    }
}
