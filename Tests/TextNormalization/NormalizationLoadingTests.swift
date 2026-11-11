import Foundation

enum NormalizationLoadingTests {
    private final class CatalogSource: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        let data: Data?

        init(data: Data?) { self.data = data }

        func load() -> Data? {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.reads += 1
            return self.data
        }

        var loadCount: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.reads
        }
    }

    static func run(data: Data) async {
        let source = CatalogSource(data: data)
        let service = DictationTextNormalizationService(loadCatalog: { source.load() })
        let quantities = await service.formatter(for: "five euros")
        precondition(source.loadCount == 0)
        precondition(quantities.normalize("five euros", phase: .afterCleanup) == "€5")
        let oversized = String(repeating: "fire emoji ", count: 7000)
        _ = await service.formatter(for: oversized)
        precondition(source.loadCount == 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let formatter = await service.formatter(for: "fire emoji")
                    precondition(formatter.normalize("fire emoji", phase: .afterCleanup) == "🔥")
                }
            }
        }
        precondition(source.loadCount == 1)
        let laterQuantities = await service.formatter(for: "five euros")
        precondition(laterQuantities.normalize("fire emoji", phase: .afterCleanup) == "fire emoji")
        let laterOversized = await service.formatter(for: oversized)
        precondition(laterOversized.normalize("fire emoji", phase: .afterCleanup) == "fire emoji")
        precondition(source.loadCount == 1)
        // A snapshot already handed to a dictation never gains rules from a later call.
        precondition(quantities.normalize("fire emoji", phase: .afterCleanup) == "fire emoji")
        let missing = CatalogSource(data: nil)
        let fallback = DictationTextNormalizationService(loadCatalog: { missing.load() })
        for _ in 0..<3 {
            let formatter = await fallback.formatter(for: "five euros fire emoji")
            precondition(formatter.normalize("five euros fire emoji", phase: .afterCleanup) == "€5 fire emoji")
        }
        precondition(missing.loadCount == 1)
        print("PASS: lazy catalog loading, concurrent load coalescing, stable snapshots, missing-resource fallback")
    }
}
