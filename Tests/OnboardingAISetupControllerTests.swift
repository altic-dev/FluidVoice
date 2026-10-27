import Foundation

@MainActor
private final class Harness {
    typealias Controller = OnboardingAISetupController
    var installed = false
    var failRecommendation = false
    var failDownload = false
    var failLoad = false
    var pauseDownload = false
    var pauseLoad = false
    var readCount = 0
    var downloads = 0
    var loads = 0
    var commits = 0
    var downloadContinuation: CheckedContinuation<Void, Never>?
    var loadContinuation: CheckedContinuation<Void, Never>?
    var progressCallback: (@Sendable (Controller.Progress) async -> Void)?
    var lastID: String?
    var pendingDownload = false
    enum Failure: Error { case simulated }

    func controller() -> Controller {
        Controller(dependencies: .init(
            recommend: {
                self.readCount += 1
                if self.failRecommendation { throw Failure.simulated }
                return .init(id: "pico", name: "Pico", byteCount: 100, installed: self.installed)
            },
            prepare: { model, progress in
                self.downloads += 1
                self.lastID = model.id
                self.progressCallback = progress
                await progress(.init(fraction: 0.5, status: "Downloading", bytes: "50 of 100"))
                if self.pauseDownload {
                    await withCheckedContinuation { self.downloadContinuation = $0 }
                }
                if self.failDownload { throw Failure.simulated }
            },
            load: { model in
                self.loads += 1
                self.lastID = model.id
                if self.pauseLoad {
                    await withCheckedContinuation { self.loadContinuation = $0 }
                }
                if self.failLoad { throw Failure.simulated }
            },
            readPendingDownload: { self.pendingDownload },
            writePendingDownload: { self.pendingDownload = $0 }
        ))
    }
}

@main
struct OnboardingAISetupControllerTests {
    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out waiting for controller")
    }

    @MainActor
    static func main() async {
        // A newly created controller recovers a persisted request, never activation.
        let restarted = Harness()
        restarted.pendingDownload = true
        restarted.failDownload = true
        let firstProcess = restarted.controller()
        firstProcess.resumePendingDownload()
        await self.waitUntil { firstProcess.errorMessage != nil }
        precondition(restarted.pendingDownload && restarted.loads == 0 && restarted.commits == 0)
        restarted.failDownload = false
        let nextProcess = restarted.controller()
        nextProcess.resumePendingDownload()
        await self.waitUntil { !restarted.pendingDownload }
        precondition(restarted.downloads == 2 && restarted.loads == 0 && restarted.commits == 0)
        firstProcess.cancel()

        let cancelled = Harness()
        cancelled.pendingDownload = true
        cancelled.controller().cancel()
        cancelled.controller().resumePendingDownload()
        precondition(!cancelled.pendingDownload && cancelled.downloads == 0)

        let saved = Harness()
        saved.installed = true
        saved.pendingDownload = true
        let savedController = saved.controller()
        savedController.resumePendingDownload()
        await self.waitUntil { !saved.pendingDownload }
        precondition(saved.downloads == 0 && saved.loads == 0 && saved.commits == 0)

        let fresh = Harness()
        let controller = fresh.controller()
        controller.refresh()
        controller.refresh()
        await self.waitUntil { controller.phase == .offered }
        precondition(fresh.readCount == 1 && fresh.downloads == 0 && fresh.loads == 0 && fresh.commits == 0)
        controller.enable { _ in fresh.commits += 1 }
        controller.enable { _ in preconditionFailure("Duplicate action") }
        await self.waitUntil { controller.phase == .ready }
        precondition(fresh.downloads == 1 && fresh.loads == 1 && fresh.commits == 1 && fresh.lastID == "pico")
        await fresh.progressCallback?(.init(fraction: 0.1, status: "stale", bytes: nil))
        precondition(controller.phase == .ready && controller.progress == nil)
        controller.introductionFinished = true
        controller.cancel() // Leaving the AI page after setup has finished.
        controller.refresh() // Returning to that page reuses the flow-owned controller.
        precondition(controller.phase == .ready && controller.introductionFinished)
        precondition(fresh.readCount == 1 && fresh.loads == 1 && fresh.commits == 1)
        controller.introductionFinished = false // Explicit Replay changes only video progress.
        precondition(controller.phase == .ready && fresh.loads == 1 && fresh.commits == 1)

        let prefetched = Harness()
        prefetched.pauseDownload = true
        let prefetchedController = prefetched.controller()
        prefetchedController.prefetch()
        prefetchedController.prefetch()
        await self.waitUntil { prefetched.downloadContinuation != nil }
        precondition(prefetchedController.phase == .downloading)
        precondition(prefetchedController.canEnable && !prefetchedController.showsPreparationProgress)
        precondition(prefetched.readCount == 1 && prefetched.downloads == 1 && prefetched.loads == 0 && prefetched.commits == 0)
        prefetchedController.enable { _ in prefetched.commits += 1 }
        precondition(!prefetchedController.canEnable && prefetchedController.showsPreparationProgress)
        prefetchedController.enable { _ in preconditionFailure("Duplicate activation") }
        prefetched.downloadContinuation?.resume()
        await self.waitUntil { prefetchedController.phase == .ready }
        precondition(prefetched.downloads == 1 && prefetched.loads == 1 && prefetched.commits == 1)

        let prefetchedCached = Harness()
        prefetchedCached.installed = true
        let prefetchedCachedController = prefetchedCached.controller()
        prefetchedCachedController.prefetch()
        await self.waitUntil { prefetchedCachedController.phase == .offered }
        precondition(prefetchedCached.readCount == 1 && prefetchedCached.downloads == 0 && prefetchedCached.loads == 0)

        let cancelledPrefetch = Harness()
        cancelledPrefetch.pauseDownload = true
        let cancelledPrefetchController = cancelledPrefetch.controller()
        cancelledPrefetchController.prefetch()
        await self.waitUntil { cancelledPrefetch.downloadContinuation != nil }
        cancelledPrefetchController.enable { _ in preconditionFailure("Cancelled activation") }
        cancelledPrefetchController.cancel()
        precondition(cancelledPrefetchController.phase == .cancelling && cancelledPrefetchController.progress == nil)
        cancelledPrefetch.downloadContinuation?.resume()
        await self.waitUntil { cancelledPrefetchController.phase == .offered }
        cancelledPrefetch.pauseDownload = false
        cancelledPrefetchController.enable { _ in cancelledPrefetch.commits += 1 }
        await self.waitUntil { cancelledPrefetchController.phase == .ready }
        precondition(cancelledPrefetch.downloads == 2 && cancelledPrefetch.loads == 1 && cancelledPrefetch.commits == 1)

        let cached = Harness()
        let deferred = Harness()
        deferred.pauseDownload = true
        var deferredController: OnboardingAISetupController? = deferred.controller()
        weak var retainedDownload = deferredController
        deferredController?.setUpLater()
        await self.waitUntil { deferred.downloadContinuation != nil }
        deferredController?.leavePage()
        deferredController = nil
        precondition(retainedDownload != nil, "Download survives onboarding dismissal")
        deferred.downloadContinuation?.resume()
        deferred.progressCallback = nil
        await self.waitUntil { retainedDownload == nil }
        precondition(deferred.downloads == 1 && deferred.loads == 0 && deferred.commits == 0)

        cached.installed = true
        let cachedController = cached.controller()
        cachedController.refresh()
        await self.waitUntil { cachedController.phase == .offered }
        cachedController.enable { _ in cached.commits += 1 }
        await self.waitUntil { cachedController.phase == .ready }
        precondition(cached.downloads == 0 && cached.loads == 1 && cached.commits == 1)

        for cancelDuringLoad in [false, true] {
            let harness = Harness()
            harness.pauseDownload = !cancelDuringLoad
            harness.pauseLoad = cancelDuringLoad
            let operation = harness.controller()
            operation.refresh()
            await self.waitUntil { operation.phase == .offered }
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { cancelDuringLoad ? harness.loadContinuation != nil : harness.downloadContinuation != nil }
            operation.cancel()
            operation.cancel()
            precondition(operation.phase == .cancelling && operation.progress == nil)
            operation.enable { _ in preconditionFailure("Cannot overlap cancelled work") }
            await harness.progressCallback?(.init(fraction: 0.9, status: "late", bytes: nil))
            precondition(operation.progress == nil)
            harness.downloadContinuation?.resume()
            harness.loadContinuation?.resume()
            await self.waitUntil { operation.phase == .offered }
            precondition(harness.commits == 0 && operation.errorMessage == nil)
            precondition(harness.loads == (cancelDuringLoad ? 1 : 0))
            let oldProgress = harness.progressCallback
            harness.pauseDownload = false
            harness.pauseLoad = false
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { operation.phase == .ready }
            await oldProgress?(.init(fraction: 0.2, status: "old operation", bytes: nil))
            precondition(operation.progress == nil && harness.commits == 1)
        }

        for downloadFailure in [true, false] {
            let harness = Harness()
            harness.failDownload = downloadFailure
            harness.failLoad = !downloadFailure
            let operation = harness.controller()
            operation.refresh()
            await self.waitUntil { operation.phase == .offered }
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { operation.errorMessage != nil }
            precondition(operation.phase == .offered && harness.commits == 0 && operation.progress == nil)
            harness.failDownload = false
            harness.failLoad = false
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { operation.phase == .ready }
            precondition(harness.commits == 1)
        }

        let unavailable = Harness()
        unavailable.failRecommendation = true
        let missing = unavailable.controller()
        missing.refresh()
        await self.waitUntil { missing.phase == .unavailable }
        precondition(unavailable.downloads == 0 && unavailable.commits == 0)
        unavailable.failRecommendation = false
        missing.refresh()
        await self.waitUntil { missing.phase == .offered }
        missing.enable { _ in throw Harness.Failure.simulated }
        await self.waitUntil { missing.errorMessage != nil }
        precondition(missing.phase == .offered && unavailable.commits == 0)
        print(
            "PASS: recommendation prefetch, fresh/cached activation, prefetch cancellation/retry, duplicate actions, cancellation during download/load, stale progress, failure/retry and commit rejection"
        )
    }
}
