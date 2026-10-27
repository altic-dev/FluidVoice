import AppKit
import Carbon.HIToolbox

// Standalone executable: compile with the production PasteKeyCodeCache.swift.
@main
enum PasteKeyCodeCacheRegressionTests {
    static func main() {
        precondition(Thread.isMainThread)
        let name = Notification.Name("FluidVoice.PasteKeyCacheTest.\(UUID().uuidString)")
        var selectedKey: CGKeyCode = 9
        var lookups = 0
        let cache = PasteKeyCodeCache(notificationName: name) {
            precondition(Thread.isMainThread)
            lookups += 1
            return selectedKey
        }
        cache.start()
        cache.start()
        precondition(lookups == 1, "Startup must resolve exactly once")
        for _ in 0..<10_000 {
            precondition(cache.snapshot() == 9)
        }
        precondition(lookups == 1, "Pastes must not query the layout")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("FluidVoice.UnrelatedTest.\(UUID().uuidString)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(lookups == 1, "Unrelated notifications must not refresh the cache")

        func notifyAndWait(for key: CGKeyCode) {
            selectedKey = key
            DistributedNotificationCenter.default().postNotificationName(
                name,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            let deadline = Date().addingTimeInterval(2)
            while cache.snapshot() != key, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            precondition(cache.snapshot() == key, "Layout-change notification must update the snapshot")
        }
        notifyAndWait(for: 47) // Alternate layout, not hard-coded QWERTY.
        notifyAndWait(for: 9) // Resolver's unavailable-layout fallback replaces stale key.
        for key: CGKeyCode in [47, 12, 9, 47, 9] {
            notifyAndWait(for: key)
        }

        // Main thread is deliberately blocked: cached reads must still finish.
        let finished = DispatchSemaphore(value: 0)
        let lookupsBeforeReads = lookups
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
                precondition(cache.snapshot() == 9)
            }
            finished.signal()
        }
        precondition(finished.wait(timeout: .now() + 2) == .success, "Background reads must not wait for main")
        precondition(lookups == lookupsBeforeReads)

        var released: PasteKeyCodeCache? = PasteKeyCodeCache(notificationName: name) { 9 }
        released?.start()
        weak var weakCache = released
        released = nil
        precondition(weakCache == nil, "Observer must not retain cache")
        weakCache = nil
        print("PASS: startup, cache hits, layout notifications, fallback, rapid changes, concurrent reads, observer cleanup")
    }
}
