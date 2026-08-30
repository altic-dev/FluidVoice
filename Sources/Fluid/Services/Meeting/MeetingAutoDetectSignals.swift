import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
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
    func isAudioActive(forBundleIdentifiers bundleIdentifiers: Set<String>) -> Bool
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
    var onEdge: ((MicActivityEdge) -> Void)?

    private var deviceListToken: AudioObjectPropertyListenerBlock?
    private var perDeviceTokens: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var lastKnownRunning: [AudioObjectID: Bool] = [:]
    private var started = false

    func start() {
        guard !self.started else { return }
        self.started = true
        self.registerDeviceListListener()
        self.resyncMonitoredDevices()
    }

    func stop() {
        guard self.started else { return }
        self.started = false
        var devicesAddress = Self.devicesAddress
        if let token = self.deviceListToken {
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: devicesAddress.mSelector, scope: devicesAddress.mScope, element: devicesAddress.mElement, queueRole: .mainControl, phase: .listener)
            #endif
            let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, token)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: devicesAddress.mSelector, scope: devicesAddress.mScope, element: devicesAddress.mElement, queueRole: .mainControl, phase: .listener, status: status)
            #endif
        }
        self.deviceListToken = nil
        for (deviceID, token) in self.perDeviceTokens {
            var address = Self.runningSomewhereAddress
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingDetector, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
            #endif
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingDetector, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
            #endif
        }
        self.perDeviceTokens = [:]
        self.lastKnownRunning = [:]
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var runningSomewhereAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func registerDeviceListListener() {
        var address = Self.devicesAddress
        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
            AudioTopologyDiagnostics.record(.callback, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
            #endif
            DispatchQueue.main.async { self?.resyncMonitoredDevices() }
        }
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, token)
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingDetector, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
        #endif
        if status == noErr {
            self.deviceListToken = token
        }
    }

    private func resyncMonitoredDevices() {
        let currentIDs = Set(AudioDevice.listInputDevices().map(\.id))
        let previousIDs = Set(self.perDeviceTokens.keys)

        for removedID in previousIDs.subtracting(currentIDs) {
            var address = Self.runningSomewhereAddress
            if let token = self.perDeviceTokens[removedID] {
                #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingDetector, objectID: removedID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
                #endif
                let status = AudioObjectRemovePropertyListenerBlock(removedID, &address, DispatchQueue.main, token)
                #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingDetector, objectID: removedID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
                #endif
            }
            self.perDeviceTokens[removedID] = nil
            self.lastKnownRunning[removedID] = nil
        }

        for addedID in currentIDs.subtracting(previousIDs) {
            self.lastKnownRunning[addedID] = self.queryIsRunningSomewhere(addedID)
            var address = Self.runningSomewhereAddress
            let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                #if DEBUG
                AudioTopologyDiagnostics.record(.callback, owner: .meetingDetector, objectID: addedID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
                #endif
                DispatchQueue.main.async { self?.handleRunningSomewhereChanged(deviceID: addedID) }
            }
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingDetector, objectID: addedID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
            #endif
            let status = AudioObjectAddPropertyListenerBlock(addedID, &address, DispatchQueue.main, token)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingDetector, objectID: addedID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
            #endif
            if status == noErr {
                self.perDeviceTokens[addedID] = token
            }
        }
    }

    private func handleRunningSomewhereChanged(deviceID: AudioObjectID) {
        let isRunning = self.queryIsRunningSomewhere(deviceID)
        let wasRunning = self.lastKnownRunning[deviceID] ?? false
        self.lastKnownRunning[deviceID] = isRunning
        guard isRunning != wasRunning else { return }
        self.onEdge?(MicActivityEdge(isActive: isRunning))
    }

    private func queryIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = Self.runningSomewhereAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
        #endif
        return status == noErr && value != 0
    }
}

@MainActor
final class CoreAudioProcessActivityProvider: AudioProcessActivityProviding {
    func isAudioActive(forBundleIdentifiers bundleIdentifiers: Set<String>) -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        return Self.processObjectIDs().contains { processID in
            guard let bundleIdentifier = Self.bundleIdentifier(for: processID), bundleIdentifiers.contains(bundleIdentifier) else { return false }
            return Self.isRunning(processID, selector: kAudioProcessPropertyIsRunningInput)
                || Self.isRunning(processID, selector: kAudioProcessPropertyIsRunningOutput)
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: sizeStatus)
        #endif
        guard sizeStatus == noErr else { return [] }
        var processIDs = Array(repeating: AudioObjectID(), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let dataStatus = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processIDs)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: systemObject, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: dataStatus)
        #endif
        guard dataStatus == noErr else { return [] }
        return processIDs
    }

    private static func bundleIdentifier(for processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
        #endif
        guard status == noErr else { return nil }
        return value as String
    }

    private static func isRunning(_ processID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryBegin, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener)
        #endif
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        #if DEBUG
        AudioTopologyDiagnostics.record(.halQueryEnd, owner: .meetingDetector, objectID: processID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .mainControl, phase: .listener, status: status)
        #endif
        return status == noErr && value != 0
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
        guard !AudioDevice.listInputDevices().isEmpty else { return .needsSetup(.noInputDevice) }
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
