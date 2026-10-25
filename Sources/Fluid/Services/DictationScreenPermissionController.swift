import Combine
import CoreGraphics

/// Permission checks are read-only. Only an explicit OCR enable action may prompt.
@MainActor
final class DictationScreenPermissionController: ObservableObject {
    @Published private(set) var isAllowed = false
    @Published private(set) var hasChecked = false
    @Published private(set) var isRequesting = false

    private let check: @Sendable () -> Bool
    private let request: @MainActor () -> Bool
    private var refreshTask: Task<Bool, Never>?
    private var generation: UInt64 = 0

    init(
        check: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() }
    ) {
        self.check = check
        self.request = request
    }

    func refresh() async {
        let generation: UInt64
        let task: Task<Bool, Never>
        if let pending = self.refreshTask {
            task = pending
            generation = self.generation
        } else {
            self.generation &+= 1
            generation = self.generation
            let check = self.check
            task = Task.detached(priority: .utility) { check() }
            self.refreshTask = task
        }
        let allowed = await task.value
        guard generation == self.generation, !Task.isCancelled else { return }
        self.isAllowed = allowed
        self.hasChecked = true
        self.refreshTask = nil
    }

    func requestIfNeeded(shouldRequest: @MainActor () -> Bool) async {
        guard !self.isRequesting, shouldRequest() else { return }
        self.isRequesting = true
        defer { self.isRequesting = false }
        await self.refresh()
        guard shouldRequest(), !self.isAllowed, !Task.isCancelled else { return }
        self.generation &+= 1
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.isAllowed = self.request()
        self.hasChecked = true
    }
}
