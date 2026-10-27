import Foundation

@main
struct DictionaryMatchReportTests {
    static func main() throws {
        var candidate = DictionaryMatchReport.Candidate(
            id: "target",
            word: "ModelOpt",
            sampleNumber: nil,
            enrollmentCount: 3,
            eligible: true,
            score: 0.699,
            start: 0,
            end: 0.5,
            heard: "model opt"
        )
        precondition(candidate.explanation.contains("Below cutoff"))
        candidate.score = 0.74
        precondition(candidate.explanation.contains("Above score cutoff"))
        candidate.competingWord = "Other"
        candidate.competingScore = 0.72
        precondition(candidate.explanation.contains("competing"))
        candidate.competingScore = nil
        candidate.heard = ""
        precondition(candidate.explanation.contains("no word overlaps"))
        let ineligible = DictionaryMatchReport.Candidate(
            id: "untrained", word: "Other", sampleNumber: nil, enrollmentCount: 1, eligible: false, score: 0.9
        )
        precondition(ineligible.explanation.contains("needs more"))
        candidate.score = nil
        precondition(candidate.explanation == "No usable audio window")

        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 4, modelKey: "parakeet-v2", originalAudioID: UUID(), observedText: "model opt")
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: UUID(), label: "ModelOpt", modelKey: "parakeet-v2", hiddenSize: 2, enrollments: [capture])
        precondition(DictionaryPronunciationDecision.requiredScore(heardText: "Model opt!", profile: profile) == 0.70)
        precondition(DictionaryPronunciationDecision.requiredScore(heardText: "other words", profile: profile) == 0.85)
        precondition(!DictionaryPronunciationDecision.accepts(score: .nan, heardText: "model opt", profile: profile))

        var tuned = profile
        tuned.matchThreshold = 0.45
        precondition(DictionaryPronunciationDecision.accepts(score: 0.49, heardText: "other words", profile: tuned))
        precondition(!DictionaryPronunciationDecision.accepts(score: 0.49, heardText: "other words", profile: profile))
        precondition(DictionaryPronunciationDecision.minimumSearchScore(profiles: [profile, tuned]) == 0.45)
        tuned.matchThreshold = .nan
        precondition(DictionaryPronunciationDecision.requiredScore(heardText: "other words", profile: tuned) == 0.85)
        tuned.matchThreshold = 0.96
        precondition(DictionaryPronunciationDecision.requiredScore(heardText: "model opt", profile: tuned) == 0.70)
        let legacy = try JSONDecoder().decode(PronunciationDictionaryProfile.self, from: JSONEncoder().encode(profile))
        precondition(legacy.matchThreshold == nil)

        let individual = [Float(0.49), 0.83, 0.62].enumerated().map { index, score in
            DictionaryMatchReport.Candidate(
                id: "sample-\(index)",
                word: "ModelOpt",
                sampleNumber: index + 1,
                enrollmentCount: 3,
                eligible: true,
                score: score,
                heard: "sample \(index + 1)"
            )
        }
        let selected = DictionaryMatchReport.bestCandidates(from: individual)
        precondition(selected.count == 1 && selected[0].score == 0.83)
        precondition(selected[0].heard == "sample 2", "The decision retains the winning recording's evidence")
        precondition(individual.map(\.score) == [0.49, 0.83, 0.62], "Display all original scores without averaging")

        let report = DictionaryMatchReport(
            createdAt: Date(),
            recordingID: UUID(),
            audioPath: "/tmp/test.wav",
            targetWord: "ModelOpt",
            modelKey: "parakeet-v2",
            duration: 1,
            rawTranscript: "model opt",
            savedTranscript: "ModelOpt",
            availableProfileCount: 1,
            candidates: [candidate],
            targetSamples: [],
            profiles: [profile]
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DictionaryMatchReport.self, from: data)
        precondition(decoded.profiles == [profile], "Export must preserve the reference embeddings")
        precondition(decoded.recordingID == report.recordingID)
        precondition(decoded.rawTranscript == "model opt" && decoded.savedTranscript == "ModelOpt")
        precondition(decoded.candidates.first?.score == nil, "Unavailable must not become a zero score")
        print("PASS: below-cutoff scores, competitors, missing alignment, eligibility, unavailable scores, shared thresholds, report round-trip")
    }
}
