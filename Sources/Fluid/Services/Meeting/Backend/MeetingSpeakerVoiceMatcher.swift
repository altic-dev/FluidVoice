import Foundation

/// Attempt-local audio only. Never persisted or sent to a service.
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {
    let token: MeetingBackendSpeakerToken
    let clips: [[Float]]

    static let maximumProfiles = 128
    static let sampleRate = 16_000

    /// Two disjoint, single-speaker excerpts. Overlap and turn edges are excluded; short or
    /// silent observations cannot establish identity. At most 10 seconds is retained per slot.
    static func collect(
        epoch: MeetingAnalysisEpochID,
        samples: [Float],
        segments: [MeetingNemotronSpeakerSegment]
    ) -> [Self] {
        let duration = Double(samples.count) / Double(self.sampleRate)
        let valid = segments.filter {
            (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1e-6
        }
        return Set(valid.map(\.slotIndex)).sorted().compactMap { slot in
            var ranges: [Range<Int>] = []
            let candidates = valid.filter { $0.slotIndex == slot }
                .sorted { $0.end - $0.start > $1.end - $1.start }.prefix(16)
            for segment in candidates {
                var pieces = [MeetingAnalysisInterval(start: segment.start, end: segment.end)]
                for other in valid where other.slotIndex != slot {
                    pieces = pieces.flatMap { piece -> [MeetingAnalysisInterval] in
                        guard other.start < piece.end, other.end > piece.start else { return [piece] }
                        var remaining: [MeetingAnalysisInterval] = []
                        if other.start > piece.start {
                            remaining.append(.init(start: piece.start, end: other.start))
                        }
                        if other.end < piece.end {
                            remaining.append(.init(start: other.end, end: piece.end))
                        }
                        return remaining
                    }
                }
                for piece in pieces {
                    let start = max(0, Int(((piece.start + 0.16) * Double(self.sampleRate)).rounded(.up)))
                    let end = min(samples.count, Int(((piece.end - 0.16) * Double(self.sampleRate)).rounded(.down)))
                    if end - start >= 3 * self.sampleRate { ranges.append(start..<end) }
                }
            }
            ranges.sort { $0.count == $1.count ? $0.lowerBound < $1.lowerBound : $0.count > $1.count }
            var selected: [Range<Int>] = []
            for range in ranges {
                var start = range.lowerBound
                while selected.count < 2, range.upperBound - start >= 3 * self.sampleRate {
                    // Split a long turn so both excerpts contain independent audio.
                    let length = min(
                        5 * self.sampleRate,
                        (range.upperBound - start >= 6 * self.sampleRate)
                            ? (range.upperBound - start) / 2 : range.upperBound - start
                    )
                    let candidate = start..<(start + length)
                    start += length
                    guard !selected.contains(where: { $0.overlaps(candidate) }) else { continue }
                    let energy = samples[candidate].reduce(Double.zero) { $0 + Double($1) * Double($1) }
                    guard energy.isFinite, energy / Double(length) > 1e-8 else { continue }
                    selected.append(candidate)
                }
                if selected.count == 2 { break }
            }
            guard selected.count == 2 else { return nil }
            return Self(
                token: MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-\(slot)"),
                clips: selected.map { Array(samples[$0]) }
            )
        }
    }
}

nonisolated struct MeetingSpeakerVoiceProfile: Codable, Equatable, Sendable {
    let token: MeetingBackendSpeakerToken
    let embeddings: [[Float]]
}

/// Explicit identity evidence across resets. Backend tokens remain epoch-scoped.
nonisolated struct MeetingSpeakerIdentityLink: Codable, Equatable, Sendable {
    let token: MeetingBackendSpeakerToken
    let canonicalToken: MeetingBackendSpeakerToken
}

nonisolated enum MeetingSpeakerVoiceMatcher {
    static let maximumDistance: Float = 0.25
    static let ambiguityMargin: Float = 0.10

    static func validLinks(_ links: [MeetingSpeakerIdentityLink], allowedTokens: Set<MeetingBackendSpeakerToken>) -> Bool {
        guard links.count <= MeetingSpeakerVoiceSamples.maximumProfiles else { return false }
        var canonicalByToken: [MeetingBackendSpeakerToken: MeetingBackendSpeakerToken] = [:]
        for link in links {
            guard allowedTokens.contains(link.token), allowedTokens.contains(link.canonicalToken),
                  link.token.analysisEpochID.trackID == link.canonicalToken.analysisEpochID.trackID,
                  link.token.analysisEpochID.ordinal > link.canonicalToken.analysisEpochID.ordinal,
                  canonicalByToken.updateValue(link.canonicalToken, forKey: link.token) == nil
            else { return false }
        }
        var epochsByIdentity: [MeetingBackendSpeakerToken: Set<MeetingAnalysisEpochID>] = [:]
        for token in allowedTokens {
            let root = canonicalByToken[token] ?? token
            guard canonicalByToken[root] == nil,
                  epochsByIdentity[root, default: []].insert(token.analysisEpochID).inserted
            else { return false }
        }
        return true
    }

    /// Links for a diarizer that kept one state per track: each slot label in a track resolves to
    /// its earliest visible epoch. Tracks never link to each other.
    static func continuityLinks(allowedTokens: Set<MeetingBackendSpeakerToken>) -> [MeetingSpeakerIdentityLink] {
        let groups = Dictionary(grouping: allowedTokens) {
            "\($0.analysisEpochID.trackID.uuidString)\u{0}\($0.label)"
        }
        return groups.values.flatMap { tokens -> [MeetingSpeakerIdentityLink] in
            let ordered = tokens.sorted {
                ($0.analysisEpochID.ordinal, $0.analysisEpochID.generation)
                    < ($1.analysisEpochID.ordinal, $1.analysisEpochID.generation)
            }
            guard let root = ordered.first else { return [] }
            return ordered.dropFirst().map { MeetingSpeakerIdentityLink(token: $0, canonicalToken: root) }
        }
    }

    private static func distance(_ left: MeetingSpeakerVoiceProfile, _ right: MeetingSpeakerVoiceProfile) -> Float? {
        guard left.embeddings.count == 2, right.embeddings.count == 2 else { return nil }
        var worst: Float = 0
        for lhs in left.embeddings {
            for rhs in right.embeddings {
                guard lhs.count == 256, rhs.count == 256,
                      let value = MeetingSpeakerEmbeddingIndex.cosineDistance(lhs, rhs), value.isFinite
                else { return nil }
                worst = max(worst, value)
            }
        }
        return worst
    }

    /// Complete-link comparison prevents gradual drift from joining different people. Distinct
    /// slots in the same epoch can never merge, including when both propose the same identity.
    static func links(
        profiles: [MeetingSpeakerVoiceProfile],
        allowedTokens: Set<MeetingBackendSpeakerToken>
    ) -> [MeetingSpeakerIdentityLink] {
        let counts = Dictionary(grouping: profiles, by: \.token)
        let valid = profiles.filter {
            allowedTokens.contains($0.token) && counts[$0.token]?.count == 1
                && (self.distance($0, $0).map { $0 <= self.maximumDistance } ?? false)
        }
        let epochs = Dictionary(grouping: valid, by: { $0.token.analysisEpochID })
        var clusters: [[MeetingSpeakerVoiceProfile]] = []
        var links: [MeetingSpeakerIdentityLink] = []
        for epoch in epochs.keys.sorted(by: {
            ($0.trackID.uuidString, $0.ordinal, $0.generation) < ($1.trackID.uuidString, $1.ordinal, $1.generation)
        }) {
            let observations = (epochs[epoch] ?? []).sorted { $0.token.label < $1.token.label }
            var proposals: [MeetingBackendSpeakerToken: Int] = [:]
            for observation in observations {
                let candidates = clusters.indices.compactMap { index -> (Int, Float)? in
                    let cluster = clusters[index]
                    guard let root = cluster.first, root.token.analysisEpochID.trackID == epoch.trackID,
                          !cluster.contains(where: { $0.token.analysisEpochID == epoch })
                    else { return nil }
                    let distances = cluster.compactMap { self.distance(observation, $0) }
                    guard distances.count == cluster.count, let worst = distances.max() else { return nil }
                    return (index, worst)
                }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
                guard let best = candidates.first, best.1 <= self.maximumDistance,
                      candidates.count == 1 || candidates[1].1 - best.1 >= self.ambiguityMargin
                else { continue }
                proposals[observation.token] = best.0
            }
            let collisions = Dictionary(grouping: proposals.values, by: { $0 })
            for observation in observations {
                if let index = proposals[observation.token], collisions[index]?.count == 1,
                   let root = clusters[index].first
                {
                    links.append(.init(token: observation.token, canonicalToken: root.token))
                    clusters[index].append(observation)
                } else {
                    clusters.append([observation])
                }
            }
        }
        return links
    }
}
