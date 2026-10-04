#if arch(arm64)
import FluidAudio
import Foundation

/// Converts immutable app metadata to the library contract without consulting settings.
nonisolated extension ParakeetSpeechModelCatalog.Descriptor {
    var asrModelVersion: AsrModelVersion {
        switch self.variant {
        case .v2: .v2
        case .v3: .v3
        case .mini: .fluidParakeetMini
        case .pico: .fluidParakeetPico
        }
    }
}

nonisolated extension ParakeetSpeechModelCatalog {
    static func descriptor(forPronunciationModelKey modelKey: String) -> Descriptor? {
        self.descriptors.first { $0.pronunciationModelKey == modelKey }
    }
}
#endif
