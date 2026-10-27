import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import Security
import XCTest

final nonisolated class UpdateBundleValidatorTests: XCTestCase {
    private let identifier = "com.fluidvoice.update-validator.fixture"
    private let version = "1.6.10-beta.8"

    func testMissingBundleIsRejected() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        XCTAssertThrowsError(try UpdateBundleValidator.validate(
            at: missing,
            expectation: self.expectation,
            policy: .developerID(allowedTeamIDs: ["V4J43B279J"])
        )) { XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .invalidBundle) }
    }

    func testUnsignedBundleIsRejected() throws {
        try self.withFixture(sign: false) { fixture in
            XCTAssertThrowsError(try self.validate(fixture))
        }
    }

    func testDevelopmentFixtureAndInstalledPolicyPreserveExactMetadata() throws {
        try self.withFixture { fixture in
            let result = try self.validate(fixture)
            XCTAssertEqual(result.bundleIdentifier, self.identifier)
            XCTAssertEqual(result.version, self.version)
            XCTAssertEqual(result.build, "27")
            XCTAssertEqual(result.teamIdentifier, fixture.team)
            XCTAssertEqual(try UpdateBundleValidator.validate(
                at: fixture.bundle,
                expectation: self.expectation,
                policy: .installedApp(allowedTeamIDs: [fixture.team])
            ), result)
        }
    }

    func testDownloadedReleasePolicyRejectsDevelopmentCertificate() throws {
        try self.withFixture { fixture in
            XCTAssertThrowsError(try UpdateBundleValidator.validate(
                at: fixture.bundle,
                expectation: self.expectation,
                policy: .developerID(allowedTeamIDs: [fixture.team])
            ))
        }
    }

    func testDeveloperIDReleaseAcceptsApprovedSigningTeams() throws {
        try self.withFixture(developerID: true) { fixture in
            let approved: Set<String> = ["V4J43B279J", "537RRRT57V"]
            let result = try UpdateBundleValidator.validate(
                at: fixture.bundle,
                expectation: self.expectation,
                policy: .developerID(allowedTeamIDs: approved)
            )
            XCTAssertTrue(approved.contains(result.teamIdentifier))
            XCTAssertEqual(result.version, self.version)
            XCTAssertEqual(result.build, "27")
        }
    }

    func testUnapprovedTeamIsRejected() throws {
        try self.withFixture { fixture in
            XCTAssertThrowsError(try UpdateBundleValidator.validate(
                at: fixture.bundle,
                expectation: self.expectation,
                policy: .appleDevelopment(allowedTeamIDs: ["0000000000"])
            ))
        }
    }

    func testDifferentApplicationIdentityIsRejected() throws {
        try self.withFixture(identifier: "com.fluidvoice.some-other-app") { fixture in
            XCTAssertThrowsError(try self.validate(fixture)) {
                XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .identityMismatch)
            }
        }
    }

    func testDifferentReleaseVersionIsRejectedButRollbackInspectionAllowsIt() throws {
        try self.withFixture(version: "1.6.10-beta.7") { fixture in
            XCTAssertThrowsError(try self.validate(fixture)) {
                XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .versionMismatch)
            }
            let rollback = try UpdateBundleValidator.validate(
                at: fixture.bundle,
                expectation: .init(bundleIdentifier: self.identifier, version: nil),
                policy: .installedApp(allowedTeamIDs: [fixture.team])
            )
            XCTAssertEqual(rollback.version, "1.6.10-beta.7")
        }
    }

    func testExpectedBuildMismatchAndMalformedBuildAreRejected() throws {
        try self.withFixture { fixture in
            XCTAssertThrowsError(try UpdateBundleValidator.validate(
                at: fixture.bundle,
                expectation: .init(bundleIdentifier: self.identifier, version: self.version, build: "28"),
                policy: .appleDevelopment(allowedTeamIDs: [fixture.team])
            )) { XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .buildMismatch) }
        }
        try self.withFixture(build: "not-a-build") { fixture in
            XCTAssertThrowsError(try self.validate(fixture)) {
                XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .invalidBundleMetadata)
            }
        }
    }

    func testTamperedResourceIsRejectedAlthoughSigningMetadataIsStillReadable() throws {
        try self.withFixture { fixture in
            try Data("changed after signing".utf8).write(to: fixture.resource)
            XCTAssertEqual(try self.signingTeam(at: fixture.bundle), fixture.team)
            XCTAssertThrowsError(try self.validate(fixture))
        }
    }

    func testTamperedNestedResourceIsRejectedAlthoughOuterSignatureStillPasses() throws {
        try self.withFixture(nested: true) { fixture in
            XCTAssertNoThrow(try self.validate(fixture))
            let nested = fixture.bundle.appendingPathComponent("Contents/PlugIns/Nested.app")
            try Data("changed nested resource".utf8).write(to: nested.appendingPathComponent("Contents/Resources/payload.txt"))
            var code: SecStaticCode?
            XCTAssertEqual(SecStaticCodeCreateWithPath(fixture.bundle as CFURL, [], &code), errSecSuccess)
            let outerCode = try XCTUnwrap(code)
            let outerOnly = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
            XCTAssertEqual(SecStaticCodeCheckValidity(outerCode, outerOnly, nil), errSecSuccess)
            XCTAssertThrowsError(try self.validate(fixture))
        }
    }

    func testTamperedNonNativeArchitectureIsRejected() throws {
        try self.withFixture { fixture in
            XCTAssertNoThrow(try self.validate(fixture))
            let executable = fixture.bundle.appendingPathComponent("Contents/MacOS/Fixture")
            var bytes = try Data(contentsOf: executable)
            // /usr/bin/true is a universal binary on the test Mac. Damage only the
            // other architecture so validating just the native slice would miss it.
            #if arch(arm64)
            let otherCPU: UInt32 = 0x01000007
            #else
            let otherCPU: UInt32 = 0x0100000c
            #endif
            let damaged = try self.textByteOffset(in: bytes, cpu: otherCPU)
            bytes[damaged] ^= 0x01
            try bytes.write(to: executable)
            var code: SecStaticCode?
            XCTAssertEqual(SecStaticCodeCreateWithPath(fixture.bundle as CFURL, [], &code), errSecSuccess)
            XCTAssertEqual(try SecStaticCodeCheckValidity(XCTUnwrap(code), SecCSFlags(rawValue: kSecCSStrictValidate), nil), errSecSuccess)
            XCTAssertThrowsError(try self.validate(fixture))
        }
    }

    func testTamperedNestedExecutableIsRejected() throws {
        try self.withFixture(nested: true) { fixture in
            XCTAssertNoThrow(try self.validate(fixture))
            let executable = fixture.bundle.appendingPathComponent("Contents/PlugIns/Nested.app/Contents/MacOS/Fixture")
            var bytes = try Data(contentsOf: executable)
            let damaged = try self.textByteOffset(in: bytes)
            bytes[damaged] ^= 0x01
            try bytes.write(to: executable)
            var code: SecStaticCode?
            XCTAssertEqual(SecStaticCodeCreateWithPath(fixture.bundle as CFURL, [], &code), errSecSuccess)
            XCTAssertEqual(try SecStaticCodeCheckValidity(XCTUnwrap(code), SecCSFlags(rawValue: kSecCSStrictValidate), nil), errSecSuccess)
            XCTAssertThrowsError(try self.validate(fixture))
        }
    }

    func testInvalidExpectationFailsClosed() {
        XCTAssertThrowsError(try UpdateBundleValidator.validate(
            at: URL(fileURLWithPath: "/unused.app"),
            expectation: .init(bundleIdentifier: self.identifier, version: self.version),
            policy: .developerID(allowedTeamIDs: [])
        )) { XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .invalidExpectation) }
    }

    private var expectation: UpdateBundleValidator.Expectation {
        .init(bundleIdentifier: self.identifier, version: self.version, build: "27")
    }

    private struct Fixture {
        let bundle: URL
        let team: String
        var resource: URL { self.bundle.appendingPathComponent("Contents/Resources/payload.txt") }
    }

    private func validate(_ fixture: Fixture) throws -> UpdateBundleValidator.ValidatedBundle {
        try UpdateBundleValidator.validate(at: fixture.bundle, expectation: self.expectation, policy: .appleDevelopment(allowedTeamIDs: [fixture.team]))
    }

    private func withFixture(
        identifier: String? = nil,
        version: String? = nil,
        build: String = "27",
        sign: Bool = true,
        nested: Bool = false,
        developerID: Bool = false,
        body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateBundleValidatorTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try self.makeBundle(at: bundle, identifier: identifier ?? self.identifier, version: version ?? self.version, build: build)
        if !sign {
            // The copied executable retains Apple's signature, but the enclosing
            // application has never been signed and has no sealed resource envelope.
            try body(Fixture(bundle: bundle, team: "V4J43B279J"))
            return
        }
        let identity = try self.signingIdentity(developerID: developerID)
        if nested {
            let nestedBundle = bundle.appendingPathComponent("Contents/PlugIns/Nested.app", isDirectory: true)
            try self.makeBundle(at: nestedBundle, identifier: self.identifier + ".nested", version: self.version, build: build)
            try self.sign(nestedBundle, identity: identity)
        }
        try self.sign(bundle, identity: identity)
        try body(Fixture(bundle: bundle, team: self.signingTeam(at: bundle)))
    }

    private func makeBundle(at bundle: URL, identifier: String, version: String, build: String) throws {
        let executableDirectory = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableDirectory.appendingPathComponent("Fixture"))
        try Data("original resource".utf8).write(to: resources.appendingPathComponent("payload.txt"))
        let plist = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private func signingIdentity(developerID: Bool) throws -> String {
        let prefix = developerID ? "Developer ID Application:" : "Apple Development:"
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw XCTSkip("A \(prefix) signing identity is required for signed bundle fixtures.")
        }
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let summary = SecCertificateCopySubjectSummary(certificate) as String?, summary.hasPrefix(prefix)
            else { continue }
            var trust: SecTrust?
            guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil),
                  SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil)
            else { continue }
            return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        }
        throw XCTSkip("A valid \(prefix) signing identity is required for signed bundle fixtures.")
    }

    private func signingTeam(at bundle: URL) throws -> String {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(bundle as CFURL, [], &code), errSecSuccess)
        let staticCode = try XCTUnwrap(code)
        var result: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &result), errSecSuccess)
        let information = try XCTUnwrap(result as? [String: Any])
        return try XCTUnwrap(information[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    private func sign(_ bundle: URL, identity: String) throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".codesign.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: log)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", identity, "--timestamp=none", bundle.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("Temporary fixture signing exceeded its bounded timeout.")
            throw NSError(domain: "UpdateBundleValidatorTests", code: 1)
        }
        guard process.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? "No signing diagnostic"
            XCTFail("Temporary fixture signing failed: \(diagnostic)")
            throw NSError(domain: "UpdateBundleValidatorTests", code: Int(process.terminationStatus))
        }
    }

    private func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Mutate sealed executable instructions, never padding inside a signature blob.
    private func textByteOffset(in data: Data, cpu: UInt32? = nil) throws -> Int {
        guard self.bigEndian32(data, at: 0) == 0xcafebabe else {
            throw XCTSkip("The system fixture is not a 32-bit-header universal binary.")
        }
        let count = Int(self.bigEndian32(data, at: 4))
        guard (1...16).contains(count), 8 + count * 20 <= data.count else {
            throw NSError(domain: "UpdateBundleValidatorTests.MachO", code: 1)
        }
        let header = try XCTUnwrap((0..<count).map { 8 + $0 * 20 }.first {
            cpu == nil || self.bigEndian32(data, at: $0) == cpu
        })
        let slice = Int(self.bigEndian32(data, at: header + 8))
        let sliceSize = Int(self.bigEndian32(data, at: header + 12))
        guard slice + 32 <= data.count, sliceSize >= 32, slice + sliceSize <= data.count,
              self.littleEndian32(data, at: slice) == 0xfeedfacf
        else { throw NSError(domain: "UpdateBundleValidatorTests.MachO", code: 2) }
        let commands = Int(self.littleEndian32(data, at: slice + 16))
        let commandsSize = Int(self.littleEndian32(data, at: slice + 20))
        let commandsEnd = slice + 32 + commandsSize
        guard (1...128).contains(commands), commandsEnd <= slice + sliceSize else {
            throw NSError(domain: "UpdateBundleValidatorTests.MachO", code: 3)
        }
        var cursor = slice + 32
        for _ in 0..<commands {
            guard cursor + 8 <= commandsEnd else { break }
            let kind = self.littleEndian32(data, at: cursor)
            let size = Int(self.littleEndian32(data, at: cursor + 4))
            guard size >= 8, cursor + size <= commandsEnd else { break }
            if kind == 0x19, size >= 72 {
                let sections = Int(self.littleEndian32(data, at: cursor + 64))
                guard sections <= 128, 72 + sections * 80 <= size else { break }
                for section in 0..<sections {
                    let position = cursor + 72 + section * 80
                    let name = String(bytes: data[position..<position + 16].prefix { $0 != 0 }, encoding: .utf8)
                    if name == "__text" {
                        let offset = Int(self.littleEndian32(data, at: position + 48))
                        let sectionSize = Int(self.littleEndian32(data, at: position + 40))
                        guard sectionSize > 0, offset + sectionSize <= sliceSize,
                              self.littleEndian32(data, at: position + 44) == 0
                        else { break }
                        return slice + offset + sectionSize / 2
                    }
                }
            }
            cursor += size
        }
        throw NSError(domain: "UpdateBundleValidatorTests.MachO", code: 4)
    }

    private func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<offset + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
