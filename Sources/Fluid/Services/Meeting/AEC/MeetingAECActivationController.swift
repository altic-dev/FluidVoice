import Foundation

/// Pure token/state owner for the AEC startup handshake. Runtime resources remain under the
/// `ScreenCaptureMeetingRuntime` lock, while this value makes every legal transition explicit and
/// independently testable without constructing an `SCStream`.
nonisolated enum MeetingAECActivationState: Equatable, Sendable {
    case raw
    case constructing(UInt64)
    case ready(UInt64)
    case armed(UInt64, renderValidated: Bool, captureValidated: Bool)
    case active(UInt64)
}

nonisolated struct MeetingAECActivationController: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var state: MeetingAECActivationState = .raw

    /// Invalidates construction, a ready/armed candidate, or an active engine synchronously.
    mutating func invalidate() {
        self.generation &+= 1
        self.state = .raw
    }

    /// Reserves the next generation. A second constructor can never overlap the first one.
    mutating func reserveConstruction() -> UInt64? {
        guard self.state == .raw else { return nil }
        self.generation &+= 1
        self.state = .constructing(self.generation)
        return self.generation
    }

    mutating func abandonConstruction(_ token: UInt64) {
        guard self.generation == token, self.state == .constructing(token) else { return }
        self.state = .raw
    }

    /// Commits only the still-current reservation. A route/stream/lifecycle invalidation makes a
    /// late candidate harmless even if its construction has already completed.
    mutating func commitCandidate(_ token: UInt64) -> Bool {
        guard self.generation == token, self.state == .constructing(token) else { return false }
        self.state = .ready(token)
        return true
    }

    /// Before the initial asynchronous `startCapture`, only raw or a current ready candidate is a
    /// legal state. Constructing, armed, and active states indicate a stale lifecycle transition.
    func allowsInitialCaptureStart(hasCandidate: Bool) -> Bool {
        switch self.state {
        case .raw:
            return !hasCandidate
        case let .ready(token):
            return hasCandidate && token == self.generation
        case .constructing, .armed, .active:
            return false
        }
    }

    /// Called after `startCapture` (or immediately after a route-time candidate commit when the
    /// stream is already running). Actual render and capture callbacks still remain raw.
    mutating func armReadyCandidate() -> Bool {
        guard case let .ready(token) = self.state, token == self.generation else { return false }
        self.state = .armed(token, renderValidated: false, captureValidated: false)
        return true
    }

    /// Returns true only on the callback that completes both real-format observations. That
    /// callback itself stays raw; a subsequent callback is the first one allowed to see `.active`.
    @discardableResult
    mutating func observeValidatedFormat(kind: MeetingAECInputKind, token: UInt64) -> Bool {
        guard token == self.generation,
              case let .armed(generation, renderValidated, captureValidated) = self.state,
              generation == token
        else { return false }
        let renderOK = renderValidated || kind == .render
        let captureOK = captureValidated || kind == .capture
        if renderOK && captureOK {
            self.state = .active(token)
            return true
        }
        self.state = .armed(token, renderValidated: renderOK, captureValidated: captureOK)
        return false
    }
}
