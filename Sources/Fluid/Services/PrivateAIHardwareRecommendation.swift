import Darwin
import Foundation
import IOKit

/// A hardware heuristic, not a latency guarantee. Does not alter settings or load models.
enum PrivateAIHardwareRecommendation {
    struct Hardware: Equatable, Sendable {
        let chip: String
        let memoryBytes: UInt64
        let gpuCoreCount: Int?
    }

    enum Model: String, Sendable {
        case pico = "fluid-1-pico-96k-dflash"
        case mini = "fluid-1-mini-96k-dflash"
    }

    enum Reason: String, Sendable {
        case sufficientHardware
        case insufficientMemory
        case entryLevelChip
        case unknownHardware
    }

    struct Recommendation: Equatable, Sendable {
        let model: Model
        let reason: Reason
        /// Published peak bandwidth; conservative lower variant when GPU identity is unavailable.
        let bandwidthGBps: Double?
    }

    // A single bounded snapshot. Even the first caller on MainActor performs hardware IO off-main.
    private static let hardwareTask = Task.detached(priority: .utility) {
        Hardware(
            chip: Self.readChip() ?? "unknown",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            gpuCoreCount: Self.readGPUCoreCount()
        )
    }

    static func currentHardware() async -> Hardware {
        await self.hardwareTask.value
    }

    static func current() async -> Recommendation {
        self.recommend(for: await self.currentHardware())
    }

    static func recommend(for hardware: Hardware) -> Recommendation {
        let bandwidth = self.bandwidth(chip: hardware.chip, gpuCores: hardware.gpuCoreCount)
        guard hardware.memoryBytes >= 16 * 1024 * 1024 * 1024 else {
            return Recommendation(model: .pico, reason: .insufficientMemory, bandwidthGBps: bandwidth)
        }
        guard let bandwidth else {
            return Recommendation(model: .pico, reason: .unknownHardware, bandwidthGBps: nil)
        }
        // Capacity and chip tier are independent gates. Generation alone is not a speed rating.
        let tier = hardware.chip.split(whereSeparator: { $0.isWhitespace }).last?.lowercased()
        let isPerformanceChip = ["pro", "max", "ultra"].contains(tier ?? "")
        return Recommendation(
            model: isPerformanceChip ? .mini : .pico,
            reason: isPerformanceChip ? .sufficientHardware : .entryLevelChip,
            bandwidthGBps: bandwidth
        )
    }

    /// Apple published specifications, reviewed September 2026. Unknown generations do not inherit a tier.
    /// M3/M4 Max: https://support.apple.com/117737 and https://support.apple.com/121554
    /// M5 Pro/Max: https://support.apple.com/126319; Ultra: https://support.apple.com/122211
    private static func bandwidth(chip: String, gpuCores: Int?) -> Double? {
        let chip = chip.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        switch chip {
        case "apple m1": return 68.3
        case "apple m2", "apple m3": return 100
        case "apple m4": return 120
        case "apple m5": return 153
        case "apple m1 pro", "apple m2 pro": return 200
        case "apple m3 pro": return 150
        case "apple m4 pro": return 273
        case "apple m5 pro": return 307
        case "apple m1 max", "apple m2 max": return 400
        case "apple m3 max": return gpuCores == 40 ? 400 : 300
        case "apple m4 max": return gpuCores == 40 ? 546 : 410
        case "apple m5 max": return gpuCores == 40 ? 614 : 460
        case "apple m1 ultra", "apple m2 ultra": return 800
        case "apple m3 ultra": return 819
        default: return nil
        }
    }

    private static func readChip() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0, size <= 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    private static func readGPUCoreCount() -> Int? {
        // Optional registry hint: fall back to the lower bandwidth variant when absent.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0),
              let number = property.takeRetainedValue() as? NSNumber else { return nil }
        let count = number.intValue
        return (1...256).contains(count) ? count : nil
    }
}
