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

final class AudioHardwareObserver: ObservableObject {
    /// Incremented every time CoreAudio reports a hardware/default-device change.
    /// Using a simple `@Published` value avoids putting `AnyPublisher`/`SubscriptionView` generics into
    /// SwiftUI's root view type, which can trigger AttributeGraph metadata-instantiation crashes at launch.
    @Published private(set) var changeTick: UInt64 = 0
    @Published private(set) var inputAvailabilityTick: UInt64 = 0

    private var installed: Bool = false
    private var devicesListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?
    private var inputAvailabilityListenerTokens: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var inputAvailabilityRefreshGeneration: UInt64 = 0
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

    @MainActor
    func signalInputAvailabilityChanged() {
        self.inputAvailabilityTick &+= 1
    }

    func restartObservingAfterAudioServiceReset() {
        // Core Audio discards every previously registered listener when its
        // service resets, so the old tokens must not be removed or reused.
        self.devicesListenerToken = nil
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.inputAvailabilityListenerTokens.removeAll()
        self.inputAvailabilityRefreshGeneration &+= 1
        self.installed = false
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
        guard self.installed == false else { return }
        var addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let queue = DispatchQueue.main
        let sys = AudioObjectID(kAudioObjectSystemObject)

        let devicesToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callback,
                    owner: .audioHardwareObserver,
                    objectID: sys,
                    selector: kAudioHardwarePropertyDevices,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .mainDelivery,
                    generation: self?.inputAvailabilityRefreshGeneration ?? 0
                )
            #endif
            self?.changeTick &+= 1
            self?.refreshInputAvailabilityListeners()
        }
        let defaultInToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callback,
                    owner: .audioHardwareObserver,
                    objectID: sys,
                    selector: kAudioHardwarePropertyDefaultInputDevice,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .mainDelivery,
                    generation: self?.inputAvailabilityRefreshGeneration ?? 0
                )
            #endif
            self?.inputAvailabilityTick &+= 1
        }
        let defaultOutToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .callback,
                    owner: .audioHardwareObserver,
                    objectID: sys,
                    selector: kAudioHardwarePropertyDefaultOutputDevice,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain,
                    queueRole: .mainDelivery,
                    generation: self?.inputAvailabilityRefreshGeneration ?? 0
                )
            #endif
            self?.changeTick &+= 1
        }

        #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let devicesStatus = AudioObjectAddPropertyListenerBlock(sys, &addrDevices, queue, devicesToken)
        #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .mainControl, phase: .listener, status: devicesStatus)
            AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultIn.mSelector, scope: addrDefaultIn.mScope, element: addrDefaultIn.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let defaultInStatus = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultIn, queue, defaultInToken)
        #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultIn.mSelector, scope: addrDefaultIn.mScope, element: addrDefaultIn.mElement, queueRole: .mainControl, phase: .listener, status: defaultInStatus)
            AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultOut.mSelector, scope: addrDefaultOut.mScope, element: addrDefaultOut.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let defaultOutStatus = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultOut, queue, defaultOutToken)
        #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultOut.mSelector, scope: addrDefaultOut.mScope, element: addrDefaultOut.mElement, queueRole: .mainControl, phase: .listener, status: defaultOutStatus)
            AudioTopologyDiagnostics.record(.readiness, owner: .audioHardwareObserver, queueRole: .mainControl, status: (devicesStatus == noErr && defaultInStatus == noErr && defaultOutStatus == noErr) ? noErr : -1)
        #endif

        guard devicesStatus == noErr, defaultInStatus == noErr, defaultOutStatus == noErr else {
            // Best-effort cleanup for any partial installs.
            if devicesStatus == noErr {
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices, queue, devicesToken)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            if defaultInStatus == noErr {
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultIn.mSelector, scope: addrDefaultIn.mScope, element: addrDefaultIn.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn, queue, defaultInToken)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultIn.mSelector, scope: addrDefaultIn.mScope, element: addrDefaultIn.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            if defaultOutStatus == noErr {
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultOut.mSelector, scope: addrDefaultOut.mScope, element: addrDefaultOut.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, defaultOutToken)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultOut.mSelector, scope: addrDefaultOut.mScope, element: addrDefaultOut.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            self.devicesListenerToken = nil
            self.defaultInputListenerToken = nil
            self.defaultOutputListenerToken = nil
            self.installed = false
            return
        }

        self.devicesListenerToken = devicesToken
        self.defaultInputListenerToken = defaultInToken
        self.defaultOutputListenerToken = defaultOutToken
        self.installed = true
        self.refreshInputAvailabilityListeners()
        self.registerClamshellStateListener()
    }

    private func unregister() {
        var addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let queue = DispatchQueue.main
        let sys = AudioObjectID(kAudioObjectSystemObject)

        if self.installed {
            if let token = self.devicesListenerToken {
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices, queue, token)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDevices.mSelector, scope: addrDevices.mScope, element: addrDevices.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            if let token = self.defaultInputListenerToken {
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultIn.mSelector, scope: addrDefaultIn.mScope, element: addrDefaultIn.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn, queue, token)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultIn.mSelector, scope: addrDefaultIn.mScope, element: addrDefaultIn.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            if let token = self.defaultOutputListenerToken {
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultOut.mSelector, scope: addrDefaultOut.mScope, element: addrDefaultOut.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, token)
                #if DEBUG
                    AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: sys, selector: addrDefaultOut.mSelector, scope: addrDefaultOut.mScope, element: addrDefaultOut.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            self.removeInputAvailabilityListeners()
        }

        self.devicesListenerToken = nil
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.installed = false
        self.inputAvailabilityRefreshGeneration &+= 1
        self.unregisterClamshellStateListener()
    }

    private func refreshInputAvailabilityListeners() {
        self.inputAvailabilityRefreshGeneration &+= 1
        let generation = self.inputAvailabilityRefreshGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            #if DEBUG
                AudioTopologyDiagnostics.record(
                    .enumerationBegin,
                    owner: .audioHardwareObserver,
                    queueRole: .dedicatedControl,
                    phase: .listener,
                    generation: generation
                )
            #endif
            let devices = AudioDevice.listInputDevicesRefreshingLiveness()
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
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.inputAvailabilityRefreshGeneration == generation
                else { return }
                self.replaceInputAvailabilityListeners(with: devices)
            }
        }
    }

    private func replaceInputAvailabilityListeners(with devices: [AudioDevice.Device]) {
        guard self.installed else { return }
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
        let currentIDs = Set(listenerDevices.map(\.id))
        for (deviceID, token) in self.inputAvailabilityListenerTokens where currentIDs.contains(deviceID) == false {
            var address = Self.inputAvailabilityAddress
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, generation: self.inputAvailabilityRefreshGeneration)
            #endif
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status, generation: self.inputAvailabilityRefreshGeneration)
            #endif
            self.inputAvailabilityListenerTokens.removeValue(forKey: deviceID)
        }

        for device in listenerDevices where self.inputAvailabilityListenerTokens[device.id] == nil {
            let deviceID = device.id
            var address = Self.inputAvailabilityAddress
            let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                #if DEBUG
                    AudioTopologyDiagnostics.record(
                        .callback,
                        owner: .audioHardwareObserver,
                        objectID: deviceID,
                        selector: kAudioDevicePropertyDeviceIsAlive,
                        scope: kAudioObjectPropertyScopeGlobal,
                        element: kAudioObjectPropertyElementMain,
                        queueRole: .mainDelivery,
                        generation: self?.inputAvailabilityRefreshGeneration ?? 0
                    )
                #endif
                // Never query Core Audio synchronously from its property callback.
                // Refresh the cached snapshot off-main before observers resolve priority.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    _ = AudioDevice.listInputDevicesRefreshingLiveness()
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.inputAvailabilityTick &+= 1
                        NotificationCenter.default.post(
                            name: .inputDeviceAvailabilityDidChange,
                            object: self,
                            userInfo: ["deviceID": deviceID]
                        )
                    }
                }
            }
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, transport: AudioTopologyDiagnostics.transportClassification(device.transportType), generation: self.inputAvailabilityRefreshGeneration)
            #endif
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                token
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, transport: AudioTopologyDiagnostics.transportClassification(device.transportType), status: status, generation: self.inputAvailabilityRefreshGeneration)
            #endif
            if status == noErr {
                self.inputAvailabilityListenerTokens[deviceID] = token
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
        for (deviceID, token) in self.inputAvailabilityListenerTokens {
            var address = Self.inputAvailabilityAddress
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, generation: self.inputAvailabilityRefreshGeneration)
            #endif
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .audioHardwareObserver, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status, generation: self.inputAvailabilityRefreshGeneration)
            #endif
        }
        self.inputAvailabilityListenerTokens.removeAll()
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
