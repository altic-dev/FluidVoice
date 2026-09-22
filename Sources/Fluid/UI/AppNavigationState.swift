//
//  AppNavigationState.swift
//  fluid
//
//  Navigation state shared by the main app and settings sidebars.
//

import Foundation

enum SidebarItem: Hashable {
    case welcome
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

    var title: String {
        switch self {
        case .welcome: "Dashboard"
        case .voiceEngine: "Voice Engine"
        case .aiEnhancements: "AI Providers"
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

/// Read-only projection; changing chrome cannot navigate or alter a page's state.
struct AppPagePresentation: Equatable {
    let title: String
    let showsPageActions: Bool

    init(destination: SidebarItem?, settings: SettingsNavigationState) {
        self.title = settings.selectedSection?.title ?? (destination ?? .welcome).title
        self.showsPageActions = !settings.isPresented
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
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
