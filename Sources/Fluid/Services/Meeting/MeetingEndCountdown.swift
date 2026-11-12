import Foundation

/// A deadline belongs to one recording and one presentation. Old tasks cannot stop a newer call.
struct MeetingEndCountdown {
    struct Ticket: Equatable {
        let sessionID: UUID
        let generation: UUID
        let deadline: TimeInterval
    }

    enum Update: Equatable {
        case waiting(Int)
        case stop(UUID)
        case cancelled
        case stale
    }

    static let duration: TimeInterval = 30
    private(set) var ticket: Ticket?

    mutating func begin(sessionID: UUID, now: TimeInterval) -> Ticket {
        if let ticket, ticket.sessionID == sessionID { return ticket }
        let ticket = Ticket(sessionID: sessionID, generation: UUID(), deadline: now + Self.duration)
        self.ticket = ticket
        return ticket
    }

    mutating func cancel() {
        self.ticket = nil
    }

    mutating func advance(_ ticket: Ticket, now: TimeInterval, isEligible: Bool, stopNow: Bool = false) -> Update {
        guard self.ticket == ticket else { return .stale }
        guard isEligible else {
            self.cancel()
            return .cancelled
        }
        let remaining = max(0, Int(ceil(ticket.deadline - now)))
        guard remaining > 0, !stopNow else {
            self.cancel()
            return .stop(ticket.sessionID)
        }
        return .waiting(remaining)
    }
}
