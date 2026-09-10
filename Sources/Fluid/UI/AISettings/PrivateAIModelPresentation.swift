import Foundation

/// A RAM-based suggestion only; never selects, loads, downloads, or persists a model.
enum PrivateAIModelRecommendation {
    // First accessed from the settings background task; physical RAM cannot change during this process.
    static let currentModelID = modelID(physicalMemory: ProcessInfo.processInfo.physicalMemory)

    static func modelID(physicalMemory: UInt64) -> String {
        physicalMemory >= 16 * 1024 * 1024 * 1024 ? "fluid-1-mini-96k-dflash" : "fluid-1-pico-96k-dflash"
    }
}

/// UI-only previews. These identifiers are never registered with a runtime or download provider.
enum PrivateAIUpcomingModel: String, CaseIterable, Identifiable {
    case quad = "preview-upcoming-quad"
    case multilingual = "preview-upcoming-multilingual"

    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .quad: "Fluid 1 Quad"
        case .multilingual: "Fluid 1.1 Multilingual"
        }
    }
}

/// Customer-facing copy only. Registry IDs, downloads, and runtime settings remain authoritative.
struct PrivateAIModelPresentation {
    let summary: String
    let useCase: String
    var language: String = "On-device"
    // Illustrative design-preview values, not measured benchmark scores.
    var intelligence: Int?
    var speed: Int?

    static func forModel(id: String) -> Self {
        switch id {
        case "fluid-1-pico-96k-dflash":
            Self(summary: "Smallest & fastest", useCase: "Everyday dictation with basic cleanup and formatting.", language: "English only", intelligence: 2, speed: 5)
        case "fluid-1-mini-96k-dflash":
            Self(summary: "More capable", useCase: "Better structure, formatting and corrections.", language: "English only", intelligence: 4, speed: 4)
        case "fluid-1":
            Self(summary: "The original Fluid model", useCase: "Cleanup and formatting across languages.", language: "Multilingual", intelligence: 4, speed: 2)
        default:
            Self(summary: "On-device cleanup", useCase: "Polish your words privately on your Mac.")
        }
    }
}
