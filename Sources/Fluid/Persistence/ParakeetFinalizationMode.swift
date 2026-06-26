import Foundation

enum ParakeetFinalizationMode: String, CaseIterable, Codable, Identifiable {
    case stableFullFinal
    case tokenTimedChunkMerge

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .stableFullFinal:
            return "Standard"
        case .tokenTimedChunkMerge:
            return "Fast"
        }
    }

    var detailText: String {
        switch self {
        case .stableFullFinal:
            return "Most reliable."
        case .tokenTimedChunkMerge:
            return "Faster, but maybe inaccurate."
        }
    }
}
