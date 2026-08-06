import Foundation
import IOKit

enum MacLidState {
    static func isClosed() -> Bool? {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(rootDomain) }

        guard let value = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }

        return (value as? NSNumber)?.boolValue
    }
}
