//
//  AppNavigationState.swift
//  fluid
//
//  Navigation state shared by the main app and settings sidebars.
//

import CoreGraphics
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

    static let prewarmedPages: [SidebarItem] = [
        .voiceEngine, .aiEnhancements, .cleanupStyles, .fileTranscription, .meetingTranscription,
        .customDictionary, .stats, .history, .changelog, .commandMode,
    ]

    var title: String {
        switch self {
        case .welcome: "Dashboard"
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

/// The settings popup never gets smaller than `minimumSize`. In a bigger window it grows with
/// the window up to `maximumSize`. While it is open the window may not shrink below
/// `minimumWindowContentSize`, so the popup always sits inside the window.
struct SettingsPopupLayout: Equatable {
    static let minimumSize = CGSize(width: 880, height: 540)
    /// Wide enough for the sidebar plus a full-width settings page (720) and its scroll bar, and no
    /// wider, so a big window never leaves empty margins beside the page. Height still grows.
    static let maximumSize = CGSize(width: 960, height: 820)
    static let windowMargin = CGSize(width: 50, height: 30)
    static let minimumWindowContentSize = CGSize(
        width: minimumSize.width + windowMargin.width * 2,
        height: minimumSize.height + windowMargin.height * 2
    )

    /// Title bar and toolbar above the content area.
    static let windowChromeHeight: CGFloat = 52
    /// Smallest whole-window size allowed while the popup is open. It must fit the smallest
    /// Mac screen the app supports (1280 x 800 with menu bar and Dock), so keep it under 1280 x 700.
    static let minimumWindowSize = CGSize(
        width: minimumWindowContentSize.width,
        height: minimumWindowContentSize.height + windowChromeHeight
    )

    /// True for a click on the window's page area behind the popup. The title bar, toolbar and a
    /// thin band along the edges are left alone so the window can still be moved and resized.
    static func isDismissingClick(at point: CGPoint, windowContent: CGRect) -> Bool {
        windowContent.insetBy(dx: 8, dy: 8).contains(point)
    }

    /// True for a press on the window's top bar, away from the close/minimize/zoom buttons and the
    /// resize edges. A press there may be the start of moving the window, so the caller closes the
    /// popup only if the window did not move.
    static func isTopBarPress(at point: CGPoint, windowFrame: CGRect, windowContent: CGRect) -> Bool {
        let bar = CGRect(
            x: windowFrame.minX + 84,
            y: windowContent.maxY,
            width: windowFrame.width - 84,
            height: windowFrame.maxY - windowContent.maxY
        )
        return bar.insetBy(dx: 8, dy: 0).contains(point) && point.y < windowFrame.maxY - 6
    }

    static let sidebarWidth: CGFloat = 220

    let width: CGFloat
    let height: CGFloat

    init(windowContentSize: CGSize) {
        self.width = min(Self.maximumSize.width, max(Self.minimumSize.width, windowContentSize.width - Self.windowMargin.width * 2))
        self.height = min(Self.maximumSize.height, max(Self.minimumSize.height, windowContentSize.height - Self.windowMargin.height * 2))
    }
}
