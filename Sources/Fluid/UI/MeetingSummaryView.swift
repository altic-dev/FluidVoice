import AppKit
import Combine
import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var isQuiescent = true
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var preferences = MeetingSummaryPreferences()
    @StateObject private var controller = MeetingSummaryController()
    @State private var kind = MeetingSummaryKind.executive
    @State private var catalog: [CommandModelOption] = []
    @State private var catalogLoaded = false
    @State private var route: MeetingSummaryRoute?
    @State private var readinessIssue: String?

    private var refreshID: String {
        // A prompt edit re-checks the saved custom summary, so an older result never stays on screen.
        let prompt = self.kind == .custom
            ? MeetingSummaryInput.fingerprint(self.preferences.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
            : ""
        return "\(self.session?.id.uuidString ?? "home")-\(self.session?.updatedAt.timeIntervalSince1970 ?? 0)-\(self.kind.rawValue)-\(prompt)"
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

    private var needsCustomPrompt: Bool {
        self.kind == .custom && self.preferences.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelID: String {
        self.preferences.selection.modelsByProvider[self.providerKey] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            self.configurationPanel
            if let error = self.controller.error ?? self.readinessIssue, !self.catalog.isEmpty {
                Text(error)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .textSelection(.enabled)
            }
            if !self.controller.output.isEmpty {
                self.summaryDocument
            }
        }
        .frame(maxWidth: 960, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
        .task(id: self.refreshID) {
            if self.kind == .custom {
                // Coalesce typing; a newer keystroke cancels this task before it reads the saved file.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await self.controller.refresh(session: self.session, kind: self.kind, customPrompt: self.preferences.customPrompt)
        }
        .task { self.reloadProviders() }
        .onReceive(self.settings.objectWillChange) { _ in
            // SettingsStore publishes before mutating its defaults.
            Task { @MainActor in self.reloadProviders() }
        }
        .onChange(of: self.preferences.selection) { _, _ in self.resolveRoute() }
        .onDisappear { self.controller.cancel() }
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your meeting, summed up.")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !self.catalog.isEmpty {
                    Button("Manage providers") { AppNavigationRouter.shared.request(.aiEnhancements) }
                        .buttonStyle(.link)
                        .disabled(self.controller.busy)
                }
            }
            if !self.catalogLoaded {
                ProgressView().controlSize(.small)
            } else if self.catalog.isEmpty {
                self.setupPrompt
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                        self.providerPicker.frame(minWidth: 180)
                        self.modelPicker.frame(minWidth: 170)
                        self.kindPicker.frame(minWidth: 160)
                    }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        self.providerPicker
                        self.modelPicker
                        self.kindPicker
                    }
                }
                .disabled(self.controller.busy)
                if self.kind == .custom {
                    self.customPromptEditor
                }
                self.actions
                if self.session == nil {
                    Text("Open a completed meeting to summarize its transcript.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Label(self.destination, systemImage: "network")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .background(RoundedRectangle(cornerRadius: 12).fill(self.theme.palette.primaryText.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(self.theme.palette.primaryText.opacity(0.1)))
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("Summaries use a provider from AI Providers. Add and verify one to summarize this meeting.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set up a provider", systemImage: "gearshape") { AppNavigationRouter.shared.request(.aiEnhancements) }
                .fluidGlassAction(prominent: true)
        }
    }

    private var destination: String {
        guard let route else { return "Choose a configured provider and model to continue." }
        let host = URL(string: route.baseURL)?.host ?? route.providerName
        return "Transcript sent to \(route.providerName) (\(host)) · Audio stays on your Mac"
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summarize with").font(self.theme.typography.caption)
            Picker("Summarize with", selection: Binding(
                get: { self.providerID },
                set: { self.selectProvider($0) }
            )) {
                ForEach(self.providers) { provider in Text(provider.providerName).tag(provider.providerID) }
                if !self.providers.contains(where: { $0.providerID == self.providerID }) {
                    Text(self.providerID.isEmpty ? "Choose provider" : "Unavailable provider").tag(self.providerID)
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
                ForEach(self.models) { model in Text(model.displayName).tag(model.modelID) }
                if !self.models.contains(where: { $0.modelID == self.modelID }) {
                    Text(self.modelID.isEmpty ? "Choose model" : self.modelID).tag(self.modelID)
                }
            }
            .labelsHidden().pickerStyle(.menu).fluidDropdownStyle()
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

    private var customPromptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom prompt").font(self.theme.typography.caption)
            TextEditor(text: self.$preferences.customPrompt)
                .font(self.theme.typography.body)
                .scrollContentBackground(.hidden)
                .padding(self.theme.metrics.spacing.sm)
                .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                .overlay(alignment: .topLeading) {
                    if self.preferences.customPrompt.isEmpty {
                        Text("For example: Write a short recap email to the client with next steps and owners.")
                            .font(self.theme.typography.body)
                            .foregroundStyle(self.theme.palette.tertiaryText)
                            .padding(self.theme.metrics.spacing.sm)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 96, maxHeight: 200)
                .disabled(self.controller.busy)
                .accessibilityLabel("Custom summary prompt")
            Text("Saved for every meeting. Replaces the summary type instructions; the transcript is still treated as source material only.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        FluidGlassControlGroup {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.controller.checking {
                    ProgressView().controlSize(.small)
                } else if self.controller.generating {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(self.theme.typography.bodySmall)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else {
                    Button(self.controller.output.isEmpty ? "Generate summary" : "Regenerate summary", systemImage: "sparkles") {
                        self.resolveRoute()
                        if let session, let route {
                            self.controller.summarize(
                                session: session,
                                kind: self.kind,
                                route: route,
                                customPrompt: self.preferences.customPrompt
                            )
                        }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(self.route == nil || self.needsCustomPrompt || self.session?.transcriptSegments.isEmpty != false || !self.isQuiescent)
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
            let models = self.catalog.filter { ModelRepository.shared.providerKey(for: $0.providerID) == key }
            let preferred = self.settings.selectedModelByProvider[key]
            selection.modelsByProvider[key] = models.first(where: { $0.modelID == preferred })?.modelID ?? models.first?.modelID
        }
        self.preferences.selection = selection
    }

    private func reloadProviders() {
        self.catalog = self.settings.commandModeModelCatalog()
        self.catalogLoaded = true
        // First use starts from the AI Settings provider when it is verified; later choices stay independent.
        if self.providerID.isEmpty, let first = self.providers.first {
            let global = ModelRepository.shared.providerKey(for: self.settings.selectedProviderID)
            let preferred = self.providers.first { ModelRepository.shared.providerKey(for: $0.providerID) == global }
            self.selectProvider((preferred ?? first).providerID)
        }
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
