import Foundation

/// Main-thread callers serialize requests; tokens reject delayed callbacks from old sheets.
struct ReleaseHighlightsPolicy {
    static let seenKey = "FluidVoiceSeenReleaseHighlightVersions"
    static let historyLimit = 32

    struct Session: Equatable, Identifiable {
        let id = UUID()
        let owner: UUID
        let version: String
        var dismissing = false
        var acknowledge = false
    }

    private(set) var seenVersions: [String]
    private(set) var session: Session?

    init(seenVersions: [String] = []) {
        var unique: [String] = []
        for version in seenVersions where !version.isEmpty {
            unique.removeAll { $0 == version }
            unique.append(version)
        }
        self.seenVersions = Array(unique.suffix(Self.historyLimit))
    }

    static func matches(version: String, release: String) -> Bool {
        !release.isEmpty && (version == release || version.hasPrefix(release + "-"))
    }

    mutating func request(owner: UUID, version: String, release: String, eligible: Bool, manual: Bool = false) -> Session? {
        guard eligible, self.session == nil, Self.matches(version: version, release: release),
              manual || !self.seenVersions.contains(version) else { return nil }
        let session = Session(owner: owner, version: version)
        self.session = session
        return session
    }

    mutating func beginDismiss(id: UUID, acknowledge: Bool) -> Bool {
        guard var session = self.session, session.id == id, !session.dismissing else { return false }
        session.dismissing = true
        session.acknowledge = acknowledge
        self.session = session
        return true
    }

    mutating func interrupt(id: UUID) {
        guard var session = self.session, session.id == id else { return }
        session.dismissing = true
        session.acknowledge = false
        self.session = session
    }

    /// Returns nil for stale callbacks. A system dismissal counts as a close only if still eligible.
    mutating func finishDismiss(id: UUID, eligible: Bool) -> Bool? {
        guard let session = self.session, session.id == id else { return nil }
        self.session = nil
        let acknowledged = eligible && (!session.dismissing || session.acknowledge)
        if acknowledged {
            self.seenVersions.removeAll { $0 == session.version }
            self.seenVersions.append(session.version)
            self.seenVersions = Array(self.seenVersions.suffix(Self.historyLimit))
        }
        return acknowledged
    }

    mutating func abandon(owner: UUID) {
        guard self.session?.owner == owner else { return }
        self.session = nil
    }
}
