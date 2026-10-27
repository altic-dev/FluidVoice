import Foundation

private actor Recorder {
    private(set) var unloads = 0
    var delayMs: Int? = 60
    var busy = false
    func noteUnload() { self.unloads += 1 }
    func set(delayMs: Int?) { self.delayMs = delayMs }
    func set(busy: Bool) { self.busy = busy }
}

private func makeUnloader(_ recorder: Recorder) -> PrivateAIIdleUnloader {
    PrivateAIIdleUnloader(
        delay: { await recorder.delayMs.map { .milliseconds($0) } },
        isBusy: { await recorder.busy },
        unload: { await recorder.noteUnload() }
    )
}

private func pause(_ ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

private func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
    print("ok: \(message)")
}

@main
enum PrivateAIIdleUnloaderTests {
    static func main() async {
        do {
            let recorder = Recorder()
            let unloader = makeUnloader(recorder)
            await unloader.tracking {}
            await pause(250)
            let unloads = await recorder.unloads
            expect(unloads == 1, "unloads once after the quiet period")
        }
        do {
            let recorder = Recorder()
            await recorder.set(delayMs: 150)
            let unloader = makeUnloader(recorder)
            for _ in 0..<4 {
                await unloader.tracking {}
                await pause(60)
            }
            var unloads = await recorder.unloads
            expect(unloads == 0, "activity keeps restarting the countdown")
            await pause(400)
            unloads = await recorder.unloads
            expect(unloads == 1, "unloads after activity stops")
        }
        do {
            let recorder = Recorder()
            let unloader = makeUnloader(recorder)
            await unloader.begin()
            await pause(250)
            var unloads = await recorder.unloads
            expect(unloads == 0, "never unloads while a request is in flight")
            await unloader.end()
            await pause(250)
            unloads = await recorder.unloads
            expect(unloads == 1, "unloads once the request finishes")
        }
        do {
            let recorder = Recorder()
            let unloader = makeUnloader(recorder)
            await unloader.begin()
            await unloader.tracking {}
            await pause(250)
            let unloads = await recorder.unloads
            expect(unloads == 0, "overlapping requests hold the model until the last ends")
            await unloader.end()
        }
        do {
            let recorder = Recorder()
            await recorder.set(delayMs: nil)
            let unloader = makeUnloader(recorder)
            await unloader.tracking {}
            await pause(250)
            var unloads = await recorder.unloads
            expect(unloads == 0, "does nothing when set to never")
            await recorder.set(delayMs: 60)
            await unloader.settingsChanged()
            await pause(250)
            unloads = await recorder.unloads
            expect(unloads == 1, "picking a period starts the countdown without new activity")
        }
        do {
            let recorder = Recorder()
            await recorder.set(busy: true)
            let unloader = makeUnloader(recorder)
            await unloader.tracking {}
            await pause(250)
            var unloads = await recorder.unloads
            expect(unloads == 0, "waits while a recording is in progress")
            await recorder.set(busy: false)
            await pause(250)
            unloads = await recorder.unloads
            expect(unloads == 1, "unloads after the recording ends")
        }
        do {
            struct Boom: Error {}
            let recorder = Recorder()
            let unloader = makeUnloader(recorder)
            do { try await unloader.tracking { throw Boom() } } catch {}
            await pause(250)
            let unloads = await recorder.unloads
            expect(unloads == 1, "a failed request still releases its hold")
        }
        print("PrivateAIIdleUnloaderTests passed")
    }
}
