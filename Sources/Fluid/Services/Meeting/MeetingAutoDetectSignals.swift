import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Darwin
import Foundation

// MARK: - Protocols (unit-testable via fakes; no CoreAudio/AX/NSWorkspace in tests)

@MainActor
protocol MeetingClockProviding: AnyObject {
    func now() -> Date
}

@MainActor
final class SystemClock: MeetingClockProviding {
    func now() -> Date { Date() }
}

nonisolated enum WorkspaceEventKind: Sendable, Equatable {
    case launched
    case terminated
    case activated
}

nonisolated struct WorkspaceEvent: Sendable, Equatable {
    var kind: WorkspaceEventKind
    var bundleIdentifier: String
    var processID: Int32
}

@MainActor
protocol WorkspaceEventsProviding: AnyObject {
    var onEvent: ((WorkspaceEvent) -> Void)? { get set }
    /// `isRegistryApp` selects which already-running apps get backfilled as armed (never prompted)
    /// candidates at startup.
    func start(isRegistryApp: @escaping (String) -> Bool, onBackfill: @escaping ([WorkspaceEvent]) -> Void)
    func stop()
}

nonisolated struct MicActivityEdge: Sendable, Equatable {
    /// true = device went from silent to in-use (0→1); false = the reverse.
    var isActive: Bool
}

@MainActor
protocol MicActivitySignalProviding: AnyObject {
    var onEdge: ((MicActivityEdge) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
protocol AudioProcessActivityProviding: AnyObject {
    func snapshot() async -> AudioProcessActivitySnapshot
}

nonisolated struct AudioProcessDescriptor: Sendable, Equatable {
    var processID: Int32
    var bundleIdentifier: String?
    var executablePath: String?
    var isInputRunning: Bool
    var isOutputRunning: Bool
}

nonisolated struct MeetingProcessOwner: Sendable, Equatable {
    var processID: Int32
    var bundleIdentifier: String
    var bundlePath: String
}

nonisolated struct AudioProcessActivitySnapshot: Sendable, Equatable {
    enum QueryState: Sendable, Equatable { case valid, unknown }
    var processes: [AudioProcessDescriptor]
    var owners: [MeetingProcessOwner]
    var queryState: QueryState
}

/// Maps HAL process objects to the registered native application that owns them. Bundle IDs from
/// HAL are advisory: helpers frequently report their own (or stale) IDs. Ownership is accepted
/// only when the live executable is contained in the owning app bundle after symlink resolution.
/// Ambiguous, missing, or malformed data is deliberately rejected.
nonisolated enum MeetingAudioProcessResolver {
    static func activeOwnerInputByPID(snapshot: AudioProcessActivitySnapshot) -> [Int32: Bool]? {
        guard snapshot.queryState == .valid else { return nil }
        var matches: [Int32: Bool] = [:]
        for process in snapshot.processes where process.isInputRunning || process.isOutputRunning {
            guard let path = canonicalPath(process.executablePath), process.processID > 0 else { return nil }
            let candidates = snapshot.owners.filter { owner in
                guard MeetingAppRegistry.isNativeMeetingApp(bundleIdentifier: owner.bundleIdentifier),
                      let ownerPath = canonicalPath(owner.bundlePath), ownerPath.hasSuffix(".app")
                else { return false }
                guard path.hasPrefix(ownerPath + "/Contents/") else { return false }
                // The owner list is built from live NSRunningApplication instances; requiring a
                // positive PID prevents stale/placeholder identities from matching.
                return owner.processID > 0
            }
            guard candidates.count <= 1 else { return nil }
            guard let owner = candidates.first else { continue }
            matches[owner.processID] = (matches[owner.processID] ?? false) || process.isInputRunning
        }
        return matches
    }

    private static func canonicalPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        return url.path.hasPrefix("/") ? url.path : nil
    }
}

nonisolated struct WindowSnapshot: Sendable, Equatable {
    var processID: Int32
    var windowID: UInt32
    /// Never logged — window titles are PII (repo invariant).
    var title: String?
    var layer: Int
}

/// Readiness is deliberately separate from meeting identity. A busy recorder is not a setup
/// problem and must remain silent; an idle, confirmed meeting may still safely offer setup.
nonisolated enum DetectionPreflightState: Sendable, Equatable {
    case ready
    case busy
    case needsSetup(DetectionSetupReason)
}

nonisolated enum DetectionSetupReason: String, Sendable, Equatable {
    case screenRecording
    case microphone
    case noInputDevice
    case storage
}

@MainActor
protocol WindowSnapshotProviding: AnyObject {
    /// `.optionAll` + `excludeDesktopElements`, NOT `.optionOnScreenOnly` — a minimized meeting
    /// window must not fail confirmation. Only windows owned by `interestPIDs` are returned.
    func snapshot(interestPIDs: Set<Int32>) -> [WindowSnapshot]
    /// Optional AX enrichment for redacted CG titles. Implementations must bound the AX call.
    func titles(processID: Int32) async -> [String]
}

nonisolated struct BrowserTabURL: Sendable, Equatable {
    var host: String
    var path: String
}

@MainActor
protocol BrowserTabReading: AnyObject {
    /// nil = unreadable or the circuit breaker tripped — callers must fail closed (no prompt).
    func frontmostTabURL(bundleIdentifier: String, processID: Int32) async -> BrowserTabURL?
}

/// Our own recording/dictation/preview state, read without materializing the meeting coordinator.
@MainActor
protocol DetectionActivityGate: AnyObject {
    var isIdle: Bool { get }
    /// Re-checked immediately before showing the prompt and atomically before Start.
    func preflightPasses() -> Bool
    func preflightState() -> DetectionPreflightState
}

extension WindowSnapshotProviding {
    func titles(processID: Int32) async -> [String] { [] }
}

extension DetectionActivityGate {
    func preflightState() -> DetectionPreflightState {
        guard self.isIdle else { return .busy }
        return self.preflightPasses() ? .ready : .needsSetup(.screenRecording)
    }
}

// MARK: - Live implementations

@MainActor
final class WorkspaceEventsMonitor: WorkspaceEventsProviding {
    var onEvent: ((WorkspaceEvent) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start(isRegistryApp: @escaping (String) -> Bool, onBackfill: @escaping ([WorkspaceEvent]) -> Void) {
        self.stop()
        let center = NSWorkspace.shared.notificationCenter
        let workspace = NSWorkspace.shared

        self.observers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.forward(.launched, note: note)
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.forward(.terminated, note: note)
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.forward(.activated, note: note)
            },
        ]

        let backfill: [WorkspaceEvent] = workspace.runningApplications.compactMap { app in
            guard let bundleIdentifier = app.bundleIdentifier, isRegistryApp(bundleIdentifier) else { return nil }
            return WorkspaceEvent(kind: .launched, bundleIdentifier: bundleIdentifier, processID: app.processIdentifier)
        }
        if !backfill.isEmpty { onBackfill(backfill) }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in self.observers { center.removeObserver(observer) }
        self.observers = []
    }

    private func forward(_ kind: WorkspaceEventKind, note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleIdentifier = app.bundleIdentifier
        else { return }
        self.onEvent?(WorkspaceEvent(kind: kind, bundleIdentifier: bundleIdentifier, processID: app.processIdentifier))
    }
}

/// Listens for `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device, re-enumerating
/// on `kAudioHardwarePropertyDevices` changes. HAL delivers listener callbacks off-main; the
/// `DispatchQueue.main.async` wrapper mirrors ASRService's device-listener trampoline
/// (deadlock-avoidance precedent) rather than acting synchronously inside the HAL callback.
@MainActor
final class CoreAudioMicActivitySignal: MicActivitySignalProviding {
    private struct ListenerIdentity: Equatable, Sendable {
        let deviceID: AudioObjectID
        let uid: String
        let listenerEpoch: UInt64
        let lifecycleGeneration: UInt64
    }

    private struct Registration: @unchecked Sendable {
        let identity: ListenerIdentity
        let token: AudioObjectPropertyListenerBlock
    }

    var onEdge: ((MicActivityEdge) -> Void)?

    private var deviceListToken: AudioObjectPropertyListenerBlock?
    private var serviceRestartedToken: AudioObjectPropertyListenerBlock?
    private var perDeviceTokens: [AudioObjectID: Registration] = [:]
    private var lastKnownRunning: [AudioObjectID: Bool] = [:]
    private var desiredUIDs: [AudioObjectID: String] = [:]
    private var started = false
    private var lifecycleGeneration: UInt64 = 0
    private var reconciliationEpoch: UInt64 = 0
    private var listenerEpoch: UInt64 = 0

    func start() {
        guard !self.started else { return }
        self.started = true
        self.lifecycleGeneration &+= 1
        let generation = self.lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootstrap(generation: generation)
        }
    }

    func stop() {
        guard self.started else { return }
        self.started = false
        self.lifecycleGeneration &+= 1
        self.reconciliationEpoch &+= 1
        let deviceListToken = self.deviceListToken
        let serviceRestartedToken = self.serviceRestartedToken
        let registrations = Array(self.perDeviceTokens.values)
        self.deviceListToken = nil
        self.serviceRestartedToken = nil
        self.perDeviceTokens = [:]
        self.lastKnownRunning = [:]
        self.desiredUIDs = [:]
        Task {
            await Self.remove(
                deviceListToken: deviceListToken,
                serviceRestartedToken: serviceRestartedToken,
                registrations: registrations
            )
        }
    }

    nonisolated private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static var runningSomewhereAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static var serviceRestartedAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func bootstrap(generation: UInt64) async {
        while self.isCurrent(generation) {
            if await self.registerDeviceListListener(generation: generation) {
                await self.resyncMonitoredDevices(generation: generation)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func registerDeviceListListener(generation: UInt64) async -> Bool {
        let address = Self.devicesAddress
        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
            AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
            defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery) }
            #endif
            guard let signal = self else { return }
            MeetingMicrophoneEventExecution.afterHALCallback {
                Task { @MainActor in
                    await signal.resyncMonitoredDevices(generation: generation, replaceAll: true)
                }
            }
        }
        let restartedToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let signal = self else { return }
            MeetingMicrophoneEventExecution.afterHALCallback {
                Task { @MainActor in
                    await signal.handleServiceRestart(generation: generation)
                }
            }
        }
        // Restart protection must exist before any other token can be invalidated by coreaudiod.
        let restartedStatus = await AudioTopologyListenerExecution.add(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: Self.serviceRestartedAddress,
            token: restartedToken
        )
        if restartedStatus == noErr, self.isCurrent(generation) {
            self.serviceRestartedToken = restartedToken
        } else {
            if restartedStatus == noErr {
                _ = await AudioTopologyListenerExecution.remove(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    address: Self.serviceRestartedAddress,
                    token: restartedToken
                )
            }
            return false
        }

        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let status = await AudioTopologyListenerExecution.add(
            objectID: AudioObjectID(kAudioObjectSystemObject), address: address, token: token
        )
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
        #endif
        if status == noErr, self.isCurrent(generation) {
            self.deviceListToken = token
            return true
        }
        if status == noErr {
            _ = await AudioTopologyListenerExecution.remove(
                objectID: AudioObjectID(kAudioObjectSystemObject), address: address, token: token
            )
        }
        if self.isCurrent(generation), let restartToken = self.serviceRestartedToken {
            self.serviceRestartedToken = nil
            _ = await AudioTopologyListenerExecution.remove(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: Self.serviceRestartedAddress,
                token: restartToken
            )
        }
        return false
    }

    private func resyncMonitoredDevices(generation: UInt64, replaceAll: Bool = false) async {
        guard self.isCurrent(generation) else { return }
        self.reconciliationEpoch &+= 1
        let reconciliation = self.reconciliationEpoch
        let devices = await AudioTopologyListenerExecution.perform { AudioDevice.listInputDevices() }
        guard self.isCurrent(generation), self.reconciliationEpoch == reconciliation else { return }

        let desired = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.uid) })
        self.desiredUIDs = desired
        // A topology event is an incarnation boundary. HAL may have discarded a listener during
        // a disconnect/reconnect even when AudioObjectID and UID are both reused.
        let obsolete = self.perDeviceTokens.values.filter {
            replaceAll || desired[$0.identity.deviceID] != $0.identity.uid
        }
        for registration in obsolete {
            self.perDeviceTokens[registration.identity.deviceID] = nil
            self.lastKnownRunning[registration.identity.deviceID] = nil
        }
        for registration in obsolete {
            _ = await AudioTopologyListenerExecution.remove(
                objectID: registration.identity.deviceID,
                address: Self.runningSomewhereAddress,
                token: registration.token
            )
        }
        guard self.isCurrent(generation), self.reconciliationEpoch == reconciliation else { return }

        for device in devices where self.perDeviceTokens[device.id] == nil {
            let initialRunning = await AudioTopologyListenerExecution.perform {
                Self.queryIsRunningSomewhere(device.id)
            }
            guard self.isCurrent(generation), self.reconciliationEpoch == reconciliation,
                  self.desiredUIDs[device.id] == device.uid, self.perDeviceTokens[device.id] == nil
            else { return }
            self.listenerEpoch &+= 1
            let identity = ListenerIdentity(
                deviceID: device.id, uid: device.uid,
                listenerEpoch: self.listenerEpoch, lifecycleGeneration: generation
            )
            let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                #if DEBUG
                AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingDetector, objectID: device.id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
                defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingDetector, objectID: device.id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery) }
                #endif
                guard let signal = self else { return }
                MeetingMicrophoneEventExecution.afterHALCallback {
                    Task { @MainActor in
                        await signal.handleRunningSomewhereChanged(identity: identity)
                    }
                }
            }
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingDetector, objectID: device.id, selector: Self.runningSomewhereAddress.mSelector, scope: Self.runningSomewhereAddress.mScope, element: Self.runningSomewhereAddress.mElement, queueRole: .dedicatedControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.add(
                objectID: device.id, address: Self.runningSomewhereAddress, token: token
            )
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingDetector, objectID: device.id, selector: Self.runningSomewhereAddress.mSelector, scope: Self.runningSomewhereAddress.mScope, element: Self.runningSomewhereAddress.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
            #endif
            guard status == noErr else { continue }
            guard self.isCurrent(generation), self.reconciliationEpoch == reconciliation,
                  self.desiredUIDs[device.id] == device.uid, self.perDeviceTokens[device.id] == nil
            else {
                _ = await AudioTopologyListenerExecution.remove(
                    objectID: device.id, address: Self.runningSomewhereAddress, token: token
                )
                return
            }
            self.perDeviceTokens[device.id] = Registration(identity: identity, token: token)
            self.lastKnownRunning[device.id] = initialRunning

            // Closes the callback-before-token-commit window: re-read after ownership is visible.
            await self.handleRunningSomewhereChanged(identity: identity)
        }
    }

    private func handleRunningSomewhereChanged(identity: ListenerIdentity) async {
        guard self.isCurrent(identity.lifecycleGeneration),
              self.perDeviceTokens[identity.deviceID]?.identity == identity
        else { return }
        let isRunning = await AudioTopologyListenerExecution.perform {
            Self.queryIsRunningSomewhere(identity.deviceID)
        }
        guard self.isCurrent(identity.lifecycleGeneration),
              self.perDeviceTokens[identity.deviceID]?.identity == identity
        else { return }
        let wasRunning = self.lastKnownRunning[identity.deviceID] ?? false
        self.lastKnownRunning[identity.deviceID] = isRunning
        guard isRunning != wasRunning else { return }
        self.onEdge?(MicActivityEdge(isActive: isRunning))
    }

    private nonisolated static func queryIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = Self.runningSomewhereAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
        #endif
        return status == noErr && value != 0
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.started && self.lifecycleGeneration == generation
    }

    private func handleServiceRestart(generation: UInt64) async {
        guard self.isCurrent(generation) else { return }
        // coreaudiod discarded these registrations. Drop ownership without attempting removal,
        // invalidate every callback/query, then build one fresh listener set.
        self.lifecycleGeneration &+= 1
        self.reconciliationEpoch &+= 1
        let replacementGeneration = self.lifecycleGeneration
        self.deviceListToken = nil
        self.serviceRestartedToken = nil
        self.perDeviceTokens = [:]
        self.lastKnownRunning = [:]
        self.desiredUIDs = [:]
        await self.bootstrap(generation: replacementGeneration)
    }

    private nonisolated static func remove(
        deviceListToken: AudioObjectPropertyListenerBlock?,
        serviceRestartedToken: AudioObjectPropertyListenerBlock?,
        registrations: [Registration]
    ) async {
        if let deviceListToken {
            _ = await AudioTopologyListenerExecution.remove(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: Self.devicesAddress,
                token: deviceListToken
            )
        }
        if let serviceRestartedToken {
            _ = await AudioTopologyListenerExecution.remove(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: Self.serviceRestartedAddress,
                token: serviceRestartedToken
            )
        }
        for registration in registrations {
            _ = await AudioTopologyListenerExecution.remove(
                objectID: registration.identity.deviceID,
                address: Self.runningSomewhereAddress,
                token: registration.token
            )
        }
    }
}

@MainActor
final class CoreAudioProcessActivityProvider: AudioProcessActivityProviding {
    func snapshot() async -> AudioProcessActivitySnapshot {
        let owners = NSWorkspace.shared.runningApplications.compactMap { app -> MeetingProcessOwner? in
            guard let bundle = app.bundleIdentifier,
                  MeetingAppRegistry.isNativeMeetingApp(bundleIdentifier: bundle),
                  !app.isTerminated, app.processIdentifier > 0,
                  let path = app.bundleURL?.path else { return nil }
            return MeetingProcessOwner(processID: app.processIdentifier, bundleIdentifier: bundle, bundlePath: path)
        }
        return await AudioTopologyListenerExecution.perform {
            guard #available(macOS 14.4, *) else {
                return AudioProcessActivitySnapshot(processes: [], owners: [], queryState: .unknown)
            }
            guard let processIDs = Self.processObjectIDs() else {
                return AudioProcessActivitySnapshot(processes: [], owners: owners, queryState: .unknown)
            }
            var queryFailed = false
            let processes = processIDs.compactMap { processObjectID -> AudioProcessDescriptor? in
                guard let input = Self.isRunning(processObjectID, selector: kAudioProcessPropertyIsRunningInput),
                      let output = Self.isRunning(processObjectID, selector: kAudioProcessPropertyIsRunningOutput)
                else { queryFailed = true; return nil }
                guard input || output else { return nil }
                guard let pid = Self.processID(for: processObjectID), pid > 0,
                      let path = Self.executablePath(for: pid),
                      Self.processID(for: processObjectID) == pid
                else { queryFailed = true; return nil }
                return AudioProcessDescriptor(
                    processID: pid,
                    bundleIdentifier: Self.bundleIdentifier(for: processObjectID),
                    executablePath: path,
                    isInputRunning: input,
                    isOutputRunning: output
                )
            }
            // Missing executable identity is not equivalent to silence. Keep the whole sample
            // unknown so the detector preserves continuity without inventing an inactive edge.
            let state: AudioProcessActivitySnapshot.QueryState = queryFailed ? .unknown : .valid
            return AudioProcessActivitySnapshot(processes: processes, owners: owners, queryState: state)
        }
    }

    nonisolated private static func processID(for objectID: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return Int32(pid)
    }

    nonisolated private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated private static func processObjectIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: sizeStatus)
        #endif
        guard sizeStatus == noErr, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        guard size > 0 else { return [] }
        var processIDs = Array(repeating: AudioObjectID(), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let dataStatus = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processIDs)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: dataStatus)
        #endif
        guard dataStatus == noErr, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        return Array(processIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    nonisolated private static func bundleIdentifier(for processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
        #endif
        guard status == noErr else { return nil }
        return value as String
    }

    nonisolated private static func isRunning(_ processID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
        #endif
        guard status == noErr, size == MemoryLayout<UInt32>.size else { return nil }
        return value != 0
    }
}

@MainActor
final class CGWindowSnapshotProvider: WindowSnapshotProviding {
    nonisolated private static let axTimeout: Float = 0.25
    nonisolated private static let maxAXWindows = 8
    private let axQueue = DispatchQueue(label: "com.fluidvoice.meeting.autodetect.ax-title", qos: .utility)

    func snapshot(interestPIDs: Set<Int32>) -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  interestPIDs.contains(ownerPID),
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { return nil }
            let title = info[kCGWindowName as String] as? String
            return WindowSnapshot(processID: ownerPID, windowID: windowNumber, title: title, layer: layer)
        }
    }

    func titles(processID: Int32) async -> [String] {
        await withCheckedContinuation { continuation in
            self.axQueue.async {
                let app = AXUIElementCreateApplication(processID)
                _ = AXUIElementSetMessagingTimeout(app, Self.axTimeout)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement]
                else { continuation.resume(returning: []); return }
                var titles: [String] = []
                for window in windows.prefix(Self.maxAXWindows) {
                    var titleValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                       let title = titleValue as? String {
                        titles.append(title)
                    }
                }
                continuation.resume(returning: titles)
            }
        }
    }
}

/// Reads the frontmost tab/window URL via Accessibility. All AX calls run on a dedicated serial
/// queue with a short messaging timeout so a frozen browser cannot stall detection; a 2-timeout
/// circuit breaker disables further scanning of that bundle for the session.
@MainActor
final class AXBrowserTabReader: BrowserTabReading {
    private static let messagingTimeoutSeconds: Float = 0.3
    private static let maxDepth = 4
    private static let maxChildrenPerLevel = 24
    private static let circuitBreakerThreshold = 2

    private let queue = DispatchQueue(label: "com.fluidvoice.meeting.autodetect.ax", qos: .utility)
    private var timeoutCounts: [String: Int] = [:]
    private var trippedBundleIdentifiers: Set<String> = []

    func frontmostTabURL(bundleIdentifier: String, processID: Int32) async -> BrowserTabURL? {
        guard !self.trippedBundleIdentifiers.contains(bundleIdentifier) else { return nil }

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ReadOutcome, Never>) in
            self.queue.async {
                continuation.resume(returning: Self.readFrontmostTabURL(processID: processID))
            }
        }

        switch outcome {
        case let .found(url):
            self.timeoutCounts[bundleIdentifier] = 0
            return url
        case .notFound:
            return nil
        case .timedOut:
            let count = (self.timeoutCounts[bundleIdentifier] ?? 0) + 1
            self.timeoutCounts[bundleIdentifier] = count
            if count >= Self.circuitBreakerThreshold {
                self.trippedBundleIdentifiers.insert(bundleIdentifier)
            }
            return nil
        }
    }

    private enum ReadOutcome {
        case found(BrowserTabURL)
        case notFound
        case timedOut
    }

    /// Off-main: all work here is plain AX API calls bounded by the messaging timeout below.
    nonisolated private static func readFrontmostTabURL(processID: Int32) -> ReadOutcome {
        let appElement = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeoutSeconds)

        var windowValue: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard windowStatus != .cannotComplete else { return .timedOut }
        guard windowStatus == .success, let window = windowValue else { return .notFound }
        // swiftlint:disable:next force_cast
        let windowElement = window as! AXUIElement

        if let urlString = self.stringAttribute(windowElement, attribute: "AXDocument"), let url = self.parse(urlString) {
            return .found(url)
        }

        var timedOut = false
        if let found = self.breadthFirstFindWebAreaURL(root: windowElement, depth: 0, timedOut: &timedOut) {
            return .found(found)
        }
        return timedOut ? .timedOut : .notFound
    }

    nonisolated private static func breadthFirstFindWebAreaURL(root: AXUIElement, depth: Int, timedOut: inout Bool) -> BrowserTabURL? {
        guard depth < Self.maxDepth else { return nil }
        var childrenValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenValue)
        if status == .cannotComplete { timedOut = true; return nil }
        guard status == .success, let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children.prefix(Self.maxChildrenPerLevel) {
            if let role = self.stringAttribute(child, attribute: kAXRoleAttribute as String), role == "AXWebArea",
               let urlString = self.stringAttribute(child, attribute: "AXURL"),
               let url = self.parse(urlString)
            {
                return url
            }
        }
        for child in children.prefix(Self.maxChildrenPerLevel) {
            if let found = self.breadthFirstFindWebAreaURL(root: child, depth: depth + 1, timedOut: &timedOut) {
                return found
            }
        }
        return nil
    }

    nonisolated private static func stringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    nonisolated private static func parse(_ urlString: String) -> BrowserTabURL? {
        guard let components = URLComponents(string: urlString), let host = components.host else { return nil }
        return BrowserTabURL(host: host, path: components.path)
    }
}

/// Reads recording/dictation/preview state without materializing the meeting coordinator (which
/// is a lazy getter — forcing it here would defeat the point of a standalone detector).
@MainActor
final class LiveDetectionActivityGate: DetectionActivityGate {
    var isIdle: Bool {
        if AppServices.shared.isMeetingSessionCoordinatorMaterialized {
            guard !AppServices.shared.hasActiveMeetingSessionActivity else { return false }
        }
        return AppServices.shared.activeExclusiveActivityIfASRMaterialized == nil
    }

    func preflightPasses() -> Bool {
        if case .ready = self.preflightState() { return true }
        return false
    }

    func preflightState() -> DetectionPreflightState {
        guard self.isIdle else { return .busy }
        guard CGPreflightScreenCaptureAccess() else { return .needsSetup(.screenRecording) }
        guard AVCaptureDeviceAuthorization.isMicrophoneAuthorized() else { return .needsSetup(.microphone) }
        guard AppServices.shared.audioObserver.hasAvailableInputDevice else { return .needsSetup(.noInputDevice) }
        guard MeetingStorageReadiness.hasSufficientFreeSpace() else { return .needsSetup(.storage) }
        return .ready
    }
}

nonisolated enum AVCaptureDeviceAuthorization {
    static func isMicrophoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

nonisolated enum MeetingStorageReadiness {
    static func hasSufficientFreeSpace() -> Bool {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let capacity = try? applicationSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                  .volumeAvailableCapacityForImportantUsage
        else { return false }
        return capacity >= 512 * 1024 * 1024
    }
}
