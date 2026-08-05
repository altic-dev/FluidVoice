import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum MeetingTranscriptionFileImport {
    nonisolated static let promisedFileContentTypeIdentifier = "com.apple.pasteboard.promised-file-content-type"

    nonisolated static var dropContentTypes: [UTType] {
        self.uniqueTypes([UTType.fileURL, .audio, .movie])
    }

    nonisolated static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        self.uniquePasteboardTypes(
            [NSPasteboard.PasteboardType.fileURL] +
                NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        )
    }

    nonisolated static func supportedURLs(from urls: [URL]) -> [URL] {
        self.uniqueURLs(urls).filter(self.isSupportedFile)
    }

    nonisolated static func isSupportedFile(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        return MeetingTranscriptionService.supportedFileExtensions.contains(fileExtension)
    }

    nonisolated static func isSupportedTypeIdentifier(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else {
            return identifier == self.promisedFileContentTypeIdentifier
        }

        if type.conforms(to: .audio) || type.conforms(to: .movie) {
            return true
        }

        if let fileExtension = type.preferredFilenameExtension?.lowercased(),
           MeetingTranscriptionService.supportedFileExtensions.contains(fileExtension)
        {
            return true
        }

        return identifier == self.promisedFileContentTypeIdentifier
    }

    nonisolated static func candidateFileRepresentationTypes(for provider: NSItemProvider) -> [String] {
        let supported = provider.registeredTypeIdentifiers.filter(self.isSupportedTypeIdentifier)
        return self.uniqueIdentifiers(supported)
    }

    nonisolated static func promisedFileDestinationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-PromisedFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func persistedTemporaryCopy(of url: URL, suggestedName: String?) throws -> URL {
        let directory = try self.promisedFileDestinationDirectory()
        let rawName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName: String
        if let rawName, !rawName.isEmpty {
            fileName = rawName
        } else {
            fileName = url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent
        }
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    nonisolated static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        func append(_ url: URL?) {
            guard let url else { return }
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    append(url)
                }
                continue
            }

            guard let typeIdentifier = self.candidateFileRepresentationTypes(for: provider).first else {
                continue
            }

            let suggestedName = provider.suggestedName
            group.enter()
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, isInPlace, _ in
                defer { group.leave() }
                guard let url else { return }

                if isInPlace {
                    append(url)
                    return
                }

                do {
                    append(try self.persistedTemporaryCopy(of: url, suggestedName: suggestedName))
                } catch {
                    DebugLogger.shared.error("Failed to persist dropped file: \(error)", source: "MeetingTranscriptionFileImport")
                }
            }
        }

        group.notify(queue: .main) {
            completion(self.supportedURLs(from: urls))
        }
    }

    private nonisolated static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private nonisolated static func uniqueTypes(_ types: [UTType]) -> [UTType] {
        var seen: Set<String> = []
        var result: [UTType] = []
        for type in types {
            guard seen.insert(type.identifier).inserted else { continue }
            result.append(type)
        }
        return result
    }

    private nonisolated static func uniquePasteboardTypes(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        var seen: Set<String> = []
        var result: [NSPasteboard.PasteboardType] = []
        for type in types {
            guard seen.insert(type.rawValue).inserted else { continue }
            result.append(type)
        }
        return result
    }

    private nonisolated static func uniqueIdentifiers(_ identifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for identifier in identifiers {
            guard seen.insert(identifier).inserted else { continue }
            result.append(identifier)
        }
        return result
    }
}

struct MeetingTranscriptionFileDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onResolved: ([URL]) -> Void
    let onRejected: () -> Void

    func makeNSView(context _: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes(MeetingTranscriptionFileImport.pasteboardTypes)
        view.onTargetedChanged = { targeted in
            DispatchQueue.main.async {
                self.isTargeted = targeted
            }
        }
        view.onResolved = { urls in
            DispatchQueue.main.async {
                self.onResolved(urls)
            }
        }
        view.onRejected = {
            DispatchQueue.main.async {
                self.onRejected()
            }
        }
        return view
    }

    func updateNSView(_ nsView: DropView, context _: Context) {
        nsView.onTargetedChanged = { targeted in
            DispatchQueue.main.async {
                self.isTargeted = targeted
            }
        }
        nsView.onResolved = { urls in
            DispatchQueue.main.async {
                self.onResolved(urls)
            }
        }
        nsView.onRejected = {
            DispatchQueue.main.async {
                self.onRejected()
            }
        }
    }

    final class DropView: NSView {
        var onTargetedChanged: ((Bool) -> Void)?
        var onResolved: (([URL]) -> Void)?
        var onRejected: (() -> Void)?

        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "FluidVoice.PromiseDropQueue"
            queue.qualityOfService = .userInitiated
            return queue
        }()

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard self.canAccept(sender) else { return [] }
            self.onTargetedChanged?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            self.canAccept(sender) ? .copy : []
        }

        override func draggingExited(_: NSDraggingInfo?) {
            self.onTargetedChanged?(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            self.canAccept(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            self.onTargetedChanged?(false)

            let pasteboard = sender.draggingPasteboard
            let urls = self.fileURLs(from: pasteboard)
            let supportedURLs = MeetingTranscriptionFileImport.supportedURLs(from: urls)
            if !supportedURLs.isEmpty {
                self.onResolved?(supportedURLs)
            }

            let receivers = self.filePromiseReceivers(from: pasteboard)
            let acceptedPromises = receivers.filter(self.canAcceptPromise)
            for receiver in acceptedPromises {
                self.receivePromisedFiles(receiver)
            }

            let handled = !supportedURLs.isEmpty || !acceptedPromises.isEmpty
            if !handled {
                self.onRejected?()
            }
            return handled
        }

        private func canAccept(_ sender: NSDraggingInfo) -> Bool {
            let pasteboard = sender.draggingPasteboard
            if !MeetingTranscriptionFileImport.supportedURLs(from: self.fileURLs(from: pasteboard)).isEmpty {
                return true
            }
            return self.filePromiseReceivers(from: pasteboard).contains(where: self.canAcceptPromise)
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        }

        private func filePromiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        }

        private func canAcceptPromise(_ receiver: NSFilePromiseReceiver) -> Bool {
            receiver.fileTypes.isEmpty || receiver.fileTypes.contains(where: MeetingTranscriptionFileImport.isSupportedTypeIdentifier)
        }

        private func receivePromisedFiles(_ receiver: NSFilePromiseReceiver) {
            do {
                let destination = try MeetingTranscriptionFileImport.promisedFileDestinationDirectory()
                receiver.receivePromisedFiles(
                    atDestination: destination,
                    options: [:],
                    operationQueue: self.promiseQueue
                ) { [weak self] fileURL, error in
                    guard let self else { return }
                    if let error {
                        DebugLogger.shared.error("Promised file drop failed: \(error)", source: "MeetingTranscriptionFileImport")
                        self.onRejected?()
                        return
                    }

                    let urls = MeetingTranscriptionFileImport.supportedURLs(from: [fileURL])
                    if urls.isEmpty {
                        self.onRejected?()
                    } else {
                        self.onResolved?(urls)
                    }
                }
            } catch {
                DebugLogger.shared.error("Failed to prepare promised file destination: \(error)", source: "MeetingTranscriptionFileImport")
                self.onRejected?()
            }
        }
    }
}
