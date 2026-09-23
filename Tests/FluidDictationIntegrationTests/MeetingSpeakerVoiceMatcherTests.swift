import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingSpeakerVoiceMatcherTests: XCTestCase {
    @MainActor
    func testLocalVoiceEncoderOnOptInAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_VOICE_MATCH_AUDIO"] else {
            throw XCTSkip("Set FLUIDVOICE_VOICE_MATCH_AUDIO to a local 24-second 16 kHz mono WAV.")
        }
        #if arch(arm64)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 384_000))
        try file.read(into: buffer, frameCount: 384_000)
        XCTAssertGreaterThanOrEqual(buffer.frameLength, 368_000)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let track = UUID()
        let first = self.profile(track: track, epoch: 0, slot: 0, angle: 0).token
        let second = self.profile(track: track, epoch: 1, slot: 1, angle: 0).token
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { ASRService() }, modelLocator: MeetingNemotronModelLocator())
        let requests = [
            MeetingSpeakerVoiceSamples(token: first, clips: [Array(samples[0..<80_000]), Array(samples[96_000..<176_000])]),
            MeetingSpeakerVoiceSamples(token: second, clips: [Array(samples[192_000..<272_000]), Array(samples[288_000..<368_000])]),
        ]
        let profiles = try await runtime.speakerVoiceProfiles(samples: requests)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.flatMap(\.embeddings).allSatisfy { $0.count == 256 && $0.allSatisfy(\.isFinite) })
        // Report independent-excerpt behavior without treating old diarizer labels as ground truth.
        print("VOICE_MATCH_REAL profiles=\(profiles.count) independentExcerptLinks=\(self.links(profiles).count)")
        if let firstProfile = profiles.first {
            let repeated = MeetingSpeakerVoiceProfile(token: second, embeddings: firstProfile.embeddings)
            XCTAssertEqual(self.links([firstProfile, repeated]).count, 1)
        }
        #endif
    }

    private func profile(track: UUID, epoch: Int, slot: Int, angle: Float) -> MeetingSpeakerVoiceProfile {
        let embedding = [cos(angle), sin(angle)] + [Float](repeating: 0, count: 254)
        return MeetingSpeakerVoiceProfile(
            token: .init(analysisEpochID: .init(trackID: track, ordinal: epoch), label: "slot-\(slot)"),
            embeddings: [embedding, embedding]
        )
    }

    private func links(_ profiles: [MeetingSpeakerVoiceProfile]) -> [MeetingSpeakerIdentityLink] {
        MeetingSpeakerVoiceMatcher.links(profiles: profiles, allowedTokens: Set(profiles.map(\.token)))
    }

    func testReturningVoicesMatchEvenWhenSlotNumbersSwap() {
        let track = UUID()
        let first = self.profile(track: track, epoch: 0, slot: 0, angle: 0)
        let second = self.profile(track: track, epoch: 0, slot: 1, angle: .pi / 2)
        let returnedFirst = self.profile(track: track, epoch: 1, slot: 1, angle: 0.05)
        let returnedSecond = self.profile(track: track, epoch: 1, slot: 0, angle: .pi / 2 - 0.05)
        let profiles = [returnedFirst, second, returnedSecond, first]
        let links = self.links(profiles)
        XCTAssertEqual(Set(links.map(\.token)), [returnedFirst.token, returnedSecond.token])
        XCTAssertEqual(links.first { $0.token == returnedFirst.token }?.canonicalToken, first.token)
        XCTAssertEqual(links.first { $0.token == returnedSecond.token }?.canonicalToken, second.token)
        XCTAssertEqual(links, self.links(profiles.reversed()))
        XCTAssertTrue(MeetingSpeakerVoiceMatcher.validLinks(links, allowedTokens: Set(profiles.map(\.token))))
    }

    func testDifferentVoicesSameEpochAndOtherTracksNeverMerge() {
        let track = UUID()
        let first = self.profile(track: track, epoch: 0, slot: 0, angle: 0)
        XCTAssertTrue(self.links([first, self.profile(track: track, epoch: 1, slot: 0, angle: .pi / 2)]).isEmpty)
        XCTAssertTrue(self.links([first, self.profile(track: track, epoch: 0, slot: 1, angle: 0)]).isEmpty)
        XCTAssertTrue(self.links([first, self.profile(track: UUID(), epoch: 1, slot: 0, angle: 0)]).isEmpty)
    }

    func testAmbiguityAndTwoSlotsClaimingOneIdentityStaySeparate() {
        let track = UUID()
        let first = self.profile(track: track, epoch: 0, slot: 0, angle: 0)
        let other = self.profile(track: track, epoch: 0, slot: 1, angle: 0.4)
        XCTAssertTrue(self.links([first, other, self.profile(track: track, epoch: 1, slot: 0, angle: 0.2)]).isEmpty)
        XCTAssertTrue(self.links([
            first,
            self.profile(track: track, epoch: 1, slot: 0, angle: 0.01),
            self.profile(track: track, epoch: 1, slot: 1, angle: 0.02),
        ]).isEmpty)
    }

    func testCompleteLinkPreventsIdentityDriftAndMalformedProfilesAreIgnored() {
        let track = UUID()
        let first = self.profile(track: track, epoch: 0, slot: 0, angle: 0)
        let intermediate = self.profile(track: track, epoch: 1, slot: 0, angle: 0.6)
        let drifted = self.profile(track: track, epoch: 2, slot: 0, angle: 1.2)
        XCTAssertEqual(self.links([first, intermediate, drifted]).map(\.token), [intermediate.token])
        let invalid = MeetingSpeakerVoiceProfile(token: intermediate.token, embeddings: [[Float.nan], [0]])
        XCTAssertTrue(self.links([first, invalid]).isEmpty)
        XCTAssertTrue(self.links([first, intermediate, intermediate]).isEmpty)
        XCTAssertTrue(MeetingSpeakerVoiceMatcher.links(profiles: [first, intermediate], allowedTokens: [first.token]).isEmpty)
    }

    func testIdentityLedgerRejectsCrossTrackChainsAndSameEpochCollisions() {
        let track = UUID()
        let first = self.profile(track: track, epoch: 0, slot: 0, angle: 0).token
        let second = self.profile(track: track, epoch: 1, slot: 0, angle: 0).token
        let third = self.profile(track: track, epoch: 1, slot: 1, angle: 0).token
        let foreign = self.profile(track: UUID(), epoch: 2, slot: 0, angle: 0).token
        let allowed: Set = [first, second, third, foreign]
        XCTAssertFalse(MeetingSpeakerVoiceMatcher.validLinks([.init(token: foreign, canonicalToken: first)], allowedTokens: allowed))
        XCTAssertFalse(MeetingSpeakerVoiceMatcher.validLinks([
            .init(token: second, canonicalToken: first), .init(token: third, canonicalToken: first),
        ], allowedTokens: allowed))
        XCTAssertFalse(MeetingSpeakerVoiceMatcher.validLinks([.init(token: first, canonicalToken: second)], allowedTokens: allowed))
    }

    func testVoiceExcerptsAreBoundedDisjointAndRejectOverlapSilenceAndShortSpeech() {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let samples = (0..<192_000).map { 0.1 + Float($0) / 1_000_000 }
        let speech = MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0, end: 12)
        let profiles = MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples, segments: [speech])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.clips.count, 2)
        XCTAssertTrue(profiles.flatMap(\.clips).allSatisfy { (48_000...80_000).contains($0.count) })
        XCTAssertNotEqual(profiles.first?.clips.first?.first, profiles.first?.clips.last?.first)
        XCTAssertTrue(MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples, segments: [
            speech, .init(slotIndex: 1, start: 0, end: 12),
        ]).isEmpty)
        XCTAssertTrue(MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: [Float](repeating: 0, count: 192_000), segments: [speech]).isEmpty)
        XCTAssertTrue(MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples, segments: [.init(slotIndex: 0, start: 0, end: 2)]).isEmpty)
    }
}

// Opt-in experiment: a single mixed timeline, one diarizer instance, then one full-buffer
// ASR request. This does not change production routing or mutate any saved meeting.
final nonisolated class WholeMeetingMemoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let began = Date()
    private var phase = "baseline"
    private var rows: [String] = ["seconds,phase,resident_bytes,physical_footprint_bytes,helper_footprint_bytes,helper_pids,app_lifetime_peak_bytes,helper_lifetime_peak_bytes,helper_read_failures"]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "meeting.memory.experiment")

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    func mark(_ value: String) {
        self.lock.withLock { self.phase = value }
        self.sample()
        print("WHOLE_MEETING_PHASE \(value)")
    }

    static func helperPIDs() -> [Int32] {
        var pids = [Int32](repeating: 0, count: 128)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(max(0, min(pids.count, Int(count)))).filter { pid in
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
            return String(cString: name).contains("fluid-intellig")
        }
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        let helpers = Self.helperPIDs()
        var helperPeak: UInt64 = 0
        var helperReadFailures = 0
        let helperFootprint = helpers.reduce(UInt64(0)) { total, pid in
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if result != 0 { helperReadFailures += 1 }
            helperPeak = max(helperPeak, result == 0 ? usage.ri_lifetime_max_phys_footprint : 0)
            return total + (result == 0 ? usage.ri_phys_footprint : 0)
        }
        var ownUsage = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &ownUsage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        self.lock.withLock {
            self.rows.append("\(Date().timeIntervalSince(self.began)),\(self.phase),\(info.resident_size),\(info.phys_footprint),\(helperFootprint),\(helpers.map(String.init).joined(separator: ";")),\(ownUsage.ri_lifetime_max_phys_footprint),\(helperPeak),\(helperReadFailures)")
        }
    }

    func finish(at url: URL) throws {
        self.timer?.cancel()
        self.timer = nil
        self.queue.sync {} // Join any sample already in flight before finalizing evidence.
        let contents = self.lock.withLock { self.rows.joined(separator: "\n") + "\n" }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension MeetingSpeakerVoiceMatcherTests {
    @MainActor
    func testOptInWholeMeetingContinuousPassAndMemory() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_WHOLE_MEETING_SESSION"],
              let outputPath = ProcessInfo.processInfo.environment["FLUIDVOICE_WHOLE_MEETING_OUTPUT"]
        else { throw XCTSkip("Set the whole-meeting session and output directory to run this experiment.") }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let service = AppServices.shared.asr
        try await Task.sleep(for: .seconds(15))
        try await service.ensureAsrReady()
        if ProcessInfo.processInfo.environment["FLUIDVOICE_WHOLE_MEETING_PREWARM_FLUID"] == "1" {
            await PrivateAIIntegrationService.shared.prewarmDictation()
            let state = await PrivateAIIntegrationService.shared.loadedModelState()
            XCTAssertEqual(state?.state, .ready, "The preloaded-Fluid experiment requires an installed ready model")
        }
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        let before = try await service.meetingResidencyParticipant().snapshot()
        let fluidBefore = await PrivateAIIntegrationService.shared.loadedModelState()
        let helpersBefore = WholeMeetingMemoryProbe.helperPIDs()
        if ProcessInfo.processInfo.environment["FLUIDVOICE_WHOLE_MEETING_PREWARM_FLUID"] == "1" {
            XCTAssertFalse(helpersBefore.isEmpty, "The Fluid helper must be observable before testing its exit")
        }
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service }, modelLocator: MeetingNemotronModelLocator())
        let probe = WholeMeetingMemoryProbe()
        probe.start()
        defer { try? probe.finish(at: output.appendingPathComponent("memory.csv")) }
        try await Task.sleep(for: .seconds(15))
        try await service.withMeetingModelResidency(attemptID: UUID()) {
            probe.mark("suspended")
            let unloaded = await PrivateAIIntegrationService.shared.loadedModelState()
            XCTAssertNil(unloaded)
            XCTAssertTrue(WholeMeetingMemoryProbe.helperPIDs().isEmpty, "Old helper must exit before any meeting model loads")
            try await Task.detached(priority: .userInitiated) {
                try await Self.runWholeMeeting(directory: URL(fileURLWithPath: path), output: output, probe: probe, runtime: runtime)
            }.value
            probe.mark("meeting_released")
            probe.mark("restoring")
        }
        let after = try await service.meetingResidencyParticipant().snapshot()
        let fluidAfter = await PrivateAIIntegrationService.shared.loadedModelState()
        XCTAssertEqual(before, after)
        XCTAssertEqual(fluidBefore?.modelID, fluidAfter?.modelID)
        XCTAssertEqual(fluidBefore?.state, fluidAfter?.state)
        let helpersAfter = WholeMeetingMemoryProbe.helperPIDs()
        XCTAssertEqual(helpersBefore.isEmpty, helpersAfter.isEmpty)
        XCTAssertTrue(Set(helpersBefore).isDisjoint(with: helpersAfter))
        XCTAssertTrue(MeetingModelResidencyCoordinator.shared.restorationErrors.isEmpty)
        let proof = "Speech before: \(before?.id ?? "none")\nSpeech after: \(after?.id ?? "none")\nFluid before: \(fluidBefore?.modelID ?? "none")\nFluid after: \(fluidAfter?.modelID ?? "none")\nHelper PIDs before: \(helpersBefore)\nHelper PIDs after: \(helpersAfter)\n"
        try proof.write(to: output.appendingPathComponent("restoration.txt"), atomically: true, encoding: .utf8)
        probe.mark("restored")
        try await Task.sleep(for: .seconds(30))
        probe.mark("after_30_seconds")
    }

    private nonisolated static func runWholeMeeting(
        directory: URL, output: URL, probe: WholeMeetingMemoryProbe, runtime: MeetingParakeetNemotronRuntime
    ) async throws {
        probe.mark("materializing")
        let began = Date()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessionData = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        let session = try decoder.decode(MeetingSession.self, from: sessionData)
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: directory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        let plan = MeetingBackendPlan(request: request, descriptor: MeetingParakeetNemotronBackend.descriptor)
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan, observer: MeetingChunkAudioObserver(sessionDirectory: directory), analysisSampleRate: 16_000
        ).build()
        let end = manifest.tracks.flatMap(\.spans).map(\.presentationInterval.end).max() ?? 0
        guard end > 0, end < 4 * 3600 else { throw NSError(domain: "WholeMeeting", code: 1) }
        var mixed = [Float](repeating: 0, count: Int((end * 16_000).rounded(.up)))
        let materializer = MeetingEpochAudioMaterializer()
        for track in manifest.tracks {
            let spans = Dictionary(uniqueKeysWithValues: track.spans.map { ($0.id, $0) })
            for epoch in track.epochs {
                let audio = try await materializer.materialize(
                    epoch: epoch, track: track, manifest: manifest, sessionDirectory: directory
                )
                for part in audio.spanSamples {
                    guard let span = spans[part.spanID] else { continue }
                    let start = max(0, Int((span.presentationInterval.start * 16_000).rounded()))
                    let count = min(part.sampleRange.count, mixed.count - start)
                    guard count > 0 else { continue }
                    for index in 0..<count {
                        // Fixed headroom, no per-track gain changes; excluded/missing audio remains silent.
                        mixed[start + index] += 0.5 * audio.samples[part.sampleRange.lowerBound + index]
                    }
                }
            }
        }
        let audio = mixed
        mixed.removeAll(keepingCapacity: false)
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let artifact = try MeetingNemotronModelLocator().locate()
        probe.mark("continuous_diarization")
        let diarizationStart = Date()
        let speakers = try await runtime.withNemotronDiarization(artifact: artifact) { factory in
            let diarizer = try await factory.makeDiarizer(epoch: epoch)
            let segments = try await diarizer.diarize(samples: audio)
            var result = MeetingNemotronPhaseResult()
            result.activity = segments.map {
                MeetingBackendSpeakerActivity(token: .init(analysisEpochID: epoch, label: "slot-\($0.slotIndex)"), start: $0.start, end: $0.end)
            }
            return result
        }
        let diarizationSeconds = Date().timeIntervalSince(diarizationStart)
        // Local listening evidence for this experiment; choose the longest non-overlapping turn.
        for token in Set(speakers.activity.map(\.token)) {
            let candidates = speakers.activity.filter { candidate in
                candidate.token == token && !speakers.activity.contains {
                    $0.token != token && $0.start < candidate.end && $0.end > candidate.start
                }
            }
            guard let segment = candidates.max(by: { $0.end - $0.start < $1.end - $1.start }),
                  segment.end - segment.start > 1 else { continue }
            let start = max(0, Int((segment.start + 0.1) * 16_000))
            let end = min(audio.count, Int(min(segment.end - 0.1, segment.start + 6) * 16_000))
            guard end > start,
                  let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = buffer.frameCapacity
            audio.withUnsafeBufferPointer { samples in
                if let base = samples.baseAddress {
                    channel.update(from: base.advanced(by: start), count: end - start)
                }
            }
            let file = try AVAudioFile(forWriting: output.appendingPathComponent("\(token.label).wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        probe.mark("continuous_transcription")
        let asrStart = Date()
        let transcript = try await runtime.withPreparedASR(attemptID: request.attemptID, configuration: request.configuration) { asr in
            let result = try await asr.transcribeWithTimings(audio)
            var phase = MeetingParakeetPhaseResult()
            phase.outputs = [.init(epochID: epoch, text: result.result.text, words: result.words, sampleRate: 16_000, sampleCount: audio.count, spanSamples: [])]
            return phase
        }
        let asrSeconds = Date().timeIntervalSince(asrStart)
        probe.mark("writing_results")
        let activity: [[String: Any]] = speakers.activity.map { ["speaker": $0.token.label, "start": $0.start, "end": $0.end] }
        let words: [[String: Any]] = (transcript.outputs.first?.words ?? []).map { ["text": $0.text, "start": $0.start, "end": $0.end] }
        let result: [String: Any] = [
            "sourceSessionID": session.id.uuidString, "durationSeconds": end,
            "elapsedSeconds": Date().timeIntervalSince(began), "diarizationSeconds": diarizationSeconds,
            "asrSeconds": asrSeconds, "speakerCount": Set(speakers.activity.map(\.token.label)).count,
            "activity": activity, "words": words, "text": transcript.outputs.first?.text ?? "",
            "gaps": manifest.tracks.map { ["track": $0.kind.rawValue, "count": $0.gaps.count] },
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"), options: .atomic)
        XCTAssertFalse(words.isEmpty)
        XCTAssertFalse(activity.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("session.json")), sessionData)
        print("WHOLE_MEETING_RESULT speakers=\(Set(speakers.activity.map(\.token.label)).count) words=\(words.count) seconds=\(Date().timeIntervalSince(began))")
    }
}
