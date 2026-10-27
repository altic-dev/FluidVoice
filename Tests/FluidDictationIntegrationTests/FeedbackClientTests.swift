@testable import FluidVoice_Debug
import XCTest

final class FeedbackClientTests: XCTestCase {
    private var draft: FeedbackSubmission {
        FeedbackSubmission(email: " TEAM@example.com ", message: " Test message ", category: .issue, appDetails: nil)
    }

    func testPayloadPreservesBackendContractAndOptIn() throws {
        let data = try JSONEncoder().encode(self.draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["email_id", "feedback"])
        XCTAssertEqual(object["email_id"], "team@example.com")
        XCTAssertEqual(object["feedback"], "[Report an issue]\nTest message")
        XCTAssertFalse(self.draft.content.contains("macOS"))
        let detailed = FeedbackSubmission(email: "team@example.com", message: "hello", category: .idea, appDetails: "macOS test")
        XCTAssertTrue(detailed.content.contains("macOS test"))
    }

    func testValidationMatchesServerLimitsIncludingEmoji() {
        for email in ["bad", "a@b", ".a@example.com", "a..b@example.com", "a b@example.com"] {
            XCTAssertFalse(FeedbackSubmission.isValidEmail(email), email)
        }
        XCTAssertTrue(FeedbackSubmission.isValidEmail(" first.last+test@example.com "))
        for message in ["  \n", String(repeating: "a", count: 4501), String(repeating: "😀", count: 2251)] {
            XCTAssertFalse(FeedbackSubmission(email: "a@example.com", message: message, category: .issue, appDetails: nil).isValid)
        }
        XCTAssertTrue(FeedbackSubmission(email: "a@example.com", message: String(repeating: "a", count: 4500), category: .issue, appDetails: FeedbackSubmission.appDetails).isValid)
        XCTAssertFalse(FeedbackSubmission(email: "a@example.com", message: "hello", category: .issue, appDetails: String(repeating: "x", count: 5000)).isValid)
    }

    func testSuccessRequiresReceiptAndUsesExpectedRequest() async throws {
        let client = self.client { request in
            XCTAssertEqual(request.url?.absoluteString, "https://altic.dev/api/fluid/feedback")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 30)
            return (200, #"{"message":"Feedback submitted successfully"}"#)
        }
        defer { client.session.invalidateAndCancel() }
        try await client.send(self.draft)
    }

    func testHTTPFailuresAndFalseSuccess() async {
        for (status, body, expected) in [
            (429, "{}", FeedbackClient.Failure.rateLimited),
            (400, "{}", .rejected), (500, "{}", .server),
            (200, "<html>Sign in</html>", .unconfirmed), (200, "{}", .unconfirmed),
        ] {
            let client = self.client { _ in (status, body) }
            do {
                try await client.send(self.draft)
                XCTFail("Expected a failure for \(status)")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
            client.session.invalidateAndCancel()
        }
    }

    func testTimeoutDoesNotAutomaticallyRetry() async {
        var requests = 0
        let client = self.client { _ in
            requests += 1
            throw URLError(.timedOut)
        }
        defer { client.session.invalidateAndCancel() }
        do {
            try await client.send(self.draft)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, FeedbackClient.Failure.connection.localizedDescription)
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(self.draft.message, " Test message ")
    }

    func testInvalidDraftNeverHitsNetwork() async {
        let client = self.client { _ in XCTFail("No network expected"); return (200, "{}") }
        defer { client.session.invalidateAndCancel() }
        do {
            try await client.send(FeedbackSubmission(email: "invalid", message: "hello", category: .issue, appDetails: nil))
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, FeedbackClient.Failure.invalid.localizedDescription)
        }
    }

    private func client(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> FeedbackClient {
        FeedbackURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocol.self]
        return FeedbackClient(session: URLSession(configuration: config))
    }
}

private class FeedbackURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = self.request.url else { throw URLError(.badURL) }
            let (status, body) = try handler(self.request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { throw URLError(.badServerResponse) }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
