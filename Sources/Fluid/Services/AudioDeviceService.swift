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
    static func listInputDevicesRefreshingLiveness() -> [Device] {
        let devices = self.listInputDevices()
        let liveness = Dictionary(
            uniqueKeysWithValues: devices.map { device in
                (
                    InputLivenessKey(id: device.id, uid: device.uid),
                    self.queryInputDeviceLiveness(device.id)
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
    static func refreshInputDeviceLiveness(deviceID: AudioObjectID) -> Bool {
        let isAlive = self.queryInputDeviceLiveness(deviceID)
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
    private static func queryInputDeviceLiveness(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 1
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
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
            self?.changeTick &+= 1
            self?.refreshInputAvailabilityListeners()
        }
        let defaultInToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.inputAvailabilityTick &+= 1
        }
        let defaultOutToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.changeTick &+= 1
        }

        let devicesStatus = AudioObjectAddPropertyListenerBlock(sys, &addrDevices, queue, devicesToken)
        let defaultInStatus = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultIn, queue, defaultInToken)
        let defaultOutStatus = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultOut, queue, defaultOutToken)

        guard devicesStatus == noErr, defaultInStatus == noErr, defaultOutStatus == noErr else {
            // Best-effort cleanup for any partial installs.
            if devicesStatus == noErr {
                _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices, queue, devicesToken)
            }
            if defaultInStatus == noErr {
                _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn, queue, defaultInToken)
            }
            if defaultOutStatus == noErr {
                _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, defaultOutToken)
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
                _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices, queue, token)
            }
            if let token = self.defaultInputListenerToken {
                _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn, queue, token)
            }
            if let token = self.defaultOutputListenerToken {
                _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, token)
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
            let devices = AudioDevice.listInputDevicesRefreshingLiveness()
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
        let currentIDs = Set(devices.map(\.id))
        for (deviceID, token) in self.inputAvailabilityListenerTokens where currentIDs.contains(deviceID) == false {
            var address = Self.inputAvailabilityAddress
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
            self.inputAvailabilityListenerTokens.removeValue(forKey: deviceID)
        }

        for device in devices where self.inputAvailabilityListenerTokens[device.id] == nil {
            let deviceID = device.id
            var address = Self.inputAvailabilityAddress
            let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
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
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                token
            )
            if status == noErr {
                self.inputAvailabilityListenerTokens[deviceID] = token
            }
        }
    }

    private func removeInputAvailabilityListeners() {
        for (deviceID, token) in self.inputAvailabilityListenerTokens {
            var address = Self.inputAvailabilityAddress
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
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
