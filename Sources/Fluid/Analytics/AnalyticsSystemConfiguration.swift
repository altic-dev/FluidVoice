import Darwin
import Foundation

struct AnalyticsSystemConfiguration: Equatable {
    let ramGB: Int
    let chip: String

    static let current = AnalyticsSystemConfiguration(
        ramGB: Self.installedRAMInGigabytes,
        chip: Self.sysctlString("machdep.cpu.brand_string") ?? "unknown"
    )

    private static var installedRAMInGigabytes: Int {
        let bytesPerGigabyte: UInt64 = 1_073_741_824
        let roundedBytes = ProcessInfo.processInfo.physicalMemory + (bytesPerGigabyte / 2)
        return max(1, Int(roundedBytes / bytesPerGigabyte))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }

        let result = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
