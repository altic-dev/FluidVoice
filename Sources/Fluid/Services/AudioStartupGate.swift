import Foundation

/// Centralized startup gate for any code paths that can trigger CoreAudio initialization.
///
/// Why this exists:
/// - SwiftUI/AttributeGraph does not expose a reliable "initial metadata processing is finished" signal.
/// - CoreAudio/AVFoundation initialization can race that work during app launch and crash with EXC_BAD_ACCESS.
/// - A single shared gate makes it much harder for new call-sites (e.g., Settings views) to accidentally
///   trigger CoreAudio too early.
actor AudioStartupGate {
    static let shared = AudioStartupGate()

    private var isOpen: Bool = false
    private var openTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Schedule opening the gate once. Safe to call multiple times.
    func scheduleOpenAfterInitialUISettled(delayNanoseconds: UInt64 = 2_000_000_000) {
        guard self.isOpen == false, self.openTask == nil else { return }

        self.openTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Give SwiftUI a couple runloop turns to finish initial layout/metadata passes.
            await Task.yield()
            await Task.yield()

            // Safety delay for slower / loaded systems (e.g., long uptime, heavy background load).
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            await self.open()
        }
    }

    /// Await until the gate is open. Returns immediately if already open.
    func waitUntilOpen() async {
        if self.isOpen { return }

        await withCheckedContinuation { cont in
            self.waiters.append(cont)
        }
    }

    private func open() {
        guard self.isOpen == false else { return }
        self.isOpen = true

        let pending = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}
