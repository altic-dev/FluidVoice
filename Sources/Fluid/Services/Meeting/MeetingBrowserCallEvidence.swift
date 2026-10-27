import ApplicationServices
import Foundation

/// URL presence alone cannot distinguish a connected call from its post-call page.
nonisolated enum MeetingBrowserCallState: Sendable, Equatable {
    case unknown
    case inCall
    case ended
}

/// Positive controls observed on Google Meet's English post-call and connected-call pages.
/// Unrecognised/localised copy stays unknown; it must never become an inferred end.
nonisolated struct MeetingBrowserCallEvidence {
    private var leftHeading = false
    private var rejoinButton = false
    private var leaveButton = false

    static func supports(_ url: BrowserTabURL) -> Bool {
        url.host.lowercased() == "meet.google.com" && MeetingInCallURLMatcher.isInCallURL(host: url.host, path: url.path)
    }

    mutating func observe(role: String, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if role == "AXHeading", label == "You left the meeting" { self.leftHeading = true }
        if role == "AXButton", label == "Rejoin" { self.rejoinButton = true }
        if role == "AXButton", label == "Leave call" { self.leaveButton = true }
    }

    var state: MeetingBrowserCallState {
        if self.leftHeading, self.rejoinButton, !self.leaveButton { return .ended }
        if self.leaveButton, !self.leftHeading, !self.rejoinButton { return .inCall }
        return .unknown
    }
}

/// Runs on the browser reader's existing utility queue with the same AX messaging timeout.
/// Reads only labels of buttons/headings; never records page text, meeting IDs or participants.
nonisolated enum MeetingBrowserCallAXReader {
    private static let maxElements = 160
    private static let maxDepth = 10
    private static let maxChildren = 32
    private static let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXLink", "AXTextField", "AXTextArea", "AXHeading", "AXButton"]

    static func state(webArea: AXUIElement, url: BrowserTabURL) -> MeetingBrowserCallState {
        guard MeetingBrowserCallEvidence.supports(url) else { return .unknown }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        var evidence = MeetingBrowserCallEvidence()
        var pending: [(AXUIElement, Int)] = [(webArea, 0)]
        var index = 0
        while index < pending.count, index < Self.maxElements {
            guard ContinuousClock.now < deadline else { return .unknown }
            let (element, depth) = pending[index]
            index += 1
            guard let role = self.string(element, attribute: kAXRoleAttribute as String) else { return .unknown }
            if role == "AXHeading" || role == "AXButton" {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .lazy.compactMap { self.string(element, attribute: $0 as String) }
                    .first { !$0.isEmpty } ?? ""
                evidence.observe(role: role, label: label)
            }
            guard depth < Self.maxDepth, !Self.leafRoles.contains(role) else { continue }
            var childrenValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            if status == .cannotComplete { return .unknown }
            guard status == .success, let children = childrenValue as? [AXUIElement] else { continue }
            let remaining = Self.maxElements - pending.count
            guard remaining > 0 else { break }
            for child in children.prefix(min(Self.maxChildren, remaining)) {
                pending.append((child, depth + 1))
            }
        }
        return evidence.state
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
