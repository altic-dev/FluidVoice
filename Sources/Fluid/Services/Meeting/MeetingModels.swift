import Foundation

typealias MeetingSessionID = UUID
typealias MeetingAudioTrackID = UUID
typealias MeetingAudioChunkID = UUID
typealias SessionSpeakerID = UUID
typealias MeetingTranscriptSegmentID = UUID

nonisolated enum MeetingCaptureMode: String, Codable, CaseIterable, Sendable {
    case onlineCall
    case inRoom
}

nonisolated enum MeetingSessionState: String, Codable, Sendable {
    case preparing
    case recording
    case recordingDegraded
    case stopping
    case processing
    case completed
    case interrupted
    case failed
}

nonisolated enum MeetingAudioTrackKind: String, Codable, CaseIterable, Sendable {
    case applicationAudio
    case microphone
}

nonisolated enum MeetingTrackHealthStatus: String, Codable, Sendable {
    case waiting
    case healthy
    case degraded
    case unavailable
    case stopped
}

nonisolated enum MeetingInterruptionKind: String, Codable, Sendable {
    case sourceLost
    case sourceRecovered
    case applicationExited
    case microphoneDisconnected
    case microphoneChanged
    case permissionRevoked
    case sleep
    case wake
    case clockDiscontinuity
    case lowDiskSpace
    case diskExhausted
    case appTermination
    case captureStoppedUnexpectedly
    case writerBackpressure
    case writerFailure
}

nonisolated enum MeetingFailureDomain: String, Codable, Sendable {
    case capture
    case processing
    case persistence
}

nonisolated enum MeetingProcessingStage: String, Codable, Sendable {
    case pending
    case saving
    case identifyingSpeakers
    case transcribing
    case finalizing
    case completed
}

nonisolated enum MeetingTranscriptStatus: String, Codable, Sendable {
    case provisional
    case final
}

nonisolated enum MeetingTranscriptCompleteness: String, Codable, Sendable {
    case complete
    case incompleteTrack
    case noSpeech
    case processingFailed
}

nonisolated enum MeetingTranscriptOverlap: String, Codable, Sendable {
    case none
    case overlapsOtherTrack
    case ambiguous
}

nonisolated enum MeetingMicrophoneRole: String, Codable, CaseIterable, Sendable {
    case personal
    case shared
    case unknown
}

nonisolated struct MeetingRecordingDefaults: Codable, Equatable, Sendable {
    var isConfigured: Bool
    var mode: MeetingCaptureMode
    var applicationBundleIdentifier: String?
    var microphoneCaptureDeviceID: String?
    var microphoneCoreAudioUID: String?
    var microphoneRole: MeetingMicrophoneRole

    static let unconfigured = Self(
        isConfigured: false,
        mode: .onlineCall,
        applicationBundleIdentifier: nil,
        microphoneCaptureDeviceID: nil,
        microphoneCoreAudioUID: nil,
        microphoneRole: .unknown
    )

    func savedApplication(in identities: [MeetingApplicationIdentity]) -> MeetingApplicationIdentity? {
        guard self.isConfigured, let applicationBundleIdentifier else { return nil }
        return identities.first(where: { $0.bundleIdentifier == applicationBundleIdentifier })
    }

    func savedMicrophone(in identities: [MeetingMicrophoneIdentity]) -> MeetingMicrophoneIdentity? {
        guard self.isConfigured else { return nil }
        return self.microphoneCaptureDeviceID.flatMap { captureDeviceID in
            identities.first(where: { $0.captureDeviceID == captureDeviceID })
        } ?? self.microphoneCoreAudioUID.flatMap { coreAudioUID in
            identities.first(where: { $0.coreAudioUID == coreAudioUID })
        }
    }
}

nonisolated struct MeetingApplicationIdentity: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var processID: Int32?
    var displayName: String
    var displayID: UInt32?

    init(
        bundleIdentifier: String,
        processID: Int32? = nil,
        displayName: String,
        displayID: UInt32? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.displayName = displayName
        self.displayID = displayID
    }
}

nonisolated struct MeetingMicrophoneIdentity: Codable, Equatable, Sendable {
    /// `AVCaptureDevice.uniqueID`, which is the identifier ScreenCaptureKit accepts.
    var captureDeviceID: String
    /// Kept only for reconciling the existing FluidVoice Core Audio preference.
    var coreAudioUID: String?
    var displayName: String
    var role: MeetingMicrophoneRole

    init(
        captureDeviceID: String,
        coreAudioUID: String? = nil,
        displayName: String,
        role: MeetingMicrophoneRole = .unknown
    ) {
        self.captureDeviceID = captureDeviceID
        self.coreAudioUID = coreAudioUID
        self.displayName = displayName
        self.role = role
    }
}

nonisolated struct MeetingPlatformProfile: Codable, Equatable, Sendable {
    var identifier: String
    var displayName: String
    var version: Int

    init(identifier: String, displayName: String, version: Int = 1) {
        self.identifier = identifier
        self.displayName = displayName
        self.version = version
    }
}

nonisolated struct MeetingCaptureConfiguration: Codable, Equatable, Sendable {
    static let defaultChunkDuration: TimeInterval = 60

    var mode: MeetingCaptureMode
    var title: String
    var languageCode: String
    var platform: MeetingPlatformProfile?
    var application: MeetingApplicationIdentity?
    var microphone: MeetingMicrophoneIdentity
    var chunkDuration: TimeInterval

    init(
        mode: MeetingCaptureMode,
        title: String,
        languageCode: String = "en",
        platform: MeetingPlatformProfile? = nil,
        application: MeetingApplicationIdentity? = nil,
        microphone: MeetingMicrophoneIdentity,
        chunkDuration: TimeInterval = Self.defaultChunkDuration
    ) {
        self.mode = mode
        self.title = title
        self.languageCode = languageCode
        self.platform = platform
        self.application = application
        self.microphone = microphone
        self.chunkDuration = max(60, chunkDuration)
    }

    func validate() throws {
        guard self.languageCode == "en" else {
            throw MeetingModelValidationError.unsupportedLanguage
        }
        guard !self.microphone.captureDeviceID.isEmpty else {
            throw MeetingModelValidationError.missingMicrophone
        }
        switch (self.mode, self.application) {
        case (.onlineCall, .none):
            throw MeetingModelValidationError.missingOnlineApplication
        case (.inRoom, .some):
            throw MeetingModelValidationError.unexpectedInRoomApplication
        case (.onlineCall, .some), (.inRoom, .none):
            break
        }
    }
}

nonisolated struct MeetingMediaTime: Codable, Equatable, Comparable, Sendable {
    var value: Int64
    var timescale: Int32

    var seconds: TimeInterval {
        guard self.timescale > 0 else { return 0 }
        return TimeInterval(self.value) / TimeInterval(self.timescale)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

nonisolated struct MeetingTimebaseMetadata: Codable, Equatable, Sendable {
    var startedHostTime: UInt64
    var machTimebaseNumerator: UInt32
    var machTimebaseDenominator: UInt32
    var firstPresentationTime: MeetingMediaTime?
}

nonisolated struct MeetingAudioFormat: Codable, Equatable, Sendable {
    var codec: String
    var sampleRate: Double
    var channelCount: Int
    var bitRate: Int?
}

nonisolated struct MeetingAudioDiscontinuity: Codable, Equatable, Sendable {
    var kind: MeetingInterruptionKind
    var presentationTime: MeetingMediaTime?
    var gapSeconds: TimeInterval?
    var detail: String?
}

nonisolated enum MeetingAudioChunkFinalizationState: String, Codable, Sendable {
    case writing
    case finalized
    case failed
}

nonisolated struct MeetingAudioChunk: Codable, Identifiable, Equatable, Sendable {
    var id: MeetingAudioChunkID
    var sequence: Int
    /// Relative to the session directory so sessions can be moved or exported safely.
    var relativeFilePath: String
    var presentationStart: MeetingMediaTime
    var presentationEnd: MeetingMediaTime
    var discontinuities: [MeetingAudioDiscontinuity]
    var sha256: String
    var byteCount: Int64
    var finalizationState: MeetingAudioChunkFinalizationState

    func fileURL(relativeTo sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(self.relativeFilePath, isDirectory: false)
    }
}

nonisolated struct MeetingTrackHealth: Codable, Equatable, Sendable {
    var status: MeetingTrackHealthStatus
    var lastPresentationTime: MeetingMediaTime?
    var lastSampleAt: Date?
    var level: Float
    var droppedSampleCount: Int
    var detail: String?
    /// Seconds of continuous below-threshold audio, derived from PTS durations. Optional so
    /// pre-Phase-1c persisted manifests still decode.
    var silentForSeconds: Double? = nil

    static let waiting = Self(
        status: .waiting,
        lastPresentationTime: nil,
        lastSampleAt: nil,
        level: 0,
        droppedSampleCount: 0,
        detail: nil
    )
}

nonisolated struct MeetingAudioTrack: Codable, Identifiable, Equatable, Sendable {
    var id: MeetingAudioTrackID
    var kind: MeetingAudioTrackKind
    var sourceIdentifier: String
    var sourceDisplayName: String
    var format: MeetingAudioFormat?
    var timebase: MeetingTimebaseMetadata
    var health: MeetingTrackHealth
    var chunks: [MeetingAudioChunk]
}

nonisolated struct MeetingSessionEvent: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var occurredAt: Date
    var kind: MeetingInterruptionKind
    var trackID: MeetingAudioTrackID?
    var detail: String?
}

nonisolated struct MeetingSessionFailure: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var occurredAt: Date
    var domain: MeetingFailureDomain
    var code: String
    var message: String
    var recoverable: Bool
}

nonisolated struct MeetingIdentityCandidate: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var source: String
    var rejected: Bool
    var confirmedAt: Date?
}

nonisolated struct MeetingSessionSpeaker: Codable, Identifiable, Equatable, Sendable {
    var id: SessionSpeakerID
    var displayName: String
    var diarizationClusterID: String?
    // Optional keeps older session manifests decodable after this additive field.
    // swiftlint:disable:next discouraged_optional_collection
    var diarizationEmbedding: [Float]? = nil
    var diarizationEmbeddingObservationCount: Int? = nil
    var diarizationQuality: Float? = nil
    var trackKind: MeetingAudioTrackKind
    var isLocalUser: Bool
    var identityCandidates: [MeetingIdentityCandidate]
}

nonisolated struct MeetingTranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id: MeetingTranscriptSegmentID
    var start: MeetingMediaTime
    var end: MeetingMediaTime
    var sourceTrackID: MeetingAudioTrackID
    var speakerID: SessionSpeakerID?
    var text: String
    var revision: Int
    var status: MeetingTranscriptStatus
    var overlap: MeetingTranscriptOverlap
    var completeness: MeetingTranscriptCompleteness
}

nonisolated struct MeetingProcessingAttempt: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var completedAt: Date?
    var stage: MeetingProcessingStage
    var pipelineVersion: Int
    var asrProvider: String?
    var asrModel: String?
    var languageCode: String? = nil
    var diarizationModel: String?
    var lastCompletedTrackID: MeetingAudioTrackID?
    var errorCode: String?
}

nonisolated struct MeetingRetentionState: Codable, Equatable, Sendable {
    var audioDeletedAt: Date?
    var meetingDeletedAt: Date?
    var retainAudioUntil: Date?
}

nonisolated struct MeetingSession: Codable, Identifiable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: MeetingSessionID
    var title: String
    var languageCode: String
    var mode: MeetingCaptureMode
    var platform: MeetingPlatformProfile?
    var capturedApplication: MeetingApplicationIdentity?
    var selectedMicrophone: MeetingMicrophoneIdentity
    var startedAt: Date
    var endedAt: Date?
    var timebase: MeetingTimebaseMetadata
    var state: MeetingSessionState
    var events: [MeetingSessionEvent]
    var failures: [MeetingSessionFailure]
    var audioTracks: [MeetingAudioTrack]
    var speakers: [MeetingSessionSpeaker]
    var transcriptSegments: [MeetingTranscriptSegment]
    var retention: MeetingRetentionState
    var processingAttempts: [MeetingProcessingAttempt]
    var updatedAt: Date
    /// Set when the user dismisses a recoverable session so it is not re-offered on next launch.
    /// Optional so pre-M2 persisted manifests still decode.
    var recoveryResolvedAt: Date? = nil

    init(
        id: MeetingSessionID = UUID(),
        configuration: MeetingCaptureConfiguration,
        startedAt: Date = Date(),
        timebase: MeetingTimebaseMetadata
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.title = configuration.title
        self.languageCode = configuration.languageCode
        self.mode = configuration.mode
        self.platform = configuration.platform
        self.capturedApplication = configuration.application
        self.selectedMicrophone = configuration.microphone
        self.startedAt = startedAt
        self.timebase = timebase
        self.state = .preparing
        self.events = []
        self.failures = []
        self.audioTracks = []
        self.speakers = []
        self.transcriptSegments = []
        self.retention = MeetingRetentionState(
            audioDeletedAt: nil,
            meetingDeletedAt: nil,
            retainAudioUntil: Calendar.current.date(byAdding: .day, value: 7, to: startedAt)
        )
        self.processingAttempts = []
        self.updatedAt = startedAt
    }

    var duration: TimeInterval {
        (self.endedAt ?? Date()).timeIntervalSince(self.startedAt)
    }

    mutating func renameSpeaker(id: SessionSpeakerID, to displayName: String) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingDomainError.emptySpeakerName }
        guard let index = self.speakers.firstIndex(where: { $0.id == id }) else {
            throw MeetingDomainError.speakerNotFound
        }
        self.speakers[index].displayName = trimmed
        self.updatedAt = Date()
    }

    func validateForPersistence() throws {
        guard self.schemaVersion > 0,
              self.schemaVersion <= Self.currentSchemaVersion
        else {
            throw MeetingModelValidationError.unsupportedSchema(self.schemaVersion)
        }
        guard self.languageCode == "en" else {
            throw MeetingModelValidationError.unsupportedLanguage
        }
        guard !self.selectedMicrophone.captureDeviceID.isEmpty else {
            throw MeetingModelValidationError.missingMicrophone
        }
        if let endedAt = self.endedAt, endedAt < self.startedAt {
            throw MeetingModelValidationError.invalidTimeRange
        }
        guard self.timebase.machTimebaseDenominator > 0 else {
            throw MeetingModelValidationError.invalidTimebase
        }
        switch (self.mode, self.capturedApplication) {
        case (.onlineCall, .none):
            throw MeetingModelValidationError.missingOnlineApplication
        case (.inRoom, .some):
            throw MeetingModelValidationError.unexpectedInRoomApplication
        case (.onlineCall, .some), (.inRoom, .none):
            break
        }

        let trackIDs = Set(self.audioTracks.map(\.id))
        guard trackIDs.count == self.audioTracks.count else {
            throw MeetingModelValidationError.duplicateTrackID
        }
        let trackKinds = self.audioTracks.map(\.kind)
        guard Set(trackKinds).count == trackKinds.count else {
            throw MeetingModelValidationError.duplicateTrackKind
        }
        if [.recording, .recordingDegraded, .stopping, .processing, .completed, .interrupted]
            .contains(self.state)
        {
            let expectedKinds: Set<MeetingAudioTrackKind> = self.mode == .onlineCall
                ? [.applicationAudio, .microphone]
                : [.microphone]
            guard Set(trackKinds) == expectedKinds else {
                throw MeetingModelValidationError.invalidTrackSet
            }
        }

        var chunkIDs = Set<MeetingAudioChunkID>()
        for track in self.audioTracks {
            let sequences = track.chunks.map(\.sequence)
            guard sequences == Array(0..<sequences.count) else {
                throw MeetingModelValidationError.invalidChunkSequence
            }
            if let format = track.format,
               format.sampleRate <= 0 || format.channelCount <= 0
            {
                throw MeetingModelValidationError.invalidAudioFormat
            }
            if let firstPresentationTime = track.timebase.firstPresentationTime {
                try Self.validateMediaTime(firstPresentationTime)
            }
            if let lastPresentationTime = track.health.lastPresentationTime {
                try Self.validateMediaTime(lastPresentationTime)
            }
            for chunk in track.chunks {
                guard chunkIDs.insert(chunk.id).inserted else {
                    throw MeetingModelValidationError.duplicateChunkID
                }
                try Self.validateMediaTime(chunk.presentationStart)
                try Self.validateMediaTime(chunk.presentationEnd)
                guard chunk.presentationEnd >= chunk.presentationStart else {
                    throw MeetingModelValidationError.invalidTimeRange
                }
                let pathComponents = URL(fileURLWithPath: chunk.relativeFilePath).pathComponents
                guard !chunk.relativeFilePath.hasPrefix("/"), !pathComponents.contains("..") else {
                    throw MeetingModelValidationError.invalidRelativePath
                }
                for discontinuity in chunk.discontinuities {
                    if let presentationTime = discontinuity.presentationTime {
                        try Self.validateMediaTime(presentationTime)
                    }
                }
                if chunk.finalizationState == .finalized {
                    guard !chunk.sha256.isEmpty, chunk.byteCount > 0 else {
                        throw MeetingModelValidationError.incompleteFinalizedChunk
                    }
                }
            }
        }
        if let firstPresentationTime = self.timebase.firstPresentationTime {
            try Self.validateMediaTime(firstPresentationTime)
        }

        let speakerIDs = Set(self.speakers.map(\.id))
        guard speakerIDs.count == self.speakers.count else {
            throw MeetingModelValidationError.duplicateSpeakerID
        }
        let segmentIDs = Set(self.transcriptSegments.map(\.id))
        guard segmentIDs.count == self.transcriptSegments.count else {
            throw MeetingModelValidationError.duplicateSegmentID
        }
        for segment in self.transcriptSegments {
            try Self.validateMediaTime(segment.start)
            try Self.validateMediaTime(segment.end)
            guard segment.end >= segment.start else {
                throw MeetingModelValidationError.invalidTimeRange
            }
            guard trackIDs.contains(segment.sourceTrackID) else {
                throw MeetingModelValidationError.missingSegmentTrack
            }
            if let speakerID = segment.speakerID, !speakerIDs.contains(speakerID) {
                throw MeetingModelValidationError.missingSegmentSpeaker
            }
        }
        for attempt in self.processingAttempts {
            if let languageCode = attempt.languageCode,
               languageCode != self.languageCode
            {
                throw MeetingModelValidationError.unsupportedLanguage
            }
        }
    }

    private static func validateMediaTime(_ time: MeetingMediaTime) throws {
        guard time.timescale > 0 else {
            throw MeetingModelValidationError.invalidMediaTimescale
        }
    }
}

extension MeetingSession {
    /// Shared retry/recovery predicate: ended, with at least one finalized non-empty chunk.
    var hasRetryableAudio: Bool {
        self.endedAt != nil && self.audioTracks.contains { track in
            track.chunks.contains { $0.finalizationState == .finalized && $0.byteCount > 0 }
        }
    }
}

nonisolated enum MeetingDomainError: LocalizedError, Equatable {
    case emptySpeakerName
    case speakerNotFound

    var errorDescription: String? {
        switch self {
        case .emptySpeakerName:
            return "Speaker name cannot be empty."
        case .speakerNotFound:
            return "The speaker is no longer part of this meeting."
        }
    }
}

nonisolated enum MeetingModelValidationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unsupportedLanguage
    case missingMicrophone
    case missingOnlineApplication
    case unexpectedInRoomApplication
    case duplicateTrackID
    case duplicateTrackKind
    case invalidTrackSet
    case invalidChunkSequence
    case duplicateChunkID
    case invalidTimeRange
    case invalidMediaTimescale
    case invalidTimebase
    case invalidAudioFormat
    case invalidRelativePath
    case incompleteFinalizedChunk
    case duplicateSpeakerID
    case duplicateSegmentID
    case missingSegmentTrack
    case missingSegmentSpeaker

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported meeting schema version \(version)."
        case .unsupportedLanguage:
            return "Meeting transcription currently supports English only."
        case .missingMicrophone:
            return "A microphone must be selected."
        case .missingOnlineApplication:
            return "An online meeting application must be selected."
        case .unexpectedInRoomApplication:
            return "In-room meetings cannot include an application-audio source."
        case .duplicateTrackID, .duplicateTrackKind, .invalidTrackSet:
            return "The meeting has an invalid audio track manifest."
        case .invalidChunkSequence, .duplicateChunkID, .invalidTimeRange, .invalidMediaTimescale,
             .invalidTimebase, .invalidAudioFormat, .invalidRelativePath, .incompleteFinalizedChunk:
            return "The meeting has an invalid audio chunk manifest."
        case .duplicateSpeakerID, .duplicateSegmentID, .missingSegmentTrack, .missingSegmentSpeaker:
            return "The meeting transcript contains invalid references."
        }
    }
}

nonisolated enum MeetingCaptureEvent: Sendable {
    case trackHealth(trackID: MeetingAudioTrackID, health: MeetingTrackHealth)
    case chunkFinalized(trackID: MeetingAudioTrackID, chunk: MeetingAudioChunk, format: MeetingAudioFormat)
    case interrupted(kind: MeetingInterruptionKind, trackID: MeetingAudioTrackID?, detail: String?)
}

/// The scope ScreenCaptureKit was filtering to for this capture. `nil` when the runtime has no
/// ScreenCaptureKit stream at all (in-room microphone-only capture).
nonisolated enum MeetingCaptureScope: Sendable {
    case display
    case window
}

nonisolated struct MeetingCaptureStartResult: Sendable {
    var tracks: [MeetingAudioTrack]
    var firstPresentationTime: MeetingMediaTime?
    var captureScope: MeetingCaptureScope? = nil
}

nonisolated struct MeetingCaptureStopResult: Sendable {
    var tracks: [MeetingAudioTrack]
    var stoppedAt: Date
}

nonisolated struct MeetingProcessingResult: Sendable {
    var speakers: [MeetingSessionSpeaker]
    var segments: [MeetingTranscriptSegment]
    var attempt: MeetingProcessingAttempt
    var skippedChunkIDs: [MeetingAudioChunkID] = []
}

/// Resume point written after the application-audio pass so a retry can skip re-diarizing and
/// re-transcribing that track. `trackFingerprints` cover every track's finalized, byteCount>0
/// chunks (origin depends on all chunks), but deliberately NOT `embeddingIndexByTrack`: only the
/// microphone pass reads `embeddingIndexByTrack[.microphone]`, so a resumed run keeps the
/// embeddings already stored on `MeetingSessionSpeaker` instead of rebuilding that index.
nonisolated struct MeetingProcessingCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 1

    nonisolated struct ChunkFingerprint: Codable, Equatable, Sendable {
        var id: MeetingAudioChunkID
        var byteCount: Int64
        var sha256: String
    }

    nonisolated struct SpeechInterval: Codable, Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
    }

    var version: Int
    var sessionID: MeetingSessionID
    var pipelineVersion: Int
    var asrProvider: String
    var asrModel: String
    var languageCode: String
    var completedTrackID: MeetingAudioTrackID
    var trackFingerprints: [MeetingAudioTrackID: [ChunkFingerprint]]
    var speakers: [MeetingSessionSpeaker]
    var segments: [MeetingTranscriptSegment]
    var remoteSpeech: [SpeechInterval]
    var speakerIDByKey: [String: SessionSpeakerID]
    var nextRemoteSpeaker: Int
    var nextMicrophoneSpeaker: Int

    static func fingerprints(for tracks: [MeetingAudioTrack]) -> [MeetingAudioTrackID: [ChunkFingerprint]] {
        Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.id, track.chunks
                .filter { $0.finalizationState == .finalized && $0.byteCount > 0 }
                .map { ChunkFingerprint(id: $0.id, byteCount: $0.byteCount, sha256: $0.sha256) })
        })
    }

    func isValid(
        session: MeetingSession,
        pipelineVersion: Int,
        provider: String,
        model: String,
        language: String,
        completedTrackID: MeetingAudioTrackID,
        expectedFingerprints: [MeetingAudioTrackID: [ChunkFingerprint]]
    ) -> Bool {
        self.version == Self.currentVersion
            && self.sessionID == session.id
            && self.pipelineVersion == pipelineVersion
            && self.asrProvider == provider
            && self.asrModel == model
            && self.languageCode == language
            && self.completedTrackID == completedTrackID
            && self.trackFingerprints == expectedFingerprints
    }
}
