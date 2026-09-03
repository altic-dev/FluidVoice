import CoreAudio
#if SWIFT_PACKAGE
import CoreAudioCaptureSupport
#endif
import Foundation

nonisolated enum DirectCoreAudioDeviceSelection: Equatable {
    case systemDefault
    case preferredUID(String)
}

typealias DirectCoreAudioPacketHandler = @Sendable (
    _ samples: UnsafePointer<Float>,
    _ frameCount: Int,
    _ sampleRate: Double,
    _ inputHostTime: UInt64,
    _ inputSampleTime: Int64
) -> Void

nonisolated struct DirectCoreAudioStreamFormatFingerprint: Equatable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(_ format: AudioStreamBasicDescription) {
        self.sampleRate = format.mSampleRate
        self.formatID = format.mFormatID
        self.formatFlags = format.mFormatFlags
        self.bytesPerPacket = format.mBytesPerPacket
        self.framesPerPacket = format.mFramesPerPacket
        self.bytesPerFrame = format.mBytesPerFrame
        self.channelsPerFrame = format.mChannelsPerFrame
        self.bitsPerChannel = format.mBitsPerChannel
    }

    var logDescription: String {
        "\(Int(self.sampleRate.rounded()))Hz/" +
            "\(self.channelsPerFrame)ch/" +
            "\(self.bitsPerChannel)bit/" +
            "flags=0x\(String(self.formatFlags, radix: 16))/" +
            "bytesPerFrame=\(self.bytesPerFrame)"
    }
}

nonisolated struct DirectCoreAudioFormatFingerprint: Equatable {
    let deviceID: AudioObjectID
    let streamID: AudioStreamID
    let virtualFormat: DirectCoreAudioStreamFormatFingerprint
    let physicalFormat: DirectCoreAudioStreamFormatFingerprint?
    let inputBufferChannels: [UInt32]
    let nominalSampleRate: Double
    let bufferFrameSize: UInt32
    let variableBufferFrameSizeMaximum: UInt32?
    let dataSourceID: UInt32?

    var logDescription: String {
        let bufferLayout = self.inputBufferChannels.map(String.init).joined(separator: ",")
        let physical = self.physicalFormat?.logDescription ?? "unavailable"
        let dataSource = self.dataSourceID.map(String.init) ?? "unavailable"
        return "device=\(self.deviceID) stream=\(self.streamID) " +
            "virtual=\(self.virtualFormat.logDescription) physical=\(physical) " +
            "buffers=[\(bufferLayout)] nominalHz=\(Int(self.nominalSampleRate.rounded())) " +
            "bufferFrames=\(self.bufferFrameSize) " +
            "variableMax=\(self.variableBufferFrameSizeMaximum.map(String.init) ?? "fixed") " +
            "dataSource=\(dataSource)"
    }

    static func read(deviceID: AudioObjectID) throws -> Self {
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let isAlive: UInt32 = try self.readScalar(
            objectID: deviceID,
            address: &aliveAddress,
            operation: "read input device liveness"
        )
        guard isAlive != 0 else {
            throw Self.error(
                status: kAudioHardwareBadDeviceError,
                operation: "read direct Core Audio format",
                detail: "device \(deviceID) is not alive"
            )
        }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let streams: [AudioStreamID] = try self.readArray(
            objectID: deviceID,
            address: &streamsAddress,
            operation: "read input streams"
        )
        guard streams.count == 1, let streamID = streams.first else {
            throw Self.error(
                status: kAudioHardwareUnsupportedOperationError,
                operation: "read direct Core Audio format",
                detail: "expected one input stream, found \(streams.count)"
            )
        }

        var virtualFormatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let virtualFormat: AudioStreamBasicDescription = try self.readScalar(
            objectID: streamID,
            address: &virtualFormatAddress,
            operation: "read input stream virtual format"
        )

        var physicalFormatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let physicalFormat: AudioStreamBasicDescription? = self.readOptionalScalar(
            objectID: streamID,
            address: &physicalFormatAddress
        )

        var nominalRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nominalSampleRate: Double = try self.readScalar(
            objectID: deviceID,
            address: &nominalRateAddress,
            operation: "read nominal input sample rate"
        )

        var bufferFrameSizeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let bufferFrameSize: UInt32 = try self.readScalar(
            objectID: deviceID,
            address: &bufferFrameSizeAddress,
            operation: "read input buffer frame size"
        )

        var variableBufferSizeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyUsesVariableBufferFrameSizes,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let variableBufferFrameSizeMaximum: UInt32? = self.readOptionalScalar(
            objectID: deviceID,
            address: &variableBufferSizeAddress
        )

        var streamConfigurationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let inputBufferChannels = try self.readInputBufferChannels(
            deviceID: deviceID,
            address: &streamConfigurationAddress
        )

        var dataSourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let dataSourceID: UInt32? = self.readOptionalScalar(
            objectID: deviceID,
            address: &dataSourceAddress
        )

        return Self(
            deviceID: deviceID,
            streamID: streamID,
            virtualFormat: DirectCoreAudioStreamFormatFingerprint(virtualFormat),
            physicalFormat: physicalFormat.map(DirectCoreAudioStreamFormatFingerprint.init),
            inputBufferChannels: inputBufferChannels,
            nominalSampleRate: nominalSampleRate,
            bufferFrameSize: bufferFrameSize,
            variableBufferFrameSizeMaximum: variableBufferFrameSizeMaximum,
            dataSourceID: dataSourceID
        )
    }

    static func captured(
        deviceID: AudioObjectID,
        streamID: AudioStreamID,
        virtualFormat: AudioStreamBasicDescription,
        bufferFrameSize: UInt32
    ) throws -> Self {
        let live = try self.read(deviceID: deviceID)
        return Self(
            deviceID: deviceID,
            streamID: streamID,
            virtualFormat: DirectCoreAudioStreamFormatFingerprint(virtualFormat),
            physicalFormat: live.streamID == streamID ? live.physicalFormat : nil,
            inputBufferChannels: live.inputBufferChannels,
            nominalSampleRate: live.nominalSampleRate,
            bufferFrameSize: bufferFrameSize,
            variableBufferFrameSizeMaximum: live.variableBufferFrameSizeMaximum,
            dataSourceID: live.dataSourceID
        )
    }

    private static func readScalar<T>(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        operation: String
    ) throws -> T {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            pointer
        )
        guard status == noErr, size == UInt32(MemoryLayout<T>.size) else {
            throw self.error(status: status, operation: operation)
        }
        return pointer.move()
    }

    private static func readOptionalScalar<T>(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> T? {
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        return try? self.readScalar(
            objectID: objectID,
            address: &address,
            operation: "read optional Core Audio property"
        )
    }

    private static func readArray<T>(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        operation: String
    ) throws -> [T] {
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size % UInt32(MemoryLayout<T>.stride) == 0 else {
            throw self.error(status: sizeStatus, operation: operation)
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }
        var mutableSize = size
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &mutableSize,
            storage
        )
        guard status == noErr,
              mutableSize == size,
              mutableSize % UInt32(MemoryLayout<T>.stride) == 0
        else {
            throw self.error(
                status: status == noErr ? kAudioHardwareUnspecifiedError : status,
                operation: "\(operation) without a topology size change"
            )
        }
        let values = storage.assumingMemoryBound(to: T.self)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }

    private static func readInputBufferChannels(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> [UInt32] {
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size >= MemoryLayout<AudioBufferList>.size else {
            throw self.error(
                status: sizeStatus,
                operation: "read input stream configuration size"
            )
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        var mutableSize = size
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &mutableSize,
            storage
        )
        guard status == noErr, mutableSize == size else {
            throw self.error(
                status: status == noErr ? kAudioHardwareUnspecifiedError : status,
                operation: "read stable input stream configuration"
            )
        }
        let bufferCount = storage.load(as: UInt32.self)
        let bufferAlignment = MemoryLayout<AudioBuffer>.alignment
        let firstBufferOffset =
            (MemoryLayout<UInt32>.size + bufferAlignment - 1) &
            ~(bufferAlignment - 1)
        let requiredSize =
            firstBufferOffset + Int(bufferCount) * MemoryLayout<AudioBuffer>.stride
        guard bufferCount > 0, requiredSize <= Int(mutableSize) else {
            throw self.error(
                status: kAudioHardwareUnspecifiedError,
                operation: "validate input stream configuration"
            )
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.map(\.mNumberChannels)
    }

    private static func error(
        status: OSStatus,
        operation: String,
        detail: String? = nil
    ) -> NSError {
        let suffix = detail.map { ": \($0)" } ?? " (OSStatus \(status))"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Failed to \(operation)\(suffix)."]
        )
    }
}

/// Prepared, input-only Core Audio capture.
///
/// `AudioDeviceIOProc` publishes native hardware-cycle PCM into a fixed SPSC
/// ring in C. This Swift wrapper drains that ring away from Core Audio's
/// realtime thread, so resampling, level calculation, logging, and ASR buffer
/// mutation never happen in the device callback.
nonisolated protocol DirectCoreAudioInputControlling: AnyObject, Sendable {
    var deviceID: AudioObjectID { get }
    var sampleRate: Double { get }
    var hardwareBufferFrameSize: UInt32 { get }
    var formatFingerprint: DirectCoreAudioFormatFingerprint { get }
    var isRunning: Bool { get }
    var droppedPacketCount: UInt64 { get }

    func start() throws
    func stop() -> OSStatus
    func markFormatDirty()
    func openPacketGateIfClean() -> Bool
    func invalidate() -> OSStatus
}

private final nonisolated class DirectCoreAudioInput: DirectCoreAudioInputControlling, @unchecked Sendable {
    private struct SendableCaptureHandle: @unchecked Sendable {
        let rawValue: FVCoreAudioCaptureRef
    }

    let deviceID: AudioObjectID
    let sampleRate: Double
    let hardwareBufferFrameSize: UInt32
    let formatFingerprint: DirectCoreAudioFormatFingerprint

    private var capture: FVCoreAudioCaptureRef?
    private var poisonedStopStatus: OSStatus?
    private let packetHandler: DirectCoreAudioPacketHandler
    private let workerQueue = DispatchQueue(
        label: "com.fluidvoice.audio.direct-input-consumer",
        qos: .userInteractive
    )
    private let workerGroup = DispatchGroup()

    init(deviceID: AudioObjectID, packetHandler: @escaping DirectCoreAudioPacketHandler) throws {
        var capture: FVCoreAudioCaptureRef?
        let status = fv_core_audio_capture_create(deviceID, &capture)
        guard status == noErr, let capture else {
            throw Self.error(status: status, operation: "prepare direct Core Audio input")
        }

        self.deviceID = deviceID
        let sampleRate = fv_core_audio_capture_sample_rate(capture)
        let hardwareBufferFrameSize = fv_core_audio_capture_buffer_frame_size(capture)
        var streamID = AudioStreamID(kAudioObjectUnknown)
        var streamFormat = AudioStreamBasicDescription()
        guard fv_core_audio_capture_copy_stream_format(
            capture,
            &streamID,
            &streamFormat
        ) else {
            _ = fv_core_audio_capture_destroy(capture)
            throw Self.error(
                status: kAudioHardwareUnspecifiedError,
                operation: "read prepared direct Core Audio format"
            )
        }
        do {
            self.formatFingerprint = try DirectCoreAudioFormatFingerprint.captured(
                deviceID: deviceID,
                streamID: streamID,
                virtualFormat: streamFormat,
                bufferFrameSize: hardwareBufferFrameSize
            )
        } catch {
            _ = fv_core_audio_capture_destroy(capture)
            throw error
        }
        self.capture = capture
        self.sampleRate = sampleRate
        self.hardwareBufferFrameSize = hardwareBufferFrameSize
        self.packetHandler = packetHandler
    }

    deinit {
        _ = self.invalidate()
    }

    var isRunning: Bool {
        guard let capture else { return false }
        return fv_core_audio_capture_is_running(capture)
    }

    var droppedPacketCount: UInt64 {
        guard let capture else { return 0 }
        return fv_core_audio_capture_dropped_packet_count(capture)
    }

    func start() throws {
        guard let capture else {
            throw Self.error(status: kAudioHardwareBadObjectError, operation: "start direct Core Audio input")
        }
        guard fv_core_audio_capture_is_running(capture) == false else { return }

        fv_core_audio_capture_clear(capture)
        let status = fv_core_audio_capture_start(capture)
        guard status == noErr else {
            throw Self.error(status: status, operation: "start direct Core Audio input")
        }

        let packetHandler = self.packetHandler
        let workerGroup = self.workerGroup
        let workerHandle = SendableCaptureHandle(rawValue: capture)
        workerGroup.enter()
        self.workerQueue.async {
            defer { workerGroup.leave() }
            Self.consumePackets(capture: workerHandle.rawValue, packetHandler: packetHandler)
        }
    }

    func markFormatDirty() {
        guard let capture else { return }
        fv_core_audio_capture_mark_format_dirty(capture)
    }

    func openPacketGateIfClean() -> Bool {
        guard let capture else { return false }
        return fv_core_audio_capture_open_packet_gate_if_clean(capture)
    }

    /// Stops hardware IO and synchronously drains every packet already published
    /// by the realtime callback before returning.
    @discardableResult
    func stop() -> OSStatus {
        if let poisonedStopStatus {
            return poisonedStopStatus
        }
        guard let capture else { return noErr }
        let status = fv_core_audio_capture_stop(capture)
        fv_core_audio_capture_wake(capture)
        self.workerGroup.wait()
        if status != noErr {
            self.poisonedStopStatus = status
        }
        return status
    }

    @discardableResult
    func invalidate() -> OSStatus {
        guard let capture else { return self.poisonedStopStatus ?? noErr }
        let stopStatus = self.stop()
        guard stopStatus == noErr else {
            // A failed AudioDeviceStop does not establish that HAL stopped
            // invoking the IOProc. Leak the callback context intentionally
            // rather than freeing memory that Core Audio may still access.
            self.capture = nil
            return stopStatus
        }
        let destroyStatus = fv_core_audio_capture_destroy(capture)
        guard destroyStatus == noErr else {
            self.poisonedStopStatus = destroyStatus
            self.capture = nil
            return destroyStatus
        }
        self.capture = nil
        return noErr
    }

    private nonisolated static func consumePackets(
        capture: FVCoreAudioCaptureRef,
        packetHandler: DirectCoreAudioPacketHandler
    ) {
        while true {
            var packet = FVCoreAudioPacket()
            while fv_core_audio_capture_peek(capture, &packet) {
                if let samples = packet.samples, packet.frameCount > 0 {
                    packetHandler(
                        samples,
                        Int(packet.frameCount),
                        packet.sampleRate,
                        packet.inputHostTime,
                        packet.inputSampleTime
                    )
                }
                fv_core_audio_capture_consume(capture)
            }

            guard fv_core_audio_capture_is_running(capture) else {
                // AudioDeviceStop waits for the IOProc to leave. One final
                // acquire/drain above therefore captures the complete tail.
                return
            }
            _ = fv_core_audio_capture_wait(capture, 100)
        }
    }

    private static func error(status: OSStatus, operation: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to \(operation) (OSStatus \(status)).",
            ]
        )
    }
}

private final nonisolated class DirectCoreAudioPacketGate: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptingPackets = true

    func withAcceptedPacket(_ body: () -> Void) {
        self.lock.lock()
        guard self.acceptingPackets else {
            self.lock.unlock()
            return
        }
        body()
        self.lock.unlock()
    }

    func retire() {
        self.lock.lock()
        self.acceptingPackets = false
        self.lock.unlock()
    }
}

final nonisolated class DirectCoreAudioLifecycleController: @unchecked Sendable {
    enum Phase: String {
        case empty
        case preparing
        case prepared
        case starting
        case running
        case stopping
        case invalidating
        case failed
        case shutDown
    }

    struct Snapshot: Equatable {
        let phase: Phase
        let generation: UInt64
        let deviceID: AudioObjectID?
        let deviceName: String?
        let sampleRate: Double?
        let bufferFrameSize: UInt32?
        let fingerprint: DirectCoreAudioFormatFingerprint?

        var isPrepared: Bool {
            switch self.phase {
            case .prepared, .starting, .running, .stopping:
                return true
            case .empty, .preparing, .invalidating, .failed, .shutDown:
                return false
            }
        }
    }

    struct StopReport {
        let status: OSStatus
        let droppedPackets: UInt64
        let retainedPreparedCapture: Bool
    }

    struct FormatInvalidation {
        let generation: UInt64
        let deviceID: AudioObjectID
        let reason: String
        let wasRunning: Bool
    }

    private enum LifecycleLogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
    }

    typealias PacketHandler = DirectCoreAudioPacketHandler
    typealias InputFactory = (
        _ deviceID: AudioObjectID,
        _ packetHandler: @escaping PacketHandler
    ) throws -> any DirectCoreAudioInputControlling
    typealias FingerprintReader = (_ deviceID: AudioObjectID) throws
        -> DirectCoreAudioFormatFingerprint

    private struct ListenerRegistration {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private enum ListenerPolicy: Equatable {
        case optional
        case required
        case requiredNotification
    }

    private let lifecycleQueue = DispatchQueue(
        label: "com.fluidvoice.audio.direct-lifecycle",
        qos: .userInitiated
    )
    private let listenerQueue = DispatchQueue(
        label: "com.fluidvoice.audio.direct-format-listeners",
        qos: .userInitiated
    )
    private let snapshotLock = NSLock()
    private let stoppedHardwareLock = NSLock()
    private var stoppedHardwareGenerations: Set<UInt64> = []
    private var storedSnapshot = Snapshot(
        phase: .empty,
        generation: 0,
        deviceID: nil,
        deviceName: nil,
        sampleRate: nil,
        bufferFrameSize: nil,
        fingerprint: nil
    )

    private let packetHandler: PacketHandler
    private let inputFactory: InputFactory
    private let fingerprintReader: FingerprintReader
    private let onFormatInvalidated: @Sendable (FormatInvalidation) -> Void
    private let installsHardwareListeners: Bool

    // lifecycleQueue-confined state
    private var input: (any DirectCoreAudioInputControlling)?
    private var packetGate: DirectCoreAudioPacketGate?
    private var listenerRegistrations: [ListenerRegistration] = []
    private var generation: UInt64 = 0
    private var isShutDown = false
    private var isPoisoned = false
    private var inputDeviceName: String?

    init(
        packetHandler: @escaping PacketHandler,
        inputFactory: @escaping InputFactory = { deviceID, handler in
            try DirectCoreAudioInput(deviceID: deviceID, packetHandler: handler)
        },
        fingerprintReader: @escaping FingerprintReader = {
            try DirectCoreAudioFormatFingerprint.read(deviceID: $0)
        },
        installsHardwareListeners: Bool = true,
        onFormatInvalidated: @escaping @Sendable (FormatInvalidation) -> Void
    ) {
        self.packetHandler = packetHandler
        self.inputFactory = inputFactory
        self.fingerprintReader = fingerprintReader
        self.installsHardwareListeners = installsHardwareListeners
        self.onFormatInvalidated = onFormatInvalidated
    }

    deinit {
        let input = self.input
        let gate = self.packetGate
        let registrations = self.listenerRegistrations
        let listenerQueue = self.listenerQueue
        let generation = self.generation
        self.lifecycleQueue.async {
            gate?.retire()
            Self.removeListeners(registrations, queue: listenerQueue)
            if registrations.isEmpty == false {
                listenerQueue.sync {}
                Self.log(
                    "Direct capture listener drain generation=\(generation) " +
                        "count=\(registrations.count) reason=controller_deinit",
                    level: .debug
                )
            }
            _ = input?.invalidate()
        }
    }

    var snapshot: Snapshot {
        self.snapshotLock.lock()
        defer { self.snapshotLock.unlock() }
        return self.storedSnapshot
    }

    func resolveDevice(
        selection: DirectCoreAudioDeviceSelection,
        reason: String
    ) async throws -> AudioDevice.Device {
        try await withCheckedThrowingContinuation { continuation in
            self.lifecycleQueue.async {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let device: AudioDevice.Device?
                switch selection {
                case .systemDefault:
                    device = AudioDevice.getDefaultInputDevice()
                        .flatMap { AudioDevice.isInputDeviceUsable($0) ? $0 : nil }
                case let .preferredUID(uid):
                    if let preferredDevice = AudioDevice.getInputDevice(byUID: uid),
                       AudioDevice.isInputDeviceUsable(preferredDevice)
                    {
                        device = preferredDevice
                    } else {
                        // Let ASRService retry the next app-priority device. Falling back
                        // here would silently bypass the user's order during a HAL race.
                        device = nil
                    }
                }
                guard let device else {
                    continuation.resume(
                        throwing: Self.error(
                            "No input device is available for \(selection)."
                        )
                    )
                    return
                }
                Self.log(
                    "Direct capture device resolved off-main reason=\(reason) " +
                        "device='\(device.name)' id=\(device.id) " +
                        "elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))",
                    level: .info
                )
                continuation.resume(returning: device)
            }
        }
    }

    func prepare(
        deviceID: AudioObjectID,
        deviceName: String,
        reason: String
    ) async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.lifecycleQueue.async {
                do {
                    try continuation.resume(
                        returning: self.prepareLocked(
                            deviceID: deviceID,
                            deviceName: deviceName,
                            reason: reason
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start(
        deviceID: AudioObjectID,
        deviceName: String,
        reason: String
    ) async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.lifecycleQueue.async {
                do {
                    guard self.isShutDown == false else {
                        throw Self.error("Direct Core Audio lifecycle is shut down.")
                    }
                    var prepared = try self.prepareLocked(
                        deviceID: deviceID,
                        deviceName: deviceName,
                        reason: reason
                    )
                    guard let input = self.input else {
                        throw Self.error("Direct Core Audio input was not prepared.")
                    }

                    let validationStartedAt = ProcessInfo.processInfo.systemUptime
                    let currentFingerprint = try self.fingerprintReader(deviceID)
                    if currentFingerprint != input.formatFingerprint {
                        Self.log(
                            "Direct capture fingerprint changed before start; rebuilding " +
                                "generation=\(prepared.generation) old={\(input.formatFingerprint.logDescription)} " +
                                "new={\(currentFingerprint.logDescription)}",
                            level: .warning
                        )
                        self.invalidateLocked(reason: "pre_start_fingerprint_changed")
                        prepared = try self.prepareLocked(
                            deviceID: deviceID,
                            deviceName: deviceName,
                            reason: "pre_start_fingerprint_changed"
                        )
                    }

                    guard let validatedInput = self.input else {
                        throw Self.error("Direct Core Audio input disappeared before start.")
                    }
                    if validatedInput.isRunning {
                        let runningFingerprint = try self.fingerprintReader(deviceID)
                        guard runningFingerprint == validatedInput.formatFingerprint,
                              validatedInput.openPacketGateIfClean()
                        else {
                            throw Self.error(
                                "Direct Core Audio format changed while reusing running input generation " +
                                    "\(self.generation)."
                            )
                        }
                        self.publishSnapshot(
                            phase: .running,
                            input: validatedInput,
                            fingerprint: validatedInput.formatFingerprint
                        )
                        Self.log(
                            "Direct capture start reused running input generation=\(self.generation) " +
                                "device='\(deviceName)'",
                            level: .debug
                        )
                        continuation.resume(returning: self.snapshot)
                        return
                    }
                    self.publishSnapshot(
                        phase: .starting,
                        input: validatedInput,
                        fingerprint: validatedInput.formatFingerprint
                    )
                    let startStartedAt = ProcessInfo.processInfo.systemUptime
                    Self.log(
                        "Direct capture start begin generation=\(self.generation) " +
                            "device='\(deviceName)' validationMs=" +
                            "\(Self.elapsedMilliseconds(since: validationStartedAt))",
                        level: .info
                    )
                    try validatedInput.start()
                    let fingerprintAfterStart = try self.fingerprintReader(deviceID)
                    guard fingerprintAfterStart == validatedInput.formatFingerprint,
                          validatedInput.openPacketGateIfClean()
                    else {
                        throw Self.error(
                            "Direct Core Audio format changed while starting generation " +
                                "\(self.generation)."
                        )
                    }
                    self.publishSnapshot(
                        phase: .running,
                        input: validatedInput,
                        fingerprint: validatedInput.formatFingerprint
                    )
                    Self.log(
                        "Direct capture start end generation=\(self.generation) " +
                            "elapsedMs=\(Self.elapsedMilliseconds(since: startStartedAt)) " +
                            "fingerprint={\(validatedInput.formatFingerprint.logDescription)}",
                        level: .info
                    )
                    continuation.resume(returning: self.snapshot)
                } catch {
                    self.publishSnapshot(
                        phase: .failed,
                        input: self.input,
                        fingerprint: self.input?.formatFingerprint
                    )
                    self.invalidateLocked(reason: "start_failed")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(retainPrepared: Bool, reason: String) async -> StopReport {
        await withCheckedContinuation { continuation in
            self.lifecycleQueue.async {
                guard let input = self.input else {
                    continuation.resume(
                        returning: StopReport(
                            status: noErr,
                            droppedPackets: 0,
                            retainedPreparedCapture: false
                        )
                    )
                    return
                }

                let startedAt = ProcessInfo.processInfo.systemUptime
                self.publishSnapshot(
                    phase: .stopping,
                    input: input,
                    fingerprint: input.formatFingerprint
                )
                Self.log(
                    "Direct capture stop begin generation=\(self.generation) " +
                        "reason=\(reason) retainPrepared=\(retainPrepared)",
                    level: .info
                )
                let status = input.stop()
                let droppedPackets = input.droppedPacketCount
                if status != noErr {
                    self.isPoisoned = true
                    _ = self.invalidateLocked(reason: "stop_failed:\(reason)")
                    self.publishSnapshot(
                        phase: .failed,
                        input: nil,
                        fingerprint: nil
                    )
                } else if retainPrepared, self.isShutDown == false {
                    self.publishSnapshot(
                        phase: .prepared,
                        input: input,
                        fingerprint: input.formatFingerprint
                    )
                } else {
                    self.invalidateLocked(reason: reason)
                }
                Self.log(
                    "Direct capture stop end generation=\(self.generation) " +
                        "elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) " +
                        "status=\(status) droppedPackets=\(droppedPackets) " +
                        "retained=\(retainPrepared && self.input != nil)",
                    level: .info
                )
                continuation.resume(
                    returning: StopReport(
                        status: status,
                        droppedPackets: droppedPackets,
                        retainedPreparedCapture: retainPrepared && self.input != nil
                    )
                )
            }
        }
    }

    func invalidate(reason: String) async {
        await withCheckedContinuation { continuation in
            self.lifecycleQueue.async {
                _ = self.invalidateLocked(reason: reason)
                continuation.resume()
            }
        }
    }

    func shutdown(reason: String) async {
        await withCheckedContinuation { continuation in
            self.lifecycleQueue.async {
                guard self.isShutDown == false else {
                    continuation.resume()
                    return
                }
                self.isShutDown = true
                _ = self.invalidateLocked(reason: reason)
                self.publishSnapshot(phase: .shutDown, input: nil, fingerprint: nil)
                continuation.resume()
            }
        }
    }

    private func prepareLocked(
        deviceID: AudioObjectID,
        deviceName: String,
        reason: String
    ) throws -> Snapshot {
        guard self.isShutDown == false else {
            throw Self.error("Direct Core Audio lifecycle is shut down.")
        }
        guard self.isPoisoned == false else {
            throw Self.error(
                "Direct Core Audio lifecycle is poisoned by a failed hardware teardown; restart the app."
            )
        }

        let currentFingerprint = try self.fingerprintReader(deviceID)
        if let input = self.input,
           input.deviceID == deviceID,
           input.formatFingerprint == currentFingerprint
        {
            self.inputDeviceName = deviceName
            self.publishSnapshot(
                phase: input.isRunning ? .running : .prepared,
                input: input,
                fingerprint: input.formatFingerprint
            )
            Self.log(
                "Direct capture prepare reuse generation=\(self.generation) " +
                    "reason=\(reason) fingerprint={\(currentFingerprint.logDescription)}",
                level: .debug
            )
            return self.snapshot
        }

        if self.input != nil {
            let invalidationStatus = self.invalidateLocked(
                reason: "prepare_replacement:\(reason)"
            )
            guard invalidationStatus == noErr, self.isPoisoned == false else {
                throw Self.error(
                    "Direct Core Audio lifecycle is poisoned after replacement teardown failed " +
                        "with status \(invalidationStatus); restart the app."
                )
            }
        }

        self.generation &+= 1
        let generation = self.generation
        self.inputDeviceName = deviceName
        self.publishSnapshot(
            phase: .preparing,
            input: nil,
            fingerprint: currentFingerprint,
            deviceID: deviceID
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.log(
            "Direct capture prepare begin generation=\(generation) " +
                "device='\(deviceName)' reason=\(reason) " +
                "fingerprint={\(currentFingerprint.logDescription)}",
            level: .info
        )

        let gate = DirectCoreAudioPacketGate()
        let downstreamHandler = self.packetHandler
        let input: any DirectCoreAudioInputControlling
        do {
            input = try self.inputFactory(deviceID) { samples, frameCount, sampleRate, inputHostTime, inputSampleTime in
                gate.withAcceptedPacket {
                    downstreamHandler(
                        samples,
                        frameCount,
                        sampleRate,
                        inputHostTime,
                        inputSampleTime
                    )
                }
            }
        } catch {
            gate.retire()
            self.publishSnapshot(phase: .failed, input: nil, fingerprint: currentFingerprint)
            throw error
        }
        guard input.formatFingerprint == currentFingerprint else {
            gate.retire()
            _ = input.invalidate()
            throw Self.error(
                "Direct Core Audio format changed while preparing generation \(generation)."
            )
        }

        self.input = input
        self.packetGate = gate
        do {
            if self.installsHardwareListeners {
                try self.installFormatListenersLocked(
                    fingerprint: input.formatFingerprint,
                    generation: generation,
                    input: input
                )
            }
            let fingerprintAfterListeners = try self.fingerprintReader(deviceID)
            guard fingerprintAfterListeners == input.formatFingerprint else {
                throw Self.error(
                    "Direct Core Audio format changed while installing listeners."
                )
            }
        } catch {
            _ = self.invalidateLocked(reason: "prepare_validation_failed")
            throw error
        }

        self.publishSnapshot(
            phase: .prepared,
            input: input,
            fingerprint: input.formatFingerprint
        )
        Self.log(
            "Direct capture prepare end generation=\(generation) " +
                "elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) " +
                "fingerprint={\(input.formatFingerprint.logDescription)}",
            level: .info
        )
        return self.snapshot
    }

    @discardableResult
    private func invalidateLocked(
        reason: String,
        allowStoppedHardwareReplacement: Bool = false
    ) -> OSStatus {
        guard self.input != nil || self.listenerRegistrations.isEmpty == false else {
            self.inputDeviceName = nil
            let phase: Phase = self.isShutDown ? .shutDown : (self.isPoisoned ? .failed : .empty)
            self.publishSnapshot(phase: phase, input: nil, fingerprint: nil)
            return noErr
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let input = self.input
        self.publishSnapshot(
            phase: .invalidating,
            input: input,
            fingerprint: input?.formatFingerprint
        )
        Self.log(
            "Direct capture invalidate begin generation=\(self.generation) reason=\(reason)",
            level: .info
        )
        self.packetGate?.retire()
        self.packetGate = nil
        let listenerCount = self.listenerRegistrations.count
        Self.removeListeners(self.listenerRegistrations, queue: self.listenerQueue)
        self.listenerRegistrations.removeAll(keepingCapacity: false)
        if listenerCount > 0 {
            let listenerDrainStartedAt = ProcessInfo.processInfo.systemUptime
            // Removal does not guarantee that an already-dispatched listener
            // block has returned. Drain it before the input can destroy the C
            // capture state accessed by markFormatDirty() and isRunning.
            self.listenerQueue.sync {}
            Self.log(
                "Direct capture listener drain generation=\(self.generation) " +
                    "count=\(listenerCount) " +
                    "elapsedMs=\(Self.elapsedMilliseconds(since: listenerDrainStartedAt))",
                level: .debug
            )
        }
        let status = input?.invalidate() ?? noErr
        let stoppedHardwareWasReported =
            self.consumeStoppedHardwareNotification(generation: self.generation)
        let replacementAllowed =
            allowStoppedHardwareReplacement || stoppedHardwareWasReported
        if status != noErr {
            if replacementAllowed {
                Self.log(
                    "Direct capture stale hardware teardown generation=\(self.generation) " +
                        "status=\(status); callback context quarantined, replacement allowed",
                    level: .warning
                )
            } else {
                self.isPoisoned = true
                Self.log(
                    "Direct capture teardown failed generation=\(self.generation) " +
                        "status=\(status); lifecycle poisoned and callback context quarantined",
                    level: .warning
                )
            }
        }
        self.input = nil
        self.inputDeviceName = nil
        let finalPhase: Phase =
            self.isShutDown ? .shutDown : (self.isPoisoned ? .failed : .empty)
        self.publishSnapshot(
            phase: finalPhase,
            input: nil,
            fingerprint: nil
        )
        Self.log(
            "Direct capture invalidate end generation=\(self.generation) " +
                "elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) reason=\(reason)",
            level: .info
        )
        return status
    }

    private func installFormatListenersLocked(
        fingerprint: DirectCoreAudioFormatFingerprint,
        generation: UInt64,
        input: any DirectCoreAudioInputControlling
    ) throws {
        try self.addListenerLocked(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyServiceRestarted,
            scope: kAudioObjectPropertyScopeGlobal,
            name: "audio_service_restarted",
            generation: generation,
            policy: .requiredNotification,
            input: input
        )

        let deviceSelectors: [
            (AudioObjectPropertySelector, AudioObjectPropertyScope, String, ListenerPolicy)
        ] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, "device_is_alive", .required),
            (kAudioDevicePropertyDeviceHasChanged, kAudioObjectPropertyScopeGlobal, "device_changed", .optional),
            (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, "streams", .required),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput, "stream_configuration", .required),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "nominal_sample_rate", .required),
            (kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, "buffer_frame_size", .required),
            (kAudioDevicePropertyUsesVariableBufferFrameSizes, kAudioObjectPropertyScopeGlobal, "variable_buffer_frame_size", .optional),
            (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput, "data_source", .optional),
            (kAudioDevicePropertyIOStoppedAbnormally, kAudioObjectPropertyScopeGlobal, "io_stopped_abnormally", .requiredNotification),
        ]
        for (selector, scope, name, policy) in deviceSelectors {
            try self.addListenerLocked(
                objectID: fingerprint.deviceID,
                selector: selector,
                scope: scope,
                name: name,
                generation: generation,
                policy: policy,
                input: input
            )
        }

        let streamSelectors: [(AudioObjectPropertySelector, String, ListenerPolicy)] = [
            (kAudioStreamPropertyVirtualFormat, "virtual_format", .required),
            (kAudioStreamPropertyPhysicalFormat, "physical_format", .optional),
            (kAudioStreamPropertyIsActive, "stream_is_active", .required),
        ]
        for (selector, name, policy) in streamSelectors {
            try self.addListenerLocked(
                objectID: fingerprint.streamID,
                selector: selector,
                scope: kAudioObjectPropertyScopeGlobal,
                name: name,
                generation: generation,
                policy: policy,
                input: input
            )
        }
    }

    private func addListenerLocked(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        name: String,
        generation: UInt64,
        policy: ListenerPolicy,
        input: any DirectCoreAudioInputControlling
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if policy != .requiredNotification,
           AudioObjectHasProperty(objectID, &address) == false
        {
            if policy == .required {
                throw Self.error(
                    "Required Core Audio listener property is unavailable: \(name)."
                )
            }
            Self.log(
                "Direct capture listener unavailable generation=\(generation) property=\(name)",
                level: .debug
            )
            return
        }

        let invalidationHandler = self.onFormatInvalidated
        let block: AudioObjectPropertyListenerBlock = { [weak self, weak input] listenerObjectID, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callbackBegin,
                    owner: .directCoreAudio,
                    objectID: listenerObjectID,
                    selector: selector,
                    scope: scope,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .dedicatedDelivery,
                    generation: generation
                )
                defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .directCoreAudio, objectID: listenerObjectID, selector: selector, scope: scope, element: kAudioObjectPropertyElementMain, queueRole: .dedicatedDelivery, generation: generation) }
            #endif
            let deviceIsAlive =
                name == "device_is_alive"
                    ? Self.readDeviceLiveness(objectID: listenerObjectID)
                    : nil
            let hardwareIsKnownStopped =
                name == "audio_service_restarted" ||
                name == "io_stopped_abnormally" ||
                (name == "device_is_alive" && deviceIsAlive != true)
            if hardwareIsKnownStopped {
                self?.recordStoppedHardwareNotification(generation: generation)
            }
            if name == "device_is_alive" {
                Self.log(
                    "Direct capture liveness notification generation=\(generation) " +
                        "device=\(listenerObjectID) " +
                        "alive=\(deviceIsAlive.map(String.init) ?? "unreadable") " +
                        "knownStopped=\(hardwareIsKnownStopped)",
                    level: hardwareIsKnownStopped ? .warning : .info
                )
            }
            input?.markFormatDirty()
            invalidationHandler(
                FormatInvalidation(
                    generation: generation,
                    deviceID: input?.deviceID ?? kAudioObjectUnknown,
                    reason: name,
                    wasRunning: input?.isRunning ?? false
                )
            )
            self?.lifecycleQueue.async { [weak self] in
                self?.handleFormatInvalidationLocked(
                    generation: generation,
                    reason: name
                )
            }
        }
        #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .directCoreAudio, objectID: objectID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, generation: generation)
        #endif
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            self.listenerQueue,
            block
        )
        #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .directCoreAudio, objectID: objectID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status, generation: generation)
        #endif
        guard status == noErr else {
            if policy != .optional {
                throw Self.error(
                    "Failed to register required Core Audio listener \(name) " +
                        "(OSStatus \(status))."
                )
            }
            Self.log(
                "Direct capture listener registration failed generation=\(generation) " +
                    "property=\(name) status=\(status)",
                level: .warning
            )
            return
        }
        self.listenerRegistrations.append(
            ListenerRegistration(objectID: objectID, address: address, block: block)
        )
    }

    private func handleFormatInvalidationLocked(generation: UInt64, reason: String) {
        guard generation == self.generation else {
            _ = self.consumeStoppedHardwareNotification(generation: generation)
            return
        }

        let hardwareIsKnownStopped =
            self.consumeStoppedHardwareNotification(generation: generation)
        guard let input = self.input else {
            if hardwareIsKnownStopped, self.isPoisoned {
                self.isPoisoned = false
                self.publishSnapshot(phase: .empty, input: nil, fingerprint: nil)
                Self.log(
                    "Direct capture cleared teardown poison generation=\(generation) " +
                        "after delayed \(reason) notification",
                    level: .warning
                )
            }
            return
        }

        let wasRunning = input.isRunning
        Self.log(
            "Direct capture format invalidated generation=\(generation) " +
                "reason=\(reason) wasRunning=\(wasRunning) " +
                "fingerprint={\(input.formatFingerprint.logDescription)}",
            level: .warning
        )
        self.invalidateLocked(
            reason: "format_listener:\(reason)",
            allowStoppedHardwareReplacement: hardwareIsKnownStopped
        )
    }

    private func recordStoppedHardwareNotification(generation: UInt64) {
        self.stoppedHardwareLock.withLock {
            self.stoppedHardwareGenerations.insert(generation)
        }
    }

    private func consumeStoppedHardwareNotification(generation: UInt64) -> Bool {
        self.stoppedHardwareLock.withLock {
            self.stoppedHardwareGenerations.remove(generation) != nil
        }
    }

    private static func readDeviceLiveness(objectID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        #if DEBUG
            AudioTopologyDiagnostics.record(.halQueryBegin, owner: .directCoreAudio, objectID: objectID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedDelivery, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &isAlive
        )
        #if DEBUG
            AudioTopologyDiagnostics.record(.halQueryEnd, owner: .directCoreAudio, objectID: objectID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedDelivery, phase: .listener, status: status)
        #endif
        guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size) else {
            return nil
        }
        return isAlive != 0
    }

    #if DEBUG
    func simulateStoppedHardwareNotificationForTesting(
        generation: UInt64,
        reason: String
    ) async {
        self.recordStoppedHardwareNotification(generation: generation)
        await withCheckedContinuation { continuation in
            self.lifecycleQueue.async {
                self.handleFormatInvalidationLocked(
                    generation: generation,
                    reason: reason
                )
                continuation.resume()
            }
        }
    }
    #endif

    private func publishSnapshot(
        phase: Phase,
        input: (any DirectCoreAudioInputControlling)?,
        fingerprint: DirectCoreAudioFormatFingerprint?,
        deviceID: AudioObjectID? = nil
    ) {
        let snapshot = Snapshot(
            phase: phase,
            generation: self.generation,
            deviceID: input?.deviceID ?? deviceID,
            deviceName: self.inputDeviceName,
            sampleRate: input?.sampleRate ?? fingerprint?.virtualFormat.sampleRate,
            bufferFrameSize: input?.hardwareBufferFrameSize ?? fingerprint?.bufferFrameSize,
            fingerprint: fingerprint
        )
        self.snapshotLock.lock()
        self.storedSnapshot = snapshot
        self.snapshotLock.unlock()
    }

    private static func removeListeners(
        _ registrations: [ListenerRegistration],
        queue: DispatchQueue
    ) {
        for registration in registrations {
            var address = registration.address
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .directCoreAudio, objectID: registration.objectID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
            #endif
            let status = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                queue,
                registration.block
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .directCoreAudio, objectID: registration.objectID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
            #endif
            if status != noErr, status != kAudioHardwareBadObjectError {
                Self.log(
                    "Direct capture listener removal failed object=\(registration.objectID) " +
                        "selector=\(address.mSelector) status=\(status)",
                    level: .warning
                )
            }
        }
    }

    private static func log(_ message: String, level: LifecycleLogLevel) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let line = "[\(level.rawValue)] [DirectCoreAudioLifecycle] " +
            "t=\(String(format: "%.6f", uptime)) \(message)"
        FileLogger.shared.append(line: line)
        print(line)
    }

    private static func elapsedMilliseconds(since startedAt: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "DirectCoreAudioLifecycle",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
