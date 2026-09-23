import Darwin.Mach
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Opt-in replay of retained meeting recordings through the current batch pipeline.
///
/// `FLUIDVOICE_REPLAY_MEETING_DIRS` is a colon-separated list of session directories. Every
/// source is copied before processing so this test can never rewrite a user's stored meeting.
@MainActor
final class MeetingExistingAudioReplayTests: XCTestCase {
    func testRetainedMeetingsReplayThroughCurrentPipeline() async throws {
        let environmentDirectories = ProcessInfo.processInfo.environment["FLUIDVOICE_REPLAY_MEETING_DIRS"]
        // XCTest's working directory is not guaranteed to be the repository root. Resolve the
        // opt-in file from this source file so a local one-fixture run cannot silently fall back
        // to the legacy machine-wide manifest.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FluidDictationIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let localManifestPath = repositoryRoot
            .appendingPathComponent("benchmark_reports/meeting-diarization/replay-directories.txt")
            .path
        let defaultManifestPath = FileManager.default.fileExists(atPath: localManifestPath)
            ? localManifestPath
            : "/private/tmp/FluidVoiceMeetingReplayDirectories.txt"
        let manifestPath = ProcessInfo.processInfo.environment["FLUIDVOICE_REPLAY_MEETING_MANIFEST"]
            ?? defaultManifestPath
        let manifestDirectories = try? String(contentsOfFile: manifestPath, encoding: .utf8)
        guard let rawDirectories = environmentDirectories ?? manifestDirectories else {
            throw XCTSkip("No retained-meeting replay input was provided")
        }
        let sourceDirectories = rawDirectories
            .split(whereSeparator: { $0 == ":" || $0.isNewline })
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        XCTAssertFalse(sourceDirectories.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let asrService = ASRService()
        let meetingLease = try asrService.acquireExclusiveActivity(.meeting)
        defer { asrService.releaseExclusiveActivity(meetingLease) }
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { asrService })
        var reportLines: [String] = []
        let reportRoot = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["FLUIDVOICE_REPLAY_REPORT_DIR"]
                ?? "/private/tmp/FluidVoiceMeetingReplayReport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: reportRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for sourceDirectory in sourceDirectories {
            let sourceManifest = sourceDirectory.appendingPathComponent("session.json", isDirectory: false)
            let sourceSession = try decoder.decode(
                MeetingSession.self,
                from: Data(contentsOf: sourceManifest)
            )
            let replayDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidVoiceMeetingReplay-\(sourceSession.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: sourceDirectory, to: replayDirectory)
            defer { try? FileManager.default.removeItem(at: replayDirectory) }

            // Force a full pass even when the retained session contains an older checkpoint.
            try? FileManager.default.removeItem(
                at: replayDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
            )
            let result: MeetingProcessingResult
            let startedAt = Date()
            let residentBytesBefore = Self.currentResidentBytes()
            do {
                result = try await pipeline.process(
                    session: sourceSession,
                    sessionDirectory: replayDirectory,
                    progress: { _ in }
                )
            } catch {
                reportLines.append("id=\(sourceSession.id) FAILED error=\(error)")
                XCTFail("\(sourceSession.id) failed replay: \(error)")
                continue
            }
            let wallTimeSeconds = Date().timeIntervalSince(startedAt)
            let residentBytesAfter = Self.currentResidentBytes()

            XCTAssertEqual(result.attempt.pipelineVersion, MeetingProcessingPipeline.pipelineVersion)
            XCTAssertFalse(result.segments.isEmpty, "\(sourceSession.id) produced no transcript segments")
            XCTAssertFalse(result.speakers.isEmpty, "\(sourceSession.id) produced no speakers")
            XCTAssertEqual(Set(result.speakers.map(\.id)).count, result.speakers.count)

            let speakerByID = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.id, $0) })
            let trackKindByID = Dictionary(uniqueKeysWithValues: sourceSession.audioTracks.map { ($0.id, $0.kind) })
            for segment in result.segments {
                XCTAssertFalse(segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                guard let speakerID = segment.speakerID,
                      let speaker = speakerByID[speakerID]
                else {
                    XCTFail("\(sourceSession.id) emitted a segment with an unknown speaker")
                    continue
                }
                XCTAssertEqual(
                    speaker.trackKind,
                    trackKindByID[segment.sourceTrackID],
                    "\(sourceSession.id) crossed application and microphone speaker identities"
                )
            }

            let speakerSummary = result.speakers
                .sorted { $0.displayName < $1.displayName }
                .map { "\($0.displayName)[\($0.trackKind.rawValue)]" }
                .joined(separator: ", ")
            let summary = "id=\(sourceSession.id) chunks=\(sourceSession.audioTracks.flatMap(\.chunks).count) "
                + "segments=\(result.segments.count) speakers=\(result.speakers.count) "
                + "skipped=\(result.skippedChunkIDs.count) wall=\(String(format: "%.3f", wallTimeSeconds))s "
                + "{\(speakerSummary)}"
            reportLines.append(summary)
            print("[meeting-replay] \(summary)")

            let fixtureDirectory = reportRoot.appendingPathComponent(sourceSession.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let hypothesisRTTM = result.segments.compactMap { segment -> String? in
                guard let speakerID = segment.speakerID,
                      let speaker = speakerByID[speakerID],
                      segment.end.seconds > segment.start.seconds else { return nil }
                return String(
                    format: "SPEAKER %@ 1 %.6f %.6f <NA> <NA> %@ <NA> <NA>",
                    sourceSession.id.uuidString,
                    segment.start.seconds,
                    segment.end.seconds - segment.start.seconds,
                    speaker.displayName.replacingOccurrences(of: " ", with: "-")
                )
            }.joined(separator: "\n") + "\n"
            try Self.writeProtected(
                Data(hypothesisRTTM.utf8),
                to: fixtureDirectory.appendingPathComponent("hypothesis.rttm")
            )

            let speakerText = Dictionary(grouping: result.segments.compactMap { segment -> (String, String)? in
                guard let speakerID = segment.speakerID, let speaker = speakerByID[speakerID] else { return nil }
                return (speaker.displayName, segment.text)
            }, by: { $0.0 }).mapValues { $0.map(\.1).joined(separator: " ") }
            let speakerTextData = try JSONSerialization.data(
                withJSONObject: speakerText,
                options: [.prettyPrinted, .sortedKeys]
            )
            try Self.writeProtected(
                speakerTextData,
                to: fixtureDirectory.appendingPathComponent("hypothesis-speaker-text.json")
            )

            let fixtureReport: [String: Any] = [
                "schemaVersion": 1,
                "sessionID": sourceSession.id.uuidString,
                "pipelineVersion": result.attempt.pipelineVersion,
                "asrProvider": result.attempt.asrProvider ?? "unknown",
                "asrModel": result.attempt.asrModel ?? "unknown",
                "languageCode": result.attempt.languageCode ?? "unknown",
                "diarizationFingerprint": result.attempt.diarizationModel ?? "unsupported",
                "sourceChunkSHA256": sourceSession.audioTracks.flatMap(\.chunks).map(\.sha256).sorted(),
                "sourceChunkCount": sourceSession.audioTracks.flatMap(\.chunks).count,
                "speakerCount": result.speakers.count,
                "speakerCountByTrack": Dictionary(
                    grouping: result.speakers,
                    by: { $0.trackKind.rawValue }
                ).mapValues(\.count),
                "segmentCount": result.segments.count,
                "segmentCountByTrack": Dictionary(
                    grouping: result.segments,
                    by: { segment in
                        trackKindByID[segment.sourceTrackID]?.rawValue ?? "unknown"
                    }
                ).mapValues(\.count),
                "skippedChunkCount": result.skippedChunkIDs.count,
                "wallTimeSeconds": wallTimeSeconds,
                "residentBytesBefore": residentBytesBefore,
                "residentBytesAfter": residentBytesAfter,
            ]
            try Self.writeProtected(
                JSONSerialization.data(withJSONObject: fixtureReport, options: [.prettyPrinted, .sortedKeys]),
                to: fixtureDirectory.appendingPathComponent("run.json")
            )
        }

        try (reportLines.joined(separator: "\n") + "\n").write(
            toFile: "/private/tmp/FluidVoiceMeetingReplayReport.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    private static func currentResidentBytes() -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? information.resident_size : 0
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension MeetingExistingAudioReplayTests {
    /// Repeated actual production pipeline, on copied retained audio, in the same app process.
    /// Includes ordinary speech transcription between meetings; no microphone or history writes.
    func testOptInRepeatedProductionMeetingsAndDictationMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let paths = environment["FLUIDVOICE_RESIDENCY_REPLAY_DIRS"],
              let outputPath = environment["FLUIDVOICE_RESIDENCY_REPLAY_OUTPUT"],
              let dictationPath = environment["FLUIDVOICE_RESIDENCY_DICTATION_AUDIO"]
        else { throw XCTSkip("Set retained-meeting residency replay inputs to run the memory regression") }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sources = paths.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let cycles = max(1, min(5, Int(environment["FLUIDVOICE_RESIDENCY_REPLAY_CYCLES"] ?? "3") ?? 3))
        let service = AppServices.shared.asr
        try await Task.sleep(for: .seconds(15)) // Allow ordinary app startup to settle.
        let probe = WholeMeetingMemoryProbe()
        probe.start()
        defer { try? probe.finish(at: output.appendingPathComponent("memory.csv")) }
        probe.mark("initial_preparation")
        try await service.ensureAsrReady()
        if environment["FLUIDVOICE_RESIDENCY_REPLAY_FLUID"] == "1" {
            await PrivateAIIntegrationService.shared.prewarmDictation()
            let state = await PrivateAIIntegrationService.shared.loadedModelState()
            XCTAssertEqual(state?.state, .ready)
            XCTAssertFalse(WholeMeetingMemoryProbe.helperPIDs().isEmpty)
        }
        probe.mark("baseline_settling")
        try await Task.sleep(for: .seconds(10))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var baselineTexts: [UUID: [String]] = [:]
        var dictationText: String?
        var reports: [[String: Any]] = []
        for cycle in 0..<cycles {
            for (index, source) in sources.enumerated() {
                let label = "cycle_\(cycle)_meeting_\(index)"
                let sourceData = try Data(contentsOf: source.appendingPathComponent("session.json"))
                let session = try decoder.decode(MeetingSession.self, from: sourceData)
                let copy = output.appendingPathComponent("copy-\(cycle)-\(index)", isDirectory: true)
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: source, to: copy)
                    try? FileManager.default.removeItem(at: copy.appendingPathComponent("checkpoint.json"))
                }.value
                probe.mark("\(label)_dictation_before")
                let beforeDictation = try await service.transcribeFileForAPI(URL(fileURLWithPath: dictationPath)).result.text
                XCTAssertFalse(beforeDictation.isEmpty)
                if let dictationText { XCTAssertEqual(beforeDictation, dictationText) } else { dictationText = beforeDictation }
                let lease = try service.acquireExclusiveActivity(.meeting)
                let speechBefore = try await service.meetingResidencyParticipant().snapshot()
                let fluidBefore = await PrivateAIIntegrationService.shared.loadedModelState()
                let pidsBefore = WholeMeetingMemoryProbe.helperPIDs()
                let pipeline = MeetingProcessingPipeline(asrServiceProvider: { service }, backendID: .parakeetNemotron)
                let started = Date()
                let result: MeetingProcessingResult
                probe.mark("\(label)_processing")
                do {
                    result = try await pipeline.process(session: session, sessionDirectory: copy) { stage in
                        probe.mark("\(label)_\(stage.rawValue)")
                        if MeetingModelResidencyCoordinator.shared.phase == .transcription {
                            XCTAssertTrue(WholeMeetingMemoryProbe.helperPIDs().isEmpty, "Fluid helper overlapped meeting work")
                        }
                    }
                } catch {
                    service.releaseExclusiveActivity(lease)
                    throw error
                }
                let speechAfter = try await service.meetingResidencyParticipant().snapshot()
                let fluidAfter = await PrivateAIIntegrationService.shared.loadedModelState()
                let pidsAfter = WholeMeetingMemoryProbe.helperPIDs()
                XCTAssertEqual(speechBefore, speechAfter)
                XCTAssertEqual(fluidBefore?.modelID, fluidAfter?.modelID)
                XCTAssertEqual(fluidBefore?.state, fluidAfter?.state)
                XCTAssertEqual(pidsBefore.isEmpty, pidsAfter.isEmpty)
                XCTAssertTrue(Set(pidsBefore).isDisjoint(with: pidsAfter))
                XCTAssertEqual(MeetingModelResidencyCoordinator.shared.phase, .normal)
                XCTAssertTrue(MeetingModelResidencyCoordinator.shared.restorationErrors.isEmpty)
                service.releaseExclusiveActivity(lease)
                XCTAssertNil(service.activeExclusiveActivity)
                XCTAssertFalse(result.segments.isEmpty)
                let texts = result.segments.map(\.text)
                if let baseline = baselineTexts[session.id] {
                    XCTAssertTrue(texts == baseline, "Transcript text changed across repeated runs; inspect protected result artifacts")
                } else { baselineTexts[session.id] = texts }
                let seconds = Date().timeIntervalSince(started)
                probe.mark("\(label)_dictation_after")
                let afterDictation = try await service.transcribeFileForAPI(URL(fileURLWithPath: dictationPath)).result.text
                XCTAssertEqual(afterDictation, dictationText)
                probe.mark("\(label)_settling")
                try await Task.sleep(for: .seconds(10))
                probe.mark("\(label)_settled")
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("session.json")), sourceData)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(result)
                try data.write(to: output.appendingPathComponent("result-\(cycle)-\(index).json"), options: .atomic)
                reports.append([
                    "cycle": cycle, "index": index, "sessionID": session.id.uuidString,
                    "seconds": seconds, "segmentCount": result.segments.count, "speakerCount": result.speakers.count,
                    "speechBefore": speechBefore?.id ?? "none", "speechAfter": speechAfter?.id ?? "none",
                    "fluidBefore": fluidBefore?.modelID ?? "none", "fluidAfter": fluidAfter?.modelID ?? "none",
                    "helperPIDsBefore": pidsBefore, "helperPIDsAfter": pidsAfter,
                    "dictationCharacters": afterDictation.count,
                ])
                try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("runs.json"), options: .atomic)
                try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: copy) }.value
            }
        }
        // Explicitly request unload after the repeated run to distinguish intentionally resident
        // models from leaked resources. This is a test-host action, never changes persisted selections.
        probe.mark("explicit_unload")
        let lease = try service.acquireExclusiveActivity(.meeting)
        try await service.meetingResidencyParticipant().suspend()
        await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "memory regression complete")
        service.releaseExclusiveActivity(lease)
        XCTAssertFalse(service.isAsrReady)
        XCTAssertTrue(WholeMeetingMemoryProbe.helperPIDs().isEmpty)
        probe.mark("all_unloaded_settling")
        try await Task.sleep(for: .seconds(30))
        probe.mark("all_unloaded_after_30_seconds")
    }
}
