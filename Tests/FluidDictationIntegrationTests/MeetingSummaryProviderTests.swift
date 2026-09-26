import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingSummaryProviderTests: XCTestCase {
    func testCLIArgumentsUseSingleTurnAndKeepModelAsOneArgument() throws {
        let model = "custom model; $(touch never)"
        for cli in MeetingSummaryCLI.allCases {
            let arguments = cli.arguments(model: model, output: URL(fileURLWithPath: "/tmp/summary"))
            XCTAssertTrue(arguments.contains(model))
            XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
            XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
            if cli == .claude {
                XCTAssertEqual(arguments.first, "-p")
                XCTAssertTrue(arguments.contains("--no-session-persistence"))
                let toolsIndex = try XCTUnwrap(arguments.firstIndex(of: "--tools"))
                XCTAssertEqual(arguments[toolsIndex + 1], "")
            } else {
                XCTAssertEqual(arguments.first, "exec")
                XCTAssertEqual(arguments.last, "-")
                XCTAssertTrue(arguments.contains("--ephemeral"))
                XCTAssertTrue(arguments.contains("read-only"))
            }
        }
    }

    func testCLIParsersRejectErrorAndEmptyResults() throws {
        XCTAssertEqual(try MeetingSummaryCLI.claude.summary(from: Data(#"{"subtype":"success","is_error":false,"result":"Summary"}"#.utf8)), "Summary")
        XCTAssertThrowsError(try MeetingSummaryCLI.claude.summary(from: Data(#"{"subtype":"error_max_turns","is_error":true,"result":"Partial"}"#.utf8)))
        XCTAssertThrowsError(try MeetingSummaryCLI.codex.summary(from: Data(" \n".utf8)))
    }

    func testClaudeCLIReceivesTranscriptOnStdinWithoutShellExpansion() async throws {
        let (directory, route) = try self.cliFixture(.claude, script: #"""
        #!/bin/sh
        /bin/cat > received-input
        /usr/bin/grep -q 'Maya: $(touch injected)' received-input || exit 8
        test ! -e injected || exit 9
        printf '%s' '{"subtype":"success","is_error":false,"result":"Release agreed"}'
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await MeetingSummaryCLIService.generate(transcript: "Maya: $(touch injected)", kind: .executive, route: route)
        XCTAssertEqual(result, "Release agreed")
    }

    func testCodexCLIReadsOnlyFinalMessageFile() async throws {
        let (directory, route) = try self.cliFixture(.codex, script: #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then shift; output="$1"; fi
          shift
        done
        /bin/cat > /dev/null
        printf 'diagnostics, not the summary'
        printf 'Final summary' > "$output"
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await MeetingSummaryCLIService.generate(transcript: "Discuss release", kind: .executive, route: route)
        XCTAssertEqual(result, "Final summary")
    }

    func testCLINonzeroExitDoesNotReturnPartialOutputOrDiagnostics() async throws {
        let (directory, route) = try self.cliFixture(.claude, script: "#!/bin/sh\necho sensitive-diagnostic >&2\necho partial-summary\nexit 17\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await MeetingSummaryCLIService.generate(transcript: "Meeting", kind: .executive, route: route)
            XCTFail("Failed runs must not produce a summary")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("17"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-diagnostic"))
        }
    }

    func testCLITimeoutAndCancellationStopTheProcess() async throws {
        let (directory, route) = try self.cliFixture(.claude, script: "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        do {
            _ = try await MeetingSummaryCLIService.generate(transcript: "Meeting", kind: .executive, route: route, timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let task = Task { try await MeetingSummaryCLIService.generate(transcript: "Meeting", kind: .executive, route: route) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testCLICancellationAndTimeoutStopWrapperAndChild() async throws {
        let (directory, route) = try self.cliFixture(.claude, script: #"""
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'trap - TERM; exec /bin/sleep 30' &
        child=$!
        printf '%s %s' "$$" "$child" > "$(/usr/bin/dirname "$0")/pids"
        wait "$child"
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pids")
        for cancel in [true, false] {
            try? FileManager.default.removeItem(at: pidFile)
            let task = Task {
                try await MeetingSummaryCLIService.generate(transcript: "Meeting", kind: .executive, route: route, timeout: cancel ? 240 : 1)
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var pids: [Int32] = []
            while pids.count != 2, ContinuousClock.now < deadline {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                    pids = text.split(separator: " ").compactMap { Int32($0) }
                }
                if pids.count != 2 { try await Task.sleep(for: .milliseconds(25)) }
            }
            XCTAssertEqual(pids.count, 2, "Wait for a real wrapper and child before cancelling")
            guard pids.count == 2 else { task.cancel(); _ = try? await task.value; return }
            defer {
                // Cleanup still runs if a regression leaves either fixture process alive.
                for pid in pids where kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
            XCTAssertNotEqual(pids[0], pids[1])
            if cancel { task.cancel() }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation or timeout")
            } catch {
                if cancel {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertTrue(error.localizedDescription.contains("timed out"))
                }
            }
            for pid in pids {
                XCTAssertEqual(kill(pid, 0), -1, "Both the wrapper and its child must exit before generation returns")
                XCTAssertEqual(errno, ESRCH)
            }
        }
    }

    private func cliFixture(_ cli: MeetingSummaryCLI, script: String) throws -> (URL, MeetingSummaryRoute) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSummaryCLITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(cli.command)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, MeetingSummaryRoute(
            providerID: cli.rawValue,
            providerName: cli.title,
            modelID: MeetingSummaryCLI.defaultModel,
            baseURL: executable.path,
            apiKey: "",
            reasoning: nil,
            supportsTemperature: false
        ))
    }

    func testMeetingSelectionPersistsWithoutChangingGlobalSelections() throws {
        let suite = "MeetingSummaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai", forKey: "SelectedProviderID")
        defaults.set("dictation-model", forKey: "SelectedModel")
        let preferences = MeetingSummaryPreferences(defaults: defaults)
        XCTAssertEqual(preferences.selection.providerID, MeetingSummarySelection.onDevice)
        preferences.selection.providerID = "openrouter"
        preferences.selection.modelsByProvider["openrouter"] = "summary-model"
        let restored = MeetingSummaryPreferences(defaults: defaults)
        XCTAssertEqual(restored.selection, preferences.selection)
        XCTAssertEqual(defaults.string(forKey: "SelectedProviderID"), "openai")
        XCTAssertEqual(defaults.string(forKey: "SelectedModel"), "dictation-model")
        restored.selection.providerID = MeetingSummarySelection.useAISettings
        XCTAssertEqual(restored.selection.modelsByProvider["openrouter"], "summary-model")
    }

    func testLegacySummaryLoadsWithoutProviderMetadata() throws {
        let data = Data(#"{"transcriptHash":"old","modelID":"local-summary","text":"Previous summary"}"#.utf8)
        let saved = try JSONDecoder().decode(MeetingSummaryController.SavedSummary.self, from: data)
        XCTAssertEqual(saved.text, "Previous summary")
        XCTAssertEqual(saved.provenance, "Fluid Intelligence · local-summary")
        XCTAssertNil(saved.generatedAt)
    }

    func testMetadataRoundTripsAndDoesNotContainCredentials() throws {
        let route = self.route()
        let saved = MeetingSummaryController.SavedSummary(
            transcriptHash: "hash",
            modelID: route.modelID,
            text: "Summary",
            providerID: route.providerID,
            providerName: route.providerName,
            configurationHash: route.configurationHash,
            promptVersion: 1,
            generatedAt: Date()
        )
        let data = try JSONEncoder().encode(saved)
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains(route.apiKey))
        XCTAssertEqual(try JSONDecoder().decode(MeetingSummaryController.SavedSummary.self, from: data).provenance, route.provenance)
    }

    func testConfiguredProviderUsesTranscriptAsDataAndPreservesReasoningSettings() throws {
        let route = self.route()
        let config = MeetingSummaryRemoteService().configuration(transcript: "Maya: ship Friday", kind: .actions, route: route)
        XCTAssertEqual(config.messages.last?["content"] as? String, "Maya: ship Friday")
        XCTAssertTrue((config.messages.first?["content"] as? String)?.contains("Action items") == true)
        XCTAssertEqual(config.baseURL, route.baseURL)
        XCTAssertEqual(config.apiKey, route.apiKey)
        XCTAssertFalse(config.streaming)
        XCTAssertTrue(config.tools.isEmpty)
        XCTAssertEqual(config.timeoutSeconds, 180)
        XCTAssertEqual(config.maxRetries, 1)
        XCTAssertEqual(config.extraParameters["enable_thinking"] as? Bool, false)
        XCTAssertNil(config.temperature)
        let request = try LLMClient.shared.buildRequest(config)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/chat/completions")
    }

    func testAnthropicUsesMessagesFormatAndStripsThinkingBlocks() throws {
        let service = MeetingSummaryRemoteService()
        let request = try service.anthropicRequest(transcript: "Transcript", kind: .decisions, route: self.route(baseURL: "https://api.anthropic.com/v1/"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key-never-persist")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["system"])
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        let data = Data(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Decision"}],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertEqual(try MeetingSummaryRemoteService.anthropicText(data), "Decision")
        XCTAssertThrowsError(try MeetingSummaryRemoteService.anthropicText(Data(#"{"content":[],"stop_reason":"max_tokens"}"#.utf8)))
    }

    func testRemoteGenerationWorksWithoutLocalModelAndRejectsEmptyOutput() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MeetingSummaryRemoteService(session: session)
        let summary = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route())
        XCTAssertEqual(summary, "Release agreed")
        do {
            _ = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: "https://empty.example/v1"))
            XCTFail("Empty responses must not replace the saved summary")
        } catch { XCTAssertTrue(error is MeetingPostProcessingError) }
    }

    func testIncompleteRemoteResponsesAreRejectedBeforeReturningSummary() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MeetingSummaryRemoteService(session: session)
        for endpoint in [
            "https://length.example/v1",
            "https://filtered.example/v1",
            "https://incomplete.example/v1/responses",
            "https://partial-item.example/v1/responses",
            "https://details.example/v1/responses",
        ] {
            do {
                _ = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: endpoint))
                XCTFail("Partial content must not reach the controller's save path: \(endpoint)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("incomplete summary"), "\(endpoint): \(error)")
            }
        }
        let complete = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: "https://complete.example/v1/responses"))
        XCTAssertEqual(complete, "Release agreed")
    }

    func testOversizedInputFailsBeforeNetworkRequest() async {
        do {
            _ = try await MeetingSummaryRemoteService().generate(transcript: String(repeating: "a", count: 512_001), kind: .executive, route: self.route())
            XCTFail("Oversized input must not be truncated or sent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }

    func testCancelledRequestDoesNotStartTransport() async {
        let route = self.route()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingSummaryRemoteService().generate(transcript: "Meeting", kind: .executive, route: route)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func route(baseURL: String = "https://gateway.example/v1/") -> MeetingSummaryRoute {
        MeetingSummaryRoute(
            providerID: "fixture",
            providerName: "Fixture",
            modelID: "summary-model",
            baseURL: baseURL,
            apiKey: "fixture-key-never-persist",
            reasoning: .init(parameterName: "enable_thinking", parameterValue: "false"),
            supportsTemperature: false
        )
    }
}

private class MeetingSummaryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        let text = url.host == "empty.example" ? "" : "Release agreed"
        let json: [String: Any]
        if url.path.contains("/responses") {
            json = [
                "status": url.host == "incomplete.example" ? "incomplete" : "completed",
                "incomplete_details": url.host == "details.example" ? ["reason": "max_output_tokens"] : NSNull(),
                "output": [[
                    "type": "message",
                    "status": url.host == "partial-item.example" ? "incomplete" : "completed",
                    "content": [["type": "output_text", "text": text]],
                ]],
            ]
        } else {
            let reason: String
            switch url.host {
            case "length.example": reason = "length"
            case "filtered.example": reason = "content_filter"
            default: reason = "stop"
            }
            json = ["choices": [["message": ["content": text], "finish_reason": reason]]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
