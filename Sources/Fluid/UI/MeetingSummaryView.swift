import AppKit
import Combine
import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var preferences = MeetingSummaryPreferences()
    @StateObject private var controller = MeetingSummaryController()
    @State private var confirmDeletion = false
    @State private var kind = MeetingSummaryKind.executive
    @State private var catalog: [CommandModelOption] = []
    @State private var route: MeetingSummaryRoute?
    @State private var readinessIssue: String?

    private var refreshID: String {
        "\(self.session?.id.uuidString ?? "home")-\(self.session?.updatedAt.timeIntervalSince1970 ?? 0)-\(self.kind.rawValue)"
    }

    private var onDevice: Bool {
        self.preferences.selection.providerID == MeetingSummarySelection.onDevice
    }

    private var cli: MeetingSummaryCLI? {
        MeetingSummaryCLI(rawValue: self.providerID)
    }

    private var providerID: String {
        self.preferences.selection.providerID
    }

    private var providerKey: String {
        ModelRepository.shared.providerKey(for: self.providerID)
    }

    private var models: [CommandModelOption] {
        self.catalog.filter { ModelRepository.shared.providerKey(for: $0.providerID) == self.providerKey }
    }

    private var providers: [CommandModelOption] {
        var seen = Set<String>()
        return self.catalog.filter { seen.insert($0.providerID).inserted }
    }

    private var modelID: String {
        if self.onDevice { return self.controller.model?.id ?? "" }
        return self.preferences.selection.modelsByProvider[self.providerKey] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            self.configurationPanel
            if let error = self.controller.error ?? self.readinessIssue {
                Text(error)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .textSelection(.enabled)
            }
            if !self.controller.output.isEmpty { self.summaryDocument }
        }
        .frame(maxWidth: 960, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
        .task(id: self.refreshID) { await self.controller.refresh(session: self.session, kind: self.kind) }
        .task { self.reloadProviders() }
        .onReceive(self.settings.objectWillChange) { _ in
            // SettingsStore publishes before mutating its defaults.
            Task { @MainActor in self.reloadProviders() }
        }
        .onChange(of: self.preferences.selection) { _, _ in self.resolveRoute() }
        .onDisappear { self.controller.cancel() }
        .alert("Delete summary model?", isPresented: self.$confirmDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let asrService { self.controller.deleteModel(asr: asrService) }
            }
        } message: {
            Text("Remove the summary model download from this Mac. Your meetings and saved summaries stay. You can download it again anytime.")
        }
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your meeting, summed up.")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !self.onDevice, self.cli == nil {
                    Button("Manage providers") { AppNavigationRouter.shared.request(.aiEnhancements) }
                        .buttonStyle(.link)
                        .disabled(self.controller.busy)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.providerPicker.frame(minWidth: 180)
                    if self.cli != nil {
                        self.cliModelField.frame(minWidth: 170)
                    } else if !self.onDevice {
                        self.modelPicker.frame(minWidth: 170)
                    }
                    if !self.onDevice || self.controller.installed { self.kindPicker.frame(minWidth: 160) }
                }
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.providerPicker
                    if self.cli != nil {
                        self.cliModelField
                    } else if !self.onDevice {
                        self.modelPicker
                    }
                    if !self.onDevice || self.controller.installed { self.kindPicker }
                }
            }
            .disabled(self.controller.busy)
            Text(self.providerHelp)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            self.actions
            if self.controller.downloading {
                Text(PrivateAIModelDownloadProgressText.detailText(for: self.controller.progress))
                    .font(self.theme.typography.caption)
            }
            if self.session == nil {
                Text("Open a completed meeting to summarize its transcript.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Label(self.destination, systemImage: self.onDevice ? "lock" : "network")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .padding(self.theme.metrics.spacing.lg)
        .background(RoundedRectangle(cornerRadius: 12).fill(self.theme.palette.primaryText.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(self.theme.palette.primaryText.opacity(0.1)))
    }

    private var providerHelp: String {
        if let cli {
            return "Uses your \(cli.title) sign-in · One prompt, one summary · Leave model blank for the CLI default."
        }
        if self.onDevice {
            return self.controller.installed ? "LFM is ready for on-device meeting summaries."
                : "Download LFM once to summarize meetings on your Mac with Fluid Intelligence."
        }
        return "Uses your saved provider settings · Independent of dictation"
    }

    private var cliModelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model (optional)").font(self.theme.typography.caption)
            TextField("CLI default", text: Binding(
                get: { self.preferences.selection.modelsByProvider[self.providerID] ?? "" },
                set: { self.preferences.selection.modelsByProvider[self.providerID] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("CLI summary model")
        }
    }

    private var destination: String {
        if self.onDevice { return "On-device · English · Frees its memory when done" }
        if let cli { return "Transcript sent through \(cli.title) to its AI provider · Audio stays on your Mac" }
        guard let route else { return "Choose a configured provider and model to continue." }
        let host = URL(string: route.baseURL)?.host ?? route.providerName
        return "Transcript sent to \(route.providerName) (\(host)) · Audio stays on your Mac"
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summarize with").font(self.theme.typography.caption)
            Picker("Summarize with", selection: Binding(
                get: { self.preferences.selection.providerID },
                set: { self.selectProvider($0) }
            )) {
                Text("On-device · Fluid Intelligence").tag(MeetingSummarySelection.onDevice)
                Divider()
                Text("Claude Code (CLI)").tag(MeetingSummaryCLI.claude.rawValue)
                Text("Codex (CLI)").tag(MeetingSummaryCLI.codex.rawValue)
                Divider()
                ForEach(self.providers) { provider in Text(provider.providerName).tag(provider.providerID) }
                if !self.onDevice, self.cli == nil, !self.providers.contains(where: { $0.providerID == self.providerID }) {
                    Text("Unavailable provider").tag(self.providerID)
                }
            }
            .labelsHidden().pickerStyle(.menu).fluidDropdownStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(self.theme.typography.caption)
            Picker("Summary model", selection: Binding(
                get: { self.modelID },
                set: { self.preferences.selection.modelsByProvider[self.providerKey] = $0 }
            )) {
                if self.onDevice {
                    Text(self.controller.model.map { ModelDisplayName.forID($0.id) } ?? "Unavailable").tag(self.modelID)
                } else {
                    ForEach(self.models) { model in Text(model.displayName).tag(model.modelID) }
                    if !self.models.contains(where: { $0.modelID == self.modelID }) {
                        Text(self.modelID.isEmpty ? "Choose model" : self.modelID).tag(self.modelID)
                    }
                }
            }
            .labelsHidden().pickerStyle(.menu).fluidDropdownStyle()
            .disabled(self.onDevice)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary type").font(self.theme.typography.caption)
            Picker("Summary type", selection: self.$kind) {
                ForEach(MeetingSummaryKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .labelsHidden().pickerStyle(.menu).fluidDropdownStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        FluidGlassControlGroup {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.controller.checking || self.controller.deleting {
                    ProgressView().controlSize(.small)
                } else if self.controller.downloading || self.controller.generating {
                    ProgressView().controlSize(.small)
                    Text(self.controller.downloading ? "Downloading…" : "Summarizing…")
                        .font(self.theme.typography.bodySmall)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else if self.onDevice && !self.controller.installed {
                    Button("Download LFM · 1.45 GB", systemImage: "arrow.down.circle") { self.controller.download() }
                        .fluidGlassAction(prominent: true)
                        .disabled(!self.isQuiescent || self.controller.model == nil)
                } else {
                    Button(self.controller.output.isEmpty ? "Generate summary" : "Regenerate summary", systemImage: "sparkles") {
                        self.resolveRoute()
                        if let session, let asrService, let route {
                            self.controller.summarize(session: session, kind: self.kind, asr: asrService, route: route)
                        }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(self.route == nil || self.session?.transcriptSegments.isEmpty != false || self.asrService == nil || !self.isQuiescent)
                }
                if self.onDevice, self.controller.installed {
                    Menu {
                        Button("Delete model", systemImage: "trash", role: .destructive) { self.confirmDeletion = true }
                    } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden).fluidGlassAction(circular: true)
                        .accessibilityLabel("Meeting summary actions")
                        .disabled(self.controller.busy || self.controller.checking || !self.isQuiescent || self.asrService == nil)
                }
            }
        }
    }

    private var summaryDocument: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.kind.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Generated with \(self.controller.outputProvenance)")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.controller.output, forType: .string)
                }
                .labelStyle(.iconOnly).fluidGlassAction(circular: true)
                .help("Copy summary")
            }
            CommandMarkdownContent(text: self.controller.output)
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(self.theme.palette.primaryText.opacity(0.1)))
    }

    private func selectProvider(_ providerID: String) {
        var selection = self.preferences.selection
        selection.providerID = providerID
        let key = ModelRepository.shared.providerKey(for: providerID)
        if selection.modelsByProvider[key] == nil {
            let models = self.catalog.filter { $0.providerID == providerID }
            let preferred = self.settings.selectedModelByProvider[key]
            selection.modelsByProvider[key] = models.first(where: { $0.modelID == preferred })?.modelID ?? models.first?.modelID
        }
        self.preferences.selection = selection
    }

    private func reloadProviders() {
        let provider = self.settings.selectedProviderID
        let key = ModelRepository.shared.providerKey(for: provider)
        self.preferences.selection.detachAISettings(
            providerID: provider,
            modelID: self.settings.selectedModelByProvider[key] ?? self.settings.selectedModel ?? ""
        )
        self.catalog = self.settings.commandModeModelCatalog()
        self.resolveRoute()
    }

    private func resolveRoute() {
        do {
            self.route = try MeetingSummaryRoute.resolve(self.preferences.selection, settings: self.settings)
            self.readinessIssue = nil
        } catch {
            self.route = nil
            self.readinessIssue = error.localizedDescription
        }
    }
}
