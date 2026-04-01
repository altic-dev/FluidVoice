import Foundation
import XCTest

@testable import FluidVoice_Debug

@MainActor
final class LLMClientRetryTests: XCTestCase {

    private let client = LLMClient.shared

    // MARK: - Retryable HTTP errors

    private static let retryableHTTPCodes: [(Int, String)] = [
        (429, "Too Many Requests"),
        (500, "Internal Server Error"),
        (502, "Bad Gateway"),
        (503, "Service Unavailable"),
        (504, "Gateway Timeout"),
    ]

    func testIsRetryable_transientHTTPErrors() {
        for (code, message) in Self.retryableHTTPCodes {
            let error = LLMError.httpError(code, message)
            XCTAssertTrue(client.isRetryable(error), "Expected HTTP \(code) to be retryable")
        }
    }

    // MARK: - Non-retryable HTTP errors

    private static let nonRetryableHTTPCodes: [(Int, String)] = [
        (400, "Bad Request"),
        (401, "Unauthorized"),
        (403, "Forbidden"),
        (404, "Not Found"),
    ]

    func testIsRetryable_permanentHTTPErrorsAreNotRetryable() {
        for (code, message) in Self.nonRetryableHTTPCodes {
            let error = LLMError.httpError(code, message)
            XCTAssertFalse(client.isRetryable(error), "Expected HTTP \(code) to not be retryable")
        }
    }

    // MARK: - Retryable network errors

    private static let retryableURLErrorCodes: [URLError.Code] = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
    ]

    func testIsRetryable_transientNetworkErrors() {
        for code in Self.retryableURLErrorCodes {
            let error = URLError(code)
            XCTAssertTrue(client.isRetryable(error), "Expected URLError.\(code) to be retryable")
        }
    }

    // MARK: - Non-retryable network errors

    private static let nonRetryableURLErrorCodes: [URLError.Code] = [
        .cancelled,
        .badURL,
    ]

    func testIsRetryable_permanentNetworkErrorsAreNotRetryable() {
        for code in Self.nonRetryableURLErrorCodes {
            let error = URLError(code)
            XCTAssertFalse(client.isRetryable(error), "Expected URLError.\(code) to not be retryable")
        }
    }

    // MARK: - Non-retryable LLM errors
    // Note: LLMError.timeout is the app-level deadline (entire request exceeded configured limit),
    // unlike URLError.timedOut which is a transient network timeout worth retrying.

    private static let nonRetryableLLMErrors: [(LLMError, String)] = [
        (.invalidURL, "invalidURL"),
        (.invalidResponse, "invalidResponse"),
        (.encodingError, "encodingError"),
        (.timeout(30), "timeout"),
    ]

    func testIsRetryable_permanentLLMErrorsAreNotRetryable() {
        for (error, label) in Self.nonRetryableLLMErrors {
            XCTAssertFalse(client.isRetryable(error), "Expected LLMError.\(label) to not be retryable")
        }
    }

    // MARK: - Unknown errors

    func testIsRetryable_unknownErrorIsNotRetryable() {
        let error = NSError(domain: "test", code: 42)
        XCTAssertFalse(client.isRetryable(error))
    }
}
