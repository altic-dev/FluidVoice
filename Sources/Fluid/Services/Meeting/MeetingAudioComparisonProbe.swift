@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Local investigation tool. Diagnostic PCM never enters session history,
/// playback, captions, echo decisions or final transcription. Disabled unless explicitly armed.
final nonisolated class MeetingAudioComparisonProbe: @unchecked Sendable {
    static let nextRecordingKey = "MeetingAudioComparisonProbeNextRecording"
    static let requestExpirationKey = "MeetingAudioComparisonProbeExpiresAt"
    static let requestLifetime: TimeInterval = 30 * 60
    static let maximumSeconds: TimeInterval = 300

    enum Stage: String, CaseIterable, Codable, Sendable {
        case browser
        case microphoneInput = "microphone-before-aec"
        case microphoneOutput = "microphone-after-aec"
        case microphoneRecognizerInput = "microphone-recognizer-input"
        case browserRecognizerInput = "browser-recognizer-input"
    }

    private struct Context: Encodable {
        let sessionID: UUID
        let mode: MeetingCaptureMode
        let microphone: MeetingMicrophoneIdentity
        let application: MeetingApplicationIdentity?
        let operatingSystem: String
        let appVersion: String
        let appBuild: String
    }

    private struct Report: Encodable {
        let context: Context
        let schemaVersion = 1
        let purpose = "Compare capture input with the microphone audio saved by FluidMeet. Input is already subject to any macOS or device processing."
        let maximumSeconds: TimeInterval
        let completed: Bool
        let hasAllStages: Bool
        let tracks: [String: MeetingAudioTrack]
        let droppedDiagnosticEvents: Int
    }

    private struct Event: Encodable {
        let uptime: TimeInterval
        let step: String
        let track: String?
        let pts: Double?
        let text: String?
        let detail: String?
    }

    let directory: URL
    private let context: Context
    private let eventQueue = DispatchQueue(label: "com.fluidvoice.meeting.audio-comparison.events", qos: .utility)
    private let eventSlots = DispatchSemaphore(value: 128)
    private let eventFile: FileHandle
    private var droppedDiagnosticEvents = 0
    private var deadlineTimer: DispatchSourceTimer?
    private let writers: [Stage: MeetingAudioChunkWriter]
    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private let deadline: TimeInterval
    private let durationLimit: TimeInterval
    private var accepting = true
    private var finalization: Task<Void, Never>?
    private let onUsefulComparison: @Sendable () -> Void

    var isRecordingDiagnostics: Bool {
        self.lock.withLock { self.accepting && self.uptime() < self.deadline }
    }

    /// Short attempts and in-room recordings must not consume an online audio comparison.
    /// Expiry bounds the request even if no usable recording is made.
    static func requestExpiration(mode: MeetingCaptureMode, defaults: UserDefaults = .standard, now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> TimeInterval? {
        guard defaults.bool(forKey: self.nextRecordingKey) else { return nil }
        var expiration = defaults.double(forKey: self.requestExpirationKey)
        if expiration == 0 {
            expiration = now + self.requestLifetime
            defaults.set(expiration, forKey: self.requestExpirationKey)
        }
        guard expiration.isFinite, expiration > now else {
            defaults.removeObject(forKey: self.nextRecordingKey)
            defaults.removeObject(forKey: self.requestExpirationKey)
            return nil
        }
        return mode == .onlineCall ? expiration : nil
    }

    static func completeRequest(expiration: TimeInterval, defaults: UserDefaults = .standard) {
        // A previous probe finishing must not clear a newly armed request.
        guard defaults.double(forKey: self.requestExpirationKey) == expiration else { return }
        defaults.removeObject(forKey: self.nextRecordingKey)
        defaults.removeObject(forKey: self.requestExpirationKey)
    }

    init(
        session: MeetingSession,
        directory: URL,
        maximumSeconds: TimeInterval = MeetingAudioComparisonProbe.maximumSeconds,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onUsefulComparison: @escaping @Sendable () -> Void = {}
    ) throws {
        self.directory = directory
        self.onUsefulComparison = onUsefulComparison
        self.context = Context(
            sessionID: session.id,
            mode: session.mode,
            microphone: session.selectedMicrophone,
            application: session.capturedApplication,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.uptime = uptime
        self.durationLimit = min(Self.maximumSeconds, max(0, maximumSeconds))
        self.deadline = uptime() + self.durationLimit
        var writers: [Stage: MeetingAudioChunkWriter] = [:]
        for stage in Stage.allCases {
            let track = MeetingAudioTrack(
                id: UUID(),
                kind: stage == .browser || stage == .browserRecognizerInput ? .applicationAudio : .microphone,
                sourceIdentifier: stage.rawValue,
                sourceDisplayName: stage.rawValue,
                format: nil,
                timebase: session.timebase,
                health: .waiting,
                chunks: []
            )
            writers[stage] = try MeetingAudioChunkWriter(
                track: track,
                sessionDirectory: directory.appendingPathComponent(stage.rawValue, isDirectory: true),
                chunkDuration: 60,
                eventHandler: { _ in },
                pendingSlotLimit: 32
            )
        }
        self.writers = writers
        let eventURL = directory.appendingPathComponent("events.jsonl")
        try Data().write(to: eventURL)
        self.eventFile = try FileHandle(forWritingTo: eventURL)
        try Self.write(Report(context: self.context, maximumSeconds: min(Self.maximumSeconds, max(0, maximumSeconds)), completed: false, hasAllStages: false, tracks: [:], droppedDiagnosticEvents: 0), to: directory)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + self.durationLimit)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.stop() }
        }
        self.deadlineTimer = timer
        timer.resume()
    }

    func recordAECFrame(_ frame: MeetingAECJoinedFrame, output: [Float], statistics: MeetingAECBridgeStatistics) {
        guard self.isRecordingDiagnostics else { return }
        func rms(_ samples: [Float]) -> Double {
            guard !samples.isEmpty else { return 0 }
            return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        }
        let delay = statistics.estimatedDelayMilliseconds.map { String($0) } ?? "unknown"
        let residual = statistics.residualEchoLikelihood.map { String($0) } ?? "unknown"
        let detail = "renderRMS=\(rms(frame.render.samples)) captureRMS=\(rms(frame.capture.samples)) outputRMS=\(rms(output)) "
            + "clockAttested=\(frame.clockAttested) pairedFrames=\(frame.pairedFrameCount) "
            + "estimatedDelayMs=\(delay) residualEcho=\(residual) resets=\(statistics.resets)"
        self.recordEvent("aec-frame", track: .microphone, pts: frame.capture.presentationTime.seconds, detail: detail)
    }

    /// Small, bounded asynchronous event log, including pre-filter text only for this explicit test.
    func recordEvent(_ step: String, track: MeetingAudioTrackKind? = nil, pts: Double? = nil, text: String? = nil, detail: String? = nil) {
        self.lock.lock()
        guard self.accepting, self.uptime() < self.deadline else { self.lock.unlock(); return }
        guard self.eventSlots.wait(timeout: .now()) == .success else {
            self.droppedDiagnosticEvents += 1
            self.lock.unlock()
            return
        }
        let event = Event(
            uptime: self.uptime(),
            step: step,
            track: track?.rawValue,
            pts: pts?.isFinite == true ? pts : nil,
            text: text.map { String($0.prefix(8192)) },
            detail: detail.map { String($0.prefix(2048)) }
        )
        self.eventQueue.async { [self] in
            defer { self.eventSlots.signal() }
            do {
                var data = try JSONEncoder().encode(event)
                data.append(0x0a)
                try self.eventFile.write(contentsOf: data)
            } catch {
                self.lock.withLock { self.droppedDiagnosticEvents += 1 }
            }
        }
        self.lock.unlock()
    }

    /// Capture is already stopped. Allow pending caption callbacks to be recorded without delaying
    /// normal Stop or holding capture hardware, then close all diagnostic files.
    func finishAfterCaptionTeardown() {
        self.recordEvent("capture-stopped")
        Task { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self.stop()
        }
    }

    /// A bounded enqueue only. Disk work stays on independent writer queues; saturation is
    /// reported in the probe's track health rather than blocking or changing normal capture.
    func offer(_ sample: CMSampleBuffer, stage: Stage, producerEpoch: UInt64 = 0) {
        let expired = self.lock.withLock { () -> Bool? in
            guard self.accepting else { return nil }
            if self.uptime() >= self.deadline {
                self.accepting = false
                return true
            }
            self.writers[stage]?.enqueue(sample, producerEpoch: producerEpoch)
            return false
        }
        if expired == true { Task { await self.stop() } }
    }

    func stop() async {
        let task = self.lock.withLock { () -> Task<Void, Never> in
            if let finalization = self.finalization { return finalization }
            self.accepting = false
            self.deadlineTimer?.cancel()
            self.deadlineTimer = nil
            let task = Task { [self] in
                var tracks: [String: MeetingAudioTrack] = [:]
                for stage in Stage.allCases {
                    if let writer = self.writers[stage] { tracks[stage.rawValue] = await writer.stop() }
                }
                await withCheckedContinuation { continuation in
                    self.eventQueue.async { [self] in
                        try? self.eventFile.synchronize()
                        try? self.eventFile.close()
                        continuation.resume()
                    }
                }
                do {
                    let hasAllStages = Stage.allCases.allSatisfy { stage in
                        tracks[stage.rawValue]?.chunks.contains(where: { $0.finalizationState == .finalized }) == true
                    }
                    let report = Report(
                        context: self.context,
                        maximumSeconds: self.durationLimit,
                        completed: true,
                        hasAllStages: hasAllStages,
                        tracks: tracks,
                        droppedDiagnosticEvents: self.lock.withLock { self.droppedDiagnosticEvents }
                    )
                    try Self.write(report, to: self.directory)
                    if hasAllStages, Self.hasUsefulComparison(tracks) { self.onUsefulComparison() }
                } catch {
                    DebugLogger.shared.warning("Audio comparison probe report could not be saved: \(error)", source: "MeetingAudioComparisonProbe")
                }
            }
            self.finalization = task
            return task
        }
        await task.value
    }

    static func hasUsefulComparison(_ tracks: [String: MeetingAudioTrack]) -> Bool {
        Stage.allCases.allSatisfy { stage in
            guard let track = tracks[stage.rawValue], track.health.droppedSampleCount == 0 else { return false }
            let seconds = track.chunks.reduce(0.0) { total, chunk in
                guard chunk.finalizationState == .finalized,
                      let asset = chunk.captureAnalysisAsset,
                      let frames = asset.frameCount,
                      let rate = asset.sampleRate, rate > 0 else { return total }
                return total + Double(frames) / rate
            }
            return seconds >= 30
        }
    }

    private static func write(_ report: Report, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("comparison.json"), options: .atomic)
    }
}
