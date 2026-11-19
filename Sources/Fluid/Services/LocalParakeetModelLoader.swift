#if arch(arm64)
import CoreML
import FluidAudio
import Foundation

nonisolated enum LocalParakeetModelLoader {
    enum LoadError: LocalizedError {
        case missingProPreprocessor

        var errorDescription: String? {
            "The Fluid Speech Pro audio processor is missing from this app. Reinstall FluidVoice to restore it."
        }
    }

    static func preprocessorURL(for version: AsrModelVersion, archiveSHA256: String?) throws -> URL? {
        guard version == .fluidParakeetPro,
              archiveSHA256 == ParakeetSpeechModelCatalog.proVersion1ArchiveSHA256
        else { return nil }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: FluidAudioProvider.self)
        #endif
        guard let url = bundle.url(forResource: "FluidSpeechProPreprocessor", withExtension: "mlmodelc") else {
            throw LoadError.missingProPreprocessor
        }
        return url
    }

    static func load(from directory: URL, version: AsrModelVersion, archiveSHA256: String?) async throws -> AsrModels {
        let replacement = try self.preprocessorURL(for: version, archiveSHA256: archiveSHA256)
        let models = try await AsrModels.loadLocalOnly(from: directory, version: version)
        guard let replacement else { return models }
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let preprocessor = try await MLModel.load(contentsOf: replacement, configuration: configuration)
        try Task.checkCancellation()
        return AsrModels(
            encoder: models.encoder,
            preprocessor: preprocessor,
            decoder: models.decoder,
            joint: models.joint,
            configuration: models.configuration,
            vocabulary: models.vocabulary,
            version: models.version,
            splitEncoder: models.splitEncoder
        )
    }
}
#endif
