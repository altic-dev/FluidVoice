//
//  AppNavigationState.swift
//  fluid
//
//  Navigation state shared by the main app and settings sidebars.
//

import CoreGraphics
import Foundation

enum SidebarItem: Hashable, CaseIterable {
    case welcome
    case models
    case voiceEngine
    case aiEnhancements
    case cleanupStyles
    case fileTranscription
    case meetingTranscription
    case customDictionary
    case stats
    case history
    case changelog
    case feedback
    case commandMode
    case rewriteMode

    static let prewarmedPages: [SidebarItem] = [
        .voiceEngine, .aiEnhancements, .cleanupStyles, .fileTranscription, .meetingTranscription,
        .customDictionary, .stats, .history, .changelog, .commandMode,
    ]

    var title: String {
        switch self {
        case .welcome: "Dashboard"
        case .models: "Models"
        case .voiceEngine: "Voice Engine"
        case .aiEnhancements: "AI Settings"
        case .cleanupStyles: "Cleanup Styles"
        case .fileTranscription: "File Transcription"
        case .meetingTranscription: "FluidMeet"
        case .customDictionary: "Custom Dictionary"
        case .stats: "Stats"
        case .history: "History"
        case .changelog: "Change logs"
        case .feedback: "Feedback"
        case .commandMode: "Command Mode"
        case .rewriteMode: "Edit Mode"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case fluidMeet
    case dictation
    case dictationFormatting
    case shortcuts
    case notifications
    case audio
    case overlay
    case dataAndDiagnostics
    case experimental

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .fluidMeet: return "FluidMeet Settings"
        case .dictation: return "Dictation"
        case .dictationFormatting: return "Dictation Formatting"
        case .shortcuts: return "Shortcuts"
        case .notifications: return "Notifications"
        case .audio: return "Audio"
        case .overlay: return "Overlay"
        case .dataAndDiagnostics: return "Data & Diagnostics"
        case .experimental: return "Experimental"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .fluidMeet: return "person.2"
        case .dictation: return "mic"
        case .dictationFormatting: return "textformat"
        case .shortcuts: return "keyboard"
        case .notifications: return "bell"
        case .audio: return "speaker.wave.2"
        case .overlay: return "rectangle.on.rectangle"
        case .dataAndDiagnostics: return "wrench.and.screwdriver"
        case .experimental: return "flask"
        }
    }
}

struct SettingsNavigationState: Equatable {
    var selectedSection: SettingsSection?
    private(set) var returnDestination: SidebarItem = .welcome

    var isPresented: Bool {
        self.selectedSection != nil
    }

    func isLeaving(_ section: SettingsSection, for destination: SettingsSection?) -> Bool {
        self.selectedSection == section && destination != section
    }

    mutating func present(_ section: SettingsSection, returningTo currentDestination: SidebarItem?) {
        if !self.isPresented {
            self.returnDestination = currentDestination ?? .welcome
        }
        self.selectedSection = section
    }

    mutating func dismiss() -> SidebarItem {
        self.selectedSection = nil
        return self.returnDestination
    }

    mutating func leaveForApp() {
        self.selectedSection = nil
    }
}

/// Settings' own column inside the shared pop-up size (`FluidPopupLayout`).
enum SettingsPopupLayout {
    static let sidebarWidth: CGFloat = 220
}
