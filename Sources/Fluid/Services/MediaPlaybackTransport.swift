import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

nonisolated struct MediaPlaybackSnapshot: Equatable, Sendable {
    let bundleIdentifier: String
    let processID: Int32
    let title: String?
    let isPlaying: Bool?

    // Safari exposes its WebKit media process, not a tab ID. This comparison
    // can reject a changed player/item, but cannot prove exact-tab identity.
    func matches(_ other: Self) -> Bool {
        self.bundleIdentifier == other.bundleIdentifier &&
            self.processID == other.processID && self.title == other.title
    }
}

nonisolated enum MediaPlaybackQueryResult: Sendable {
    case snapshot(MediaPlaybackSnapshot)
    case unavailable(String)
}

nonisolated enum MediaPlaybackCommand: String, Sendable {
    case pause
    case play
}

nonisolated enum MediaPlaybackCommandResult: Sendable {
    /// The helper exited successfully. This is NOT acknowledgement from the player.
    case helperCompleted
    case failed(String)
}

nonisolated protocol MediaPlaybackTransport: Sendable {
    nonisolated func query() async -> MediaPlaybackQueryResult
    nonisolated func send(_ command: MediaPlaybackCommand) async -> MediaPlaybackCommandResult
}

/// Uses the existing bundled bridge, but owns its process completion and output.
/// A serial queue plus a hard process deadline prevents overlapping commands,
/// unbounded helpers, and the adapter's exit-versus-output callback race.
final nonisolated class MediaPlaybackProcessTransport: MediaPlaybackTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "media.playback.transport", qos: .utility)

    func query() async -> MediaPlaybackQueryResult {
        let result = await self.invoke("get")
        guard result.failure == nil else { return .unavailable(result.failure ?? "helper_failed") }
        return Self.decode(result.output)
    }

    func send(_ command: MediaPlaybackCommand) async -> MediaPlaybackCommandResult {
        let result = await self.invoke(command.rawValue)
        if let failure = result.failure { return .failed(failure) }
        return .helperCompleted
    }

    static func decode(_ output: Data) -> MediaPlaybackQueryResult {
        guard let text = String(data: output, encoding: .utf8) else {
            return .unavailable("invalid_utf8")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable("empty_output") }
        guard trimmed != "NIL", trimmed != "null" else { return .unavailable("no_media_reported") }
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return .unavailable("invalid_payload") }
        let processID: Int32?
        if let value = payload["PID"] as? String {
            processID = Int32(value)
        } else {
            processID = (payload["PID"] as? NSNumber)?.int32Value
        }
        guard let bundle = payload["bundleIdentifier"] as? String, !bundle.isEmpty,
              let processID, processID > 0
        else { return .unavailable("missing_player_identity") }
        let playing: Bool?
        if let value = payload["isPlaying"] as? Bool {
            playing = value
        } else if let rate = payload["playbackRate"] as? Double {
            playing = rate > 0
        } else {
            playing = nil
        }
        return .snapshot(MediaPlaybackSnapshot(
            bundleIdentifier: bundle,
            processID: processID,
            title: payload["title"] as? String,
            isPlaying: playing
        ))
    }

    private func invoke(_ command: String) async -> MediaHelperResult {
        await withCheckedContinuation { continuation in
            self.queue.async {
                continuation.resume(returning: self.run(command))
            }
        }
    }

    private func run(_ command: String) -> MediaHelperResult {
        #if arch(arm64)
        let framework = Bundle(for: MediaController.self)
        guard let library = framework.executablePath,
              let resourceURL = Bundle.main.url(
                  forResource: "MediaRemoteAdapter_MediaRemoteAdapter", withExtension: "bundle"
              ),
              let resources = Bundle(url: resourceURL),
              let script = resources.path(forResource: "run", ofType: "pl")
        else { return MediaHelperResult(output: Data(), failure: "bridge_resources_missing") }

        // Run the shipped script unchanged. For commands, keep its run loop alive
        // through one bounded query before exiting, as the original upstream does.
        // The returned state is not used as command acknowledgement.
        let wrapper = """
        my $script = shift @ARGV;
        my $command = $ARGV[1];
        do $script;
        die $@ if $@;
        main::get() if $command eq 'pause' || $command eq 'play';
        """
        return MediaHelperProcess.run(arguments: ["-e", wrapper, script, library, command])
        #else
        return MediaHelperResult(output: Data(), failure: "unsupported_architecture")
        #endif
    }
}

nonisolated struct MediaHelperResult: Sendable {
    let output: Data
    let failure: String?
}

/// Private process plumbing; never runs on the main actor.
nonisolated enum MediaHelperProcess {
    static func run(arguments: [String], timeout: TimeInterval = 1.0) -> MediaHelperResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        let outputBuffer = MediaHelperBuffer(limit: 4 * 1024 * 1024)
        let errorBuffer = MediaHelperBuffer(limit: 4096)
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in outputBuffer.drain(handle) }
        errors.fileHandleForReading.readabilityHandler = { handle in errorBuffer.drain(handle) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        do {
            try process.run()
        } catch {
            return MediaHelperResult(output: Data(), failure: "launch_failed:\(error.localizedDescription)")
        }
        let deadline = MediaHelperDeadline(process: process)
        let timeoutWork = DispatchWorkItem { deadline.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        process.waitUntilExit()
        let timedOut = deadline.finish()
        timeoutWork.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let data = outputBuffer.finish(output.fileHandleForReading)
        let stderr = errorBuffer.finish(errors.fileHandleForReading)
        if timedOut { return MediaHelperResult(output: data, failure: "helper_timeout") }
        if process.terminationStatus != 0 {
            let message = (String(bytes: stderr.prefix(512), encoding: .utf8) ?? "invalid_utf8")
                .replacingOccurrences(of: "\n", with: " ")
            return MediaHelperResult(output: data, failure: "helper_exit_\(process.terminationStatus):\(message)")
        }
        if outputBuffer.overflowed { return MediaHelperResult(output: Data(), failure: "output_limit") }
        return MediaHelperResult(output: data, failure: nil)
    }
}

private final nonisolated class MediaHelperDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var finished = false
    private var expired = false

    init(process: Process) { self.process = process }

    func expire() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.finished, self.process.isRunning else { return }
        self.expired = true
        // This is our own one-shot Perl child, with no user state to flush.
        kill(self.process.processIdentifier, SIGKILL)
    }

    func finish() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.finished = true
        return self.expired
    }
}

private final nonisolated class MediaHelperBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var didOverflow = false

    init(limit: Int) { self.limit = limit }

    var overflowed: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.didOverflow
    }

    func drain(_ handle: FileHandle) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil }
        self.append(chunk)
    }

    func finish(_ handle: FileHandle) -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
            self.append(chunk)
        }
        return self.data
    }

    private func append(_ chunk: Data) {
        let remaining = self.limit - self.data.count
        if chunk.count > remaining { self.didOverflow = true }
        self.data.append(chunk.prefix(remaining))
    }
}
