import AppKit
import SwiftUI

/// Small presentation cache shared by history rows; no application lookup during rendering.
@MainActor
private final class HistoryAppIconCache {
    static let shared = HistoryAppIconCache()

    private final class Result {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private let cache = NSCache<NSString, Result>()
    private var pending: [String: Task<NSImage?, Never>] = [:]

    private init() {
        self.cache.countLimit = 48
    }

    func icon(for name: String) async -> NSImage? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let result = self.cache.object(forKey: name as NSString) { return result.image }
        if let task = self.pending[name] { return await task.value }
        guard self.pending.count < 48 else { return nil }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard let path = NSWorkspace.shared.fullPath(forApplication: name) else { return nil }
            return NSWorkspace.shared.icon(forFile: path)
        }
        self.pending[name] = task
        let image = await task.value
        self.cache.setObject(Result(image), forKey: name as NSString)
        self.pending[name] = nil
        return image
    }
}

struct HistoryAppIcon: View {
    let appName: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(self.appName.isEmpty ? "Unknown app" : self.appName)
        .help(self.appName.isEmpty ? "Unknown app" : self.appName)
        .task(id: self.appName) {
            self.image = nil
            let image = await HistoryAppIconCache.shared.icon(for: self.appName)
            guard !Task.isCancelled else { return }
            self.image = image
        }
    }
}
