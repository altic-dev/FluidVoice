import Foundation

/// Main-thread callers serialize requests; tokens reject delayed callbacks from old sheets.
struct ReleaseHighlightsPolicy {
    static let seenKey = "FluidVoiceSeenReleaseHighlightVersions"
    static let historyLimit = 32

    struct Session: Equatable, Identifiable {
        let id = UUID()
        let owner: UUID
        let version: String
        let build: String
        let manual: Bool
        var dismissing = false
        var acknowledge = false
    }

    private(set) var seenVersions: [String]
    private(set) var session: Session?
    private var manualRequests: Set<UUID> = []

    init(seenVersions: [String] = []) {
        var unique: [String] = []
        for version in seenVersions where !version.isEmpty {
            unique.removeAll { $0 == version }
            unique.append(version)
        }
        self.seenVersions = Array(unique.suffix(Self.historyLimit))
    }

    static func updateID(version: String, build: String) -> String {
        build.isEmpty ? version : "\(version) (\(build))"
    }

    mutating func requestManual(owner: UUID) {
        // Repeated requests for an already-open sheet must not queue a second popup.
        guard self.session?.owner != owner else { return }
        self.manualRequests.insert(owner)
    }

    mutating func request(owner: UUID, version: String, build: String = "", eligible: Bool, manual: Bool = false) -> Session? {
        if manual { self.requestManual(owner: owner) }
        // Content may describe an earlier release. Every newly installed version/build
        // still gets a presentation, without interrupting an ineligible activity.
        guard eligible, self.session == nil, !version.isEmpty,
              self.manualRequests.contains(owner) || !self.seenVersions.contains(Self.updateID(version: version, build: build)) else { return nil }
        let session = Session(owner: owner, version: version, build: build, manual: self.manualRequests.contains(owner))
        self.manualRequests.remove(owner)
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
        if !acknowledged, session.manual { self.manualRequests.insert(session.owner) }
        if acknowledged {
            let updateID = Self.updateID(version: session.version, build: session.build)
            self.seenVersions.removeAll { $0 == updateID }
            self.seenVersions.append(updateID)
            self.seenVersions = Array(self.seenVersions.suffix(Self.historyLimit))
        }
        return acknowledged
    }

    mutating func abandon(owner: UUID) {
        self.manualRequests.remove(owner)
        guard self.session?.owner == owner else { return }
        self.session = nil
    }
}
