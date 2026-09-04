//
//  SettingsSearch.swift
//  fluid
//
//  Search metadata and fuzzy matching for the Settings sidebar.
//

import AppKit
import Foundation
import SwiftUI

enum SettingsSearchTarget: Hashable {
    case general
    case launchAtStartup
    case showWindowAtLogin
    case dockVisibility
    case accentColor
    case transcriptionSounds
    case automaticUpdates
    case analyticsPrivacy

    case dictation
    case microphonePermission
    case globalHotkey
    case primaryDictationShortcuts
    case commandModeShortcut
    case editModeShortcut
    case cancelRecordingShortcut
    case pasteLastTranscriptionShortcut
    case activationMode
    case copyToClipboard
    case textInsertionMode
    case spokenSend
    case transcriptionHistory
    case audioHistory
    case usageStreak
    case skipSilentRecordings
    case pauseMedia
    case dictionarySuggestions
    case accessibilityPermission
    case textFormatting

    case notifications
    case aiEnhancementFailures
    case microphoneChanges

    case audio
    case inputDevicePriority
    case outputDevice

    case overlay
    case overlaySensitivity
    case overlayPosition
    case transcriptionPreviewLength
    case overlayStyle
    case livePreview
    case bottomOffset

    case dataAndDiagnostics
    case backupAndRestore
    case audioStorage
    case debugLogs
    case experimental
    case fasterLongDictation
    case historyPerformance

    var section: SettingsSection {
        switch self {
        case .general,
             .launchAtStartup,
             .showWindowAtLogin,
             .dockVisibility,
             .accentColor,
             .transcriptionSounds,
             .automaticUpdates:
            return .general

        case .dictation,
             .analyticsPrivacy,
             .microphonePermission,
             .globalHotkey,
             .primaryDictationShortcuts,
             .commandModeShortcut,
             .editModeShortcut,
             .cancelRecordingShortcut,
             .pasteLastTranscriptionShortcut,
             .activationMode,
             .copyToClipboard,
             .textInsertionMode,
             .spokenSend,
             .transcriptionHistory,
             .audioHistory,
             .audioStorage,
             .usageStreak,
             .skipSilentRecordings,
             .pauseMedia,
             .dictionarySuggestions,
             .accessibilityPermission,
             .textFormatting:
            return .dictation

        case .notifications, .aiEnhancementFailures, .microphoneChanges:
            return .notifications

        case .audio, .inputDevicePriority, .outputDevice:
            return .audio

        case .overlay,
             .overlaySensitivity,
             .overlayPosition,
             .transcriptionPreviewLength,
             .overlayStyle,
             .livePreview,
             .bottomOffset:
            return .overlay

        case .dataAndDiagnostics, .backupAndRestore, .debugLogs:
            return .dataAndDiagnostics

        case .experimental, .fasterLongDictation, .historyPerformance:
            return .experimental
        }
    }
}

extension SettingsSection {
    var searchTarget: SettingsSearchTarget {
        switch self {
        case .general: return .general
        case .dictation: return .dictation
        case .notifications: return .notifications
        case .audio: return .audio
        case .overlay: return .overlay
        case .dataAndDiagnostics: return .dataAndDiagnostics
        case .experimental: return .experimental
        }
    }
}

struct SettingsSearchResult: Identifiable, Equatable {
    let target: SettingsSearchTarget
    let score: Int

    var id: SettingsSearchTarget {
        self.target
    }

    var section: SettingsSection {
        self.target.section
    }
}

enum SettingsSearchIndex {
    private static let queryStopWords: Set<String> = ["and", "for", "from", "in", "of", "or", "the", "to", "with"]

    private struct Entry {
        let target: SettingsSearchTarget
        let title: String
        let terms: [String]
    }

    private struct WeightedField {
        let text: String
        let weight: Int
    }

    private static let entries: [Entry] = [
        .init(target: .general, title: "General", terms: ["app settings preferences"]),
        .init(
            target: .launchAtStartup,
            title: "Launch at startup",
            terms: ["Automatically start FluidVoice when you log in", "login startup boot open"]
        ),
        .init(
            target: .showWindowAtLogin,
            title: "Show window when launched at login",
            terms: ["starts silently in the menu bar", "login window visibility"]
        ),
        .init(
            target: .dockVisibility,
            title: "Hide from Dock & App Switcher",
            terms: ["menu bar only", "dock icon command tab cmd tab app switcher"]
        ),
        .init(target: .accentColor, title: "Accent Color", terms: ["appearance theme tint colour preset"]),
        .init(
            target: .transcriptionSounds,
            title: "Transcription Sounds",
            terms: ["recording sound cue volume independent mute start end audio"]
        ),
        .init(
            target: .automaticUpdates,
            title: "Automatic Updates",
            terms: ["beta releases check for updates release notes rollback previous builds version"]
        ),
        .init(
            target: .analyticsPrivacy,
            title: "Share Detailed Anonymous Analytics",
            terms: ["Analytics Privacy what we collect telemetry data active use weekly opt out"]
        ),

        .init(target: .dictation, title: "Dictation", terms: ["typing transcription keyboard preferences"]),
        .init(
            target: .microphonePermission,
            title: "Microphone Permission",
            terms: ["mic access authorization privacy grant denied system settings"]
        ),
        .init(target: .globalHotkey, title: "Global Hotkey", terms: ["keyboard shortcut activation accessibility"]),
        .init(
            target: .primaryDictationShortcuts,
            title: "Primary Dictation Shortcuts",
            terms: ["keyboard shortcut mouse button record hotkey"]
        ),
        .init(target: .commandModeShortcut, title: "Command Mode", terms: ["voice commands terminal hotkey shortcut"]),
        .init(target: .editModeShortcut, title: "Edit Mode", terms: ["rewrite selected text hotkey shortcut"]),
        .init(
            target: .cancelRecordingShortcut,
            title: "Cancel Recording",
            terms: ["dismiss overlay stop hotkey shortcut"]
        ),
        .init(
            target: .pasteLastTranscriptionShortcut,
            title: "Paste Last Transcription",
            terms: ["reinsert recent text hotkey shortcut clipboard"]
        ),
        .init(target: .activationMode, title: "Activation Mode", terms: ["hold toggle hotkey behavior"]),
        .init(
            target: .copyToClipboard,
            title: "Copy to Clipboard",
            terms: ["automatically copy transcribed text pasteboard backup"]
        ),
        .init(
            target: .textInsertionMode,
            title: "Text Insertion Mode",
            terms: ["type text copy paste clipboard reliable insertion delivery"]
        ),
        .init(
            target: .spokenSend,
            title: "Spoken Send",
            terms: ["send immediately phrase command enter return submit voice"]
        ),
        .init(
            target: .transcriptionHistory,
            title: "Save Transcription History",
            terms: ["stats tracking privacy remember transcript"]
        ),
        .init(
            target: .audioHistory,
            title: "Save Audio With History",
            terms: ["store microphone recording locally dictation audio"]
        ),
        .init(
            target: .usageStreak,
            title: "Weekends Don't Break Streak",
            terms: ["Saturday Sunday stats usage streak weekday"]
        ),
        .init(
            target: .skipSilentRecordings,
            title: "Skip Silent Recordings",
            terms: ["silence quiet speech avoid transcription"]
        ),
        .init(
            target: .pauseMedia,
            title: "Pause Media During Transcription",
            terms: ["resume music audio video playback recording"]
        ),
        .init(
            target: .dictionarySuggestions,
            title: "Auto-Learn Corrections",
            terms: ["automatic corrections learn words custom dictionary frequency ignore"]
        ),
        .init(
            target: .accessibilityPermission,
            title: "Accessibility Permission",
            terms: ["global hotkey access macOS system settings authorize"]
        ),
        .init(
            target: .textFormatting,
            title: "Text Formatting",
            terms: [
                "Lowercase First Letter Remove Trailing Period Slash Commands @ Formatting",
                "Space Between Dictations Smart Capitalization punctuation uppercase symbols mentions",
            ]
        ),

        .init(target: .notifications, title: "Notifications", terms: ["alerts warnings"]),
        .init(
            target: .aiEnhancementFailures,
            title: "AI Enhancement Failures",
            terms: ["notify processing error raw transcription alert"]
        ),
        .init(
            target: .microphoneChanges,
            title: "Microphone Changes",
            terms: ["mic device lost changed alert notification"]
        ),

        .init(target: .audio, title: "Audio", terms: ["sound devices microphone speaker"]),
        .init(
            target: .inputDevicePriority,
            title: "Input Device Priority",
            terms: ["microphone mic order drag reorder default restore removed unavailable active"]
        ),
        .init(
            target: .outputDevice,
            title: "Output Device",
            terms: ["speaker headphones audio system default refresh loading"]
        ),

        .init(target: .overlay, title: "Overlay", terms: ["recording indicator notch pill visualizer"]),
        .init(
            target: .overlaySensitivity,
            title: "Sensitivity",
            terms: ["audio visualizer sound input more less threshold"]
        ),
        .init(
            target: .overlayPosition,
            title: "Overlay Position",
            terms: ["recording indicator screen notch pill bottom location"]
        ),
        .init(
            target: .transcriptionPreviewLength,
            title: "Transcription Preview Length",
            terms: ["recent characters notch pill preview size"]
        ),
        .init(
            target: .overlayStyle,
            title: "Overlay Size & Notch Style",
            terms: ["large compact regular recording indicator presentation layout"]
        ),
        .init(
            target: .livePreview,
            title: "Live Preview",
            terms: ["streaming transcription text while speak overlay"]
        ),
        .init(target: .bottomOffset, title: "Bottom Offset", terms: ["distance from bottom screen pixels position"]),

        .init(
            target: .dataAndDiagnostics,
            title: "Data & Diagnostics",
            terms: ["backup restore debug logs experimental storage troubleshooting"]
        ),
        .init(
            target: .backupAndRestore,
            title: "Backup & Restore",
            terms: ["export import settings prompt profiles history stats API keys"]
        ),
        .init(
            target: .audioStorage,
            title: "Audio Storage",
            terms: ["history budget GB export ZIP delete prune WAV manifest"]
        ),
        .init(
            target: .debugLogs,
            title: "Debug Settings",
            terms: ["Show Debug Logs in App Reveal Log File crash diagnostics troubleshooting"]
        ),
        .init(
            target: .fasterLongDictation,
            title: "Faster Long Dictation",
            terms: ["experimental Parakeet reuse live windows remaining tail transcription"]
        ),
        .init(
            target: .experimental,
            title: "Experimental",
            terms: ["preview early access optional features"]
        ),
        .init(
            target: .historyPerformance,
            title: "Show Performance in History",
            terms: ["timing speed tokens per second ASR cleanup Fluid Intelligence"]
        ),
    ]

    static func results(for query: String) -> [SettingsSearchResult] {
        let normalizedQuery = self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let rankedResults: [(index: Int, result: SettingsSearchResult)] = self.entries.enumerated().compactMap { index, entry in
            guard let score = self.score(entry, for: normalizedQuery) else { return nil }
            return (index, SettingsSearchResult(target: entry.target, score: score))
        }

        return rankedResults.sorted { lhs, rhs in
            if lhs.result.score == rhs.result.score {
                return lhs.index < rhs.index
            }
            return lhs.result.score > rhs.result.score
        }
        .map(\.result)
    }

    static func matchingSections(for query: String) -> [SettingsSection] {
        let matchingSections = Set(self.results(for: query).map(\.section))
        return SettingsSection.allCases.filter(matchingSections.contains)
    }

    static func preferredSection(
        current: SettingsSection?,
        results: [SettingsSearchResult]
    ) -> SettingsSection? {
        guard !results.isEmpty else { return current }
        if let current, results.contains(where: { $0.section == current }) {
            return current
        }
        return results.first?.section
    }

    private static func score(_ entry: Entry, for query: String) -> Int? {
        let fields = [
            WeightedField(text: entry.title, weight: 100),
            WeightedField(text: entry.target.section.title, weight: 45),
        ] + entry.terms.map { WeightedField(text: $0, weight: 55) }

        let allQueryTokens = self.tokens(in: query)
        let meaningfulQueryTokens = allQueryTokens.filter { !self.queryStopWords.contains($0) }
        let queryTokens = meaningfulQueryTokens.isEmpty ? allQueryTokens : meaningfulQueryTokens
        let compactQuery = self.compact(query)
        let compactCandidates = fields.flatMap { field in
            var candidates = [self.compact(self.normalize(field.text))]
            for token in self.tokens(in: field.text) {
                candidates.append(self.compact(token))
            }
            return candidates
        }
        let hasCompactFuzzyMatch = compactQuery.count >= 4 &&
            compactCandidates.contains(where: { self.isFuzzyMatch(query: compactQuery, candidate: $0) })
        var score = 0

        for queryToken in queryTokens {
            let bestTokenScore = fields.compactMap { field -> Int? in
                self.tokens(in: field.text)
                    .compactMap { self.tokenScore(query: queryToken, candidate: $0) }
                    .max()
                    .map { $0 + field.weight }
            }.max()

            if let bestTokenScore {
                score += bestTokenScore
            } else if !hasCompactFuzzyMatch {
                return nil
            }
        }

        let normalizedTitle = self.normalize(entry.title)
        let normalizedSection = self.normalize(entry.target.section.title)
        score += self.phraseBonus(query: query, candidate: normalizedTitle, exactBonus: 1000)
        score += self.phraseBonus(query: query, candidate: normalizedSection, exactBonus: 400)

        for term in entry.terms {
            score += self.phraseBonus(query: query, candidate: self.normalize(term), exactBonus: 220)
        }

        if hasCompactFuzzyMatch {
            score += 180
        }

        return score
    }

    private static func phraseBonus(query: String, candidate: String, exactBonus: Int) -> Int {
        if candidate == query {
            return exactBonus
        }
        if candidate.hasPrefix(query) {
            return exactBonus * 3 / 5
        }
        if query.count >= 3, candidate.contains(query) {
            return exactBonus * 2 / 5
        }
        return 0
    }

    private static func tokenScore(query: String, candidate: String) -> Int? {
        if candidate == query {
            return 120
        }
        if candidate.hasPrefix(query) {
            return 105
        }
        if query.count >= 3, candidate.contains(query) {
            return 90
        }
        if self.isFuzzyMatch(query: query, candidate: candidate) {
            return 70 - (self.editDistance(query, candidate) * 8)
        }
        return nil
    }

    private static func isFuzzyMatch(query: String, candidate: String) -> Bool {
        let tolerance: Int
        switch query.count {
        case 0...3:
            return false
        case 4...6:
            tolerance = 1
        default:
            tolerance = 2
        }

        guard abs(query.count - candidate.count) <= tolerance else { return false }
        return self.editDistance(query, candidate) <= tolerance
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)

            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let separated = folded.map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(separated)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func tokens(in value: String) -> [String] {
        self.normalize(value).split(separator: " ").map(String.init)
    }

    private static func compact(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.placeholderString = "Search Settings"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .regular
        searchField.focusRingType = .default
        searchField.setAccessibilityLabel("Search Settings")
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != self.text {
            searchField.stringValue = self.text
        }
        Self.resignFocusIfNeeded(from: searchField, isActive: self.isActive)
    }

    static func resignFocusIfNeeded(from searchField: NSSearchField, isActive: Bool) {
        guard !isActive,
              searchField.currentEditor() != nil,
              let window = searchField.window
        else { return }

        window.makeFirstResponder(nil)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField

        init(_ parent: SettingsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            self.parent.text = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.string = ""
            control.stringValue = ""
            self.parent.text = ""
            return true
        }
    }
}
