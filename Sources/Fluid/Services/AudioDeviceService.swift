//
//  AudioDeviceService.swift
//  fluid
//
//  CoreAudio device management and monitoring
//

import Combine
import CoreAudio
import Foundation

// MARK: - Audio Device Manager

enum AudioDevice {
    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
    }

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

        var devices: [Device] = []
        devices.reserveCapacity(deviceIDs.count)

        for devId in deviceIDs {
            let name = self.getStringProperty(devId, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown"
            let uid = self.getStringProperty(devId, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) ?? ""
            let hasIn = self.hasChannels(devId, scope: kAudioObjectPropertyScopeInput)
            let hasOut = self.hasChannels(devId, scope: kAudioObjectPropertyScopeOutput)
            devices.append(Device(id: devId, uid: uid, name: name, hasInput: hasIn, hasOutput: hasOut))
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func listInputDevices() -> [Device] {
        return self.listAllDevices().filter { $0.hasInput }
    }

    static func listOutputDevices() -> [Device] {
        return self.listAllDevices().filter { $0.hasOutput }
    }

    static func getDefaultInputDevice() -> Device? {
        guard let devId: AudioObjectID = getDefaultDeviceId(selector: kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return self.listAllDevices().first { $0.id == devId }
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

// MARK: - Audio Hardware Observer

final class AudioHardwareObserver: ObservableObject {
    /// Incremented every time CoreAudio reports a hardware/default-device change.
    /// Using a simple `@Published` value avoids putting `AnyPublisher`/`SubscriptionView` generics into
    /// SwiftUI's root view type, which can trigger AttributeGraph metadata-instantiation crashes at launch.
    @Published private(set) var changeTick: UInt64 = 0

    private var installed: Bool = false
    private var devicesListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?

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
        }
        let defaultInToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.changeTick &+= 1
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
    }

    private func unregister() {
        guard self.installed else { return }
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

        if let token = self.devicesListenerToken {
            _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices, queue, token)
        }
        if let token = self.defaultInputListenerToken {
            _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn, queue, token)
        }
        if let token = self.defaultOutputListenerToken {
            _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, token)
        }

        self.devicesListenerToken = nil
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.installed = false
    }
}
