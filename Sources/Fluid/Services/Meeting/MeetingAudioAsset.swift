import Foundation

/// Additive audio-asset vocabulary. Unknown values are retained verbatim so a future asset can be
/// quarantined without making the containing session undecodable.
nonisolated enum MeetingAudioAssetRole: Equatable, Sendable {
    case captureAnalysis
    case playbackArchive
    case unknown(String)

    var rawValue: String {
        switch self { case .captureAnalysis: return "captureAnalysis"; case .playbackArchive: return "playbackArchive"; case let .unknown(raw): return raw }
    }
    init(rawValue: String) { self = rawValue == "captureAnalysis" ? .captureAnalysis : rawValue == "playbackArchive" ? .playbackArchive : .unknown(rawValue) }
}

nonisolated extension MeetingAudioAssetRole: Codable {
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

nonisolated enum MeetingAudioEncoding: Equatable, Hashable, Sendable {
    case linearPCMFloat32CAFV1
    case aacLCM4AV1
    case legacyAACUnknownPrimingV1
    case unknown(String)

    var rawValue: String {
        switch self { case .linearPCMFloat32CAFV1: return "linearPCMFloat32CAFV1"; case .aacLCM4AV1: return "aacLCM4AV1"; case .legacyAACUnknownPrimingV1: return "legacyAACUnknownPrimingV1"; case let .unknown(raw): return raw }
    }
    init(rawValue: String) {
        switch rawValue { case "linearPCMFloat32CAFV1": self = .linearPCMFloat32CAFV1; case "aacLCM4AV1": self = .aacLCM4AV1; case "legacyAACUnknownPrimingV1": self = .legacyAACUnknownPrimingV1; default: self = .unknown(rawValue) }
    }
}

nonisolated extension MeetingAudioEncoding: Codable {
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

nonisolated enum MeetingAudioAssetPresence: Equatable, Sendable {
    case partial
    case ready
    case evicted
    case failed
    case unknown(String)

    var rawValue: String {
        switch self { case .partial: return "partial"; case .ready: return "ready"; case .evicted: return "evicted"; case .failed: return "failed"; case let .unknown(raw): return raw }
    }
    init(rawValue: String) {
        switch rawValue { case "partial": self = .partial; case "ready": self = .ready; case "evicted": self = .evicted; case "failed": self = .failed; default: self = .unknown(rawValue) }
    }
}

nonisolated extension MeetingAudioAssetPresence: Codable {
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

nonisolated struct MeetingAudioAsset: Codable, Equatable, Sendable {
    var role: MeetingAudioAssetRole
    var encoding: MeetingAudioEncoding
    var presence: MeetingAudioAssetPresence
    var relativeFilePath: String
    var byteCount: Int64
    var sha256: String?
    var sampleRate: Double?
    var channelCount: Int?
    var frameCount: Int64?
    var sourceAssetSHA256: String?

    init(role: MeetingAudioAssetRole, encoding: MeetingAudioEncoding, presence: MeetingAudioAssetPresence,
         relativeFilePath: String, byteCount: Int64, sha256: String? = nil, sampleRate: Double? = nil,
         channelCount: Int? = nil, frameCount: Int64? = nil, sourceAssetSHA256: String? = nil) {
        self.role = role; self.encoding = encoding; self.presence = presence; self.relativeFilePath = relativeFilePath; self.byteCount = byteCount
        self.sha256 = sha256; self.sampleRate = sampleRate; self.channelCount = channelCount; self.frameCount = frameCount; self.sourceAssetSHA256 = sourceAssetSHA256
    }

    /// Pure metadata validation. It performs no path or filesystem access and callers may use the
    /// returned issues to quarantine this asset while continuing to decode its parent session.
    func validationIssues() -> [MeetingAudioAssetValidationIssue] {
        var issues: [MeetingAudioAssetValidationIssue] = []
        if case let .unknown(raw) = role { issues.append(.unknownRole(raw)) }
        if case let .unknown(raw) = encoding { issues.append(.unknownEncoding(raw)) }
        if case let .unknown(raw) = presence { issues.append(.unknownPresence(raw)) }
        guard issues.isEmpty else { return issues }
        if relativeFilePath.isEmpty { issues.append(.emptyRelativeFilePath) }
        if byteCount < 0 { issues.append(.negativeByteCount) }
        switch (role, encoding) {
        case (.captureAnalysis, .linearPCMFloat32CAFV1): break
        case (.playbackArchive, .aacLCM4AV1): break
        case (.playbackArchive, .legacyAACUnknownPrimingV1): break
        case (.captureAnalysis, .aacLCM4AV1), (.captureAnalysis, .legacyAACUnknownPrimingV1): issues.append(.encodingRoleContradiction)
        case (.playbackArchive, .linearPCMFloat32CAFV1): issues.append(.encodingRoleContradiction)
        default: break
        }
        if presence == .ready {
            if byteCount <= 0 { issues.append(.readyAssetMissingBytes) }
            if encoding == .legacyAACUnknownPrimingV1 { return issues }
            if sha256?.isEmpty != false { issues.append(.readyAssetMissingHash) }
            if sampleRate == nil || !(sampleRate?.isFinite ?? false) || (sampleRate ?? 0) <= 0 { issues.append(.readyAssetMissingSampleRate) }
            if channelCount == nil || (channelCount ?? 0) <= 0 { issues.append(.readyAssetMissingChannelCount) }
            if frameCount == nil || (frameCount ?? 0) <= 0 { issues.append(.readyAssetMissingFrameCount) }
        }
        return issues
    }
}

nonisolated enum MeetingAudioAssetValidationIssue: Equatable, Sendable {
    case unknownRole(String)
    case unknownEncoding(String)
    case unknownPresence(String)
    case emptyRelativeFilePath
    case negativeByteCount
    case encodingRoleContradiction
    case readyAssetMissingBytes
    case readyAssetMissingHash
    case readyAssetMissingSampleRate
    case readyAssetMissingChannelCount
    case readyAssetMissingFrameCount
}
