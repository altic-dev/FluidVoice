import AppKit

private func record(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

@MainActor
private final class TerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if CommandLine.arguments.contains("--original") {
                NSApp.terminate(nil)
            } else {
                UpdateTerminationScheduler.requestTermination()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("termination-requested")
        // Match the real delegate's asynchronous history-save path. Even an immediately
        // ready save cannot execute while terminate occupies the main dispatch queue.
        Task { @MainActor in
            await Task.yield()
            record("history-save-completed")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        record("termination-completed")
    }
}

@main
private enum UpdaterTerminationBoundaryTests {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = TerminationDelegate()
        application.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            record("termination-stuck")
            exit(2)
        }
        withExtendedLifetime(delegate) { application.run() }
    }
}
