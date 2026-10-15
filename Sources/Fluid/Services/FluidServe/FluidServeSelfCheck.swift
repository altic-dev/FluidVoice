import Foundation

/// Runs the bundled `fv-serve` for real and reports what it says, so the settings page can show
/// proof that the command works instead of only that a file was written.
nonisolated enum FluidServeSelfCheck {
    enum Outcome: Equatable, Sendable {
        case working(meetings: Int)
        case accessOff
        case failed(String)
    }

    /// Blocking and bounded: call it from a plain dispatch queue, never from the main thread or a Swift
    /// concurrency thread. `fv-serve status` decodes every saved meeting, so a large library takes a while.
    static func run(tool: URL, timeout: TimeInterval = 10) -> Outcome {
        let process = Process()
        let output = Pipe()
        process.executableURL = tool
        process.arguments = ["status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failed("The meeting reader could not start: \(error.localizedDescription)")
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failed("The meeting reader did not answer in time.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            return .failed("The meeting reader stopped with code \(process.terminationStatus).")
        }
        return self.outcome(fromStatusJSON: data)
    }

    static func outcome(fromStatusJSON data: Data) -> Outcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access"] as? Bool,
              let meetings = object["meetings"] as? Int
        else { return .failed("The meeting reader gave an answer FluidVoice could not read.") }
        return access ? .working(meetings: meetings) : .accessOff
    }
}
