import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import Vision

/// Which windows a context-trained dictation model may read text from.
/// A wider scope adds a case here and its windows in
/// `DictationContextReader.windows(for:)`.
nonisolated enum DictationScreenContextScope: String, CaseIterable, Sendable {
    case off
    /// The window being dictated into; for a browser, its current tab.
    case frontWindow

    var displayName: String {
        switch self {
        case .off: "Off"
        case .frontWindow: "Front window"
        }
    }
}

/// Raw text around a dictation, for models trained to read it.
/// Fluid Intelligence picks the useful words and writes the prompt lines,
/// so nothing here formats them.
nonisolated struct DictationTypingContext: Sendable, Equatable {
    var textBeforeCursor: String?
    // One Accessibility element or OCR line per entry; nil means none was read.
    // swiftlint:disable:next discouraged_optional_collection
    var screenText: [String]?
}

/// Reads the dictation context when recording starts, off the main thread,
/// so it is ready when speech ends. What it reads is never logged or kept.
final nonisolated class DictationContextCapture: @unchecked Sendable {
    private let target: TypingService.RecordingTargetContext
    private let task: Task<DictationTypingContext?, Never>
    private let first = FirstResult()

    init(target: TypingService.RecordingTargetContext, task: Task<DictationTypingContext?, Never>) {
        self.target = target
        self.task = task
    }

    deinit { self.cancel() }

    @MainActor
    func matches(_ target: TypingService.RecordingTargetContext) -> Bool {
        guard self.target.pid == target.pid else { return false }
        if self.target.id == target.id { return true }
        guard let original = self.target.element, let current = target.element,
              CFEqual(original, current)
        else { return false }
        switch (self.target.window, target.window) {
        case let (original?, current?): return CFEqual(original, current)
        case (nil, nil): return true
        default: return false
        }
    }

    @MainActor
    static func start(
        target: TypingService.RecordingTargetContext,
        textBeforeCursor: String?,
        settings: SettingsStore
    ) -> DictationContextCapture? {
        guard AXIsProcessTrusted() else { return nil }
        let request = DictationContextReader.Request(
            pid: target.pid,
            bundleID: target.bundleIdentifier,
            window: target.window,
            element: target.element,
            textBeforeCursor: textBeforeCursor,
            scope: settings.dictationScreenContextScope,
            readsWindowImage: settings.dictationScreenContextOCREnabled
        )
        let task = Task.detached(priority: .userInitiated) {
            await DictationContextReader.read(request)
        }
        return DictationContextCapture(target: target, task: task)
    }

    /// The context, or nil when it is not ready within `timeout`; a late
    /// result is dropped.
    func result(timeout: Duration) async -> DictationTypingContext? {
        let task = self.task
        let first = self.first
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                first.install(continuation)
                Task.detached {
                    let value = await task.value
                    first.resume(task.isCancelled ? nil : value)
                }
                first.setTimeout(Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    task.cancel()
                    first.resume(nil)
                })
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        self.task.cancel()
        self.first.resume(nil)
    }
}

private final nonisolated class FirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DictationTypingContext?, Never>?
    private var completed = false
    private var value: DictationTypingContext?
    private var timeout: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<DictationTypingContext?, Never>) {
        self.lock.lock()
        if self.completed {
            let value = self.value
            self.lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func setTimeout(_ timeout: Task<Void, Never>) {
        self.lock.lock()
        let completed = self.completed
        if !completed { self.timeout = timeout }
        self.lock.unlock()
        if completed { timeout.cancel() }
    }

    func resume(_ value: DictationTypingContext?) {
        self.lock.lock()
        guard !self.completed else {
            self.lock.unlock()
            return
        }
        self.completed = true
        self.value = value
        let continuation = self.continuation
        self.continuation = nil
        let timeout = self.timeout
        self.timeout = nil
        self.lock.unlock()
        timeout?.cancel()
        continuation?.resume(returning: value)
    }
}

nonisolated enum DictationContextReader {
    struct Request: @unchecked Sendable {
        let pid: pid_t
        let bundleID: String?
        let window: AXUIElement?
        let element: AXUIElement?
        /// Already read for dictation formatting; nil reads it here.
        let textBeforeCursor: String?
        let scope: DictationScreenContextScope
        let readsWindowImage: Bool
    }

    static let maxTextBeforeCursorCharacters = 2000
    static let maxScreenLines = 300
    static let maxLineCharacters = 400
    /// Fewer words than this means Accessibility could not read the window,
    /// so OCR is tried when it is allowed.
    static let minimumAccessibilityWords = 25

    private static let maxLinesPerElement = 150
    private static let maxVisitedElements = 4000
    private static let accessibilityBudgetSeconds = 0.5
    private static let messagingTimeoutSeconds: Float = 0.1
    /// Long text views are read for their visible part only.
    private static let longValueCharacters = 4000

    private static let passwordManagerMarkers = [
        "password", "1password", "onepassword", "bitwarden", "lastpass", "dashlane",
        "keepass", "enpass", "keychain", "strongbox", "nordpass", "proton.pass", "keeper",
    ]
    private static let skippedRoles: Set<String> = [
        "AXSecureTextField", "AXScrollBar", "AXValueIndicator", "AXSplitter",
        "AXGrowArea", "AXIncrementor", "AXMenuBar", "AXMenu",
    ]
    /// Roles whose description is their visible label, such as icon buttons.
    private static let labelledRoles: Set<String> = [
        "AXButton", "AXLink", "AXImage", "AXMenuButton", "AXPopUpButton",
        "AXRadioButton", "AXCheckBox", "AXTab",
    ]
    private static let textEntryRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    static func read(
        _ request: Request,
        recognizeWindow: @Sendable (pid_t, AXUIElement?) async -> [String] = { await DictationContextReader.recognizedWindowText(pid: $0, window: $1) }
    ) async -> DictationTypingContext? {
        guard !Task.isCancelled else { return nil }
        if let element = request.element { AXUIElementSetMessagingTimeout(element, self.messagingTimeoutSeconds) }
        guard !self.isPrivate(request) else { return nil }

        let textBeforeCursor = (request.textBeforeCursor ?? request.element.flatMap(self.textBeforeCursor(in:)))
            .map { String($0.suffix(self.maxTextBeforeCursorCharacters)) }

        var lines = LineCollector()
        let windows = self.windows(for: request)
        for window in windows where !Task.isCancelled {
            self.collectAccessibilityText(in: window, into: &lines)
        }
        if request.scope != .off, request.readsWindowImage, let window = windows.first,
           lines.wordCount < self.minimumAccessibilityWords, !Task.isCancelled
        {
            for line in await recognizeWindow(request.pid, window) {
                lines.add(line)
            }
        }
        guard !Task.isCancelled else { return nil }

        let context = DictationTypingContext(
            textBeforeCursor: textBeforeCursor?.isEmpty == false ? textBeforeCursor : nil,
            screenText: lines.lines.isEmpty ? nil : lines.lines
        )
        return context.textBeforeCursor == nil && context.screenText == nil ? nil : context
    }

    private static func windows(for request: Request) -> [AXUIElement] {
        switch request.scope {
        case .off:
            return []
        case .frontWindow:
            guard let window = request.window else { return [] }
            let app = AXUIElementCreateApplication(request.pid)
            self.exposeWebContent(of: app, pid: request.pid)
            return [window]
        }
    }

    private static let webContentLock = NSLock()
    private nonisolated(unsafe) static var webContentPIDs: [pid_t] = []

    /// Chrome and Electron apps build their page's Accessibility tree only
    /// when asked; other apps ignore the attribute. The tree may still be
    /// building on the first dictation in such an app.
    private static func exposeWebContent(of app: AXUIElement, pid: pid_t) {
        self.webContentLock.lock()
        let isNew = !self.webContentPIDs.contains(pid)
        if isNew {
            if self.webContentPIDs.count == 64 { self.webContentPIDs.removeFirst() }
            self.webContentPIDs.append(pid)
        }
        self.webContentLock.unlock()
        guard isNew else { return }
        AXUIElementSetMessagingTimeout(app, self.messagingTimeoutSeconds)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Privacy

    private static func isPrivate(_ request: Request) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        if let bundleID = request.bundleID?.lowercased(),
           self.passwordManagerMarkers.contains(where: { bundleID.contains($0) })
        {
            return true
        }
        return request.element.map(self.isSecure) ?? false
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let role = self.string(element, kAXRoleAttribute) ?? ""
        let subrole = self.string(element, kAXSubroleAttribute) ?? ""
        return role == "AXSecureTextField"
            || subrole == (kAXSecureTextFieldSubrole as String)
            || subrole.localizedCaseInsensitiveContains("secure")
    }

    // MARK: - Text before the cursor

    private static func textBeforeCursor(in element: AXUIElement) -> String? {
        guard let selection = self.range(element, kAXSelectedTextRangeAttribute) else { return nil }
        let end = selection.location
        guard end > 0 else { return nil }
        let start = max(0, end - self.maxTextBeforeCursorCharacters)
        if let text = self.string(element, in: CFRange(location: start, length: end - start)) {
            return text
        }
        guard let value = self.string(element, kAXValueAttribute) else { return nil }
        let nsValue = value as NSString
        let safeEnd = min(end, nsValue.length)
        let safeStart = max(0, safeEnd - self.maxTextBeforeCursorCharacters)
        return nsValue.substring(with: NSRange(location: safeStart, length: safeEnd - safeStart))
    }

    // MARK: - Accessibility text

    private struct ElementText {
        let role: String
        let isSecure: Bool
        let texts: [String]
        let frame: CGRect?
        let children: [AXUIElement]
    }

    private static let fetchedAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ] as CFArray

    private static func collectAccessibilityText(in window: AXUIElement, into lines: inout LineCollector) {
        let deadline = ProcessInfo.processInfo.systemUptime + self.accessibilityBudgetSeconds
        AXUIElementSetMessagingTimeout(window, self.messagingTimeoutSeconds)
        let windowFrame = self.frame(of: window)
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < self.maxVisitedElements, !lines.isFull {
            visited += 1
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
                break
            }
            AXUIElementSetMessagingTimeout(element, self.messagingTimeoutSeconds)
            guard let item = self.elementText(element),
                  !item.isSecure, !self.skippedRoles.contains(item.role)
            else { continue }
            // Scrolled-out content lies outside the window; it is not on screen.
            if let windowFrame, let frame = item.frame, !frame.isEmpty, !frame.intersects(windowFrame) {
                continue
            }
            for text in item.texts {
                lines.add(text, limit: self.maxLinesPerElement)
            }
            stack.append(contentsOf: item.children.prefix(max(0, self.maxVisitedElements - visited - stack.count)).reversed())
        }
    }

    private static func elementText(_ element: AXUIElement) -> ElementText? {
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, self.fetchedAttributes, AXCopyMultipleAttributeOptions(), &valuesRef) == .success,
              let values = valuesRef as? [AnyObject], values.count == 8
        else { return nil }

        let role = values[0] as? String ?? ""
        let subrole = values[1] as? String ?? ""
        var texts: [String] = []
        if var value = values[2] as? String {
            if value.utf16.count > self.longValueCharacters, self.textEntryRoles.contains(role) {
                value = self.visibleText(of: element) ?? ""
            }
            texts.append(value)
        }
        if let title = values[3] as? String { texts.append(title) }
        if self.labelledRoles.contains(role), let description = values[4] as? String { texts.append(description) }

        var frame: CGRect?
        if let origin = self.axValue(values[5], as: CGPoint.self, type: .cgPoint),
           let size = self.axValue(values[6], as: CGSize.self, type: .cgSize)
        {
            frame = CGRect(origin: origin, size: size)
        }
        return ElementText(
            role: role,
            isSecure: role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String),
            texts: texts,
            frame: frame,
            children: values[7] as? [AXUIElement] ?? []
        )
    }

    private static func visibleText(of element: AXUIElement) -> String? {
        guard let visible = self.range(element, kAXVisibleCharacterRangeAttribute), visible.length > 0 else { return nil }
        return self.string(element, in: visible)
    }

    // MARK: - OCR fallback

    /// Screenshots only the dictated-into window, at native Retina pixels
    /// (Vision garbles small gray text at 1x), and reads it with Vision.
    /// Needs Screen Recording; FluidVoice never asks for it here.
    private static func recognizedWindowText(pid: pid_t, window: AXUIElement?) async -> [String] {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess(),
              let frame = window.flatMap(self.frame(of:)),
              let windowID = self.windowID(pid: pid, frame: frame)
        else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled,
                  let scWindow = content.windows.first(where: { $0.windowID == windowID })
            else { return [] }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard !Task.isCancelled else { return [] }
            return self.recognizedLines(in: image)
        } catch {
            return []
        }
    }

    private static func recognizedLines(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Only the captured window may be read; a stale window must never fall back to another one.
    private static func windowID(pid: pid_t, frame: CGRect?) -> CGWindowID? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = info.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let matching = frame.flatMap { frame in
            windows.first { window in
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { return false }
                return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2
                    && abs(rect.width - frame.width) < 2 && abs(rect.height - frame.height) < 2
            }
        }
        return matching?[kCGWindowNumber as String] as? CGWindowID
    }

    // MARK: - Accessibility helpers

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func string(_ element: AXUIElement, in range: CFRange) -> String? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return self.axValue(value, as: CFRange.self, type: .cfRange)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let origin = self.axValue(position, as: CGPoint.self, type: .cgPoint),
              let extent = self.axValue(size, as: CGSize.self, type: .cgSize)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func axValue<T>(_ value: CFTypeRef?, as _: T.Type, type: AXValueType) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(axValue, type, pointer) else { return nil }
        return pointer.pointee
    }
}

/// Screen lines in reading order, without repeats, within the size caps.
private nonisolated struct LineCollector {
    private(set) var lines: [String] = []
    private(set) var wordCount = 0
    private var seen: Set<String> = []

    var isFull: Bool { self.lines.count >= DictationContextReader.maxScreenLines }

    mutating func add(_ text: String, limit: Int = .max) {
        var added = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard !self.isFull, added < limit else { return }
            let line = String(rawLine.trimmingCharacters(in: .whitespaces).prefix(DictationContextReader.maxLineCharacters))
            guard line.contains(where: \.isLetter), self.seen.insert(line).inserted else { continue }
            self.lines.append(line)
            self.wordCount += line.split(whereSeparator: \.isWhitespace).count
            added += 1
        }
    }
}
