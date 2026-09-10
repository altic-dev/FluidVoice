import Foundation

/// A view-lifetime snapshot: no disk access from row rendering and no persisted state changes.
nonisolated enum HistoryAudioAvailability {
    static func scan(
        fileNames: [String],
        exists: @escaping @Sendable (String) -> Bool
    ) async -> Set<String> {
        let worker = Task.detached(priority: .utility) {
            var available: Set<String> = []
            for fileName in Set(fileNames) {
                guard !Task.isCancelled else { return Set<String>() }
                if exists(fileName) { available.insert(fileName) }
            }
            return available
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
