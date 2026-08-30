import AppKit
import Foundation

@MainActor
final class CodexHandoffService {
    static let shared = CodexHandoffService()

    private static let codexBundleID = "com.openai.codex"
    private static let pasteboardSessionSemaphore = DispatchSemaphore(value: 1)
    private static let bundledCodexCLIPath = "/Applications/Codex.app/Contents/Resources/codex"

    private init() {}

    struct HandoffResult {
        let success: Bool
        let message: String
    }

    enum HandoffStyle: Equatable {
        case notch
        case app

        init(rawValue: String) {
            self = rawValue == "app" ? .app : .notch
        }
    }

    private struct PasteboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    func sendToCodex(_ text: String, style: HandoffStyle) async -> HandoffResult {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return HandoffResult(success: false, message: "No command text to send to Codex.")
        }

        switch style {
        case .notch:
            return await self.runCodexInNotch(prompt)
        case .app:
            return await self.sendToCodexApp(prompt)
        }
    }

    private func sendToCodexApp(_ prompt: String) async -> HandoffResult {
        guard await self.activateCodex() else {
            return HandoffResult(success: false, message: "Could not open Codex.")
        }

        try? await Task.sleep(nanoseconds: 250_000_000)

        guard await self.pasteAndSubmit(prompt) else {
            return HandoffResult(success: false, message: "Could not paste into Codex.")
        }

        return HandoffResult(success: true, message: "Sent to Codex.")
    }

    private func runCodexInNotch(_ prompt: String) async -> HandoffResult {
        guard FileManager.default.isExecutableFile(atPath: Self.bundledCodexCLIPath) else {
            return HandoffResult(success: false, message: "Codex CLI was not found.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.bundledCodexCLIPath)
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.arguments = [
            "-a", "never",
            "exec",
            "--skip-git-repo-check",
            "--color", "never",
            "-C", NSHomeDirectory(),
            "-o", outputURL.path,
            "-"
        ]

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            DebugLogger.shared.error("Failed to start Codex CLI: \(error.localizedDescription)", source: "CodexHandoffService")
            return HandoffResult(success: false, message: "Could not start Codex.")
        }

        if let data = prompt.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        let completed = await self.waitForProcess(process, timeout: 120)
        guard completed else {
            process.terminate()
            return HandoffResult(success: false, message: "Codex took too long and was stopped.")
        }

        guard process.terminationStatus == 0 else {
            return HandoffResult(success: false, message: "Codex finished with an error.")
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            return HandoffResult(success: true, message: "Codex finished.")
        }

        return HandoffResult(success: true, message: output)
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            func resume(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }

            process.terminationHandler = { _ in
                resume(true)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume(false)
            }
        }
    }

    private func activateCodex() async -> Bool {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.codexBundleID }) {
            return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleID) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    DebugLogger.shared.error("Failed to launch Codex: \(error.localizedDescription)", source: "CodexHandoffService")
                    continuation.resume(returning: false)
                    return
                }
                _ = app?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                continuation.resume(returning: app != nil)
            }
        }
    }

    private func pasteAndSubmit(_ text: String) async -> Bool {
        Self.pasteboardSessionSemaphore.wait()

        let pasteboard = NSPasteboard.general
        let snapshot = self.capturePasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            Self.pasteboardSessionSemaphore.signal()
            return false
        }

        guard self.sendCommandKey("v") else {
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            Self.pasteboardSessionSemaphore.signal()
            return false
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        guard self.sendReturnKey() else {
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            Self.pasteboardSessionSemaphore.signal()
            return false
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        self.restorePasteboardSnapshot(snapshot, to: pasteboard)
        Self.pasteboardSessionSemaphore.signal()

        return true
    }

    private func sendCommandKey(_ character: Character) -> Bool {
        guard let keyCode = Self.keyCode(for: character),
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(10_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func sendReturnKey() -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
        else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        usleep(10_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func keyCode(for character: Character) -> CGKeyCode? {
        switch character.lowercased() {
        case "v": return 9
        default: return nil
        }
    }

    private func capturePasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [PasteboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }
}
