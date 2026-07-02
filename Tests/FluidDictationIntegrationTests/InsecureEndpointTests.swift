@testable import FluidVoice_Debug
import Foundation
import XCTest

final class InsecureEndpointTests: XCTestCase {
    private let repository = ModelRepository.shared

    func testPlainHTTPToRemoteHostsIsInsecure() {
        XCTAssertTrue(self.repository.isInsecureRemoteEndpoint("http://mars-main.box:8317/v1"))
        XCTAssertTrue(self.repository.isInsecureRemoteEndpoint("http://192.168.1.20:8080/v1"))
        XCTAssertTrue(self.repository.isInsecureRemoteEndpoint("http://proxy.example.com/v1"))
        XCTAssertTrue(self.repository.isInsecureRemoteEndpoint("  http://proxy.example.com/v1  "))
        XCTAssertTrue(self.repository.isInsecureRemoteEndpoint("HTTP://proxy.example.com/v1"))
    }

    func testLoopbackHTTPIsNotFlagged() {
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("http://localhost:11434/v1"))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("http://LOCALHOST:11434/v1"))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("http://127.0.0.1:1234/v1"))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("http://127.1.2.3:1234/v1"))
    }

    func testHTTPSAndInvalidInputAreNotFlagged() {
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("https://api.example.com/v1"))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("https://mars-main.box:8317/v1"))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint(""))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("   "))
        XCTAssertFalse(self.repository.isInsecureRemoteEndpoint("api.example.com/v1"))
    }
}
