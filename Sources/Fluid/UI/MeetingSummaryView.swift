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
    /// The on-device summary model, read when the providers are; nil in builds without one.
    @State private var onDeviceModel: PrivateAIRegisteredModel?
    @State private var confirmDeletion = false
    @State private var showModelPicker = false

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

    private var providers: [CommandModelOption] {
        var seen = Set<String>()
        return self.catalog.filter { seen.insert($0.providerID).inserted }
    }

    private var usesOnDevice: Bool {
        self.onDeviceModel != nil && self.providerID == MeetingSummaryOnDevice.providerID
    }

    private var hasChoices: Bool {
        !self.catalog.isEmpty || self.onDeviceModel != nil
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
        .alert("Delete summary model?", isPresented: self.$confirmDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { self.controller.deleteModel(asr: AppServices.shared.asr) }
        } message: {
            Text("Remove the \(self.downloadSize.map { "\($0) " } ?? "")download from this Mac. Your meetings and saved summaries stay. You can download it again anytime.")
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
                if !self.catalog.isEmpty {
                    Button("Manage providers") { AppNavigationRouter.shared.request(.aiEnhancements) }
                        .buttonStyle(.link)
                        .disabled(self.controller.busy)
                }
            }
            if !self.catalogLoaded {
                ProgressView().controlSize(.small)
            } else if !self.hasChoices {
                self.setupPrompt
            } else {
                // Two equal columns; stacked when the window is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                        self.modelChooser.frame(minWidth: 240)
                        self.kindPicker.frame(minWidth: 200)
                    }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        self.modelChooser
                        self.kindPicker
                    }
                }
                .disabled(self.controller.busy)
                if self.usesOnDevice {
                    self.thinkingRow.disabled(self.controller.busy)
                }
                if self.kind == .custom {
                    self.customPromptEditor
                }
                self.actions
                if self.usesOnDevice, self.controller.downloading {
                    Text(PrivateAIModelDownloadProgressText.detailText(for: self.controller.progress))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                if let error = self.controller.error ?? self.readinessIssue {
                    Text(error)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if self.session == nil {
                    Text("Open a completed meeting to summarize its transcript.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Label(self.destination, systemImage: self.usesOnDevice ? "lock" : "network")
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
        if self.usesOnDevice {
            return "Nothing leaves your Mac · Summaries are in English"
        }
        guard let route else { return "Choose a configured provider and model to continue." }
        let host = URL(string: route.baseURL)?.host ?? route.providerName
        return "Transcript sent to \(route.providerName) (\(host)) · Audio stays on your Mac"
    }

    /// Every model a summary can use: the one on this Mac first, then each verified provider's.
    private var modelOptions: [CommandModelOption] {
        guard let onDeviceModel else { return self.catalog }
        // The model's own name stands in for its ID, which is not meant to be read.
        return [CommandModelOption(
            providerID: MeetingSummaryOnDevice.providerID,
            providerName: MeetingSummaryOnDevice.providerName,
            modelID: onDeviceModel.displayName,
            displayName: onDeviceModel.displayName
        )] + self.catalog
    }

    private var selectedOption: CommandModelOption? {
        self.modelOptions.first {
            self.usesOnDevice
                ? $0.providerID == MeetingSummaryOnDevice.providerID
                : ModelRepository.shared.providerKey(for: $0.providerID) == self.providerKey && $0.modelID == self.modelID
        }
    }

    /// One searchable list across providers, the same chooser Command Mode uses.
    private var modelChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(self.theme.typography.caption)
            Button {
                self.showModelPicker.toggle()
            } label: {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if let option = self.selectedOption {
                        Text(option.displayName).lineLimit(1).truncationMode(.middle)
                        Text(option.providerName)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .lineLimit(1)
                    } else {
                        Text("Choose model").foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                    FluidDropdownChevron()
                }
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fluidDropdownSurface()
            }
            .buttonStyle(.plain)
            .help("Search models on this Mac and from verified providers")
            .accessibilityLabel("Summary model")
            .accessibilityValue(self.selectedOption.map { "\($0.displayName), \($0.providerName)" } ?? "None")
            .popover(isPresented: self.$showModelPicker, arrowEdge: .top) {
                CommandModelPicker(
                    options: self.modelOptions,
                    selectedProviderID: self.selectedOption?.providerID ?? "",
                    selectedModelID: self.selectedOption?.modelID ?? "",
                    onSelect: { option in
                        self.selectModel(option)
                        self.showModelPicker = false
                    },
                    onDismiss: { self.showModelPicker = false }
                )
            }
            if self.usesOnDevice, let memoryWarning = self.memoryWarning {
                Label(memoryWarning, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var memoryWarning: String? {
        MeetingSummaryOnDevice.memoryWarning(
            recommendedMemoryGB: self.onDeviceModel?.recommendedMemoryGB,
            memoryGB: MeetingSummaryOnDevice.thisMacMemoryGB
        )
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary type").font(self.theme.typography.caption)
            FluidDropdownPicker("Summary type", selectedTitle: self.kind.title, selection: self.$kind) {
                ForEach(MeetingSummaryKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .fluidDropdownStyle(fillsWidth: true)
        }
    }

    /// A setting of the model on this Mac, laid out like the rows in Recording settings.
    private var thinkingRow: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Think first").font(self.theme.typography.bodySmallStrong)
                Text("The model reasons about the transcript before it writes. More careful, a little slower.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Think first", isOn: self.$preferences.thinksFirst)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Think before summarizing")
        }
    }

    private var downloadSize: String? {
        self.onDeviceModel?.artifact.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private var customPromptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom prompt").font(self.theme.typography.caption)
            TextEditor(text: self.$preferences.customPrompt)
                .font(self.theme.typography.body)
                .scrollContentBackground(.hidden)
                .background(DictationTextTarget())
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
                } else if self.usesOnDevice, self.controller.downloading {
                    Button {} label: {
                        VStack(spacing: 4) {
                            Text(PrivateAIModelDownloadProgressText.buttonTitle(for: self.controller.progress))
                            ProgressView(value: self.controller.progress?.fractionCompleted)
                                .progressViewStyle(.linear)
                                .frame(width: 160)
                                .controlSize(.mini)
                        }
                    }
                    .fluidGlassAction()
                    .disabled(true)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else if self.usesOnDevice, self.controller.deleting {
                    ProgressView().controlSize(.small)
                    Text("Deleting download…").font(self.theme.typography.bodySmall)
                } else if self.usesOnDevice, !self.controller.installed {
                    Button(self.downloadSize.map { "Download · \($0)" } ?? "Download", systemImage: "arrow.down.circle") {
                        self.controller.download()
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(!self.isQuiescent)
                } else {
                    Button(self.controller.output.isEmpty ? "Generate summary" : "Regenerate summary", systemImage: "sparkles") {
                        self.generate()
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(
                        (!self.usesOnDevice && self.route == nil) || self.needsCustomPrompt
                            || self.session?.transcriptSegments.isEmpty != false || !self.isQuiescent
                    )
                }
                if self.usesOnDevice, self.controller.installed {
                    Menu {
                        Button("Delete model", systemImage: "trash", role: .destructive) {
                            self.confirmDeletion = true
                        }
                        .disabled(self.controller.busy || self.controller.checking || !self.isQuiescent)
                    } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden)
                        .fluidGlassAction(circular: true)
                        .accessibilityLabel("Summary model actions")
                        .disabled(self.controller.busy)
                }
            }
        }
    }

    private func generate() {
        guard let session else { return }
        if self.usesOnDevice {
            self.controller.summarizeOnDevice(
                session: session,
                kind: self.kind,
                customPrompt: self.preferences.customPrompt,
                thinking: self.preferences.thinksFirst,
                asr: AppServices.shared.asr
            )
            return
        }
        self.resolveRoute()
        if let route {
            self.controller.summarize(
                session: session,
                kind: self.kind,
                route: route,
                customPrompt: self.preferences.customPrompt
            )
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
            Text(self.controller.outputNotice)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(self.theme.palette.primaryText.opacity(0.1)))
    }

    private func selectModel(_ option: CommandModelOption) {
        guard option.providerID != MeetingSummaryOnDevice.providerID else {
            self.selectProvider(option.providerID)
            return
        }
        var selection = self.preferences.selection
        selection.providerID = option.providerID
        selection.modelsByProvider[ModelRepository.shared.providerKey(for: option.providerID)] = option.modelID
        self.preferences.selection = selection
    }

    private func selectProvider(_ providerID: String) {
        var selection = self.preferences.selection
        selection.providerID = providerID
        // The on-device choice has one model and no ModelRepository entry.
        guard providerID != MeetingSummaryOnDevice.providerID else {
            self.preferences.selection = selection
            return
        }
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
        self.onDeviceModel = self.controller.model
        self.catalogLoaded = true
        // First use starts from the AI Settings provider when it is verified; later choices stay independent.
        if self.providerID.isEmpty, let first = self.providers.first {
            let global = ModelRepository.shared.providerKey(for: self.settings.selectedProviderID)
            let preferred = self.providers.first { ModelRepository.shared.providerKey(for: $0.providerID) == global }
            self.selectProvider((preferred ?? first).providerID)
        } else if self.providerID.isEmpty, self.onDeviceModel != nil {
            // No cloud provider is set up, so the model on this Mac is the one choice.
            self.selectProvider(MeetingSummaryOnDevice.providerID)
        }
        self.resolveRoute()
    }

    private func resolveRoute() {
        guard !self.usesOnDevice else {
            self.route = nil
            self.readinessIssue = nil
            return
        }
        do {
            self.route = try MeetingSummaryRoute.resolve(self.preferences.selection, settings: self.settings)
            self.readinessIssue = nil
        } catch {
            self.route = nil
            self.readinessIssue = error.localizedDescription
        }
    }
}

/// Marks a text editor in the app's own window as somewhere dictation may write. Dictated text
/// otherwise goes to other apps, and inside the app only to the sidebar search field.
struct DictationTextTarget: NSViewRepresentable {
    final class Marker: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context _: Context) -> Marker { Marker() }
    func updateNSView(_: Marker, context _: Context) {}

    /// True when `editor` lies on a marker. SwiftUI hosts a background view and the editor it
    /// backs under a shared ancestor a few levels up, with the same frame.
    static func accepts(_ editor: NSTextView) -> Bool {
        guard editor.isEditable, !editor.isFieldEditor else { return false }
        let editorView: NSView = editor.enclosingScrollView ?? editor
        var ancestor = editorView.superview
        for _ in 0..<6 {
            guard let current = ancestor else { return false }
            let editorFrame = editorView.convert(editorView.bounds, to: current)
            var pending = current.subviews
            while let view = pending.popLast() {
                if view is Marker, view.convert(view.bounds, to: current).insetBy(dx: -2, dy: -2).contains(editorFrame) {
                    return true
                }
                pending.append(contentsOf: view.subviews)
            }
            ancestor = current.superview
        }
        return false
    }
}
