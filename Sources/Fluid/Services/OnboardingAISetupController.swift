import Combine
import Foundation

/// Owns one explicit setup attempt. Reads and cancelled work never commit a model selection.
@MainActor
final class OnboardingAISetupController: ObservableObject {
    struct Model: Equatable, Sendable {
        let id: String
        let name: String
        let byteCount: Int64?
        let installed: Bool
    }

    struct Progress: Equatable, Sendable {
        let fraction: Double?
        let status: String
        let bytes: String?
    }

    enum Phase: Equatable {
        case checking, offered, downloading, loading, cancelling, ready, unavailable
    }

    struct Dependencies {
        var recommend: () async throws -> Model
        var prepare: (Model, @escaping @Sendable (Progress) async -> Void) async throws -> Void
        var load: (Model) async throws -> Void
        var readPendingDownload: () -> Bool = { false }
        var writePendingDownload: (Bool) -> Void = { _ in }
    }

    /// Retained by the onboarding flow across Back/Continue; Replay is the only reset.
    @Published var introductionFinished = false
    @Published private(set) var model: Model?
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var progress: Progress?
    @Published private(set) var errorMessage: String?
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    @Published private(set) var activationRequested = false
    private var isPrefetching = false
    private var pendingActivation: ((Model) throws -> Void)?
    private var prefetchAfterRefresh = false
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 30

    func resumePendingDownload() {
        guard self.dependencies.readPendingDownload() else { return }
        self.prefetch()
    }

    private func finishPendingDownload() {
        self.dependencies.writePendingDownload(false)
        self.retryTask?.cancel()
        self.retryTask = nil
        self.retryDelay = 30
    }

    private func schedulePendingRetry() {
        guard self.dependencies.readPendingDownload(), self.retryTask == nil else { return }
        let delay = self.retryDelay
        self.retryDelay = min(delay * 2, 300)
        self.retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.resumePendingDownload()
        }
    }

    var canEnable: Bool {
        !self.activationRequested && (self.phase == .offered || (self.isPrefetching && self.phase != .cancelling))
    }

    var showsPreparationProgress: Bool { self.activationRequested && self.isBusy }

    var isBusy: Bool { [.downloading, .loading, .cancelling].contains(self.phase) }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func refresh() {
        guard self.task == nil, self.phase != .ready else { return }
        let operation = UUID()
        self.operationID = operation
        self.phase = .checking
        self.errorMessage = nil
        self.task = Task { @MainActor in
            defer {
                if self.operationID == operation {
                    self.task = nil
                    if self.prefetchAfterRefresh {
                        self.prefetchAfterRefresh = false
                        self.prefetch()
                    }
                }
            }
            do {
                let model = try await self.dependencies.recommend()
                try Task.checkCancellation()
                guard self.operationID == operation else { return }
                self.model = model
                self.phase = .offered
            } catch {
                guard self.operationID == operation else { return }
                self.phase = .unavailable
                if !Task.isCancelled { self.errorMessage = error.localizedDescription }
            }
        }
    }

    /// Downloads the recommended model early without loading it or changing the user's settings.
    func prefetch() {
        self.dependencies.writePendingDownload(true)
        self.retryTask?.cancel()
        self.retryTask = nil
        if self.phase == .ready {
            self.finishPendingDownload()
            return
        }
        if self.task != nil {
            if self.phase == .checking, !self.isPrefetching { self.prefetchAfterRefresh = true }
            return
        }
        guard self.task == nil, self.phase != .ready else { return }
        if let model, model.installed {
            self.finishPendingDownload()
            self.phase = .offered
            return
        }

        let operation = UUID()
        self.operationID = operation
        self.progress = nil
        self.errorMessage = nil
        self.phase = .checking
        self.isPrefetching = true
        self.task = Task { @MainActor in
            defer {
                if self.operationID == operation {
                    self.task = nil
                    self.isPrefetching = false
                    self.schedulePendingRetry()
                    let activation = self.pendingActivation
                    self.pendingActivation = nil
                    self.activationRequested = false
                    if self.phase == .offered, self.errorMessage == nil, let activation {
                        self.enable(onReady: activation)
                    }
                }
            }
            do {
                let model = try await self.dependencies.recommend()
                try Task.checkCancellation()
                guard self.operationID == operation else { return }
                self.model = model
                guard !model.installed else {
                    self.finishPendingDownload()
                    self.phase = .offered
                    return
                }

                self.phase = .downloading
                try await self.dependencies.prepare(model) { progress in
                    await MainActor.run {
                        guard self.operationID == operation, self.phase == .downloading else { return }
                        self.progress = progress
                    }
                }
                try Task.checkCancellation()
                guard self.operationID == operation else { return }
                self.model = Model(
                    id: model.id,
                    name: model.name,
                    byteCount: model.byteCount,
                    installed: true
                )
                self.progress = nil
                self.phase = .offered
                self.finishPendingDownload()
            } catch {
                guard self.operationID == operation else { return }
                self.progress = nil
                self.phase = self.model == nil ? .unavailable : .offered
                if !Task.isCancelled, !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func enable(onReady: @escaping (Model) throws -> Void) {
        if self.isPrefetching, self.canEnable {
            self.activationRequested = true
            self.pendingActivation = onReady
            return
        }
        guard self.task == nil, self.phase == .offered, let model else { return }
        self.activationRequested = true
        if !model.installed { self.dependencies.writePendingDownload(true) }
        let operation = UUID()
        self.operationID = operation
        self.progress = nil
        self.errorMessage = nil
        self.phase = model.installed ? .loading : .downloading
        self.task = Task { @MainActor in
            defer {
                if self.operationID == operation {
                    self.task = nil
                    self.schedulePendingRetry()
                }
            }
            do {
                if !model.installed {
                    try await self.dependencies.prepare(model) { progress in
                        await MainActor.run {
                            guard self.operationID == operation, self.phase == .downloading else { return }
                            self.progress = progress
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.operationID == operation else { return }
                self.model = Model(id: model.id, name: model.name, byteCount: model.byteCount, installed: true)
                self.finishPendingDownload()
                guard self.activationRequested else {
                    self.phase = .offered
                    self.progress = nil
                    return
                }
                self.phase = .loading
                self.progress = nil
                try await self.dependencies.load(model)
                try Task.checkCancellation()
                guard self.operationID == operation else { return }
                guard self.activationRequested else {
                    self.phase = .offered
                    return
                }
                // Persistence is performed only here, after readiness and cancellation checks.
                try onReady(model)
                self.phase = .ready
            } catch {
                guard self.operationID == operation else { return }
                self.activationRequested = false
                self.phase = .offered
                self.progress = nil
                if !Task.isCancelled, !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Navigation withdraws activation, but the retained task finishes saving the model.
    func leavePage() {
        self.pendingActivation = nil
        self.activationRequested = false
    }

    func setUpLater() {
        self.leavePage()
        if self.task == nil {
            self.prefetch()
        } else if self.phase == .checking, !self.isPrefetching {
            self.prefetchAfterRefresh = true
        }
    }

    func cancel() {
        self.finishPendingDownload()
        self.prefetchAfterRefresh = false
        self.pendingActivation = nil
        self.activationRequested = false
        guard self.task != nil else { return }
        self.task?.cancel()
        self.progress = nil
        self.errorMessage = nil
        if self.isBusy { self.phase = .cancelling }
    }
}
