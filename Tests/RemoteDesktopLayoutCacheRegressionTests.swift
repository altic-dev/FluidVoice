import AppKit
import Carbon.HIToolbox

// Standalone executable: compile with the production KeyboardLayoutSnapshotCache.swift and
// RemoteDesktopKeyMap.swift.
//
// Pins the invariant that the Windows App crash violated: the remote-desktop typing path runs
// on a background queue, so it must read a snapshot and must never resolve the layout itself.
@main
enum RemoteDesktopLayoutCacheRegressionTests {
    static func stroke(_ code: CGKeyCode) -> RemoteDesktopKeyStroke {
        RemoteDesktopKeyStroke(keyCode: code, needsShift: false)
    }

    static func snap(_ map: [Character: RemoteDesktopKeyStroke], paste: CGKeyCode? = 9) -> RemoteDesktopKeyMapResolver.Snapshot {
        RemoteDesktopKeyMapResolver.Snapshot(typable: map, pasteKeyCode: paste)
    }

    static func main() {
        precondition(Thread.isMainThread)
        let name = Notification.Name("FluidVoice.RemoteLayoutCacheTest.\(UUID().uuidString)")
        var resolved = snap(["v": stroke(9)])
        var lookups = 0
        let cache = KeyboardLayoutSnapshotCache(
            initialValue: RemoteDesktopKeyMapResolver.Snapshot(),
            notificationName: name
        ) {
            precondition(Thread.isMainThread, "the layout must only ever be resolved on the main thread")
            lookups += 1
            return resolved
        }

        // Fails closed before start(): an unstarted cache must not claim the layout agrees.
        precondition(cache.snapshot().typable.isEmpty, "an unstarted cache must offer nothing")
        precondition(cache.snapshot().pasteKeyCode == nil, "an unstarted cache must not offer a paste position")
        precondition(lookups == 0, "snapshot() must not resolve")

        cache.start()
        cache.start()
        precondition(lookups == 1, "Startup must resolve exactly once")
        precondition(cache.snapshot().typable["v"] == stroke(9))

        // The typing path reads this per dictation, on a background queue, and must never
        // resolve the layout from there - that is the call that trapped inside HIToolbox.
        let group = DispatchGroup()
        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                precondition(!Thread.isMainThread)
                precondition(cache.snapshot().typable["v"] == stroke(9))
                group.leave()
            }
        }
        precondition(group.wait(timeout: .now() + 10) == .success, "background readers must not block")
        precondition(lookups == 1, "Typing must not query the layout")

        // Unrelated notifications must not refresh.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("FluidVoice.UnrelatedTest.\(UUID().uuidString)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(lookups == 1, "Unrelated notifications must not refresh the cache")

        func notifyAndWait(for map: RemoteDesktopKeyMapResolver.Snapshot, label: String) {
            resolved = map
            DistributedNotificationCenter.default().postNotificationName(
                name, object: nil, userInfo: nil, deliverImmediately: true
            )
            let deadline = Date().addingTimeInterval(2)
            while cache.snapshot() != map, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            precondition(cache.snapshot() == map, "layout change must update the snapshot (\(label))")
        }

        // A layout switch narrows the agreed set; switching back restores it.
        notifyAndWait(for: snap(["1": stroke(18)], paste: RemoteDesktopKeyMapResolver.ansiPasteKeyCode), label: "non-Latin layout")
        notifyAndWait(for: snap(["v": stroke(9)]), label: "back to Latin")
        // Fail closed: an unreadable layout must empty the snapshot, not leave it stale.
        notifyAndWait(for: snap([:], paste: nil), label: "unreadable layout")
        print("PASS remote-desktop layout cache: resolves on main only, \(lookups) lookups")

        // The agreement filter itself stays pure and testable without touching Carbon.
        precondition(RemoteDesktopKeyMapResolver.layoutSafeMap(local: [:]).isEmpty,
                     "no local layout means no agreement")
        guard let ansiV = RemoteDesktopKeyMapResolver.ansiKeyMap["v"] else {
            fatalError("the ANSI table must define a position for v")
        }
        precondition(RemoteDesktopKeyMapResolver.layoutSafeMap(local: ["v": ansiV])["v"] == ansiV,
                     "an agreeing position survives the filter")
        precondition(RemoteDesktopKeyMapResolver.layoutSafeMap(local: ["v": stroke(47)])["v"] == nil,
                     "a disagreeing position is dropped")
        print("PASS layoutSafeMap(local:) agreement filter")
    }
}
