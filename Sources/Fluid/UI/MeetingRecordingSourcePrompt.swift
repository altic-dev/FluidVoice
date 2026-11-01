import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// A single snapshot keeps the app shown in the confirmation identical to the app recorded.
nonisolated struct MeetingRecordingSourceSnapshot: Sendable {
    var defaults: MeetingRecordingDefaults
    var applications: [MeetingApplicationIdentity]
    var microphones: MeetingMicrophoneCatalogSnapshot
    var selectedApplication: MeetingApplicationIdentity?
    var selectedMicrophoneID: String?
    var sourceMessage: String?
    var recentApplication: MeetingApplicationIdentity?
    var installedApplications: [MeetingInstalledCallApplication] = []

    var microphoneSelectionLabel: String {
        if let selected = self.microphones.identities.first(where: { $0.captureDeviceID == self.selectedMicrophoneID }) {
            return selected.displayName
        }
        return self.microphones.identities.isEmpty ? "No microphone available" : "Choose a microphone…"
    }

    var availableRecentApplication: MeetingApplicationIdentity? {
        guard let recentApplication else { return nil }
        if let exact = try? MeetingRecordingSourceResolver.resolve(
            mode: .onlineCall, source: MeetingRecordingSource(application: recentApplication), target: nil, applications: self.applications
        ) { return exact }
        guard !recentApplication.bundleIdentifier.isEmpty else { return nil }
        return try? MeetingRecordingSourceResolver.resolve(
            mode: .onlineCall,
            source: .application(bundleIdentifier: recentApplication.bundleIdentifier, processID: nil, displayName: recentApplication.displayName),
            target: nil,
            applications: self.applications
        )
    }

    func applicationLabel(_ application: MeetingApplicationIdentity) -> String {
        let name = application.displayName.isEmpty ? "Audio source (\(application.processID ?? 0))" : application.displayName
        guard self.recentApplication?.bundleIdentifier == application.bundleIdentifier,
              let recent = self.availableRecentApplication,
              recent.bundleIdentifier == application.bundleIdentifier, recent.processID == application.processID else { return name }
        return "\(name) (Recent)"
    }

    static func suggestedApplication(
        defaults: MeetingRecordingDefaults,
        target: MeetingAutoDetector.ResolvedTarget?,
        foreground: MeetingApplicationIdentity?,
        applications: [MeetingApplicationIdentity]
    ) -> MeetingApplicationIdentity? {
        guard defaults.mode == .onlineCall else { return nil }
        let source = MeetingRecordingSource(defaults: defaults)
        if let application = try? MeetingRecordingSourceResolver.resolve(mode: .onlineCall, source: source, target: target, applications: applications) {
            return application
        }
        // A missing saved choice must stay missing, rather than silently choosing a different app.
        guard source == .automatic, let foreground else { return nil }
        return try? MeetingRecordingSourceResolver.resolve(
            mode: .onlineCall, source: MeetingRecordingSource(application: foreground), target: nil, applications: applications
        )
    }

    func configuration(applications: [MeetingApplicationIdentity], microphones: [MeetingMicrophoneIdentity]) throws -> MeetingCaptureConfiguration {
        guard var microphone = microphones.first(where: { $0.captureDeviceID == self.selectedMicrophoneID }) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        microphone.role = .unknown
        var application: MeetingApplicationIdentity?
        if self.defaults.mode == .onlineCall {
            guard let selectedApplication = self.selectedApplication else { throw MeetingCaptureError.applicationNotSelected }
            application = try MeetingRecordingSourceResolver.resolve(
                mode: .onlineCall, source: MeetingRecordingSource(application: selectedApplication), target: nil, applications: applications
            )
            application?.windowID = selectedApplication.windowID
        }
        return MeetingCaptureConfiguration(
            mode: self.defaults.mode,
            title: MeetingTranscriptionSetupDraft.defaultTitle(mode: self.defaults.mode, applicationDisplayName: application?.displayName),
            languageCode: self.defaults.languageCode ?? "en",
            platform: application.map { MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName) },
            application: application,
            microphone: microphone,
            timestampDefaultTitle: true
        )
    }
}

@MainActor
final class MeetingRecordingSourcePromptController: ObservableObject {
    static let shared = MeetingRecordingSourcePromptController()
    typealias Loader = (MeetingApplicationIdentity?) async throws -> MeetingRecordingSourceSnapshot
    typealias Starter = (MeetingRecordingSourceSnapshot) async throws -> Void

    @Published private(set) var isPresented = false
    @Published private(set) var isLoading = false
    @Published private(set) var isStarting = false
    @Published private(set) var snapshot: MeetingRecordingSourceSnapshot?
    @Published private(set) var errorMessage: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var panel: MeetingFloatingCaptionsPanel?
    private var refreshSelection: MeetingRecordingSourceSnapshot?
    private var refreshMicrophoneID: String?
    private let load: Loader
    private let start: Starter
    private let showsPanel: Bool

    init(showsPanel: Bool = true, load: @escaping Loader = MeetingRecordingSourcePromptController.loadSnapshot, start: @escaping Starter = MeetingRecordingSourcePromptController.startSnapshot) {
        self.showsPanel = showsPanel
        self.load = load
        self.start = start
    }

    var canConfirm: Bool {
        guard let snapshot, !self.isLoading, !self.isStarting else { return false }
        return snapshot.selectedMicrophoneID != nil && (snapshot.defaults.mode == .inRoom || snapshot.selectedApplication != nil)
    }

    /// Called only after the shortcut/menu has checked that no recording or dictation is active.
    func handleShortcut(foreground: MeetingApplicationIdentity? = nil, restoring selection: MeetingRecordingSourceSnapshot? = nil, microphoneID: String? = nil) {
        guard SettingsStore.shared.fluidMeetEnabled else { self.cancel(); return }
        if self.isPresented {
            self.confirm()
            return
        }
        // Read before creating a key panel, so the popup cannot become its own fallback.
        let app = NSWorkspace.shared.frontmostApplication
        let foreground = foreground ?? app.flatMap { app in
            app.bundleIdentifier.map { MeetingApplicationIdentity(bundleIdentifier: $0, processID: app.processIdentifier, displayName: app.localizedName ?? $0) }
        }
        self.generation = UUID()
        let generation = self.generation
        self.refreshSelection = selection
        self.refreshMicrophoneID = microphoneID
        self.snapshot = nil
        self.errorMessage = nil
        self.isLoading = true
        self.isPresented = true
        if self.showsPanel, !self.showPanel() {
            self.cancel()
            return
        }
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                var snapshot = try await self.load(foreground)
                snapshot.recentApplication = SettingsStore.shared.meetingRecentApplication
                if let selection {
                    snapshot.defaults.mode = selection.defaults.mode
                    if let selected = selection.selectedApplication {
                        snapshot.selectedApplication = try? MeetingRecordingSourceResolver.resolve(
                            mode: selection.defaults.mode,
                            source: .application(bundleIdentifier: selected.bundleIdentifier, processID: nil, displayName: selected.displayName),
                            target: nil,
                            applications: snapshot.applications
                        )
                    } else if selection.defaults.mode == .inRoom {
                        snapshot.selectedApplication = nil
                    }
                    // A refresh must not replace a disconnected or absent selection
                    // with the newly discovered default microphone.
                    snapshot.selectedMicrophoneID = snapshot.microphones.identities.contains(where: { $0.captureDeviceID == selection.selectedMicrophoneID })
                        ? selection.selectedMicrophoneID : nil
                }
                if let microphoneID {
                    // A page selection is explicit. If it disappeared, require another
                    // choice instead of replacing it with the system's default input.
                    snapshot.selectedMicrophoneID = snapshot.microphones.identities.contains(where: { $0.captureDeviceID == microphoneID }) ? microphoneID : nil
                }
                guard !Task.isCancelled, self.generation == generation, self.isPresented else { return }
                self.refreshSelection = nil
                self.refreshMicrophoneID = nil
                self.snapshot = snapshot
                self.errorMessage = snapshot.sourceMessage
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func selectApplication(_ application: MeetingApplicationIdentity?) {
        guard !self.isStarting, self.snapshot != nil else { return }
        self.snapshot?.defaults.mode = application == nil ? .inRoom : .onlineCall
        self.snapshot?.selectedApplication = application
        if let application {
            SettingsStore.shared.meetingRecentApplication = application
            self.snapshot?.recentApplication = application
        }
        self.errorMessage = nil
    }

    func selectMicrophone(_ id: String) {
        guard !self.isStarting else { return }
        self.snapshot?.selectedMicrophoneID = id
    }

    func refresh() {
        guard !self.isStarting, !self.isLoading else { return }
        let selection = self.snapshot ?? self.refreshSelection
        let microphoneID = self.refreshMicrophoneID
        self.cancel()
        self.handleShortcut(foreground: selection?.selectedApplication, restoring: selection, microphoneID: microphoneID)
    }

    func confirm() {
        guard SettingsStore.shared.fluidMeetEnabled else { self.cancel(); return }
        guard self.isPresented, self.canConfirm, let snapshot else { return }
        self.isStarting = true
        self.errorMessage = nil
        let generation = self.generation
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.start(snapshot)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.dismiss()
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.isStarting = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func recordingDidStart() {
        // The start task owns its own dismissal. Cancelling it here could interrupt capture.
        if self.isPresented, !self.isStarting { self.cancel() }
    }

    func cancel() {
        self.task?.cancel()
        self.dismiss()
    }

    private func dismiss() {
        self.generation = UUID()
        self.task = nil
        self.isPresented = false
        self.isLoading = false
        self.isStarting = false
        self.snapshot = nil
        self.refreshSelection = nil
        self.refreshMicrophoneID = nil
        self.panel?.orderOut(nil)
    }

    private static func loadSnapshot(foreground: MeetingApplicationIdentity?) async throws -> MeetingRecordingSourceSnapshot {
        async let installedApplications = MeetingInstalledCallApplications.snapshot()
        let defaults = SettingsStore.shared.meetingRecordingDefaults
        let target = AppServices.shared.meetingAutomaticTarget
        let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
        let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        var applications: [MeetingApplicationIdentity] = []
        var sourceMessage: String?
        if CGPreflightScreenCaptureAccess() {
            do {
                applications = try await MeetingCaptureSourceCatalog.availableApplications()
            } catch {
                sourceMessage = error.localizedDescription
            }
        } else if defaults.mode == .onlineCall {
            sourceMessage = "Allow Screen & System Audio access in System Settings, then refresh sources to choose an app."
        }
        try Task.checkCancellation()
        let savedMicrophone = defaults.savedMicrophone(in: microphones.identities)
        let selection = MeetingMicrophonePreselection.select(
            identities: microphones.identities,
            savedDeviceID: savedMicrophone?.captureDeviceID,
            savedRole: defaults.microphoneRole,
            systemDefaultUID: microphones.defaultCoreAudioUID,
            preferredInputUID: preferredInputUID,
            systemDefaultCaptureID: nil
        )
        return MeetingRecordingSourceSnapshot(
            defaults: defaults,
            applications: applications,
            microphones: microphones,
            selectedApplication: MeetingRecordingSourceSnapshot.suggestedApplication(
                defaults: defaults, target: target, foreground: foreground, applications: applications
            ),
            selectedMicrophoneID: selection.deviceID,
            sourceMessage: sourceMessage,
            installedApplications: await installedApplications
        )
    }

    private static func startSnapshot(_ snapshot: MeetingRecordingSourceSnapshot) async throws {
        guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        let applications = try await snapshot.defaults.mode == .onlineCall ? MeetingCaptureSourceCatalog.availableApplications() : []
        try Task.checkCancellation()
        let configuration = try snapshot.configuration(applications: applications, microphones: microphones.identities)
        _ = try await AppServices.shared.meetingSessionCoordinator.startRecording(configuration: configuration)
    }

    private func showPanel() -> Bool {
        MeetingDetectionPromptController.shared.dismissForSourceSelection()
        if self.panel == nil {
            let content = AnyView(AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingRecordingSourcePromptContent(controller: self)
            })
            self.panel = MeetingFloatingPanelFactory.make(
                size: NSSize(width: 392, height: 300), resizable: false, content: content, allowsKeyboardFocus: true
            )
        }
        guard let panel = self.panel, let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main else { return false }
        panel.setFrame(MeetingDetectionPromptController.defaultFrame(panelSize: panel.frame.size, visibleFrame: screen.visibleFrame), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        return true
    }
}

struct MeetingRecordingSourcePromptContent: View {
    @ObservedObject var controller: MeetingRecordingSourcePromptController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record this meeting?").font(self.theme.typography.bodyStrong)
            Text("Choose the app and microphone to record.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if self.controller.isLoading {
                ProgressView("Finding audio sources…").controlSize(.small)
            } else if let snapshot = self.controller.snapshot {
                self.sourceSelector(snapshot)
                self.microphoneSelector(snapshot)
            }
            if let error = self.controller.errorMessage {
                Text(error).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(self.recordingDescription)
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer(minLength: 0)
            FluidGlassControlGroup {
                HStack {
                    Button("Cancel") { self.controller.cancel() }.keyboardShortcut(.cancelAction).fluidGlassAction()
                    Button("Refresh") { self.controller.refresh() }.fluidGlassAction()
                        .disabled(self.controller.isLoading || self.controller.isStarting)
                    Spacer()
                    Button(self.controller.isStarting ? "Starting…" : "Record") { self.controller.confirm() }
                        .keyboardShortcut(.defaultAction).fluidGlassAction(prominent: true)
                        .disabled(!self.controller.canConfirm)
                }
            }
            Text("Press the meeting shortcut again or Return to record.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
        }
        .padding(16)
        .frame(width: 392, height: 300, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(self.theme.palette.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.separator.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose meeting recording sources")
    }

    private var recordingDescription: String {
        guard let snapshot = self.controller.snapshot else { return "Nothing is recording yet." }
        if snapshot.defaults.mode == .inRoom { return "Only your microphone will be recorded." }
        if snapshot.selectedApplication == nil { return "Choose an app, or In person for mic only." }
        return "App audio and your microphone will be recorded."
    }

    private func sourceSelector(_ snapshot: MeetingRecordingSourceSnapshot) -> some View {
        let recent = snapshot.availableRecentApplication
        let sections = MeetingAppRegistry.pickerSections(
            MeetingAppPickerEntry.entries(applications: snapshot.applications, installed: snapshot.installedApplications)
                .filter { $0.application != recent || recent == nil },
            bundleIdentifier: { $0.bundleIdentifier },
            name: { $0.displayName },
            isBackgroundItem: { _ in false }
        )
        return Menu {
            if let recent {
                self.applicationEntry(MeetingApplicationOption(identity: recent), snapshot: snapshot)
                Divider()
            }
            Button("In person · mic only") { self.controller.selectApplication(nil) }
            Divider()
            ForEach(sections.usual) { option in
                self.pickerEntry(option, snapshot: snapshot)
            }
            if !sections.others.isEmpty {
                Menu("Other apps") {
                    ForEach(sections.others) { option in
                        self.pickerEntry(option, snapshot: snapshot)
                    }
                }
            }
            Divider()
            Button("Refresh apps") { self.controller.refresh() }
        } label: {
            Text(snapshot.defaults.mode == .inRoom ? "In person · mic only" : snapshot.selectedApplication.map(snapshot.applicationLabel) ?? "Choose an app…")
                .lineLimit(1).truncationMode(.middle)
        }
        .fluidDropdownStyle(fillsWidth: true)
        .accessibilityLabel("App to record")
        .accessibilityValue(snapshot.defaults.mode == .inRoom ? "In person, microphone only" : snapshot.selectedApplication.map(snapshot.applicationLabel) ?? "No app selected")
        .disabled(self.controller.isStarting)
    }

    @ViewBuilder
    private func pickerEntry(_ entry: MeetingAppPickerEntry, snapshot: MeetingRecordingSourceSnapshot) -> some View {
        if let application = entry.application {
            self.applicationEntry(MeetingApplicationOption(identity: application), snapshot: snapshot)
        } else {
            Button(entry.unavailableLabel) {}.disabled(true)
        }
    }

    private func applicationEntry(_ option: MeetingApplicationOption, snapshot: MeetingRecordingSourceSnapshot) -> some View {
        let name = snapshot.applicationLabel(option.identity)
        return Button { self.controller.selectApplication(option.identity) } label: {
            if snapshot.selectedApplication?.processID == option.identity.processID {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private func microphoneSelector(_ snapshot: MeetingRecordingSourceSnapshot) -> some View {
        Menu {
            ForEach(snapshot.microphones.identities, id: \.captureDeviceID) { microphone in
                Button(microphone.displayName) { self.controller.selectMicrophone(microphone.captureDeviceID) }
            }
        } label: {
            Text(snapshot.microphoneSelectionLabel)
                .lineLimit(1).truncationMode(.middle)
        }
        .fluidDropdownStyle(fillsWidth: true)
        .accessibilityLabel("Microphone to record")
        .accessibilityValue(snapshot.microphoneSelectionLabel)
        .disabled(self.controller.isStarting)
    }
}
