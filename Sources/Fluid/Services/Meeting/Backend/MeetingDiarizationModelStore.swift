import Combine
import Foundation

/// Downloads and installs the Nemotron 3 Diarization package from Hugging Face.
///
/// The model is only needed after a recording stops, so opening FluidMeet starts the download in
/// the background and final processing awaits it. One attempt runs at a time and every caller
/// shares its result; a failed attempt ends in `.failed` and the next call starts a fresh one.
@MainActor
final class MeetingDiarizationModelStore: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(fraction: Double)
        case ready(MeetingNemotronModelArtifact)
        case failed(message: String)
    }

    /// Carries the same plain message the settings row shows, so a meeting whose processing
    /// waited on a failed download explains itself instead of showing a raw network code.
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }

    static let shared = MeetingDiarizationModelStore()

    static let repositoryOwner = "altic-dev"
    static let repositoryName = "nemotron-3-diarization-coreml"
    /// Pinned so a later push to the repository can never change an installed app's model.
    static let repositoryRevision = "8976c3c40a752cd6468a08f2aa08626770bc048f"

    typealias Validate = @Sendable () throws -> MeetingNemotronModelArtifact
    typealias Install = @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws
        -> MeetingNemotronModelArtifact

    @Published private(set) var state: State = .idle
    private var attempt: Task<MeetingNemotronModelArtifact, Error>?
    private let canDownload: @Sendable () -> Bool
    private let validate: Validate
    private let install: Install

    init(
        canDownload: @escaping @Sendable () -> Bool = MeetingDiarizationModelStore.usesDefaultLocation,
        validate: @escaping Validate = {
            let package = MeetingNemotronModelLocator().resolvedPackageURL()
            _ = try MeetingModelInstaller.validatedSilenceEmbedding(
                at: MeetingModelInstaller.silenceEmbeddingURL(besides: package)
            )
            return try MeetingModelInstaller.validate(package)
        },
        install: @escaping Install = MeetingDiarizationModelStore.downloadAndInstall
    ) {
        self.canDownload = canDownload
        self.validate = validate
        self.install = install
    }

    /// Starts a check, and a download when needed, without waiting for it.
    func prepareInBackground() {
        Task { _ = try? await self.ensureInstalled() }
    }

    /// Returns the installed model, downloading it first when it is missing or damaged.
    @discardableResult
    func ensureInstalled() async throws -> MeetingNemotronModelArtifact {
        if let attempt { return try await attempt.value }
        let attempt = Task { @MainActor in
            // Cleared before the result is delivered, so a caller reacting to a failure can
            // immediately start a fresh attempt.
            defer { self.attempt = nil }
            return try await self.run()
        }
        self.attempt = attempt
        return try await attempt.value
    }

    private func run() async throws -> MeetingNemotronModelArtifact {
        self.state = .checking
        let validate = self.validate
        if let installed = try? await Task.detached(priority: .utility, operation: validate).value {
            self.state = .ready(installed)
            return installed
        }
        guard CPUArchitecture.isAppleSilicon else {
            self.state = .failed(message: "Speaker labels need an Apple silicon Mac.")
            throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
        }
        guard self.canDownload() else {
            let error = MeetingNemotronModelReadinessError.invalidModelPackage(reason: "developmentOverrideInvalid")
            self.state = .failed(message: "The development model path is missing or invalid. Remove the override and restart FluidVoice.")
            throw error
        }

        self.state = .downloading(fraction: 0)
        do {
            let installed = try await self.install { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: fraction)
                }
            }
            self.state = .ready(installed)
            return installed
        } catch {
            DebugLogger.shared.error(
                "Speaker model download failed: \(error.localizedDescription)",
                source: "MeetingDiarizationModelStore"
            )
            let message = Self.userMessage(for: error)
            self.state = .failed(message: message)
            throw DownloadError(message: message)
        }
    }

    nonisolated static func usesDefaultLocation() -> Bool {
        MeetingNemotronModelLocator().resolvedPackageURL().standardizedFileURL
            == MeetingNemotronModelLocator.defaultPackageURL().standardizedFileURL
    }

    /// Downloads into a stable staging folder, so an interrupted download resumes file by file,
    /// then hands the package to the checksum-pinned installer.
    nonisolated static func downloadAndInstall(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingNemotronModelArtifact {
        let destination = MeetingNemotronModelLocator.defaultPackageURL()
        let staging = destination.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("download-\(MeetingNemotronModelLocator.cacheVersion)", isDirectory: true)
        let downloader = HuggingFaceModelDownloader(
            owner: Self.repositoryOwner,
            repo: Self.repositoryName,
            revision: Self.repositoryRevision,
            requiredItems: [
                .init(path: MeetingNemotronModelLocator.packageFileName, isDirectory: true),
                .init(path: MeetingModelInstaller.silenceEmbeddingFileName, isDirectory: false),
            ]
        )
        try await downloader.ensureModelsPresent(at: staging) { fraction, _ in progress(fraction) }
        let downloaded = staging.appendingPathComponent(MeetingNemotronModelLocator.packageFileName, isDirectory: true)
        do {
            let installed = try await Task.detached(priority: .utility) {
                try MeetingModelInstaller.installSilenceEmbedding(
                    from: staging.appendingPathComponent(MeetingModelInstaller.silenceEmbeddingFileName),
                    besides: destination
                )
                return try MeetingModelInstaller.install(from: downloaded, to: destination)
            }.value
            try? FileManager.default.removeItem(at: staging)
            return installed
        } catch MeetingModelInstaller.InstallError.wrongPackage {
            // A damaged download would otherwise be "resumed" forever; start clean next time.
            try? FileManager.default.removeItem(at: staging)
            throw MeetingModelInstaller.InstallError.wrongPackage
        }
    }

    nonisolated static func userMessage(for error: Error) -> String {
        if error is MeetingModelInstaller.InstallError {
            return "The downloaded speaker model was damaged. Try again."
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Couldn't download the speaker model. Check your internet connection and try again."
        }
        if nsError.domain == "HF", [401, 403, 404].contains(nsError.code) {
            return "The speaker model isn't available for download right now. Try again later."
        }
        return "Couldn't download the speaker model (\(error.localizedDescription)). Try again."
    }
}
