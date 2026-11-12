import Foundation

/// macOS adapter. Loads the catalog once off the UI thread, then returns an immutable formatter snapshot.
actor DictationTextNormalizationService {
    static let shared = DictationTextNormalizationService()
    private let loadCatalog: @Sendable () -> Data?
    private var didLoadEmoji = false
    private var normalizer = FluidTextNormalizer()

    init(loadCatalog: @escaping @Sendable () -> Data? = DictationTextNormalizationService.bundledCatalog) {
        self.loadCatalog = loadCatalog
    }

    private nonisolated static func bundledCatalog() -> Data? {
        guard let url = Bundle.main.url(forResource: "fluid-text-emoji-en", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    func formatter(for text: String) -> FluidTextNormalizer {
        // A previous catalog load must not change the formatter selected
        // for later input.
        guard text.utf8.count <= FluidTextNormalizer.maximumUTF8Length,
              text.range(of: "emoji", options: .caseInsensitive) != nil else { return FluidTextNormalizer() }
        if !self.didLoadEmoji {
            self.didLoadEmoji = true
            if let data = self.loadCatalog(), let emoji = SpokenEmojiRules(data: data) {
                self.normalizer = FluidTextNormalizer(emoji: emoji)
            }
        }
        return self.normalizer
    }
}
