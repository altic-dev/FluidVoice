import AppKit

@MainActor
enum UpdateTerminationScheduler {
    static func requestTermination() {
        // AppKit may synchronously pump its termination run loop for .terminateLater.
        // Calling terminate from a main-queue block keeps that serial queue occupied,
        // preventing applicationShouldTerminate's MainActor history-save task from running.
        // A run-loop callback leaves the main dispatch queue available for that task.
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }
}
