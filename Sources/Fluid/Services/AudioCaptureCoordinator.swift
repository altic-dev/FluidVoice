import Foundation

/// Coordinates call and dictation workflow ownership.
@MainActor
final class AudioCaptureCoordinator {
    enum Owner: Hashable {
        case call
        case dictation
    }

    static let shared = AudioCaptureCoordinator()

    private(set) var owner: Owner?
    private var releaseWaiters: [Owner: [CheckedContinuation<Void, Never>]] = [:]

    init() {}

    func reserve(for requestedOwner: Owner) -> Bool {
        guard self.owner == nil else {
            if requestedOwner == .dictation, self.owner == .call {
                NotificationService.showCallTranscriptionInProgress()
            }
            return false
        }
        self.owner = requestedOwner
        return true
    }

    func release(for releasingOwner: Owner) {
        guard self.owner == releasingOwner else { return }
        self.owner = nil
        let waiters = self.releaseWaiters.removeValue(forKey: releasingOwner) ?? []
        waiters.forEach { $0.resume() }
    }

    func waitUntilReleased(_ owner: Owner) async {
        guard self.owner == owner else { return }
        await withCheckedContinuation { continuation in
            if self.owner == owner {
                self.releaseWaiters[owner, default: []].append(continuation)
            } else {
                continuation.resume()
            }
        }
    }
}
