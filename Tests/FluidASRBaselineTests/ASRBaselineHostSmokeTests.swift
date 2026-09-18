import AppKit
import XCTest

@MainActor
final class ASRBaselineHostSmokeTests: XCTestCase {
    private static let hostBundleID = "com.FluidApp.ASRBaselineHost"

    func testHostSandboxSmoke() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, Self.hostBundleID)
        XCTAssertNil(NSApplication.shared.delegate)
        XCTAssertTrue(NSApplication.shared.windows.isEmpty)

        let home = URL(fileURLWithPath: NSHomeDirectory()).standardized.resolvingSymlinksInPath()
        let containerSuffix = ["Library", "Containers", Self.hostBundleID, "Data"]
        let homeComponents = home.pathComponents
        XCTAssertTrue(
            homeComponents.count >= containerSuffix.count
                && Array(homeComponents.suffix(containerSuffix.count)) == containerSuffix,
            "home directory is not the host sandbox container: \(home.path)"
        )

        let appSupport = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .standardized.resolvingSymlinksInPath()
        let appSupportComponents = appSupport.pathComponents
        XCTAssertTrue(
            appSupportComponents.count > homeComponents.count
                && Array(appSupportComponents.prefix(homeComponents.count)) == homeComponents,
            "Application Support is not inside the host sandbox container: \(appSupport.path)"
        )

        let metadata: [String: String] = [
            "applicationSupportDirectory": appSupport.path,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "homeDirectory": home.path,
            "runBenchmark": ProcessInfo.processInfo.environment["FLUID_ASR_RUN_BENCHMARK"] ?? "0",
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "ASRBaselineHostSmoke"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
