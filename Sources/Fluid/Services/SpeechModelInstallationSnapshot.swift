import Combine
import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// UI reads immutable IDs. Only an event-triggered worker inspects downloaded files.
@MainActor
final class SpeechModelInstallationSnapshot: ObservableObject {
    static let shared = SpeechModelInstallationSnapshot()

    nonisolated enum State: Equatable, Sendable {
        case checking, ready, failed
    }

    nonisolated struct Probe: Sendable {
        nonisolated enum Kind: Sendable {
            case builtIn
            case parakeet(ParakeetSpeechModelCatalog.Descriptor)
            case realtime(folder: String, requiredModels: [String])
            case cohere(ExternalCoreMLASRModelSpec, storedPath: String?)
            case nemotron(folder: String)
            case whisper(file: String, expectedBytes: Int64)
            case unavailable
        }

        let modelID: String
        let kind: Kind
    }

    typealias Scanner = @Sendable ([Probe]) async throws -> Set<String>
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var state: State = .checking
    var isChecking: Bool { self.state == .checking }
    var canUseModelActions: Bool { self.state == .ready }

    private let capture: @MainActor () -> [Probe]
    private let scanner: Scanner
    private let timeoutNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var pending: (generation: UInt64, probes: [Probe])?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var deadlineID: UUID?

    init(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        capture: @escaping @MainActor () -> [Probe] = SpeechModelInstallationSnapshot.captureProbes,
        scanner: @escaping Scanner = { try await SpeechModelInstallationSnapshot.scan($0) }
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.capture = capture
        self.scanner = scanner
    }

    func isInstalled(modelID: String) -> Bool { self.installedIDs.contains(modelID) }

    /// Keep at most one worker and one latest request. Byte-progress callbacks never call this.
    func refresh() {
        self.generation &+= 1
        self.pending = (self.generation, self.capture())
        self.state = .checking
        if self.deadline == nil {
            let id = UUID()
            self.deadlineID = id
            self.deadline = Task { [weak self, timeoutNanoseconds] in
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                guard !Task.isCancelled, let self, self.deadlineID == id, self.state == .checking else { return }
                self.cancel()
            }
        }
        self.startWorkerIfNeeded()
    }

    /// A slow/unavailable volume has a visible bounded exit. A canceled worker must
    /// actually drain before a replacement starts, even when filesystem IO cannot cancel.
    func cancel() {
        self.generation &+= 1
        self.pending = nil
        self.worker?.cancel()
        self.deadline?.cancel()
        self.deadline = nil
        self.deadlineID = nil
        self.installedIDs = []
        self.state = .failed
    }

    private func startWorkerIfNeeded() {
        guard self.worker == nil, self.pending != nil else { return }
        self.worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = self.pending {
                self.pending = nil
                do {
                    let installed = try await self.scanner(request.probes)
                    guard !Task.isCancelled, request.generation == self.generation else { continue }
                    self.installedIDs = installed
                    self.state = .ready
                    self.finishDeadline()
                } catch {
                    guard !Task.isCancelled, request.generation == self.generation else { continue }
                    self.installedIDs = []
                    self.state = .failed
                    self.finishDeadline()
                }
            }
            self.worker = nil
            self.startWorkerIfNeeded()
        }
    }

    private func finishDeadline() {
        self.deadline?.cancel()
        self.deadline = nil
        self.deadlineID = nil
    }

    private static func captureProbes() -> [Probe] {
        SettingsStore.SpeechModel.availableModels.map { model in
            let kind: Probe.Kind
            if let descriptor = model.parakeetDescriptor {
                kind = .parakeet(descriptor)
            } else if let spec = model.externalCoreMLSpec {
                kind = .cohere(spec, storedPath: SettingsStore.shared.storedExternalCoreMLArtifactsPath(for: model))
            } else if let file = model.whisperModelFile {
                kind = .whisper(file: file, expectedBytes: model.expectedDownloadBytes)
            } else {
                switch model {
                case .appleSpeech, .appleSpeechAnalyzer:
                    kind = .builtIn
                case .parakeetRealtime:
                    #if canImport(FluidAudio)
                    kind = .realtime(folder: Repo.parakeetEou160.folderName, requiredModels: Array(ModelNames.ParakeetEOU.requiredModels).sorted())
                    #else
                    kind = .unavailable
                    #endif
                case .nemotronOffline:
                    kind = .nemotron(folder: "nemotron-3.5-asr-offline-6bit-CoreML")
                case .nemotronStreaming, .nemotronStreaming320:
                    kind = .nemotron(folder: "nemotron-3.5-asr-streaming320-int8-CoreML")
                default:
                    kind = .unavailable
                }
            }
            return Probe(modelID: model.id, kind: kind)
        }
    }

    @concurrent static func scan(_ probes: [Probe], cachesDirectory: URL? = nil, modelsDirectory: URL? = nil) async throws -> Set<String> {
        var installed: Set<String> = []
        let fm = FileManager.default
        let caches = cachesDirectory ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let models = modelsDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
        for probe in probes {
            try Task.checkCancellation()
            let exists: Bool
            switch probe.kind {
            case .builtIn:
                exists = true
            case let .parakeet(descriptor):
                exists = models.map { descriptor.artifactsAreComplete(at: descriptor.cacheDirectory(in: $0)) } ?? false
            case let .realtime(folder, requiredModels):
                let directory = models?.appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                    .appendingPathComponent(folder, isDirectory: true)
                exists = directory.map { root in
                    requiredModels.allSatisfy {
                        HuggingFaceModelDownloader.artifactIsComplete(at: root.appendingPathComponent($0), isDirectory: $0.hasSuffix(".mlmodelc"))
                    }
                } ?? false
            case let .cohere(spec, storedPath):
                let directory = storedPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? spec.defaultCacheDirectory
                exists = directory.map { spec.validatesInstalledArtifacts(at: $0) } ?? false
            case let .nemotron(folder):
                #if arch(arm64)
                exists = caches.map { NemotronProvider.artifactsAreComplete(at: $0.appendingPathComponent(folder, isDirectory: true)) } ?? false
                #else
                exists = false
                #endif
            case let .whisper(file, expectedBytes):
                let url = caches?.appendingPathComponent("WhisperModels", isDirectory: true).appendingPathComponent(file)
                let attributes = url.flatMap { try? fm.attributesOfItem(atPath: $0.path) }
                exists = expectedBytes > 0 && (attributes?[.size] as? NSNumber)?.int64Value == expectedBytes
            case .unavailable:
                exists = false
            }
            if exists { installed.insert(probe.modelID) }
        }
        try Task.checkCancellation()
        return installed
    }
}
