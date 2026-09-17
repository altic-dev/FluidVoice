import Foundation

/// Releases the local model after a quiet period so its memory goes back to
/// the system instead of being compressed or swapped. Work in flight, and any
/// state the caller reports as busy (a recording that will need the model when
/// it ends), postpones the unload rather than cancelling it.
actor PrivateAIIdleUnloader {
    /// The quiet period to wait, or nil while the feature is off.
    private let delay: @Sendable () async -> Duration?
    private let isBusy: @Sendable () async -> Bool
    private let unload: @Sendable () async -> Void
    private let activityEnded: @Sendable () async -> Void
    private var inFlight = 0
    private var pending: Task<Void, Never>?

    init(
        delay: @escaping @Sendable () async -> Duration?,
        isBusy: @escaping @Sendable () async -> Bool,
        unload: @escaping @Sendable () async -> Void,
        activityEnded: @escaping @Sendable () async -> Void = {}
    ) {
        self.activityEnded = activityEnded
        self.delay = delay
        self.isBusy = isBusy
        self.unload = unload
    }

    func begin() {
        self.inFlight += 1
        self.pending?.cancel()
        self.pending = nil
    }

    func end() {
        self.inFlight = max(0, self.inFlight - 1)
        guard self.inFlight == 0 else { return }
        self.schedule()
        Task { [activityEnded] in await activityEnded() }
    }

    /// Runs `work` as model activity: the countdown restarts when it finishes.
    nonisolated func tracking<T>(_ work: () async throws -> T) async rethrows -> T {
        await self.begin()
        do {
            let result = try await work()
            await self.end()
            return result
        } catch {
            await self.end()
            throw error
        }
    }

    /// Restarts the countdown with the current setting, e.g. after the user
    /// picks a different quiet period.
    func settingsChanged() {
        guard self.inFlight == 0 else { return }
        self.schedule()
    }

    private func schedule() {
        self.pending?.cancel()
        self.pending = Task { [delay] in
            guard let delay = await delay() else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.fire()
        }
    }

    private func fire() async {
        guard self.inFlight == 0, await self.delay() != nil else { return }
        if await self.isBusy() {
            self.schedule()
            return
        }
        // A request may have started while the checks above were suspended.
        guard self.inFlight == 0, !Task.isCancelled else { return }
        self.pending = nil
        await self.unload()
    }
}
