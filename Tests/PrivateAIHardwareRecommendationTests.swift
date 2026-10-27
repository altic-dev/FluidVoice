import Foundation

@main
struct PrivateAIHardwareRecommendationTests {
    static func main() async {
        typealias Policy = PrivateAIHardwareRecommendation
        let gib: UInt64 = 1024 * 1024 * 1024
        let cases: [(String, Int?, UInt64, Policy.Model)] = [
            ("Apple M1", 8, 8, .pico), ("Apple M1", 8, 16, .pico),
            ("Apple M1 Pro", 16, 32, .mini), ("Apple M1 Max", 24, 32, .mini),
            ("Apple M2", 10, 24, .pico), ("Apple M2 Pro", 19, 32, .mini),
            ("Apple M2 Max", 30, 32, .mini), ("Apple M3", 10, 24, .pico),
            ("Apple M3 Pro", 18, 36, .mini), ("Apple M3 Max", 30, 36, .mini),
            ("Apple M3 Max", 40, 48, .mini), ("Apple M3 Max", nil, 128, .mini),
            ("Apple M3 Max", 99, 128, .mini), ("Apple M4", 10, 32, .pico),
            ("Apple M4 Pro", 20, 64, .mini), ("Apple M4 Max", 32, 36, .mini),
            ("Apple M4 Max", 40, 128, .mini), ("Apple M5", 10, 32, .pico),
            ("Apple M5 Pro", 20, 64, .mini), ("Apple M5 Max", 32, 36, .mini),
            ("Apple M5 Max", 40, 128, .mini), ("Apple M1 Ultra", 48, 64, .mini),
            ("Apple M2 Ultra", 60, 64, .mini), ("Apple M3 Ultra", 60, 96, .mini),
            ("Apple M5 Max", 40, 8, .pico), ("Apple M5 Max", 40, 16, .mini), ("Apple M5 Max", 40, 24, .mini),
            ("Apple M3 Pro", 18, 18, .mini),
            ("Apple M1 Pro", 16, 16, .mini), ("Apple M2 Pro", 19, 16, .mini),
            ("Apple M4 Pro", 20, 18, .mini), ("Apple M4", 10, 16, .pico),
            ("Intel Core i9", nil, 64, .pico), ("Apple M99 Max", 40, 128, .pico),
            ("", nil, 0, .pico), ("  APPLE   M1 MAX  ", nil, 32, .mini),
        ]
        for (chip, cores, ram, expected) in cases {
            let hardware = Policy.Hardware(chip: chip, memoryBytes: ram * gib, gpuCoreCount: cores)
            precondition(Policy.recommend(for: hardware).model == expected, "Unexpected recommendation: \(chip), \(ram) GB")
        }
        let belowBoundary = Policy.Hardware(chip: "Apple M1 Max", memoryBytes: 16 * gib - 1, gpuCoreCount: nil)
        precondition(Policy.recommend(for: belowBoundary).reason == .insufficientMemory)
        let unknown = Policy.Hardware(chip: "unknown", memoryBytes: 128 * gib, gpuCoreCount: nil)
        precondition(Policy.recommend(for: unknown).reason == .unknownHardware)
        precondition(Policy.recommend(for: unknown).bandwidthGBps == nil)
        let hardware = await Policy.currentHardware()
        let expected = Policy.recommend(for: hardware)
        // Concurrent requests share an immutable snapshot and return the same recommendation.
        await withTaskGroup(of: Policy.Recommendation.self) { group in
            for _ in 0..<32 {
                group.addTask { await Policy.current() }
            }
            for await result in group {
                precondition(result == expected)
            }
        }
        print("PASS: \(cases.count) hardware cases, boundary/failure checks, 32 concurrent requests")
        print("LIVE: \(hardware.chip), GPU cores \(hardware.gpuCoreCount ?? 0), RAM \(hardware.memoryBytes / gib) GiB")
        print("RESULT: \(expected.model.rawValue), \(expected.bandwidthGBps ?? 0) GB/s, \(expected.reason.rawValue)")
    }
}
