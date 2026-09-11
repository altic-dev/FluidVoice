import Foundation

/// Serializes microphone-owning workflows that share audio hardware and ASR providers.
@MainActor
final class AudioCaptureCoordinator {
    enum Owner: Hashable {
        case call
        case dictation
    }

    static let shared = AudioCaptureCoordinator()

    private var owners: Set<Owner> = []
    private var releaseWaiters: [Owner: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var isCallRecording = false

    init() {}

    func reserve(for requestedOwner: Owner) -> Bool {
        guard !self.owners.contains(requestedOwner) else { return false }
        if requestedOwner == .dictation, self.isCallRecording, self.owners == [.call] {
            self.owners.insert(.dictation)
            return true
        }
        guard self.owners.isEmpty else { return false }
        self.owners.insert(requestedOwner)
        return true
    }

    func release(for releasingOwner: Owner) {
        guard self.owners.remove(releasingOwner) != nil else { return }
        if releasingOwner == .call {
            self.isCallRecording = false
        }
        let waiters = self.releaseWaiters.removeValue(forKey: releasingOwner) ?? []
        waiters.forEach { $0.resume() }
    }

    func setCallRecording(_ isRecording: Bool) {
        self.isCallRecording = isRecording && self.owners.contains(.call)
    }

    func waitUntilReleased(_ owner: Owner) async {
        guard self.owners.contains(owner) else { return }
        await withCheckedContinuation { continuation in
            if self.owners.contains(owner) {
                self.releaseWaiters[owner, default: []].append(continuation)
            } else {
                continuation.resume()
            }
        }
    }
}
