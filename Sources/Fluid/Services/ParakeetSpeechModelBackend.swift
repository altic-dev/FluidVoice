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

#endif
