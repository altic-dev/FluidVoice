#if DEBUG

    import CoreAudio
    import CoreGraphics
    import CryptoKit
    import Foundation

    /// Ephemeral DEBUG-only feasibility probe for CoreAudio process-tap meeting detection.
    /// Runs at most once per process when FLUIDVOICE_MEETING_PROBE_DURATION_SECONDS is 5...300.
    /// Writes a closed-schema JSONL file to the temp dir; emits no raw IDs, names, paths, or errors.
    nonisolated enum MeetingDetectorFeasibilityProbe {
        private static let gate = ProbeOnceGate()

        static func startIfRequested() {
            guard let raw = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_PROBE_DURATION_SECONDS"],
                  let duration = Int(raw),
                  ProbeLimits.validDurations.contains(duration)
            else { return }
            guard gate.checkAndSet() else { return }
            ProbeSession(durationSeconds: duration).start()
        }
    }

    private nonisolated enum ProbeLimits {
        static let validDurations = 5 ... 300
        static let maxObjectCount = 4096
        static let maxBufferCount = 4096
        static let maxStreamConfigBytes = 65_536
        static let tokenDigestBytes = 16
        static let saltBytes = 16
    }

    private nonisolated enum ProbeEvent: String, Codable, Sendable {
        case start
        case sample
        case terminal
    }

    private nonisolated enum TerminalReason: String, Codable, Sendable {
        case completed
        case deadlineExceeded
        case cancelled
        case encodingFailure
        case writeFailure
        case validationFailure
        case setupFailure
    }

    private nonisolated enum ProbeNote: String, Codable, Sendable {
        case tempMayBePurged
    }

    private nonisolated enum ProbeReadStatus: String, Codable, Sendable {
        case ok
        case readError
        case unsupported
        case invalidLayout
    }

    private nonisolated enum ProbeStreamState: String, Codable, Sendable {
        case active
        case inactive
        case readError
        case unsupported
    }

    private nonisolated enum ProbeRunningState: String, Codable, Sendable {
        case running
        case notRunning
        case readError
        case unsupported
    }

    private nonisolated enum ProbeFamily: String, Codable, Sendable {
        case zoom
        case teams
        case webex
        case selfProcess
        case other
    }

    private nonisolated enum ProbeTransport: String, Codable, Sendable {
        case builtIn
        case bluetooth
        case usb
        case virtual
        case aggregate
        case other
        case unknown
    }

    private nonisolated struct ProbeStartLine: Codable, Sendable {
        var schemaVersion: Int
        var event: ProbeEvent
        var durationSeconds: Int
        var note: ProbeNote
    }

    private nonisolated struct ProbeTerminalLine: Codable, Sendable {
        var schemaVersion: Int
        var event: ProbeEvent
        var monotonicOffsetMs: Int
        var reason: TerminalReason
        var recordCount: Int
    }

    private nonisolated struct ProbeSampleLine: Codable, Sendable {
        var schemaVersion: Int
        var event: ProbeEvent
        var monotonicOffsetMs: Int
        var processListStatus: ProbeReadStatus
        var processCount: Int
        var deviceListStatus: ProbeReadStatus
        var deviceCount: Int
        var hardwareDeviceCount: Int
        var classificationFailureCount: Int
        var windowListSuccess: Bool
        var windowListCount: Int
        var windowListLatencyMs: Int
        var processes: [ProcessEntry]
        var devices: [DeviceEntry]
    }

    private nonisolated struct ProcessEntry: Codable, Sendable {
        var family: ProbeFamily
        var input: ProbeStreamState
        var output: ProbeStreamState
    }

    private nonisolated struct DeviceEntry: Codable, Sendable {
        var token: String?
        var inputChannels: Int
        var streamStatus: ProbeReadStatus
        var transport: ProbeTransport
        var running: ProbeRunningState
    }

    /// NSLock-guarded one-run check-and-set; the only Swift 6 Sendable escape hatch this file needs.
    private final nonisolated class ProbeOnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasRun = false

        func checkAndSet() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if hasRun { return false }
            hasRun = true
            return true
        }
    }

    private nonisolated enum AudioListReadResult {
        case ok([AudioObjectID])
        case readError
        case unsupported
        case invalidLayout
    }

    private final nonisolated class ProbeSession: @unchecked Sendable {
        private let durationSeconds: Int
        private let baseInstant = ContinuousClock.now
        private let salt: [UInt8]
        private let samplingQueue = DispatchQueue(label: "com.fluidvoice.meetingprobe.sampling", qos: .utility)
        // Sole owner of encoder, fileHandle, deadlineTimer, terminalReason, recordCount, outputPath, sampleInFlight.
        private let controlQueue = DispatchQueue(label: "com.fluidvoice.meetingprobe.control")

        private let encoder = JSONEncoder()
        private var fileHandle: FileHandle?
        private var deadlineTimer: DispatchSourceTimer?
        private var terminalReason: TerminalReason?
        private var recordCount = 0
        private var outputPath = ""
        private var sampleInFlight = false

        private var deadlineMs: Int { durationSeconds * 1000 }

        init(durationSeconds: Int) {
            self.durationSeconds = durationSeconds
            var generator = SystemRandomNumberGenerator()
            self.salt = (0 ..< ProbeLimits.saltBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }

        func start() {
            controlQueue.async { self.setup() }
        }

        func cancel() {
            controlQueue.async { self.finalize(.cancelled) }
        }

        // MARK: - Control queue

        private func setup() {
            guard terminalReason == nil else { return }
            guard Self.validateSchema() else {
                finalize(.validationFailure)
                return
            }

            let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL
            let candidate = tempDir.appendingPathComponent("fluidvoice-meeting-probe-\(UUID().uuidString).jsonl").standardizedFileURL
            guard candidate.path.hasPrefix(tempDir.path + "/") else {
                finalize(.setupFailure)
                return
            }
            guard FileManager.default.createFile(
                atPath: candidate.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                finalize(.setupFailure)
                return
            }
            outputPath = candidate.path
            do {
                fileHandle = try FileHandle(forWritingTo: candidate)
            } catch {
                try? FileManager.default.removeItem(at: candidate)
                outputPath = ""
                finalize(.setupFailure)
                return
            }

            let startLine = ProbeStartLine(
                schemaVersion: 1,
                event: .start,
                durationSeconds: durationSeconds,
                note: .tempMayBePurged
            )
            guard writeLine(startLine) else { return }

            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now() + .seconds(durationSeconds))
            timer.setEventHandler { [self] in
                finalize(sampleInFlight ? .deadlineExceeded : .completed)
            }
            deadlineTimer = timer
            timer.resume()

            scheduleTick(after: 0)
        }

        private func scheduleTick(after seconds: Int) {
            sampleInFlight = true
            samplingQueue.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
                let snapshot = captureSnapshot()
                controlQueue.async { [self] in
                    sampleInFlight = false
                    guard terminalReason == nil else { return }
                    guard Self.milliseconds(from: baseInstant) < deadlineMs else {
                        finalize(.deadlineExceeded)
                        return
                    }
                    guard writeLine(snapshot) else { return }
                    if Self.milliseconds(from: baseInstant) + 1000 < deadlineMs {
                        scheduleTick(after: 1)
                    }
                }
            }
        }

        private func writeLine(_ line: some Codable) -> Bool {
            guard let handle = fileHandle else {
                finalize(.setupFailure)
                return false
            }
            let payload: Data
            do {
                payload = try encoder.encode(line)
            } catch {
                finalize(.encodingFailure)
                return false
            }
            var framed = payload
            framed.append(0x0A)
            do {
                try handle.write(contentsOf: framed)
            } catch {
                finalize(.writeFailure)
                return false
            }
            recordCount += 1
            return true
        }

        private func finalize(_ reason: TerminalReason) {
            guard terminalReason == nil else { return }
            terminalReason = reason
            deadlineTimer?.cancel()
            deadlineTimer = nil
            var outcome = reason
            if let handle = fileHandle {
                let terminal = ProbeTerminalLine(
                    schemaVersion: 1,
                    event: .terminal,
                    monotonicOffsetMs: Self.milliseconds(from: baseInstant),
                    reason: reason,
                    recordCount: recordCount
                )
                do {
                    var framed = try encoder.encode(terminal)
                    framed.append(0x0A)
                    try handle.write(contentsOf: framed)
                } catch is EncodingError {
                    outcome = .encodingFailure
                } catch {
                    outcome = .writeFailure
                }
                try? handle.close()
                fileHandle = nil
            }
            terminalReason = outcome
            let message = "terminal=\(outcome.rawValue) records=\(recordCount) output=\(outputPath)"
            DispatchQueue.main.async {
                DebugLogger.shared.info(message, source: "MeetingProbe")
            }
        }

        // MARK: - Sampling queue

        private func captureSnapshot() -> ProbeSampleLine {
            var processes: [ProcessEntry] = []
            let processListStatus: ProbeReadStatus
            var processCount = 0
            switch readAudioObjectIDList(kAudioHardwarePropertyProcessObjectList) {
            case let .ok(ids):
                processListStatus = .ok
                processCount = ids.count
                for id in ids {
                    let family = Self.meetingFamily(for: readProcessBundleID(id))
                    guard family != .other else { continue }
                    processes.append(ProcessEntry(
                        family: family,
                        input: readProcessRunning(id, selector: kAudioProcessPropertyIsRunningInput),
                        output: readProcessRunning(id, selector: kAudioProcessPropertyIsRunningOutput)
                    ))
                }
            case .readError: processListStatus = .readError
            case .unsupported: processListStatus = .unsupported
            case .invalidLayout: processListStatus = .invalidLayout
            }

            var devices: [DeviceEntry] = []
            let deviceListStatus: ProbeReadStatus
            var hardwareDeviceCount = 0
            var classificationFailureCount = 0
            switch readAudioObjectIDList(kAudioHardwarePropertyDevices) {
            case let .ok(ids):
                deviceListStatus = .ok
                hardwareDeviceCount = ids.count
                for id in ids {
                    let stream = readInputChannels(id)
                    guard stream.status == .ok else {
                        classificationFailureCount += 1
                        continue
                    }
                    guard stream.channels > 0 else { continue }
                    devices.append(DeviceEntry(
                        token: readDeviceUID(id).map(saltedToken(for:)),
                        inputChannels: stream.channels,
                        streamStatus: stream.status,
                        transport: readTransport(id),
                        running: readRunningSomewhere(id)
                    ))
                }
            case .readError: deviceListStatus = .readError
            case .unsupported: deviceListStatus = .unsupported
            case .invalidLayout: deviceListStatus = .invalidLayout
            }

            let window = captureWindowList()
            return ProbeSampleLine(
                schemaVersion: 1,
                event: .sample,
                monotonicOffsetMs: Self.milliseconds(from: baseInstant),
                processListStatus: processListStatus,
                processCount: processCount,
                deviceListStatus: deviceListStatus,
                deviceCount: devices.count,
                hardwareDeviceCount: hardwareDeviceCount,
                classificationFailureCount: classificationFailureCount,
                windowListSuccess: window.success,
                windowListCount: window.count,
                windowListLatencyMs: window.latencyMs,
                processes: processes,
                devices: devices
            )
        }

        private static let selfBundleID: String? = Bundle.main.bundleIdentifier

        private static func meetingFamily(for bundleID: String?) -> ProbeFamily {
            if let selfBundleID, bundleID == selfBundleID { return .selfProcess }
            switch bundleID {
            case "us.zoom.xos", "us.zoom.caphost": return .zoom
            case "com.microsoft.teams2", "com.microsoft.teams": return .teams
            case "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark": return .webex
            default: return .other
            }
        }

        private func saltedToken(for uid: String) -> String {
            var hasher = SHA256()
            hasher.update(data: Data(salt))
            hasher.update(data: Data(uid.utf8))
            return hasher.finalize().prefix(ProbeLimits.tokenDigestBytes).map { String(format: "%02x", $0) }.joined()
        }

        private static func milliseconds(from instant: ContinuousClock.Instant) -> Int {
            Int((ContinuousClock.now - instant) / .milliseconds(1))
        }

        // MARK: - CoreAudio reads

        private func readAudioObjectIDList(_ selector: AudioObjectPropertySelector) -> AudioListReadResult {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let systemObject = AudioObjectID(kAudioObjectSystemObject)
            guard AudioObjectHasProperty(systemObject, &address) else { return .unsupported }
            let stride = MemoryLayout<AudioObjectID>.stride

            var lastWasChurn = false
            for _ in 0 ..< 2 {
                var size: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
                    lastWasChurn = false
                    continue
                }
                if size == 0 { return .ok([]) }
                guard size % UInt32(stride) == 0,
                      Int(size) / stride <= ProbeLimits.maxObjectCount
                else { return .invalidLayout }

                var dataSize = size
                var buffer = [UInt8](repeating: 0, count: Int(size))
                let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, base)
                }
                guard status == noErr else {
                    lastWasChurn = false
                    continue
                }
                guard dataSize <= size,
                      dataSize % UInt32(stride) == 0,
                      Int(dataSize) / stride <= ProbeLimits.maxObjectCount
                else {
                    lastWasChurn = true
                    continue
                }

                let count = Int(dataSize) / stride
                var result = [AudioObjectID](repeating: 0, count: count)
                buffer.withUnsafeBytes { raw in
                    result.withUnsafeMutableBytes { destination in
                        destination.copyBytes(from: raw.prefix(count * stride))
                    }
                }
                return .ok(result)
            }
            return lastWasChurn ? .invalidLayout : .readError
        }

        private func readProcessBundleID(_ objectID: AudioObjectID) -> String? {
            readStringProperty(objectID, selector: kAudioProcessPropertyBundleID)
        }

        private func readProcessRunning(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> ProbeStreamState {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { return .unsupported }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.stride)
            guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
                return .readError
            }
            return value != 0 ? .active : .inactive
        }

        private func readDeviceUID(_ objectID: AudioObjectID) -> String? {
            readStringProperty(objectID, selector: kAudioDevicePropertyDeviceUID)
        }

        private func readStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { return nil }
            // CoreAudio returns a +1 retained CFString; takeRetainedValue() transfers ownership.
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }

        private func readInputChannels(_ objectID: AudioObjectID) -> (channels: Int, status: ProbeReadStatus) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { return (0, .unsupported) }
            let headerOffset = MemoryLayout<AudioBufferList>.stride - MemoryLayout<AudioBuffer>.stride
            let bufferStride = MemoryLayout<AudioBuffer>.stride

            for _ in 0 ..< 2 {
                var size: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { continue }
                guard size > 0, size <= ProbeLimits.maxStreamConfigBytes else { return (0, .invalidLayout) }

                var dataSize = size
                var buffer = [UInt8](repeating: 0, count: Int(size))
                let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, base)
                }
                guard status == noErr else { continue }
                guard dataSize <= size else { continue }
                guard Int(dataSize) >= headerOffset else { return (0, .invalidLayout) }

                var parsed: Int?
                buffer.withUnsafeBytes { raw in
                    let byteCount = Int(dataSize)
                    let declared = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                    guard declared <= ProbeLimits.maxBufferCount,
                          headerOffset + declared * bufferStride <= byteCount
                    else { return }
                    var channels = 0
                    for index in 0 ..< declared {
                        let audioBuffer = raw.loadUnaligned(
                            fromByteOffset: headerOffset + index * bufferStride,
                            as: AudioBuffer.self
                        )
                        let (sum, overflow) = channels.addingReportingOverflow(Int(audioBuffer.mNumberChannels))
                        guard !overflow else { return }
                        channels = sum
                    }
                    parsed = channels
                }
                guard let channels = parsed else { return (0, .invalidLayout) }
                return (channels, .ok)
            }
            return (0, .readError)
        }

        private func readTransport(_ objectID: AudioObjectID) -> ProbeTransport {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { return .unknown }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.stride)
            guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
                return .unknown
            }
            switch value {
            case UInt32(kAudioDeviceTransportTypeBuiltIn): return .builtIn
            case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE): return .bluetooth
            case UInt32(kAudioDeviceTransportTypeUSB): return .usb
            case UInt32(kAudioDeviceTransportTypeVirtual): return .virtual
            case UInt32(kAudioDeviceTransportTypeAggregate): return .aggregate
            case UInt32(kAudioDeviceTransportTypeUnknown): return .unknown
            default: return .other
            }
        }

        private func readRunningSomewhere(_ objectID: AudioObjectID) -> ProbeRunningState {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { return .unsupported }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.stride)
            guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
                return .readError
            }
            return value != 0 ? .running : .notRunning
        }

        // MARK: - Window list

        private func captureWindowList() -> (success: Bool, count: Int, latencyMs: Int) {
            autoreleasepool {
                let started = ContinuousClock.now
                let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                let latencyMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                guard let list else { return (false, 0, latencyMs) }
                return (true, CFArrayGetCount(list), latencyMs)
            }
        }

        // MARK: - Schema validation

        private static let allowedStartKeys: Set<String> = ["schemaVersion", "event", "durationSeconds", "note"]
        private static let allowedSampleKeys: Set<String> = [
            "schemaVersion", "event", "monotonicOffsetMs",
            "processListStatus", "processCount", "deviceListStatus", "deviceCount",
            "hardwareDeviceCount", "classificationFailureCount",
            "windowListSuccess", "windowListCount", "windowListLatencyMs",
            "processes", "devices",
        ]
        private static let allowedTerminalKeys: Set<String> = ["schemaVersion", "event", "monotonicOffsetMs", "reason", "recordCount"]
        private static let allowedProcessKeys: Set<String> = ["family", "input", "output"]
        private static let allowedDeviceKeys: Set<String> = ["token", "inputChannels", "streamStatus", "transport", "running"]

        private static func encodedDictionary(_ record: some Codable) -> [String: Any]? {
            guard let data = try? JSONEncoder().encode(record),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return dict
        }

        private static func validateSchema() -> Bool {
            let start = ProbeStartLine(schemaVersion: 1, event: .start, durationSeconds: 5, note: .tempMayBePurged)
            guard let startDict = encodedDictionary(start),
                  Set(startDict.keys) == allowedStartKeys
            else { return false }

            let process = ProcessEntry(family: .zoom, input: .active, output: .inactive)
            let device = DeviceEntry(token: "00", inputChannels: 2, streamStatus: .ok, transport: .builtIn, running: .running)
            let sample = ProbeSampleLine(
                schemaVersion: 1,
                event: .sample,
                monotonicOffsetMs: 0,
                processListStatus: .ok,
                processCount: 1,
                deviceListStatus: .ok,
                deviceCount: 1,
                hardwareDeviceCount: 1,
                classificationFailureCount: 0,
                windowListSuccess: true,
                windowListCount: 1,
                windowListLatencyMs: 0,
                processes: [process],
                devices: [device]
            )
            guard let sampleDict = encodedDictionary(sample),
                  Set(sampleDict.keys) == allowedSampleKeys,
                  let processes = sampleDict["processes"] as? [[String: Any]],
                  processes.count == 1,
                  Set(processes[0].keys) == allowedProcessKeys,
                  let devices = sampleDict["devices"] as? [[String: Any]],
                  devices.count == 1,
                  Set(devices[0].keys) == allowedDeviceKeys
            else { return false }

            let tokenAbsent = DeviceEntry(token: nil, inputChannels: 1, streamStatus: .ok, transport: .usb, running: .notRunning)
            guard let tokenAbsentDict = encodedDictionary(tokenAbsent),
                  Set(tokenAbsentDict.keys) == allowedDeviceKeys.subtracting(["token"])
            else { return false }

            let terminal = ProbeTerminalLine(schemaVersion: 1, event: .terminal, monotonicOffsetMs: 0, reason: .completed, recordCount: 0)
            guard let terminalDict = encodedDictionary(terminal),
                  Set(terminalDict.keys) == allowedTerminalKeys
            else { return false }
            return true
        }
    }

#endif
