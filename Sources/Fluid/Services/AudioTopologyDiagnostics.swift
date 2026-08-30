#if DEBUG
import CoreAudio
#if SWIFT_PACKAGE
import CoreAudioCaptureSupport
#endif
import CoreFoundation
import Darwin
import Foundation

nonisolated enum AudioTopologyTraceEvent: UInt32, CaseIterable, Sendable {
    case callback = 1
    case enumerationBegin
    case enumerationEnd
    case replaceBegin
    case replaceEnd
    case listenerAddBegin
    case listenerAddEnd
    case listenerRemoveBegin
    case listenerRemoveEnd
    case halQueryBegin
    case halQueryEnd
    case vpioEnableBegin
    case vpioEnableEnd
    case audioUnitBindBegin
    case audioUnitBindEnd
    case enginePrepareBegin
    case enginePrepareEnd
    case engineStartBegin
    case engineStartEnd
    case engineStopBegin
    case engineStopEnd
    case avfDiscoveryBegin
    case avfDiscoveryEnd
    case avfDefaultBegin
    case avfDefaultEnd
    case avfAuthorizationBegin
    case avfAuthorizationEnd
    case recoveryScheduled
    case recoveryBegin
    case recoveryEnd
    case recoveryCancel
    case topologySnapshot
    case topologyGeneration
    case phaseBegin
    case phaseEnd
    case probeCycleBegin
    case probeCycleEnd
    case readiness
    case isolationActive
    case policyExcluded

    var label: String {
        String(describing: self)
    }
}

nonisolated enum AudioTopologyTraceOwner: UInt32, CaseIterable, Sendable {
    case unknown = 0
    case diagnostics
    case audioHardwareObserver
    case asrDefaultInput
    case asrDefaultOutput
    case asrDeviceList
    case asrMonitoredInput
    case directCoreAudio
    case meetingDetector
    case meetingMicrophone
    case meetingOutputRoute
    case meetingCatalog
    case meetingCoordinator
    case phaseZeroProbe

    var label: String {
        String(describing: self)
    }
}

nonisolated enum AudioTopologyTraceQueueRole: UInt32, CaseIterable, Sendable {
    case unknown = 0
    case mainDelivery
    case dedicatedDelivery
    case mainControl
    case dedicatedControl
    case actorControl
    case callbackCurrent

    var label: String {
        String(describing: self)
    }
}

nonisolated enum AudioTopologyTracePhase: UInt32, CaseIterable, Sendable {
    case none = 0
    case catalog
    case vpio
    case engine
    case listener
    case recovery
    case handoff
    case quiescing

    var label: String {
        String(describing: self)
    }
}

nonisolated enum AudioTopologyTraceTransport: UInt32, CaseIterable, Sendable {
    case unknown = 0
    case builtIn
    case bluetooth
    case usb
    case aggregate
    case virtual
    case other

    var label: String {
        String(describing: self)
    }
}

nonisolated struct AudioTopologyDiagnosticsConfiguration: Equatable, Sendable {
    static let enabledKey = "FLUIDVOICE_AUDIO_TOPOLOGY_DIAGNOSTICS"
    static let outputDirectoryKey = "FLUIDVOICE_AUDIO_TOPOLOGY_TRACE_DIRECTORY"
    static let stallThresholdKey = "FLUIDVOICE_AUDIO_TOPOLOGY_STALL_SECONDS"

    var enabled: Bool
    var outputDirectory: URL
    var stallThresholdSeconds: Double

    static func resolve(
        environment: [String: String],
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) -> Self {
        let enabled = environment[Self.enabledKey] == "1"
        let outputDirectory = environment[Self.outputDirectoryKey]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? temporaryDirectory
        let requestedThreshold = environment[Self.stallThresholdKey].flatMap(Double.init)
        return Self(
            enabled: enabled,
            outputDirectory: outputDirectory,
            stallThresholdSeconds: min(max(requestedThreshold ?? 2.0, 0.5), 30.0)
        )
    }
}

nonisolated enum AudioTopologyStallClassification: String, Sendable {
    case heartbeatHealthy
    case heartbeatMissing
    case heartbeatStalledPhaseOpen
    case heartbeatStalledPhaseClosed

    static func classify(
        heartbeatAgeSeconds: Double?,
        thresholdSeconds: Double,
        topologyPhaseOpen: Bool
    ) -> Self {
        guard let heartbeatAgeSeconds else { return .heartbeatMissing }
        guard heartbeatAgeSeconds >= thresholdSeconds else { return .heartbeatHealthy }
        return topologyPhaseOpen ? .heartbeatStalledPhaseOpen : .heartbeatStalledPhaseClosed
    }
}

/// DEBUG-only, opt-in diagnostics for the meeting-start Core Audio freeze.
///
/// The event capture path is implemented in C and remains numeric, preallocated,
/// non-blocking, and HAL-free. This Swift owner only drains or persists snapshots
/// away from Core Audio callbacks.
final nonisolated class AudioTopologyDiagnostics: @unchecked Sendable {
    static let shared = AudioTopologyDiagnostics()
    static let noStatus = Int32.min
    static let schemaKeys: Set<String> = [
        "kind", "sequence", "continuous_time", "wall_unix_ns", "event", "owner",
        "object_id", "selector", "scope", "element", "queue_role", "phase",
        "transport", "status", "generation", "pid", "heartbeat_age_ms",
        "stall_classification", "trace_path", "stall_path",
    ]

    private let drainQueue = DispatchQueue(
        label: "com.fluidvoice.audio-topology-diagnostics.drain",
        qos: .utility
    )
    private let watchdogQueue = DispatchQueue(
        label: "com.fluidvoice.audio-topology-diagnostics.watchdog",
        qos: .userInitiated
    )
    private let lifecycleLock = NSLock()
    private var started = false
    private var configuration: AudioTopologyDiagnosticsConfiguration?
    private var traceFileDescriptor: Int32 = -1
    private var traceURL: URL?
    private var lastDrainedSequence: UInt64 = 0
    private var drainTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var runLoopObserver: CFRunLoopObserver?
    private var lastPersistedStallHeartbeat: UInt64 = 0

    private init() {}

    static var isEnabled: Bool {
        fv_audio_topology_trace_is_enabled()
    }

    /// Call once during launch, before installing any instrumented listener.
    func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolved = AudioTopologyDiagnosticsConfiguration.resolve(environment: environment)
        guard resolved.enabled else { return }

        self.lifecycleLock.lock()
        guard self.started == false else {
            self.lifecycleLock.unlock()
            return
        }
        self.started = true
        self.configuration = resolved
        self.lifecycleLock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: resolved.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            self.markStartFailed()
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let traceURL = resolved.outputDirectory
            .appendingPathComponent("fluidvoice-audio-topology-\(pid).jsonl")
        let descriptor = Darwin.open(
            traceURL.path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            self.markStartFailed()
            return
        }
        self.traceFileDescriptor = descriptor
        self.traceURL = traceURL

        fv_audio_topology_trace_set_enabled(true)
        fv_audio_topology_trace_main_heartbeat()
        self.installRunLoopHeartbeat()
        self.writeClockAnchor(sync: false)
        self.startDrainTimer()
        self.startWatchdog(thresholdSeconds: resolved.stallThresholdSeconds)
    }

    func stop() {
        self.lifecycleLock.lock()
        guard self.started else {
            self.lifecycleLock.unlock()
            return
        }
        self.started = false
        self.lifecycleLock.unlock()

        fv_audio_topology_trace_set_enabled(false)
        self.drainTimer?.cancel()
        self.watchdogTimer?.cancel()
        self.drainTimer = nil
        self.watchdogTimer = nil
        if let observer = self.runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.runLoopObserver = nil
        }
        self.drainQueue.sync {
            self.drainAvailableEvents(sync: true)
            if self.traceFileDescriptor >= 0 {
                _ = Darwin.close(self.traceFileDescriptor)
                self.traceFileDescriptor = -1
            }
        }
    }

    @inline(__always)
    static func record(
        _ event: AudioTopologyTraceEvent,
        owner: AudioTopologyTraceOwner,
        objectID: AudioObjectID = kAudioObjectUnknown,
        selector: AudioObjectPropertySelector = 0,
        scope: AudioObjectPropertyScope = 0,
        element: AudioObjectPropertyElement = 0,
        queueRole: AudioTopologyTraceQueueRole = .unknown,
        phase: AudioTopologyTracePhase = .none,
        transport: AudioTopologyTraceTransport = .unknown,
        status: Int32 = AudioTopologyDiagnostics.noStatus,
        generation: UInt64 = 0
    ) {
        _ = fv_audio_topology_trace_record(
            event.rawValue,
            owner.rawValue,
            objectID,
            selector,
            scope,
            element,
            queueRole.rawValue,
            phase.rawValue,
            transport.rawValue,
            status,
            generation
        )
    }

    static func transportClassification(_ transportType: UInt32) -> AudioTopologyTraceTransport {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .other
        }
    }

    static func snapshot(after sequence: UInt64 = 0) -> ([FVAudioTopologyTraceEvent], UInt64) {
        let capacity = Int(fv_audio_topology_trace_capacity())
        var events = [FVAudioTopologyTraceEvent](
            repeating: FVAudioTopologyTraceEvent(),
            count: capacity
        )
        var latest: UInt64 = 0
        let count = events.withUnsafeMutableBufferPointer { buffer in
            fv_audio_topology_trace_snapshot(
                sequence,
                buffer.baseAddress,
                UInt32(buffer.count),
                &latest
            )
        }
        return (Array(events.prefix(Int(count))), latest)
    }

    static func heartbeatAgeSeconds(now: UInt64 = mach_continuous_time()) -> Double? {
        let heartbeat = fv_audio_topology_trace_last_main_heartbeat()
        guard heartbeat > 0, now >= heartbeat else { return nil }
        return Self.seconds(fromContinuousTicks: now - heartbeat)
    }

    private func installRunLoopHeartbeat() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { _, _ in
            fv_audio_topology_trace_main_heartbeat()
        }
        guard let observer else { return }
        self.runLoopObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: self.drainQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.drainAvailableEvents(sync: false)
        }
        self.drainTimer = timer
        timer.resume()
    }

    private func startWatchdog(thresholdSeconds: Double) {
        let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeat(thresholdSeconds: thresholdSeconds)
        }
        self.watchdogTimer = timer
        timer.resume()
    }

    private func checkHeartbeat(thresholdSeconds: Double) {
        let heartbeat = fv_audio_topology_trace_last_main_heartbeat()
        guard heartbeat > 0,
              let age = Self.heartbeatAgeSeconds(),
              age >= thresholdSeconds,
              heartbeat != self.lastPersistedStallHeartbeat
        else { return }
        let snapshot = Self.snapshot()
        let topologyPhaseOpen = Self.hasOpenTopologyPhase(snapshot.0)
        let classification = AudioTopologyStallClassification.classify(
            heartbeatAgeSeconds: age,
            thresholdSeconds: thresholdSeconds,
            topologyPhaseOpen: topologyPhaseOpen
        )
        let persisted = self.persistStallSnapshot(
            events: snapshot.0,
            latestSequence: snapshot.1,
            heartbeatAgeSeconds: age,
            classification: classification
        )
        if persisted {
            self.lastPersistedStallHeartbeat = heartbeat
        }
    }

    private func drainAvailableEvents(sync: Bool) {
        guard self.traceFileDescriptor >= 0 else { return }
        let snapshot = Self.snapshot(after: self.lastDrainedSequence)
        guard snapshot.1 > self.lastDrainedSequence else { return }
        self.writeClockAnchor(sync: false)
        for event in snapshot.0 {
            Self.writeAll(
                descriptor: self.traceFileDescriptor,
                bytes: Self.jsonLine(for: event)
            )
        }
        self.lastDrainedSequence = snapshot.1
        if sync {
            _ = Darwin.fsync(self.traceFileDescriptor)
        }
    }

    private func writeClockAnchor(sync: Bool) {
        guard self.traceFileDescriptor >= 0 else { return }
        let line = Self.clockAnchorLine(
            continuousTime: mach_continuous_time(),
            wallNanoseconds: UInt64((Date().timeIntervalSince1970 * 1_000_000_000).rounded()),
            pid: ProcessInfo.processInfo.processIdentifier
        )
        Self.writeAll(descriptor: self.traceFileDescriptor, bytes: Array(line.utf8))
        if sync {
            _ = Darwin.fsync(self.traceFileDescriptor)
        }
    }

    @discardableResult
    private func persistStallSnapshot(
        events: [FVAudioTopologyTraceEvent],
        latestSequence: UInt64,
        heartbeatAgeSeconds: Double,
        classification: AudioTopologyStallClassification
    ) -> Bool {
        guard let configuration else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        let stallURL = configuration.outputDirectory.appendingPathComponent(
            "fluidvoice-audio-topology-stall-\(pid)-\(latestSequence).jsonl"
        )
        let descriptor = Darwin.open(
            stallURL.path,
            O_WRONLY | O_CREAT | O_TRUNC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        let anchor = Self.clockAnchorLine(
            continuousTime: mach_continuous_time(),
            wallNanoseconds: UInt64((Date().timeIntervalSince1970 * 1_000_000_000).rounded()),
            pid: pid
        )
        let header = "{\"kind\":\"stall\",\"pid\":\(pid),\"sequence\":\(latestSequence)," +
            "\"heartbeat_age_ms\":\(Int((heartbeatAgeSeconds * 1000).rounded()))," +
            "\"stall_classification\":\"\(classification.rawValue)\"}\n"
        guard Self.writeAll(descriptor: descriptor, bytes: Array(anchor.utf8)),
              Self.writeAll(descriptor: descriptor, bytes: Array(header.utf8))
        else {
            _ = Darwin.close(descriptor)
            return false
        }
        for event in events {
            guard Self.writeAll(descriptor: descriptor, bytes: Self.jsonLine(for: event)) else {
                _ = Darwin.close(descriptor)
                return false
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            _ = Darwin.close(descriptor)
            return false
        }
        _ = Darwin.close(descriptor)

        let markerURL = configuration.outputDirectory.appendingPathComponent(
            "fluidvoice-audio-topology-\(pid).stall"
        )
        let markerDescriptor = Darwin.open(
            markerURL.path,
            O_WRONLY | O_CREAT | O_TRUNC,
            S_IRUSR | S_IWUSR
        )
        guard markerDescriptor >= 0 else { return false }
        let marker = "{\"kind\":\"stall_marker\",\"pid\":\(pid)," +
            "\"sequence\":\(latestSequence),\"stall_path\":\"\(stallURL.path)\"," +
            "\"trace_path\":\"\(self.traceURL?.path ?? "")\"}\n"
        let markerWritten = Self.writeAll(descriptor: markerDescriptor, bytes: Array(marker.utf8))
        let markerSynced = markerWritten && Darwin.fsync(markerDescriptor) == 0
        _ = Darwin.close(markerDescriptor)
        return markerSynced
    }

    static func hasOpenTopologyPhase(_ events: [FVAudioTopologyTraceEvent]) -> Bool {
        struct Key: Hashable {
            var category: UInt8
            var owner: UInt32
            var objectID: UInt32
            var generation: UInt64
        }
        var openCounts: [Key: Int] = [:]
        for event in events {
            guard let kind = AudioTopologyTraceEvent(rawValue: event.event) else { continue }
            guard let pair = Self.phasePair(for: kind) else { continue }
            let key = Key(category: pair.category, owner: event.owner, objectID: event.objectID, generation: event.generation)
            if pair.isBegin {
                openCounts[key, default: 0] += 1
            } else if let count = openCounts[key], count > 0 {
                openCounts[key] = count - 1
            }
        }
        return openCounts.values.contains { $0 > 0 }
    }

    private static func phasePair(for event: AudioTopologyTraceEvent) -> (category: UInt8, isBegin: Bool)? {
        switch event {
        case .enumerationBegin: (1, true)
        case .enumerationEnd: (1, false)
        case .replaceBegin: (2, true)
        case .replaceEnd: (2, false)
        case .listenerAddBegin: (3, true)
        case .listenerAddEnd: (3, false)
        case .listenerRemoveBegin: (4, true)
        case .listenerRemoveEnd: (4, false)
        case .halQueryBegin: (5, true)
        case .halQueryEnd: (5, false)
        case .vpioEnableBegin: (6, true)
        case .vpioEnableEnd: (6, false)
        case .audioUnitBindBegin: (7, true)
        case .audioUnitBindEnd: (7, false)
        case .enginePrepareBegin: (8, true)
        case .enginePrepareEnd: (8, false)
        case .engineStartBegin: (9, true)
        case .engineStartEnd: (9, false)
        case .engineStopBegin: (10, true)
        case .engineStopEnd: (10, false)
        case .avfDiscoveryBegin: (11, true)
        case .avfDiscoveryEnd: (11, false)
        case .avfDefaultBegin: (12, true)
        case .avfDefaultEnd: (12, false)
        case .avfAuthorizationBegin: (13, true)
        case .avfAuthorizationEnd: (13, false)
        case .recoveryBegin: (14, true)
        case .recoveryEnd: (14, false)
        case .phaseBegin: (15, true)
        case .phaseEnd: (15, false)
        case .probeCycleBegin: (16, true)
        case .probeCycleEnd: (16, false)
        default: nil
        }
    }

    static func jsonLine(for event: FVAudioTopologyTraceEvent) -> [UInt8] {
        let eventLabel = AudioTopologyTraceEvent(rawValue: event.event)?.label ?? "unknown"
        let ownerLabel = AudioTopologyTraceOwner(rawValue: event.owner)?.label ?? "unknown"
        let queueLabel = AudioTopologyTraceQueueRole(rawValue: event.queueRole)?.label ?? "unknown"
        let phaseLabel = AudioTopologyTracePhase(rawValue: event.phase)?.label ?? "none"
        let transportLabel = AudioTopologyTraceTransport(rawValue: event.transport)?.label ?? "unknown"
        let line = "{\"kind\":\"event\",\"sequence\":\(event.sequence)," +
            "\"continuous_time\":\(event.continuousTime),\"event\":\"\(eventLabel)\"," +
            "\"owner\":\"\(ownerLabel)\",\"object_id\":\(event.objectID)," +
            "\"selector\":\(event.selector),\"scope\":\(event.scope)," +
            "\"element\":\(event.element),\"queue_role\":\"\(queueLabel)\"," +
            "\"phase\":\"\(phaseLabel)\",\"transport\":\"\(transportLabel)\"," +
            "\"status\":\(event.status),\"generation\":\(event.generation)}\n"
        return Array(line.utf8)
    }

    static func clockAnchorLine(
        continuousTime: UInt64,
        wallNanoseconds: UInt64,
        pid: Int32
    ) -> String {
        "{\"kind\":\"clock_anchor\",\"continuous_time\":\(continuousTime)," +
            "\"wall_unix_ns\":\(wallNanoseconds),\"pid\":\(pid)}\n"
    }

    private func markStartFailed() {
        self.lifecycleLock.lock()
        self.started = false
        self.configuration = nil
        self.lifecycleLock.unlock()
    }

    @discardableResult
    private static func writeAll(descriptor: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private static func seconds(fromContinuousTicks ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
#endif
