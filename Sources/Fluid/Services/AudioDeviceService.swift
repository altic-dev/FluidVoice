//
//  AudioDeviceService.swift
//  fluid
//
//  CoreAudio device management and monitoring
//

import Combine
import CoreAudio
import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - Audio Device Manager

nonisolated enum AudioDevice {
    enum LivenessDiagnosticsOwner: Sendable {
        case audioHardwareObserver
        case asrService

        #if DEBUG
        var traceOwner: AudioTopologyTraceOwner {
            switch self {
            case .audioHardwareObserver: .audioHardwareObserver
            case .asrService: .asrDeviceList
            }
        }
        #endif
    }

    struct Device: Identifiable, Hashable, Sendable {
        static let externalMicrophoneDataSourceID: UInt32 = 0x656d6963 // 'emic'

        let id: AudioObjectID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
        let transportType: UInt32
        let inputDataSourceID: UInt32?
        let isAlive: Bool

        init(
            id: AudioObjectID,
            uid: String,
            name: String,
            hasInput: Bool,
            hasOutput: Bool,
            transportType: UInt32 = kAudioDeviceTransportTypeUnknown,
            inputDataSourceID: UInt32? = nil,
            isAlive: Bool = true
        ) {
            self.id = id
            self.uid = uid
            self.name = name
            self.hasInput = hasInput
            self.hasOutput = hasOutput
            self.transportType = transportType
            self.inputDataSourceID = inputDataSourceID
            self.isAlive = isAlive
        }

        var isBluetooth: Bool {
            self.transportType == kAudioDeviceTransportTypeBluetooth ||
                self.transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var isBuiltIn: Bool {
            self.transportType == kAudioDeviceTransportTypeBuiltIn
        }

        /// Analog headsets use the Mac's built-in audio transport, but Core Audio
        /// identifies their selected input source as an external microphone.
        var isUnavailableWhenClamshellClosed: Bool {
            self.isBuiltIn && self.inputDataSourceID != Self.externalMicrophoneDataSourceID
        }
    }

    private struct InputLivenessKey: Hashable {
        let id: AudioObjectID
        let uid: String
    }

    private final class InputLivenessCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [InputLivenessKey: Bool] = [:]

        func snapshot() -> [InputLivenessKey: Bool] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }

        func replace(with values: [InputLivenessKey: Bool]) {
            self.lock.lock()
            self.values = values
            self.lock.unlock()
        }

        func update(deviceID: AudioObjectID, isAlive: Bool) {
            self.lock.lock()
            let matchingKeys = self.values.keys.filter { $0.id == deviceID }
            for key in matchingKeys {
                self.values[key] = isAlive
            }
            self.lock.unlock()
        }
    }

    private static let inputLivenessCache = InputLivenessCache()

    static func listAllDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        if status != noErr || dataSize == 0 {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = deviceIDs.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        if status != noErr {
            return []
        }

        let cachedInputLiveness = self.inputLivenessCache.snapshot()
        var devices: [Device] = []
        devices.reserveCapacity(deviceIDs.count)

        for devId in deviceIDs {
            let name = self.getStringProperty(devId, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown"
            let uid = self.getStringProperty(devId, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) ?? ""
            let hasIn = self.hasChannels(devId, scope: kAudioObjectPropertyScopeInput)
            let hasOut = self.hasChannels(devId, scope: kAudioObjectPropertyScopeOutput)
            let transportType = self.getUInt32Property(
                devId,
                selector: kAudioDevicePropertyTransportType,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? kAudioDeviceTransportTypeUnknown
            let inputDataSourceID = hasIn ? self.getUInt32Property(
                devId,
                selector: kAudioDevicePropertyDataSource,
                scope: kAudioObjectPropertyScopeInput
            ) : nil
            devices.append(
                Device(
                    id: devId,
                    uid: uid,
                    name: name,
                    hasInput: hasIn,
                    hasOutput: hasOut,
                    transportType: transportType,
                    inputDataSourceID: inputDataSourceID,
                    isAlive: cachedInputLiveness[
                        InputLivenessKey(id: devId, uid: uid)
                    ] ?? true
                )
            )
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func listInputDevices() -> [Device] {
        return self.listAllDevices().filter { $0.hasInput }
    }

    /// Refreshes the HAL liveness snapshot. Call only from an existing background
    /// hardware-refresh path; UI and capture selection consume the cached value.
    static func listInputDevicesRefreshingLiveness(
        diagnosticsOwner: LivenessDiagnosticsOwner = .audioHardwareObserver
    ) -> [Device] {
        let devices = self.listInputDevices()
        let liveness = Dictionary(
            uniqueKeysWithValues: devices.map { device in
                (
                    InputLivenessKey(id: device.id, uid: device.uid),
                    self.queryInputDeviceLiveness(device.id, diagnosticsOwner: diagnosticsOwner)
                )
            }
        )
        self.inputLivenessCache.replace(with: liveness)
        return devices.map { device in
            Device(
                id: device.id,
                uid: device.uid,
                name: device.name,
                hasInput: device.hasInput,
                hasOutput: device.hasOutput,
                transportType: device.transportType,
                inputDataSourceID: device.inputDataSourceID,
                isAlive: liveness[InputLivenessKey(id: device.id, uid: device.uid)] ?? true
            )
        }
    }

    /// Refreshes one monitored device without blocking the listener's main queue.
    /// Callers must invoke this from a background hardware-refresh path.
    static func refreshInputDeviceLiveness(
        deviceID: AudioObjectID,
        diagnosticsOwner: LivenessDiagnosticsOwner = .audioHardwareObserver
    ) -> Bool {
        let isAlive = self.queryInputDeviceLiveness(deviceID, diagnosticsOwner: diagnosticsOwner)
        self.inputLivenessCache.update(deviceID: deviceID, isAlive: isAlive)
        return isAlive
    }

    static func listOutputDevices() -> [Device] {
        return self.listAllDevices().filter { $0.hasOutput }
    }

    static func getDefaultInputDevice() -> Device? {
        self.getDefaultInputDevice(from: self.listAllDevices())
    }

    static func getDefaultInputDevice(from devices: [Device]) -> Device? {
        guard let deviceID: AudioObjectID = getDefaultDeviceId(
            selector: kAudioHardwarePropertyDefaultInputDevice
        ) else { return nil }
        return devices.first { $0.id == deviceID }
    }

    static func getDefaultOutputDevice() -> Device? {
        guard let devId: AudioObjectID = getDefaultDeviceId(selector: kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return self.listAllDevices().first { $0.id == devId }
    }

    @discardableResult
    static func setDefaultInputDevice(uid: String) -> Bool {
        guard let device = listInputDevices().first(where: { $0.uid == uid }) else { return false }
        return self.setDefaultDeviceId(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    @discardableResult
    static func setDefaultOutputDevice(uid: String) -> Bool {
        guard let device = listOutputDevices().first(where: { $0.uid == uid }) else { return false }
        return self.setDefaultDeviceId(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Get input device by UID without affecting system settings
    static func getInputDevice(byUID uid: String) -> Device? {
        return self.listInputDevices().first { $0.uid == uid }
    }

    /// Reads the liveness value captured by the latest background hardware refresh.
    static func isInputDeviceAlive(_ device: Device) -> Bool {
        device.isAlive
    }

    /// Core Audio may continue enumerating an input after it has stopped being usable.
    /// Fail open when HAL cannot answer so unusual and virtual devices still work.
    private static func queryInputDeviceLiveness(
        _ deviceID: AudioObjectID,
        diagnosticsOwner: LivenessDiagnosticsOwner
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 1
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        #if DEBUG
            AudioTopologyDiagnostics.record(
                .halQueryBegin,
                owner: diagnosticsOwner.traceOwner,
                objectID: deviceID,
                selector: address.mSelector,
                scope: address.mScope,
                element: address.mElement,
                queueRole: .dedicatedControl,
                phase: .listener
            )
        #endif
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        #if DEBUG
            AudioTopologyDiagnostics.record(
                .halQueryEnd,
                owner: diagnosticsOwner.traceOwner,
                objectID: deviceID,
                selector: address.mSelector,
                scope: address.mScope,
                element: address.mElement,
                queueRole: .dedicatedControl,
                phase: .listener,
                status: status
            )
        #endif
        return status != noErr || value != 0
    }

    /// The built-in microphone remains enumerated and may still report itself
    /// alive while a MacBook is closed. Treat it as unavailable in that state,
    /// while leaving external and virtual inputs eligible.
    static func isInputDeviceUsable(_ device: Device) -> Bool {
        self.isInputDeviceAlive(device) &&
            (device.isUnavailableWhenClamshellClosed == false || ClamshellState.isClosed == false)
    }

    /// Get output device by UID without affecting system settings
    static func getOutputDevice(byUID uid: String) -> Device? {
        return self.listOutputDevices().first { $0.uid == uid }
    }

    /// Get device AudioObjectID from UID
    static func getDeviceId(forUID uid: String) -> AudioObjectID? {
        return self.listAllDevices().first { $0.uid == uid }?.id
    }

    private static func getDefaultDeviceId(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devId = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devId
        )
        return status == noErr ? devId : nil
    }

    private static func setDefaultDeviceId(_ devId: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDevId = devId
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &mutableDevId
        )
        return status == noErr
    }

    private static func getStringProperty(
        _ devId: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        // Use Unmanaged to safely bridge the CFTypeRef-style output parameter.
        // CoreAudio returns a +1 retained CFString - use takeRetainedValue() to transfer ownership
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func getUInt32Property(
        _ devId: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    /// 'hdpn' — kAudioDevicePropertyDataSource's headphones value, output scope.
    private static let headphonesDataSource: UInt32 = 0x6864_706E

    static func outputDataSourceIsHeadphones(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return true }
        var dataSource: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &dataSource)
        guard status == noErr else { return true }
        return dataSource == Self.headphonesDataSource
    }

    private static func hasChannels(_ devId: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(devId, &address, 0, nil, &dataSize)
        if status != noErr || dataSize == 0 {
            return false
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }

        status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, rawPtr)
        if status != noErr {
            return false
        }

        let ablPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        var channelCount = 0
        for buffer in buffers {
            channelCount += Int(buffer.mNumberChannels)
        }
        return channelCount > 0
    }
}

nonisolated enum ClamshellState {
    static var isClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        let property = IORegistryEntryCreateCFProperty(
            rootDomain,
            kAppleClamshellStateKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return (property as? NSNumber)?.boolValue ?? false
    }
}

extension Notification.Name {
    static let clamshellStateDidChange = Notification.Name("ClamshellStateDidChange")
    static let inputDeviceAvailabilityDidChange = Notification.Name("InputDeviceAvailabilityDidChange")
}

// MARK: - Audio Hardware Observer

/// Production policy for `AudioHardwareObserver`'s broad per-input `DeviceIsAlive` ledger only.
/// An aggregate device is a Core Audio *composition* of other (physical and/or virtual) devices,
/// and VPIO capture creates and tears down transient aggregates repeatedly across meeting/dictation
/// start and stop. In a production-shaped controlled run, excluding only aggregate membership from
/// this observer's broad liveness ledger passed normal dictation and three meeting cycles while the
/// normal AVFoundation catalog and all other transports remained active. This is the narrowest
/// empirically validated mitigation for the strongest isolated inducing condition; it is not proof
/// of Apple's complete private HAL wait graph. Excluding aggregate-transport inputs from the broad
/// ledger removes that duplicate observation during teardown; every other transport
/// (physical, virtual, or unknown) keeps its current liveness monitoring unchanged. This is
/// unconditional production behavior — no environment flag gates it — and must stay reachable
/// from Release builds.
nonisolated enum AggregateInputLivenessLedgerPolicy {
    static func permitsBroadLedgerMembership(transportType: UInt32) -> Bool {
        transportType != kAudioDeviceTransportTypeAggregate
    }
}

#if DEBUG
    /// Prior Phase-0 diagnostic switch, broader than the production aggregate exclusion above
    /// (it also drops virtual and unknown transports). Kept for future isolation experiments;
    /// it is not part of the shipped policy and stays opt-in behind an environment flag. It
    /// deliberately classifies from the already captured off-main device snapshot, so the
    /// experiment does not add a Core Audio query during reconciliation.
    nonisolated enum InputLivenessLedgerIsolationPolicy {
        static func permitsListenerForTransientIsolation(transportType: UInt32) -> Bool {
            switch transportType {
            case kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeVirtual,
                 kAudioDeviceTransportTypeUnknown:
                false
            default:
                true
            }
        }
    }
#endif

/// Process-wide execution boundary for app-owned Core Audio property listeners.
///
/// Core Audio may synchronously wait for the listener delivery queue while it tears a device down.
/// Keeping delivery off main, and serializing add/remove calls on a different queue, prevents main/HAL
/// circular waits. Callers always await asynchronously; MainActor must never `sync` onto either queue.
nonisolated enum AudioTopologyListenerExecution {
    static let deliveryQueue = DispatchQueue(
        label: "com.fluidvoice.audio.topology-listener-delivery",
        qos: .userInitiated
    )

    private static let controlQueue = DispatchQueue(
        label: "com.fluidvoice.audio.topology-listener-control",
        qos: .userInitiated
    )

    /// Runs synchronous HAL catalog/property work away from MainActor and listener delivery.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.controlQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    static func add(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        token: @escaping AudioObjectPropertyListenerBlock
    ) async -> OSStatus {
        await withCheckedContinuation { continuation in
            Self.controlQueue.async {
                var mutableAddress = address
                continuation.resume(returning: AudioObjectAddPropertyListenerBlock(
                    objectID,
                    &mutableAddress,
                    Self.deliveryQueue,
                    token
                ))
            }
        }
    }

    static func remove(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        token: @escaping AudioObjectPropertyListenerBlock
    ) async -> OSStatus {
        await withCheckedContinuation { continuation in
            Self.controlQueue.async {
                var mutableAddress = address
                continuation.resume(returning: AudioObjectRemovePropertyListenerBlock(
                    objectID,
                    &mutableAddress,
                    Self.deliveryQueue,
                    token
                ))
            }
        }
    }

    static func isBenignRemovalStatus(_ status: OSStatus) -> Bool {
        status == noErr || status == kAudioHardwareBadObjectError
    }
}

nonisolated struct AudioInputAvailabilityListenerIdentity: Equatable {
    let deviceID: AudioObjectID
    let uid: String
    let epoch: UInt64
    let lifecycleGeneration: UInt64
}

/// Pure lifecycle rules for the asynchronous CoreAudio liveness-listener ledger.
/// Keeping these decisions independent of HAL makes the race cases deterministic in tests.
nonisolated enum AudioInputAvailabilityListenerPolicy {
    static func callbackIsCurrent(
        captured: AudioInputAvailabilityListenerIdentity,
        registered: AudioInputAvailabilityListenerIdentity?,
        installed: Bool
    ) -> Bool {
        installed && registered == captured
    }

    static func registrationNeedsReplacement(registeredUID: String?, desiredUID: String?) -> Bool {
        registeredUID != desiredUID
    }

    static func completionCanInstall(
        statusSucceeded: Bool,
        ownsPendingMarker: Bool,
        installed: Bool,
        capturedLifecycleGeneration: UInt64,
        currentLifecycleGeneration: UInt64,
        capturedUID: String,
        desiredUID: String?,
        reconciliationIsCurrent: Bool
    ) -> Bool {
        statusSucceeded
            && ownsPendingMarker
            && installed
            && capturedLifecycleGeneration == currentLifecycleGeneration
            && desiredUID == capturedUID
            && reconciliationIsCurrent
    }

    static func shouldRetryStaleCompletion(
        ownsPendingMarker: Bool,
        installed: Bool,
        capturedLifecycleGeneration: UInt64,
        currentLifecycleGeneration: UInt64,
        capturedUID: String,
        desiredUID: String?,
        hasRegistration: Bool,
        reconciliationIsStale: Bool
    ) -> Bool {
        ownsPendingMarker
            && installed
            && capturedLifecycleGeneration == currentLifecycleGeneration
            && desiredUID == capturedUID
            && !hasRegistration
            && reconciliationIsStale
    }
}

nonisolated enum AudioInputAvailabilityPolicy {
    static func hasAvailableInput(liveness: [Bool]) -> Bool {
        liveness.contains(true)
    }
}

final class AudioHardwareObserver: ObservableObject {
    private struct InputAvailabilityRegistration {
        let identity: AudioInputAvailabilityListenerIdentity
        let token: AudioObjectPropertyListenerBlock
    }

    private struct PendingInputAvailabilityRegistration: Equatable {
        let identity: AudioInputAvailabilityListenerIdentity
    }

    /// Incremented every time CoreAudio reports a hardware/default-device change.
    /// Using a simple `@Published` value avoids putting `AnyPublisher`/`SubscriptionView` generics into
    /// SwiftUI's root view type, which can trigger AttributeGraph metadata-instantiation crashes at launch.
    @Published private(set) var changeTick: UInt64 = 0
    @Published private(set) var inputAvailabilityTick: UInt64 = 0
    @Published private(set) var hasAvailableInputDevice = false

    private var installed: Bool = false
    private var devicesListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?
    private var inputAvailabilityRegistrations: [AudioObjectID: InputAvailabilityRegistration] = [:]
    private var pendingInputAvailabilityRegistrations: [AudioObjectID: PendingInputAvailabilityRegistration] = [:]
    private var desiredInputAvailabilityUIDs: [AudioObjectID: String] = [:]
    private var nextInputAvailabilityEpoch: UInt64 = 0
    private var inputAvailabilityRefreshGeneration: UInt64 = 0
    private var listenerLifecycleGeneration: UInt64 = 0
    private var registrationTask: Task<Void, Never>?
    private var trackedTopologyTasks: [UUID: Task<Void, Never>] = [:]
    private var topologyReconciliationSuspended = false
    private var topologyReconciliationDirty = false
    private var topologySuspensionGeneration: UInt64 = 0
    private var activeTopologySuspension: UInt64?
    private var registrationDeferredByTopologySuspension = false
    private var clamshellRootDomain: io_service_t = IO_OBJECT_NULL
    private var clamshellNotificationPort: IONotificationPortRef?
    private var clamshellNotification: io_object_t = IO_OBJECT_NULL
    private var lastClamshellClosed: Bool?

    init() {
        // IMPORTANT: Do NOT call register() here!
        // Calling AudioObjectAddPropertyListenerBlock during @StateObject init causes a race condition
        // with SwiftUI's AttributeGraph metadata processing, leading to EXC_BAD_ACCESS crashes.
        // Registration is deferred until startObserving() is called after app finishes launching.
    }

    /// Call this AFTER the app has finished launching to start observing audio hardware changes.
    /// This must be called from onAppear or later, never during init.
    func startObserving() {
        self.register()
    }

    /// Prevents this observer's catalog queries and per-device listener maintenance from
    /// overlapping a capture-backend transition. The returned generation owns the resume.
    func suspendTopologyReconciliation() async -> UInt64 {
        if let activeTopologySuspension {
            await self.drainTrackedTopologyWork()
            return activeTopologySuspension
        }
        self.topologySuspensionGeneration &+= 1
        let generation = self.topologySuspensionGeneration
        self.activeTopologySuspension = generation
        self.topologyReconciliationSuspended = true
        self.topologyReconciliationDirty = true
        self.inputAvailabilityRefreshGeneration &+= 1
        await self.drainTrackedTopologyWork()
        return generation
    }

    /// Resumes only the exact suspension owner and does not return until the single
    /// coalesced catalog/listener reconciliation has reached stable quiescence.
    func resumeTopologyReconciliation(_ generation: UInt64) async {
        guard self.activeTopologySuspension == generation else { return }
        self.topologyReconciliationSuspended = false
        self.topologyReconciliationDirty = false

        if self.registrationDeferredByTopologySuspension {
            self.registrationDeferredByTopologySuspension = false
            self.register()
        } else {
            self.refreshInputAvailabilityListeners()
        }
        await self.drainTrackedTopologyWork()
        guard self.activeTopologySuspension == generation else { return }
        self.activeTopologySuspension = nil
    }

    private func launchTrackedTopologyTask(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.trackedTopologyTasks.removeValue(forKey: id)
        }
        self.trackedTopologyTasks[id] = task
    }

    private func retainRegistrationTaskForDrain(_ task: Task<Void, Never>) {
        self.launchTrackedTopologyTask {
            await task.value
        }
    }

    private func drainTrackedTopologyWork() async {
        while true {
            if let registrationTask = self.registrationTask {
                await registrationTask.value
            }
            let tasks = Array(self.trackedTopologyTasks.values)
            for task in tasks { await task.value }
            // Drains any exact-token cleanup queued by a completion before it returned.
            await AudioTopologyListenerExecution.perform {}
            await Task.yield()
            if self.registrationTask == nil, self.trackedTopologyTasks.isEmpty { return }
        }
    }

    @MainActor
    func signalInputAvailabilityChanged() {
        self.inputAvailabilityTick &+= 1
    }

    func restartObservingAfterAudioServiceReset() {
        // Core Audio discards every previously registered listener when its
        // service resets, so the old tokens must not be removed or reused.
        self.listenerLifecycleGeneration &+= 1
        if let registrationTask = self.registrationTask {
            registrationTask.cancel()
            self.retainRegistrationTaskForDrain(registrationTask)
        }
        self.registrationTask = nil
        self.devicesListenerToken = nil
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.inputAvailabilityRegistrations.removeAll()
        self.pendingInputAvailabilityRegistrations.removeAll()
        self.desiredInputAvailabilityUIDs.removeAll()
        self.inputAvailabilityRefreshGeneration &+= 1
        self.installed = false
        if self.topologyReconciliationSuspended {
            self.registrationDeferredByTopologySuspension = true
            self.topologyReconciliationDirty = true
            self.changeTick &+= 1
            return
        }
        self.register()
        self.changeTick &+= 1
        if self.installed {
            DebugLogger.shared.warning(
                "Re-registered audio hardware observers after Core Audio service reset",
                source: "AudioHardwareObserver"
            )
        } else {
            DebugLogger.shared.error(
                "Failed to re-register audio hardware observers after Core Audio service reset",
                source: "AudioHardwareObserver"
            )
        }
    }

    deinit {
        unregister()
    }

    private func register() {
        guard self.topologyReconciliationSuspended == false else {
            self.registrationDeferredByTopologySuspension = true
            return
        }
        guard self.installed == false, self.registrationTask == nil else { return }
        self.listenerLifecycleGeneration &+= 1
        let generation = self.listenerLifecycleGeneration
        let addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let sys = AudioObjectID(kAudioObjectSystemObject)

        let devicesToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callbackBegin,
                    owner: .audioHardwareObserver,
                    objectID: sys,
                    selector: kAudioHardwarePropertyDevices,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .callbackCurrent,
                    generation: generation
                )
                defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .audioHardwareObserver, objectID: sys, selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation) }
            #endif
            DispatchQueue.main.async { [weak self] in
                guard let self, self.installed, self.listenerLifecycleGeneration == generation else { return }
                self.changeTick &+= 1
                self.refreshInputAvailabilityListeners()
            }
        }
        let defaultInToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callbackBegin,
                    owner: .audioHardwareObserver,
                    objectID: sys,
                    selector: kAudioHardwarePropertyDefaultInputDevice,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .callbackCurrent,
                    generation: generation
                )
                defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .audioHardwareObserver, objectID: sys, selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation) }
            #endif
            DispatchQueue.main.async { [weak self] in
                guard let self, self.installed, self.listenerLifecycleGeneration == generation else { return }
                self.inputAvailabilityTick &+= 1
            }
        }
        let defaultOutToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callbackBegin,
                    owner: .audioHardwareObserver,
                    objectID: sys,
                    selector: kAudioHardwarePropertyDefaultOutputDevice,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .callbackCurrent,
                    generation: generation
                )
                defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .audioHardwareObserver, objectID: sys, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation) }
            #endif
            DispatchQueue.main.async { [weak self] in
                guard let self, self.installed, self.listenerLifecycleGeneration == generation else { return }
                self.changeTick &+= 1
            }
        }

        self.registrationTask = Task { @MainActor [weak self] in
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .dedicatedControl, phase: .listener, generation: generation)
            #endif
            let devicesStatus = await AudioTopologyListenerExecution.add(objectID: sys, address: addrDevices, token: devicesToken)
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .dedicatedControl, phase: .listener, status: devicesStatus, generation: generation)
            #endif
            let defaultInStatus = Task.isCancelled
                ? kAudioHardwareUnspecifiedError
                : await AudioTopologyListenerExecution.add(objectID: sys, address: addrDefaultIn, token: defaultInToken)
            let defaultOutStatus = Task.isCancelled
                ? kAudioHardwareUnspecifiedError
                : await AudioTopologyListenerExecution.add(objectID: sys, address: addrDefaultOut, token: defaultOutToken)

            guard let self, self.listenerLifecycleGeneration == generation, !Task.isCancelled else {
                await Self.removeSuccessfulSystemListeners(
                    sys: sys,
                    registrations: [
                        (addrDevices, devicesToken, devicesStatus),
                        (addrDefaultIn, defaultInToken, defaultInStatus),
                        (addrDefaultOut, defaultOutToken, defaultOutStatus),
                    ],
                    generation: generation
                )
                return
            }
            self.registrationTask = nil
            guard devicesStatus == noErr, defaultInStatus == noErr, defaultOutStatus == noErr else {
                await Self.removeSuccessfulSystemListeners(
                    sys: sys,
                    registrations: [
                        (addrDevices, devicesToken, devicesStatus),
                        (addrDefaultIn, defaultInToken, defaultInStatus),
                        (addrDefaultOut, defaultOutToken, defaultOutStatus),
                    ],
                    generation: generation
                )
                return
            }
            self.devicesListenerToken = devicesToken
            self.defaultInputListenerToken = defaultInToken
            self.defaultOutputListenerToken = defaultOutToken
            self.installed = true
            self.refreshInputAvailabilityListeners()
            self.registerClamshellStateListener()
        }
    }

    private func unregister() {
        self.listenerLifecycleGeneration &+= 1
        if let registrationTask = self.registrationTask {
            registrationTask.cancel()
            self.retainRegistrationTaskForDrain(registrationTask)
        }
        self.registrationTask = nil
        let addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let sys = AudioObjectID(kAudioObjectSystemObject)
        let registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = [
            self.devicesListenerToken.map { (addrDevices, $0) },
            self.defaultInputListenerToken.map { (addrDefaultIn, $0) },
            self.defaultOutputListenerToken.map { (addrDefaultOut, $0) },
        ].compactMap { $0 }
        self.devicesListenerToken = nil
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.installed = false
        self.inputAvailabilityRefreshGeneration &+= 1
        self.removeInputAvailabilityListeners()
        self.unregisterClamshellStateListener()
        Task {
            for (address, token) in registrations {
                _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: address, token: token)
            }
        }
    }

    private nonisolated static func removeSuccessfulSystemListeners(
        sys: AudioObjectID,
        registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock, OSStatus)],
        generation: UInt64
    ) async {
        for (address, token, status) in registrations where status == noErr {
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, generation: generation)
            #endif
            let removalStatus = await AudioTopologyListenerExecution.remove(objectID: sys, address: address, token: token)
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: removalStatus, generation: generation)
            #endif
        }
    }

    private func refreshInputAvailabilityListeners() {
        guard self.topologyReconciliationSuspended == false else {
            self.topologyReconciliationDirty = true
            return
        }
        self.inputAvailabilityRefreshGeneration &+= 1
        let generation = self.inputAvailabilityRefreshGeneration
        self.launchTrackedTopologyTask { [weak self] in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .enumerationBegin,
                    owner: .audioHardwareObserver,
                    queueRole: .dedicatedControl,
                    phase: .listener,
                    generation: generation
                )
            #endif
            let devices = await AudioTopologyListenerExecution.perform {
                AudioDevice.listInputDevicesRefreshingLiveness()
            }
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .enumerationEnd,
                    owner: .audioHardwareObserver,
                    queueRole: .dedicatedControl,
                    phase: .listener,
                    status: noErr,
                    generation: generation
                )
            #endif
            guard let self,
                  self.topologyReconciliationSuspended == false,
                  self.inputAvailabilityRefreshGeneration == generation
            else {
                self?.topologyReconciliationDirty = true
                return
            }
            self.replaceInputAvailabilityListeners(with: devices)
        }
    }

    private func replaceInputAvailabilityListeners(with devices: [AudioDevice.Device]) {
        guard self.installed, self.topologyReconciliationSuspended == false else {
            self.topologyReconciliationDirty = true
            return
        }
        self.hasAvailableInputDevice = AudioInputAvailabilityPolicy.hasAvailableInput(
            liveness: devices.map(\.isAlive)
        )
        #if DEBUG
            // Phase-0 isolation for the rebase-introduced all-input liveness ledger. The flag is
            // deliberately scoped to this observer: default-device monitoring, ASR's existing
            // selected-device listener, and dictation capture remain active.
            if ProcessInfo.processInfo.environment["FLUIDVOICE_OMIT_INPUT_LIVENESS_LEDGER_ISOLATION"] == "1" {
                AudioTopologyDiagnostics.record(
                    .isolationActive,
                    owner: .audioHardwareObserver,
                    queueRole: .mainControl,
                    phase: .listener,
                    generation: self.inputAvailabilityRefreshGeneration
                )
                self.removeInputAvailabilityListeners()
                return
            }
        #endif
        #if DEBUG
            AudioTopologyDiagnostics.record(
                .replaceBegin,
                owner: .audioHardwareObserver,
                queueRole: .mainControl,
                phase: .listener,
                generation: self.inputAvailabilityRefreshGeneration
            )
            for device in devices {
                AudioTopologyDiagnostics.record(
                    .topologySnapshot,
                    owner: .audioHardwareObserver,
                    objectID: device.id,
                    queueRole: .mainControl,
                    phase: .listener,
                    transport: AudioTopologyDiagnostics.transportClassification(device.transportType),
                    generation: self.inputAvailabilityRefreshGeneration
                )
            }
        #endif
        // Production policy: never register this observer's broad per-input DeviceIsAlive
        // ledger for aggregate-transport inputs. See AggregateInputLivenessLedgerPolicy for the
        // evidence and scope. Unconditional — no environment flag required — and applies in Release too.
        let productionScopedDevices = devices.filter {
            let permitted = AggregateInputLivenessLedgerPolicy.permitsBroadLedgerMembership(
                transportType: $0.transportType
            )
            #if DEBUG
                if permitted == false {
                    AudioTopologyDiagnostics.record(
                        .policyExcluded,
                        owner: .audioHardwareObserver,
                        objectID: $0.id,
                        queueRole: .mainControl,
                        phase: .listener,
                        transport: AudioTopologyDiagnostics.transportClassification($0.transportType),
                        generation: self.inputAvailabilityRefreshGeneration
                    )
                }
            #endif
            return permitted
        }

        #if DEBUG
            // Opt-in diagnostic isolation on top of the production policy above, for future
            // experiments only; see InputLivenessLedgerIsolationPolicy.
            let excludesTransientInputs = ProcessInfo.processInfo.environment[
                "FLUIDVOICE_EXCLUDE_TRANSIENT_INPUT_LIVENESS_ISOLATION"
            ] == "1"
            let listenerDevices = excludesTransientInputs
                ? productionScopedDevices.filter {
                    let permitted = InputLivenessLedgerIsolationPolicy.permitsListenerForTransientIsolation(
                        transportType: $0.transportType
                    )
                    if permitted == false {
                        AudioTopologyDiagnostics.record(
                            .isolationActive,
                            owner: .audioHardwareObserver,
                            objectID: $0.id,
                            queueRole: .mainControl,
                            phase: .listener,
                            transport: AudioTopologyDiagnostics.transportClassification($0.transportType),
                            generation: self.inputAvailabilityRefreshGeneration
                        )
                    }
                    return permitted
                }
                : productionScopedDevices
        #else
            let listenerDevices = productionScopedDevices
        #endif
        let desiredUIDs = Dictionary(
            listenerDevices.map { ($0.id, $0.uid) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.desiredInputAvailabilityUIDs = desiredUIDs
        for (deviceID, registration) in self.inputAvailabilityRegistrations
            where AudioInputAvailabilityListenerPolicy.registrationNeedsReplacement(
                registeredUID: registration.identity.uid,
                desiredUID: desiredUIDs[deviceID]
            )
        {
            let address = Self.inputAvailabilityAddress
            self.inputAvailabilityRegistrations.removeValue(forKey: deviceID)
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, generation: self.inputAvailabilityRefreshGeneration)
            #endif
            let generation = self.inputAvailabilityRefreshGeneration
            self.launchTrackedTopologyTask {
                let status = await AudioTopologyListenerExecution.remove(
                    objectID: deviceID,
                    address: address,
                    token: registration.token
                )
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status, generation: generation)
                #endif
            }
        }

        for device in listenerDevices {
            let deviceID = device.id
            let uid = device.uid
            if self.inputAvailabilityRegistrations[deviceID]?.identity.uid == uid
                || self.pendingInputAvailabilityRegistrations[deviceID]?.identity.uid == uid
            {
                continue
            }

            let address = Self.inputAvailabilityAddress
            let reconciliationGeneration = self.inputAvailabilityRefreshGeneration
            let lifecycleGeneration = self.listenerLifecycleGeneration
            self.nextInputAvailabilityEpoch &+= 1
            let epoch = self.nextInputAvailabilityEpoch
            let identity = AudioInputAvailabilityListenerIdentity(
                deviceID: deviceID,
                uid: uid,
                epoch: epoch,
                lifecycleGeneration: lifecycleGeneration
            )
            let pending = PendingInputAvailabilityRegistration(identity: identity)
            let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                #if DEBUG
                    AudioTopologyDiagnostics.record(
                        .callbackBegin,
                        owner: .audioHardwareObserver,
                        objectID: deviceID,
                        selector: kAudioDevicePropertyDeviceIsAlive,
                        scope: kAudioObjectPropertyScopeGlobal,
                        element: kAudioObjectPropertyElementMain,
                        queueRole: .callbackCurrent,
                        generation: reconciliationGeneration
                    )
                    defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: reconciliationGeneration) }
                #endif
                // First reject callbacks from replaced registrations on main, then query Core Audio
                // off-main. Validate the same registration again before publishing the result.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.listenerLifecycleGeneration == lifecycleGeneration,
                          AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                              captured: identity,
                              registered: self.inputAvailabilityRegistrations[deviceID]?.identity,
                              installed: self.installed
                          )
                    else { return }
                    guard self.topologyReconciliationSuspended == false else {
                        self.topologyReconciliationDirty = true
                        return
                    }
                    self.launchTrackedTopologyTask { [weak self] in
                        let devices = await AudioTopologyListenerExecution.perform {
                            AudioDevice.listInputDevicesRefreshingLiveness()
                        }
                        #if DEBUG
                            AudioTopologyDiagnostics.record(.mainHopBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainControl, generation: reconciliationGeneration)
                            defer { AudioTopologyDiagnostics.record(.mainHopEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainControl, generation: reconciliationGeneration) }
                        #endif
                        guard let self,
                              self.topologyReconciliationSuspended == false,
                              self.listenerLifecycleGeneration == lifecycleGeneration,
                              AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                                  captured: identity,
                                  registered: self.inputAvailabilityRegistrations[deviceID]?.identity,
                                  installed: self.installed
                              )
                        else {
                            self?.topologyReconciliationDirty = true
                            return
                        }
                        self.hasAvailableInputDevice = AudioInputAvailabilityPolicy.hasAvailableInput(
                            liveness: devices.map(\.isAlive)
                        )
                        self.inputAvailabilityTick &+= 1
                        NotificationCenter.default.post(
                            name: .inputDeviceAvailabilityDidChange,
                            object: self,
                            userInfo: ["deviceID": deviceID]
                        )
                    }
                }
            }
            self.pendingInputAvailabilityRegistrations[deviceID] = pending
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, transport: AudioTopologyDiagnostics.transportClassification(device.transportType), generation: reconciliationGeneration)
            #endif
            self.launchTrackedTopologyTask { [weak self] in
                let status = await AudioTopologyListenerExecution.add(objectID: deviceID, address: address, token: token)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, transport: AudioTopologyDiagnostics.transportClassification(device.transportType), status: status, generation: reconciliationGeneration)
                #endif
                guard let self else {
                    if status == noErr {
                        _ = await AudioTopologyListenerExecution.remove(objectID: deviceID, address: address, token: token)
                    }
                    return
                }
                let ownsPendingMarker = self.pendingInputAvailabilityRegistrations[deviceID] == pending
                if ownsPendingMarker {
                    self.pendingInputAvailabilityRegistrations.removeValue(forKey: deviceID)
                }
                let completionCanInstall = AudioInputAvailabilityListenerPolicy.completionCanInstall(
                    statusSucceeded: status == noErr,
                    ownsPendingMarker: ownsPendingMarker,
                    installed: self.installed,
                    capturedLifecycleGeneration: lifecycleGeneration,
                    currentLifecycleGeneration: self.listenerLifecycleGeneration,
                    capturedUID: uid,
                    desiredUID: self.desiredInputAvailabilityUIDs[deviceID],
                    reconciliationIsCurrent: self.inputAvailabilityRefreshGeneration
                        == reconciliationGeneration
                )
                guard self.topologyReconciliationSuspended == false,
                      completionCanInstall
                else {
                    if self.topologyReconciliationSuspended {
                        self.topologyReconciliationDirty = true
                    }
                    if status == noErr {
                        _ = await AudioTopologyListenerExecution.remove(objectID: deviceID, address: address, token: token)
                    }
                    let staleReconciliationNeedsRetry = AudioInputAvailabilityListenerPolicy
                        .shouldRetryStaleCompletion(
                            ownsPendingMarker: ownsPendingMarker,
                            installed: self.installed,
                            capturedLifecycleGeneration: lifecycleGeneration,
                            currentLifecycleGeneration: self.listenerLifecycleGeneration,
                            capturedUID: uid,
                            desiredUID: self.desiredInputAvailabilityUIDs[deviceID],
                            hasRegistration: self.inputAvailabilityRegistrations[deviceID] != nil,
                            reconciliationIsStale: self.inputAvailabilityRefreshGeneration
                                != reconciliationGeneration
                        )
                    if staleReconciliationNeedsRetry,
                       self.topologyReconciliationSuspended == false
                    {
                        self.refreshInputAvailabilityListeners()
                    }
                    return
                }
                self.inputAvailabilityRegistrations[deviceID] = InputAvailabilityRegistration(
                    identity: identity,
                    token: token
                )
            }
        }
        #if DEBUG
            AudioTopologyDiagnostics.record(
                .replaceEnd,
                owner: .audioHardwareObserver,
                queueRole: .mainControl,
                phase: .listener,
                status: noErr,
                generation: self.inputAvailabilityRefreshGeneration
            )
        #endif
    }

    private func removeInputAvailabilityListeners() {
        let registrations = self.inputAvailabilityRegistrations
        let generation = self.inputAvailabilityRefreshGeneration
        self.inputAvailabilityRegistrations.removeAll()
        self.pendingInputAvailabilityRegistrations.removeAll()
        self.desiredInputAvailabilityUIDs.removeAll()
        for (deviceID, registration) in registrations {
            let address = Self.inputAvailabilityAddress
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, generation: generation)
            #endif
            self.launchTrackedTopologyTask {
                let status = await AudioTopologyListenerExecution.remove(
                    objectID: deviceID,
                    address: address,
                    token: registration.token
                )
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status, generation: generation)
                #endif
            }
        }
    }

    private static var inputAvailabilityAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func registerClamshellStateListener() {
        guard self.clamshellNotificationPort == nil else { return }

        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL,
              let notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        else {
            if rootDomain != IO_OBJECT_NULL {
                IOObjectRelease(rootDomain)
            }
            DebugLogger.shared.warning(
                "Unable to observe MacBook clamshell state",
                source: "AudioHardwareObserver"
            )
            return
        }

        IONotificationPortSetDispatchQueue(notificationPort, DispatchQueue.main)
        var notification = io_object_t(IO_OBJECT_NULL)
        let status = IOServiceAddInterestNotification(
            notificationPort,
            rootDomain,
            kIOGeneralInterest,
            clamshellStateInterestCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )
        guard status == KERN_SUCCESS else {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
            IOObjectRelease(rootDomain)
            DebugLogger.shared.warning(
                "Unable to register clamshell state listener (status=\(status))",
                source: "AudioHardwareObserver"
            )
            return
        }

        self.clamshellRootDomain = rootDomain
        self.clamshellNotificationPort = notificationPort
        self.clamshellNotification = notification
        self.lastClamshellClosed = ClamshellState.isClosed
        DebugLogger.shared.info(
            "Clamshell state listener registered (closed=\(self.lastClamshellClosed == true))",
            source: "AudioHardwareObserver"
        )
    }

    private func unregisterClamshellStateListener() {
        if let notificationPort = self.clamshellNotificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
        }
        if self.clamshellNotification != IO_OBJECT_NULL {
            IOObjectRelease(self.clamshellNotification)
        }
        if let notificationPort = self.clamshellNotificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        if self.clamshellRootDomain != IO_OBJECT_NULL {
            IOObjectRelease(self.clamshellRootDomain)
        }

        self.clamshellRootDomain = IO_OBJECT_NULL
        self.clamshellNotificationPort = nil
        self.clamshellNotification = IO_OBJECT_NULL
        self.lastClamshellClosed = nil
    }

    func handleClamshellInterestMessage() {
        let isClosed = ClamshellState.isClosed
        guard isClosed != self.lastClamshellClosed else { return }
        self.lastClamshellClosed = isClosed
        self.inputAvailabilityTick &+= 1
        DebugLogger.shared.info(
            "MacBook clamshell state changed (closed=\(isClosed))",
            source: "AudioHardwareObserver"
        )
        NotificationCenter.default.post(
            name: .clamshellStateDidChange,
            object: self,
            userInfo: ["isClosed": isClosed]
        )
    }
}

private func clamshellStateInterestCallback(
    refcon: UnsafeMutableRawPointer?,
    _: io_service_t,
    _: natural_t,
    _: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<AudioHardwareObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .handleClamshellInterestMessage()
}
