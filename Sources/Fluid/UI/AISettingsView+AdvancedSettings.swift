//
//  AISettingsView+AdvancedSettings.swift
//  fluid
//
//  Extracted from AISettingsView.swift to keep view body under lint limit.
//

import AppKit
import SwiftUI

private struct PromptCardAssignments {
    let isDefault: Bool
    let isReady: Bool
    let shortcutDisplay: String?
    let modelPicker: PromptCardModelPicker?
    let onMakeDefault: () -> Void
}

private struct PromptCardModelPicker {
    let summary: String
    let selectedModel: String
    let models: [String]
    let providerName: String
    let onSelectModel: (String) -> Void
    let onOpenProviders: () -> Void
}

private struct PromptAdvancedDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

extension AIEnhancementSettingsView {
    // MARK: - Advanced Settings Card

    var advancedSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.promptModeViewport(mode: .dictate)
        }
        .sheet(item: self.$viewModel.promptEditorMode) { mode in
            self.promptEditorSheet(mode: mode)
        }
    }

    var promptProfilesHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "text.bubble.fill")
                    .font(.fluidSystem(size: 13, weight: .semibold))
                    .foregroundStyle(Color.fluidGreen)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.fluidGreen.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.fluidGreen.opacity(0.24), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt Profiles")
                        .font(.fluidSystem(size: 13, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("Choose the prompt behavior for dictation.")
                        .font(.fluidSystem(.caption))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                self.promptProfilesHelpRow("Built-in is the normal prompt. Assign any prompt as Primary to use it with your main hotkey.")
                self.promptProfilesHelpRow("\(PrivateAIProviderFeature.displayName) uses its own local prompt.")
                self.promptProfilesHelpRow("Custom prompts can be assigned globally, by app, or by shortcut.")
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .background(self.theme.palette.cardBackground)
    }

    private func promptProfilesHelpRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.fluidGreen.opacity(0.75))
                .frame(width: 4, height: 4)
                .padding(.top, 6)

            Text(text)
                .font(.fluidSystem(.caption))
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func promptModeViewport(mode: SettingsStore.PromptMode) -> some View {
        self.promptModeSection(mode: mode)
            .frame(
                maxWidth: .infinity,
                minHeight: AISettingsLayout.promptModeMinHeight,
                alignment: .topLeading
            )
            .transaction { transaction in
                transaction.animation = nil
            }
    }

    private func promptProfileCard(
        title: String,
        subtitle: String,
        mode: SettingsStore.PromptMode,
        assignments: PromptCardAssignments? = nil,
        notice: String? = nil,
        onManage: (() -> Void)? = nil,
        manageTitle: String? = nil,
        onDelete: (() -> Void)? = nil,
        isEnabled: Bool = true
    ) -> some View {
        let tone = Color.fluidGreen
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                self.promptCardIcon(
                    title: title,
                    mode: mode,
                    tone: tone
                )

                self.promptCardTitleBlock(
                    title: title,
                    subtitle: subtitle,
                    mode: mode,
                    assignments: assignments,
                    notice: notice,
                    tone: tone
                )

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    if let onManage, let manageTitle {
                        Button(manageTitle, action: onManage)
                            .fluidGlassAction()
                            .disabled(!isEnabled)
                    } else if let onManage {
                        Button {
                            onManage()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.fluidSystem(size: 12, weight: .semibold))
                                .frame(width: AISettingsLayout.providerRowControlHeight, height: AISettingsLayout.providerRowControlHeight)
                        }
                        .fluidGlassAction(circular: true)
                        .disabled(!isEnabled)
                        .help("Configure")
                    }

                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.fluidSystem(size: 12, weight: .semibold))
                                .frame(width: AISettingsLayout.providerRowControlHeight, height: AISettingsLayout.providerRowControlHeight)
                        }
                        .fluidGlassAction(circular: true, tone: .red)
                        .disabled(!isEnabled)
                        .help("Delete")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if let shortcut = assignments?.shortcutDisplay {
                HStack {
                    Label(shortcut, systemImage: "keyboard")
                        .font(.fluidSystem(.caption2))
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 46)
            }
        }
        .padding(16)
        .frame(minHeight: 76)
        .opacity(isEnabled ? 1 : 0.68)
        .background(
            shape
                .fill(self.theme.palette.cardBackground.opacity(0.7))
                .overlay(
                    shape
                        .stroke(
                            self.theme.palette.cardBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    private func promptCardIcon(
        title: String,
        mode: SettingsStore.PromptMode,
        tone: Color
    ) -> some View {
        let symbol: String
        if title == PrivateAIProviderFeature.displayName {
            symbol = "sparkles"
        } else if title.localizedCaseInsensitiveContains("default") {
            symbol = "text.bubble.fill"
        } else {
            symbol = mode.normalized == .dictate ? "quote.bubble.fill" : "text.cursor"
        }

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.theme.palette.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                )

            Image(systemName: symbol)
                .font(.fluidSystem(size: 13, weight: .semibold))
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func promptCardTitleBlock(
        title: String,
        subtitle: String,
        mode: SettingsStore.PromptMode,
        assignments: PromptCardAssignments?,
        notice: String?,
        tone: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.fluidSystem(size: 14, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                self.promptStatusTags(
                    assignments: assignments,
                    mode: mode,
                    tone: tone
                )
            }

            if let notice {
                self.promptNoticeRow(notice)
            } else if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.fluidSystem(.caption2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promptCardMetadataChips(
        assignments: PromptCardAssignments,
        tone: Color,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if !assignments.isReady {
                self.promptConfigChip(
                    systemImage: "exclamationmark.triangle.fill",
                    text: assignments.modelPicker?.providerName.isEmpty == false
                        ? "Needs setup"
                        : "No valid provider configured",
                    tone: .orange
                )
            }

            // Provider chip
            if let modelPicker = assignments.modelPicker, !modelPicker.providerName.isEmpty {
                self.promptConfigChip(
                    systemImage: "server.rack",
                    text: modelPicker.providerName,
                    tone: tone
                )
            }

            // Model chip
            if let modelPicker = assignments.modelPicker, !modelPicker.summary.isEmpty {
                self.promptConfigChip(
                    systemImage: "cpu",
                    text: modelPicker.selectedModel.isEmpty
                        ? (modelPicker.providerName.isEmpty ? "No model" : modelPicker.summary)
                        : ModelDisplayName.forID(modelPicker.selectedModel),
                    tone: tone
                )
            }

            // Shortcut chip
            if let shortcutDisplay = assignments.shortcutDisplay {
                self.promptConfigChip(
                    systemImage: "keyboard",
                    text: shortcutDisplay,
                    tone: tone
                )
            } else {
                self.promptConfigChip(
                    systemImage: "keyboard",
                    text: "No shortcut",
                    tone: self.theme.palette.tertiaryText,
                    isGhost: true
                )
            }

            Spacer(minLength: 0)
        }
        .opacity(isEnabled ? 1 : 0.68)
    }

    private func promptConfigChip(
        systemImage: String,
        text: String,
        tone: Color,
        isGhost: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.fluidSystem(size: 9, weight: .semibold))
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.fluidSystem(.caption2).weight(.semibold))
        .foregroundStyle(isGhost ? self.theme.palette.tertiaryText : tone)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(self.theme.palette.contentBackground)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func promptNoticeRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.fluidSystem(size: 10, weight: .semibold))
            Text(text)
                .font(.fluidSystem(.caption2).weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(self.theme.palette.secondaryText)
    }

    @ViewBuilder
    private func promptStatusTags(
        assignments: PromptCardAssignments?,
        mode: SettingsStore.PromptMode,
        tone: Color
    ) -> some View {
        if mode.normalized == .edit {
            Text("Context: Auto")
                .font(.fluidSystem(.caption2))
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.fluidGreen.opacity(0.2)))
                .foregroundStyle(Color.fluidGreen)
        }
    }

    private func promptStatusBadge(
        _ title: String,
        systemImage: String,
        tone: Color,
        isProminent: Bool
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.fluidSystem(.caption2).weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tone.opacity(isProminent ? 0.5 : 0.3), lineWidth: 1)
                    )
            )
            .foregroundStyle(tone)
    }

    private func promptAssignments(
        selection: SettingsStore.DictationPromptSelection,
        isPrivateAI: Bool = false
    ) -> PromptCardAssignments {
        let configuration = self.settings.dictationPromptConfiguration(for: selection)
        return PromptCardAssignments(
            isDefault: self.viewModel.isDictationPromptSelection(selection, for: .primary),
            isReady: self.isPromptConfigurationReady(selection: selection, isPrivateAI: isPrivateAI),
            shortcutDisplay: configuration.shortcut?.displayString,
            modelPicker: self.promptModelPicker(selection: selection, isPrivateAI: isPrivateAI),
            onMakeDefault: {
                self.viewModel.setDictationPromptSelection(selection, for: .primary)
            }
        )
    }

    private func isPromptConfigurationReady(
        selection: SettingsStore.DictationPromptSelection,
        isPrivateAI: Bool
    ) -> Bool {
        if isPrivateAI {
            return self.viewModel.isPrivateAIPromptAvailable()
        }

        let configuration = self.settings.dictationPromptConfiguration(for: selection)
        let configuredProviderID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = configuredProviderID.isEmpty
            ? self.defaultExternalPromptProviderID
            : configuredProviderID
        let configuredModel = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? self.viewModel.selectedModel(for: providerID) : configuredModel
        return !providerID.isEmpty && !model.isEmpty && self.viewModel.connectionStatus(for: providerID) == .success
    }

    private var defaultExternalPromptProviderID: String {
        DictationProviderRoute.externalFallbackProviderID(from: self.settings.selectedProviderID)
    }

    private func promptEditorSelection(for mode: PromptEditorMode) -> SettingsStore.DictationPromptSelection? {
        switch mode {
        case let .defaultPrompt(promptMode):
            guard promptMode.normalized == .dictate else { return nil }
            return .default
        case let .edit(promptID):
            guard self.viewModel.draftPromptMode.normalized == .dictate else { return nil }
            return .profile(promptID)
        case .newPrompt:
            return nil
        case .privateAI:
            return .privateAI
        }
    }

    private func preparePromptEditorConfigurationDraft(mode: PromptEditorMode) {
        self.promptEditorPrimarySelectionDraft = self.viewModel.dictationPromptSelection(for: .primary)

        if case .newPrompt = mode {
            let pending = self.viewModel.pendingNewPromptConfiguration
            self.promptEditorOriginalConfiguration = nil
            self.promptEditorShortcutDraft = pending?.shortcut
            let providerID = pending?.providerID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.promptEditorProviderIDDraft = providerID.isEmpty
                ? self.viewModel.defaultVerifiedPromptProviderID()
                : providerID
            self.promptEditorModelDraft = pending?.modelName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if self.promptEditorModelDraft.isEmpty, !self.promptEditorProviderIDDraft.isEmpty {
                self.promptEditorModelDraft = self.viewModel.selectedModel(for: self.promptEditorProviderIDDraft)
            }
            return
        }

        let selection = self.promptEditorSelection(for: mode)
        let configuration = selection.map { self.settings.dictationPromptConfiguration(for: $0) }
        self.promptEditorOriginalConfiguration = configuration
        self.promptEditorShortcutDraft = configuration?.shortcut

        let providerID = configuration?.providerID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.promptEditorProviderIDDraft = providerID.isEmpty ? self.viewModel.defaultVerifiedPromptProviderID() : providerID
        self.promptEditorModelDraft = configuration?.modelName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if self.promptEditorModelDraft.isEmpty, !self.promptEditorProviderIDDraft.isEmpty {
            self.promptEditorModelDraft = self.viewModel.selectedModel(for: self.promptEditorProviderIDDraft)
        }

        if mode.isPrivateAI {
            self.promptEditorProviderIDDraft = PrivateAIProviderFeature.shared.providerID
            self.promptEditorModelDraft = PrivateAIIntegrationService.configuredModelID
        }

        if mode.isDefault, let promptMode = mode.mode {
            self.viewModel.draftPromptMode = promptMode.normalized
        }
    }

    private func applyPromptEditorConfigurationDraft(mode: PromptEditorMode) {
        if case .newPrompt = mode {
            let providerID = self.promptEditorProviderIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = self.promptEditorModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            self.viewModel.pendingNewPromptConfiguration = SettingsStore.DictationPromptConfiguration(
                shortcut: self.promptEditorShortcutDraft,
                providerID: providerID,
                modelName: modelName
            )
            return
        }

        if let selection = self.promptEditorSelection(for: mode) {
            if self.promptEditorPrimarySelectionDraft == selection {
                self.viewModel.setDictationPromptSelection(selection, for: .primary)
            }
            let providerID = self.promptEditorProviderIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = self.promptEditorModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = SettingsStore.DictationPromptConfiguration(
                shortcut: self.promptEditorShortcutDraft,
                providerID: providerID,
                modelName: modelName
            )
            self.settings.setDictationPromptConfiguration(configuration, for: selection)
            NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
        }
    }

    private func restorePromptEditorConfigurationDraft(mode: PromptEditorMode) {
        guard let selection = self.promptEditorSelection(for: mode) else { return }
        if let original = self.promptEditorOriginalConfiguration {
            self.settings.setDictationPromptConfiguration(original, for: selection)
        } else {
            self.settings.removeDictationPromptConfiguration(for: selection)
        }
        NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
    }

    private func hasDefaultPromptCustomization(for mode: SettingsStore.PromptMode) -> Bool {
        if self.viewModel.hasDefaultPromptOverride(for: mode) {
            return true
        }
        guard mode.normalized == .dictate else { return false }
        let configuration = self.settings.dictationPromptConfiguration(for: .default)
        return configuration.shortcut != nil ||
            !configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetDefaultPrompt(for mode: SettingsStore.PromptMode) {
        self.viewModel.resetDefaultPromptOverride(for: mode)
        if mode.normalized == .dictate {
            self.settings.removeDictationPromptConfiguration(for: .default)
            self.promptEditorOriginalConfiguration = nil
            self.promptEditorShortcutDraft = nil
            self.promptEditorProviderIDDraft = ""
            self.promptEditorModelDraft = ""
            NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
        }
        self.viewModel.openDefaultPromptViewer(for: mode)
    }

    private func promptEditorAssignments(mode: PromptEditorMode) -> PromptCardAssignments? {
        if case .newPrompt = mode {
            return PromptCardAssignments(
                isDefault: false,
                isReady: self.isPromptEditorConfigurationReady(),
                shortcutDisplay: self.promptEditorShortcutDraft?.displayString,
                modelPicker: self.promptEditorModelPicker(),
                onMakeDefault: {
                    // New prompts can't be the default key until saved
                }
            )
        }

        guard let selection = self.promptEditorSelection(for: mode) else { return nil }

        return PromptCardAssignments(
            isDefault: self.promptEditorPrimarySelectionDraft == selection,
            isReady: mode.isPrivateAI
                ? self.viewModel.isPrivateAIPromptAvailable()
                : self.isPromptEditorConfigurationReady(),
            shortcutDisplay: self.promptEditorShortcutDraft?.displayString,
            modelPicker: self.promptEditorModelPicker(),
            onMakeDefault: {
                self.promptEditorPrimarySelectionDraft = selection
            }
        )
    }

    private func isPromptEditorConfigurationReady() -> Bool {
        let providerID = self.promptEditorProviderIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = self.promptEditorModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !providerID.isEmpty && !model.isEmpty && self.viewModel.connectionStatus(for: providerID) == .success
    }

    private func promptEditorModelPicker() -> PromptCardModelPicker? {
        let providerID = self.promptEditorProviderIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            return PromptCardModelPicker(
                summary: "Choose provider first",
                selectedModel: "",
                models: [],
                providerName: "",
                onSelectModel: { _ in },
                onOpenProviders: {
                    self.selectedConfigurationSection = .providers
                    self.expandedProviderID = nil
                }
            )
        }

        let providerName = self.viewModel.providerDisplayName(for: providerID)
        let selectedModel = self.promptEditorModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = selectedModel.isEmpty ? providerName : "\(providerName) - \(ModelDisplayName.forID(selectedModel))"

        return PromptCardModelPicker(
            summary: summary,
            selectedModel: selectedModel,
            models: self.viewModel.models(for: providerID),
            providerName: providerName,
            onSelectModel: { modelName in
                self.promptEditorModelDraft = modelName
                self.syncDraftToPendingConfig()
            },
            onOpenProviders: {
                self.selectedConfigurationSection = .providers
                self.expandedProviderID = providerID
            }
        )
    }

    private func syncDraftToPendingConfig() {
        guard self.viewModel.promptEditorMode?.isNewPrompt == true else { return }
        self.viewModel.pendingNewPromptConfiguration = SettingsStore.DictationPromptConfiguration(
            shortcut: self.promptEditorShortcutDraft,
            providerID: self.promptEditorProviderIDDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: self.promptEditorModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func shouldShowPromptEditorConfigurationPanel(for mode: PromptEditorMode) -> Bool {
        if case .newPrompt = mode {
            return self.viewModel.draftPromptMode.normalized == .dictate
        }
        if case .privateAI = mode {
            return true
        }
        return self.promptEditorSelection(for: mode) != nil
    }

    private func promptEditorConfigurationPanel(mode: PromptEditorMode) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
            self.promptEditorShortcutRow(mode: mode)
            if mode.isPrivateAI {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack(spacing: 3) {
                        Text("Also available in")
                            .foregroundStyle(self.theme.palette.secondaryText)
                        Button("Settings") {
                            self.viewModel.closePromptEditor()
                            AppNavigationRouter.shared.request(.dictationShortcuts)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(self.theme.palette.accent)
                    }
                    .font(self.theme.typography.caption)
                }
            }
            if !mode.isPrivateAI {
                self.promptEditorProviderRow
                self.promptEditorModelRow
                self.promptEditorProviderGuidance
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                )
        )
    }

    private func promptEditorShortcutRow(mode: PromptEditorMode) -> some View {
        let isNewPrompt: Bool = {
            if case .newPrompt = mode { return true }
            return false
        }()
        let selection = self.promptEditorSelection(for: mode)
        let configurationKey = selection.flatMap { self.settings.dictationPromptConfigurationKey(for: $0) }
        let isRecording: Bool = {
            if isNewPrompt {
                return self.activeShortcutRecordingTarget == .newPrompt
            }
            return configurationKey.map { self.activeShortcutRecordingTarget == .dictationPrompt($0) } ?? false
        }()
        let hasShortcut = self.promptEditorShortcutDraft != nil

        return self.promptEditorConfigRow(title: "Shortcut", description: "") {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if isRecording {
                        Image(systemName: "keyboard")
                            .font(.fluidSystem(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("Press shortcut…")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if let shortcut = self.promptEditorShortcutDraft {
                        Image(systemName: "keyboard")
                            .font(.fluidSystem(size: 11, weight: .semibold))
                            .foregroundStyle(self.theme.palette.secondaryText)
                        Text(shortcut.displayString)
                            .font(.fluidSystem(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "keyboard")
                            .font(.fluidSystem(size: 11, weight: .semibold))
                            .foregroundStyle(self.theme.palette.tertiaryText)
                        Text("None")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                            .foregroundStyle(self.theme.palette.tertiaryText)
                    }
                    Spacer(minLength: 4)
                }
                .searchablePickerControlChrome(
                    width: isRecording ? 192 : 114,
                    height: AISettingsLayout.controlHeight
                )

                Button {
                    self.shortcutRecordingMessage = nil
                    if isRecording {
                        self.activeShortcutRecordingTarget = nil
                    } else if isNewPrompt {
                        self.activeShortcutRecordingTarget = .newPrompt
                    } else if let configurationKey {
                        self.activeShortcutRecordingTarget = .dictationPrompt(configurationKey)
                    }
                } label: {
                    Text(isRecording ? "Cancel" : "Change")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: 70, height: AISettingsLayout.controlHeight)
                }
                .fluidCompactButton(isReady: true)

                if hasShortcut && !isRecording {
                    Button {
                        self.promptEditorShortcutDraft = nil
                        if isNewPrompt {
                            if self.activeShortcutRecordingTarget == .newPrompt {
                                self.activeShortcutRecordingTarget = nil
                            }
                        } else if let configurationKey, self.activeShortcutRecordingTarget == .dictationPrompt(configurationKey) {
                            self.activeShortcutRecordingTarget = nil
                        }
                    } label: {
                        Text("Clear")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(width: 70, height: AISettingsLayout.controlHeight)
                    }
                    .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.5))
                } else if !isRecording {
                    Color.clear
                        .frame(width: 70, height: AISettingsLayout.controlHeight)
                }
            }
            .frame(width: AISettingsLayout.promptEditorControlColumnWidth, alignment: .leading)
        }
    }

    private var promptEditorProviderRow: some View {
        self.promptEditorConfigRow(title: "AI provider", description: "Verified providers only.") {
            Menu {
                let providers = self.viewModel.verifiedPromptProviders()
                if providers.isEmpty {
                    Text("No verified providers")
                } else {
                    ForEach(providers) { provider in
                        Button {
                            self.promptEditorProviderIDDraft = provider.id
                            let models = self.viewModel.models(for: provider.id)
                            if !models.contains(self.promptEditorModelDraft) {
                                self.promptEditorModelDraft = self.viewModel.selectedModel(for: provider.id)
                            }
                            self.syncDraftToPendingConfig()
                        } label: {
                            Label(provider.name, systemImage: provider.id == self.promptEditorProviderIDDraft ? "checkmark" : "")
                        }
                    }
                }
            } label: { Text(self.viewModel.providerDisplayName(for: self.promptEditorProviderIDDraft)) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fluidDropdownStyle()
                .frame(width: AISettingsLayout.promptEditorControlColumnWidth)
                .buttonStyle(.plain)
        }
    }

    private var promptEditorProviderGuidance: some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom cleanup styles require an external AI provider. Fluid Intelligence isn’t supported here.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if self.viewModel.verifiedPromptProviders().isEmpty {
                    Button("Set up AI provider") { self.showingPromptProviderSetup = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(self.theme.palette.accent)
                }
            }
            .frame(width: AISettingsLayout.promptEditorControlColumnWidth, alignment: .leading)
        }
        .sheet(isPresented: self.$showingPromptProviderSetup) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("AI Providers").font(self.theme.typography.title)
                    Spacer()
                    Button("Done") { self.showingPromptProviderSetup = false }
                        .fluidGlassAction()
                }
                ScrollView { self.addedExternalProvidersSection }
            }
            .padding(24)
            .frame(width: 640, height: 520)
            .appTheme(self.theme)
        }
    }

    private var promptEditorModelRow: some View {
        self.promptEditorConfigRow(title: "Model", description: "") {
            HStack(spacing: 8) {
                SearchableModelPicker(
                    models: self.viewModel.models(for: self.promptEditorProviderIDDraft),
                    selectedModel: self.promptEditorModelBinding,
                    onRefresh: nil,
                    selectionEnabled: !self.viewModel.models(for: self.promptEditorProviderIDDraft).isEmpty,
                    // The searchable control adds its horizontal padding outside its content width.
                    controlWidth: AISettingsLayout.promptEditorControlColumnWidth
                        - AISettingsLayout.providerRowControlHeight - 8
                        - 2 * SearchablePickerControlChrome.horizontalPadding,
                    controlHeight: AISettingsLayout.controlHeight
                )

                self.companionIconButton(
                    isRefreshing: self.viewModel.refreshingProviderID == self.promptEditorProviderIDDraft,
                    disabled: !self.canFetchModels(for: self.promptEditorProviderIDDraft),
                    opacity: self.canFetchModels(for: self.promptEditorProviderIDDraft) ? 1 : 0.45,
                    help: "Refresh model list"
                ) {
                    Task { await self.viewModel.fetchModels(for: self.promptEditorProviderIDDraft) }
                }
            }
        }
    }

    private var promptEditorModelBinding: Binding<String> {
        Binding(
            get: { self.promptEditorModelDraft },
            set: { newValue in
                self.promptEditorModelDraft = newValue
                self.syncDraftToPendingConfig()
            }
        )
    }

    private func promptEditorConfigRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.fluidSystem(size: 13, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                if !description.isEmpty {
                    Text(description)
                        .font(.fluidSystem(size: 11))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .gridColumnAlignment(.leading)
            .frame(width: AISettingsLayout.promptEditorLabelColumnWidth, alignment: .leading)

            content()
                .gridColumnAlignment(.leading)
                .frame(width: AISettingsLayout.promptEditorControlColumnWidth, alignment: .leading)
        }
    }

    private func promptModelPicker(
        selection: SettingsStore.DictationPromptSelection,
        isPrivateAI: Bool
    ) -> PromptCardModelPicker? {
        if isPrivateAI {
            return PromptCardModelPicker(
                summary: ModelDisplayName.forID(PrivateAIIntegrationService.configuredModelID),
                selectedModel: PrivateAIIntegrationService.configuredModelID,
                models: PrivateAIModelRegistry.modelIDs(),
                providerName: PrivateAIProviderFeature.displayName,
                onSelectModel: { _ in
                    self.selectedConfigurationSection = .providers
                    self.expandedProviderID = PrivateAIProviderFeature.shared.providerID
                },
                onOpenProviders: {
                    self.selectedConfigurationSection = .providers
                    self.expandedProviderID = PrivateAIProviderFeature.shared.providerID
                }
            )
        }

        let configuration = self.settings.dictationPromptConfiguration(for: selection)
        let configuredProviderID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = configuredProviderID.isEmpty
            ? self.defaultExternalPromptProviderID
            : configuredProviderID
        guard !providerID.isEmpty else {
            return PromptCardModelPicker(
                summary: "Choose provider first",
                selectedModel: "",
                models: [],
                providerName: "",
                onSelectModel: { _ in },
                onOpenProviders: {
                    self.selectedConfigurationSection = .providers
                    self.expandedProviderID = nil
                }
            )
        }

        let providerName = self.viewModel.providerDisplayName(for: providerID)
        let configuredModel = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = configuredModel.isEmpty ? self.viewModel.selectedModel(for: providerID) : configuredModel
        let summary = selectedModel.isEmpty ? providerName : "\(providerName) - \(ModelDisplayName.forID(selectedModel))"

        return PromptCardModelPicker(
            summary: summary,
            selectedModel: selectedModel,
            models: self.viewModel.models(for: providerID),
            providerName: providerName,
            onSelectModel: { modelName in
                var updated = self.settings.dictationPromptConfiguration(for: selection)
                updated.providerID = providerID
                updated.modelName = modelName
                self.settings.setDictationPromptConfiguration(updated, for: selection)
            },
            onOpenProviders: {
                self.selectedConfigurationSection = .providers
                self.expandedProviderID = providerID
            }
        )
    }

    private var promptModeTabSelector: some View {
        HStack(spacing: 2) {
            ForEach(SettingsStore.PromptMode.visiblePromptModes) { mode in
                self.promptModeTabButton(mode: mode)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(self.theme.palette.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                )
        )
    }

    private func promptModeTabButton(mode: SettingsStore.PromptMode) -> some View {
        let isSelected = mode.normalized == self.selectedPromptMode.normalized
        let isHovering = self.hoveredPromptModeKey == mode.normalized.rawValue
        let tone = self.modeAccentColor(mode)
        let cornerRadius: CGFloat = 12

        return Button {
            self.selectedPromptMode = mode.normalized
        } label: {
            HStack(spacing: 7) {
                Image(systemName: self.modeSymbol(mode))
                    .font(.fluidSystem(size: 11, weight: .semibold))
                Text(self.friendlyModeName(mode))
                    .font(.fluidSystem(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? tone : (isHovering ? self.theme.palette.primaryText : self.theme.palette.secondaryText))
            .frame(width: self.promptTabWidth(for: mode), height: 32)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .fluidControlSurface(
                isSelected: isSelected,
                isHovered: isHovering,
                tone: tone,
                cornerRadius: cornerRadius
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredPromptModeKey = hovering ? mode.normalized.rawValue : nil
        }
    }

    private func promptTabWidth(for mode: SettingsStore.PromptMode) -> CGFloat {
        switch mode.normalized {
        case .dictate:
            return 116
        case .edit, .write, .rewrite:
            return 124
        }
    }

    @ViewBuilder
    private func promptModeSection(mode: SettingsStore.PromptMode) -> some View {
        let customProfiles = self.viewModel.dictationPromptProfiles
            .filter { $0.mode.normalized == mode }
        let privateAIAvailable = mode.normalized == .dictate && self.viewModel.isPrivateAIPromptAvailable()
        let isSelectedAppsOnly = self.viewModel.promptRoutingScope(for: mode) == .selectedAppsOnly

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Switch styles from the dictation overlay", systemImage: "info.circle")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.accent)
                Text("Manage instructions, models, and shortcuts here.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 16) {
                FluidGlassControlGroup {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: privateAIAvailable ? 2 : 1), spacing: 16) {
                        if privateAIAvailable {
                            let assignments = self.promptAssignments(selection: .privateAI, isPrivateAI: true)
                            self.builtInStyleCard(
                                title: SettingsStore.DictationModeLabels.smart,
                                symbol: "sparkles",
                                subtitle: "On-device · \(assignments.modelPicker.map { ModelDisplayName.forID($0.selectedModel) } ?? "Fluid Intelligence")",
                                detail: "Built-in style",
                                assignments: assignments,
                                isEnabled: true,
                                action: ("Edit shortcut", { self.viewModel.openPrivateAIPromptEditor() })
                            )
                        }
                        let assignments = self.promptAssignments(selection: .default)
                        self.builtInStyleCard(
                            title: SettingsStore.DictationModeLabels.externalDefault,
                            symbol: "textformat",
                            subtitle: assignments.isReady ? self.styleConfigurationSummary(assignments) : "External AI provider",
                            detail: assignments.isReady ? "Customizable cleanup" : "Setup required",
                            assignments: assignments,
                            isEnabled: true,
                            action: (assignments.isReady ? "Edit style" : "Set up", { self.viewModel.openDefaultPromptViewer(for: mode) })
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Custom instructions").font(self.theme.typography.bodyStrong)
                        Spacer()
                        Button {
                            self.viewModel.openNewPromptEditor(prefillMode: mode)
                        } label: {
                            Label("Add instruction", systemImage: "plus")
                        }
                        .fluidGlassAction()
                    }

                    if customProfiles.isEmpty {
                        Text("Create a style for the way you write, then choose it from the overlay.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    } else {
                        ForEach(customProfiles) { profile in
                            let profileSelection = SettingsStore.DictationPromptSelection.profile(profile.id)
                            self.promptProfileCard(
                                title: profile.name.isEmpty ? "Untitled Prompt" : profile.name,
                                subtitle: self.styleConfigurationSummary(self.promptAssignments(selection: profileSelection)),
                                mode: profile.mode,
                                assignments: profile.mode.normalized == .dictate
                                    ? self.promptAssignments(selection: profileSelection)
                                    : nil,
                                onManage: { self.viewModel.openEditor(for: profile) },
                                manageTitle: "Edit style",
                                onDelete: { self.viewModel.requestDeletePrompt(profile) },
                                isEnabled: true
                            )
                        }
                    }

                    Divider().padding(.vertical, 4)
                    DisclosureGroup(isExpanded: self.$showsAppSpecificStyles) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Where custom styles apply")
                                .font(self.theme.typography.bodyStrong)
                            self.promptRoutingScopeRow(mode: mode)
                            Text(isSelectedAppsOnly
                                ? "Custom styles run only in the apps listed below. Other apps use the built-in prompt for the selected mode."
                                : "Your chosen custom style can run in any app. Add an app rule below to use a different style there.")
                                .font(.fluidSystem(.caption))
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            self.appPromptBindingsSection(mode: mode, isEmphasized: isSelectedAppsOnly, isEnabled: true)
                        }
                        .padding(.top, 12)
                    } label: {
                        HStack {
                            Text("Advanced").font(self.theme.typography.bodyStrong)
                            Spacer()
                            if isSelectedAppsOnly {
                                Text("Listed apps only")
                                    .font(.fluidSystem(.caption))
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                            let ruleCount = self.viewModel.appBindings(for: mode).count
                            if ruleCount > 0 {
                                Text("\(ruleCount) app \(ruleCount == 1 ? "rule" : "rules")")
                                    .font(.fluidSystem(.caption))
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                        }
                    }
                    .disclosureGroupStyle(PromptAdvancedDisclosureStyle())
                }
                .padding(16)
                .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.top, 2)
    }

    private func builtInStyleCard(
        title: String,
        symbol: String,
        subtitle: String,
        detail: String,
        assignments: PromptCardAssignments,
        isEnabled: Bool,
        action: (title: String, perform: () -> Void)
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.fluidSystem(size: 20, weight: .medium))
                    .foregroundStyle(symbol == "sparkles" ? self.theme.palette.accent : self.theme.palette.secondaryText)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.fluidSystem(size: 14, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text(subtitle)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text(detail)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(assignments.isReady ? self.theme.palette.secondaryText : self.theme.palette.warning)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Button(action.title, action: action.perform)
                    .fluidGlassAction()
                    .fixedSize()
                    .disabled(!isEnabled)
                if let shortcut = assignments.shortcutDisplay {
                    Label(shortcut, systemImage: "keyboard")
                        .font(.fluidSystem(.caption2))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(self.theme.palette.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func styleConfigurationSummary(_ assignments: PromptCardAssignments) -> String {
        guard let picker = assignments.modelPicker, !picker.providerName.isEmpty else {
            return "External provider required"
        }
        guard assignments.isReady else { return "\(picker.providerName) · Setup required" }
        return "\(picker.providerName) · \(ModelDisplayName.forID(picker.selectedModel))"
    }

    private func promptModeHintRow(mode: SettingsStore.PromptMode) -> some View {
        HStack {
            if mode.normalized == .dictate {
                Text("Default uses the main dictation shortcut. Add a custom shortcut only when a prompt needs one.")
                    .font(.fluidSystem(.caption2))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: AISettingsLayout.promptModeHintHeight, alignment: .topLeading)
        .padding(.horizontal, 4)
    }

    private func promptRoutingScopeRow(mode: SettingsStore.PromptMode) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                self.promptRoutingScopeButton(title: "Everywhere", scope: .allApps, mode: mode)
                self.promptRoutingScopeButton(title: "Only in listed apps", scope: .selectedAppsOnly, mode: mode)
            }

            Spacer(minLength: 12)

            if mode.normalized == .edit {
                self.editModeInlineModelControls
            }
        }
        .frame(minHeight: AISettingsLayout.controlHeight)
        .padding(.top, 2)
        .padding(.horizontal, 4)
    }

    private func promptRoutingScopeButton(
        title: String,
        scope: SettingsStore.PromptRoutingScope,
        mode: SettingsStore.PromptMode
    ) -> some View {
        let selectedScope = self.viewModel.promptRoutingScope(for: mode)
        let key = "\(mode.normalized.rawValue)-\(scope.rawValue)"
        let isSelected = selectedScope == scope
        let isEnabled = true
        let isHovering = isEnabled && self.hoveredPromptScopeKey == key
        let tone = self.modeAccentColor(mode)

        return Button {
            guard isEnabled else { return }
            self.viewModel.setPromptRoutingScope(scope, for: mode)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.fluidSystem(size: 17))
                    .foregroundStyle(isSelected ? tone : self.theme.palette.secondaryText)
                Text(title)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(isHovering ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .onHover { hovering in
            self.hoveredPromptScopeKey = hovering && isEnabled ? key : nil
        }
    }

    private func selectedAppsOnlySummary(mode: SettingsStore.PromptMode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.fluidSystem(size: 12, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 18, height: 18)

            Text(
                mode.normalized == .dictate
                    ? "No default enhancement. Add app overrides to use prompts in selected apps."
                    : "Default edit stays built-in. App overrides can use custom prompts."
            )
            .font(.fluidSystem(.caption2))
            .foregroundStyle(self.theme.palette.secondaryText)
            .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                )
        )
    }

    private var editModeInlineModelControls: some View {
        let verified = self.editModeVerifiedProviders

        return HStack(alignment: .center, spacing: 10) {
            Text("Edit model")
                .font(.fluidSystem(size: 12, weight: .semibold))
                .foregroundStyle(self.theme.palette.secondaryText)

            if verified.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                    Text("No verified AI provider")
                        .font(.fluidSystem(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                let providerID = self.activeEditModeProviderID
                let models = self.editModeModels(for: providerID)
                Group {
                    Toggle("Sync", isOn: self.editModeLinkedToGlobalBinding)
                        .toggleStyle(.checkbox)
                        .font(.fluidSystem(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .onChange(of: self.settings.rewriteModeLinkedToGlobal) { _, linked in
                            if linked {
                                self.syncEditModeToGlobalSelection()
                            } else {
                                self.normalizeEditModeProviderSelection()
                            }
                        }

                    Text("Provider")
                        .font(.fluidSystem(.caption))
                        .foregroundStyle(.secondary)

                    Picker("", selection: self.editModeProviderBinding) {
                        ForEach(verified) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fluidDropdownStyle()
                    .labelsHidden()
                    .frame(width: AISettingsLayout.promptInlinePickerWidth)
                    .disabled(self.settings.rewriteModeLinkedToGlobal)

                    Text("Model")
                        .font(.fluidSystem(.caption))
                        .foregroundStyle(.secondary)

                    SearchableModelPicker(
                        models: models,
                        selectedModel: self.editModeModelBinding(for: providerID),
                        onRefresh: {
                            guard !self.isPrivateAIProviderID(providerID) else { return }
                            await self.viewModel.fetchModels(for: providerID)
                        },
                        isRefreshing: self.viewModel.refreshingProviderID == providerID,
                        refreshEnabled: !self.settings.rewriteModeLinkedToGlobal && self.canFetchModels(for: providerID),
                        selectionEnabled: !self.settings.rewriteModeLinkedToGlobal && !models.isEmpty,
                        controlWidth: AISettingsLayout.promptInlineModelWidth,
                        controlHeight: 26
                    )
                    .disabled(self.settings.rewriteModeLinkedToGlobal)
                }
                .opacity(self.settings.rewriteModeLinkedToGlobal ? 0.65 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear {
            self.ensureDefaultEditModeSyncState()
            if self.settings.rewriteModeLinkedToGlobal {
                self.syncEditModeToGlobalSelection()
            } else if !verified.isEmpty {
                self.normalizeEditModeProviderSelection()
            }
        }
    }

    @ViewBuilder
    private func appPromptBindingsSection(mode: SettingsStore.PromptMode, isEmphasized: Bool = false, isEnabled: Bool = true) -> some View {
        let bindings = self.viewModel.appBindings(for: mode)
        let appTargets = self.viewModel.appBindingTargets(for: mode)
        let modeProfiles = self.viewModel.dictationPromptProfiles
            .filter { $0.mode.normalized == mode.normalized }

        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "app.dashed")
                    .font(.fluidSystem(size: 12, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text("App-specific styles")
                    .font(.fluidSystem(size: 13, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)

                Spacer(minLength: 8)

                Menu {
                    if appTargets.isEmpty {
                        Text("No unassigned running apps")
                    } else {
                        ForEach(appTargets) { target in
                            Button(self.appBindingTargetMenuTitle(target)) {
                                self.viewModel.addAppPromptBinding(
                                    for: mode,
                                    appBundleID: target.bundleID,
                                    appName: target.name
                                )
                            }
                        }
                    }

                    Divider()

                    Button("Choose App…") {
                        self.viewModel.addAppPromptBindingFromFilePicker(for: mode)
                    }
                } label: {
                    Text("+ Add App")
                }
                .fluidDropdownStyle()
                .frame(minHeight: AISettingsLayout.controlHeight)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.48)
            }

            if bindings.isEmpty {
                Text("No app overrides yet. Add one to use a different prompt for a specific app.")
                    .font(.fluidSystem(.caption2))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(bindings) { binding in
                    self.appPromptBindingRow(
                        binding: binding,
                        mode: mode,
                        modeProfiles: modeProfiles,
                        isEnabled: isEnabled
                    )
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func appPromptBindingRow(
        binding: SettingsStore.AppPromptBinding,
        mode: SettingsStore.PromptMode,
        modeProfiles: [SettingsStore.DictationPromptProfile],
        isEnabled: Bool = true
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                self.appIconView(bundleID: binding.appBundleID)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(binding.appName)
                        .font(.fluidSystem(size: 14, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                        .lineLimit(1)
                    Text(binding.appBundleID)
                        .font(.fluidSystem(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    Menu {
                        Button(SettingsStore.DictationModeLabels.externalDefault) {
                            self.viewModel.setPromptID(nil, for: binding)
                        }

                        Divider()

                        Button("Create New Prompt…") {
                            self.viewModel.openNewPromptEditor(prefillMode: mode)
                        }

                        if !modeProfiles.isEmpty {
                            Divider()
                            ForEach(modeProfiles) { profile in
                                Button(profile.name.isEmpty ? "Untitled Prompt" : profile.name) {
                                    self.viewModel.setPromptID(profile.id, for: binding)
                                }
                            }
                        }
                    } label: { Text(self.viewModel.promptName(for: mode, promptID: binding.promptID)) }
                        .fluidDropdownStyle()
                        .frame(width: 224)
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)

                    Button {
                        guard isEnabled else { return }
                        self.viewModel.removeAppPromptBinding(binding)
                    } label: {
                        Image(systemName: "trash")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                            .frame(width: AISettingsLayout.providerRowControlHeight, height: AISettingsLayout.providerRowControlHeight)
                    }
                    .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red.opacity(0.5)))
                    .disabled(!isEnabled)
                    .help("Remove app-specific override")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 86)
        .opacity(isEnabled ? 1 : 0.68)
        .background(
            shape
                .fill(self.theme.palette.cardBackground.opacity(0.7))
                .overlay(
                    shape
                        .stroke(self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func appIconView(bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "app.dashed")
                .font(.fluidSystem(size: 15, weight: .semibold))
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                )
        }
    }

    private var editModeVerifiedProviders: [AIEnhancementSettingsViewModel.ProviderItemData] {
        self.viewModel.cachedVerifiedProviderItems
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var editModeSelectedProviderID: String {
        let current = self.settings.rewriteModeSelectedProviderID
        if self.editModeVerifiedProviders.contains(where: { $0.id == current }) {
            return current
        }
        return self.editModeVerifiedProviders.first?.id ?? current
    }

    private var activeEditModeProviderID: String {
        if self.settings.rewriteModeLinkedToGlobal {
            return self.settings.selectedProviderID
        }
        return self.editModeSelectedProviderID
    }

    private var editModeLinkedToGlobalBinding: Binding<Bool> {
        Binding(
            get: { self.settings.rewriteModeLinkedToGlobal },
            set: { self.settings.rewriteModeLinkedToGlobal = $0 }
        )
    }

    private var editModeProviderBinding: Binding<String> {
        Binding(
            get: { self.activeEditModeProviderID },
            set: { newProviderID in
                guard !self.settings.rewriteModeLinkedToGlobal else { return }
                self.settings.rewriteModeSelectedProviderID = newProviderID
                let models = self.editModeModels(for: newProviderID)
                let current = self.settings.rewriteModeSelectedModel ?? ""
                if !models.contains(current) {
                    self.settings.rewriteModeSelectedModel = models.first
                }
            }
        )
    }

    private func editModeModelBinding(for providerID: String) -> Binding<String> {
        Binding(
            get: {
                let models = self.editModeModels(for: providerID)
                if self.settings.rewriteModeLinkedToGlobal {
                    let key = self.viewModel.providerKey(for: providerID)
                    let preferred = self.settings.selectedModelByProvider[key]
                        ?? self.settings.selectedModel
                    return ModelRepository.eligibleModel(preferred: preferred, from: models) ?? ""
                }
                return ModelRepository.eligibleModel(
                    preferred: self.settings.rewriteModeSelectedModel,
                    from: models
                ) ?? ""
            },
            set: { newModel in
                guard !self.settings.rewriteModeLinkedToGlobal else { return }
                self.settings.rewriteModeSelectedModel = newModel
            }
        )
    }

    private func normalizeEditModeProviderSelection() {
        guard let first = self.editModeVerifiedProviders.first else { return }
        let current = self.settings.rewriteModeSelectedProviderID
        if !self.editModeVerifiedProviders.contains(where: { $0.id == current }) {
            self.settings.rewriteModeSelectedProviderID = first.id
        }

        let providerID = self.settings.rewriteModeSelectedProviderID
        let models = self.editModeModels(for: providerID)
        let currentModel = self.settings.rewriteModeSelectedModel ?? ""
        if !models.contains(currentModel) {
            self.settings.rewriteModeSelectedModel = models.first
        }
    }

    private func syncEditModeToGlobalSelection() {
        let global = self.settings.selectedProviderID
        guard !global.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.settings.rewriteModeSelectedProviderID = ""
            self.settings.rewriteModeSelectedModel = nil
            return
        }

        self.settings.rewriteModeSelectedProviderID = global

        if self.isPrivateAIProviderID(global) {
            self.settings.rewriteModeSelectedModel = self.editModeModels(for: global).first
            return
        }

        let key = self.viewModel.providerKey(for: global)
        let model = self.settings.selectedModelByProvider[key]
            ?? self.settings.selectedModel
            ?? self.viewModel.models(for: global).first
        self.settings.rewriteModeSelectedModel = model
    }

    private func editModeModels(for providerID: String) -> [String] {
        if self.isPrivateAIProviderID(providerID) {
            return ModelRepository.shared.defaultModels(for: providerID, task: .edit)
        }
        return self.viewModel.models(for: providerID)
    }

    private func isPrivateAIProviderID(_ providerID: String) -> Bool {
        PrivateFeatures.privateAIProvider &&
            providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            == PrivateAIProviderFeature.shared.providerID
    }

    private func ensureDefaultEditModeSyncState() {
        // If no persisted value exists yet, default Sync to ON.
        if UserDefaults.standard.object(forKey: "RewriteModeLinkedToGlobal") == nil {
            self.settings.rewriteModeLinkedToGlobal = true
            self.syncEditModeToGlobalSelection()
        }
    }

    private func canFetchModels(for providerID: String) -> Bool {
        let apiKey = self.viewModel.providerAPIKey(for: providerID)
        let hasAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let baseURL: String
        if let saved = self.viewModel.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = saved.baseURL
        } else {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        }
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.viewModel.isLocalEndpoint(trimmedBaseURL)

        return isLocal ? !trimmedBaseURL.isEmpty : (hasAPIKey && !trimmedBaseURL.isEmpty)
    }

    private func promptSectionDescription(for mode: SettingsStore.PromptMode) -> String {
        switch mode {
        case .dictate:
            return "Each prompt can have its own provider, model, and optional shortcut."
        case .edit, .write, .rewrite:
            return "Uses selected text as context (when text is selected) - Edit or rewrite selected text - answer questions, summarize, convert to bullets etc."
        }
    }

    private func modeAccentColor(_ mode: SettingsStore.PromptMode) -> Color {
        _ = mode
        return self.theme.palette.accent
    }

    private func appBindingTargetMenuTitle(_ target: AIEnhancementSettingsViewModel.AppBindingTarget) -> String {
        if target.name.caseInsensitiveCompare(target.bundleID) == .orderedSame {
            return target.bundleID
        }
        return "\(target.name) (\(target.bundleID))"
    }

    private func modeSymbol(_ mode: SettingsStore.PromptMode) -> String {
        switch mode.normalized {
        case .dictate:
            return "mic.fill"
        case .edit, .write, .rewrite:
            return "square.and.pencil"
        }
    }

    private func friendlyModeName(_ mode: SettingsStore.PromptMode) -> String {
        switch mode.normalized {
        case .dictate:
            return "Dictate"
        case .edit, .write, .rewrite:
            return "Edit Text"
        }
    }

    func promptEditorSheet(mode: PromptEditorMode) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text({
                                switch mode {
                                case let .defaultPrompt(promptMode): return "Default \(self.friendlyModeName(promptMode)) Prompt"
                                case let .newPrompt(prefillMode): return "New \(self.friendlyModeName(prefillMode)) Prompt"
                                case .edit: return "Edit Prompt"
                                case .privateAI: return PrivateAIProviderFeature.displayName
                                }
                            }())
                                .font(.fluidSystem(.headline))
                            if mode.isPrivateAI {
                                Text("Built-in cleanup.")
                                    .font(.fluidSystem(.caption))
                                    .foregroundStyle(.secondary)
                            } else if mode.isDefault {
                                Text("This is the built-in prompt. Create a custom prompt to override it.")
                                    .font(.fluidSystem(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }

                    if self.shouldShowPromptEditorConfigurationPanel(for: mode) {
                        self.promptEditorConfigurationPanel(mode: mode)
                    }

                    if !mode.isPrivateAI {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Name")
                                .font(.fluidSystem(.caption))
                                .foregroundStyle(.secondary)
                            let isDefaultNameLocked = mode.isDefault
                            TextField("Prompt name", text: self.$viewModel.draftPromptName)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isDefaultNameLocked)
                        }
                    }

                    if !mode.isPrivateAI {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Prompt")
                                .font(.fluidSystem(.caption))
                                .foregroundStyle(.secondary)
                            PromptTextView(
                                text: self.$viewModel.draftPromptText,
                                isEditable: true,
                                font: NSFont.fluidMonospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                            )
                            .id(self.viewModel.promptEditorSessionID)
                            .frame(minHeight: 180)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(self.theme.palette.contentBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                                    )
                            )
                            .onChange(of: self.viewModel.draftPromptText) { _, newValue in
                                guard self.viewModel.draftPromptMode == .dictate else { return }
                                let combined = self.viewModel.combinedDraftPrompt(newValue, mode: self.viewModel.draftPromptMode)
                                self.promptTest.updateDraftPromptText(combined)
                            }
                        }
                    }

                    if self.viewModel.draftPromptMode != .dictate {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Selected text is added automatically when text is selected.")
                                .font(.fluidSystem(.caption))
                                .foregroundStyle(self.theme.palette.secondaryText)

                            Text("Context block added automatically:")
                                .font(.fluidSystem(.caption2))
                                .foregroundStyle(.secondary)

                            Text(SettingsStore.contextTemplateText())
                                .font(.fluidSystem(.caption2, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(self.theme.palette.contentBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                                        )
                                )
                        }
                    }

                    // MARK: - Test Mode

                    if self.viewModel.draftPromptMode == .dictate && !mode.isPrivateAI {
                        VStack(alignment: .leading, spacing: 8) {
                            let hotkeyDisplay = self.settings.primaryDictationShortcutDisplayString
                            let canTest = DictationAIPostProcessingGate.isProviderConfigured(
                                providerID: self.promptEditorProviderIDDraft,
                                model: self.promptEditorModelDraft
                            )

                            Toggle(isOn: Binding(
                                get: { self.promptTest.isActive },
                                set: { enabled in
                                    if enabled {
                                        let combined = self.viewModel.combinedDraftPrompt(self.viewModel.draftPromptText, mode: self.viewModel.draftPromptMode)
                                        self.promptTest.activate(
                                            draftPromptText: combined,
                                            providerID: self.promptEditorProviderIDDraft,
                                            model: self.promptEditorModelDraft
                                        )
                                    } else {
                                        self.promptTest.deactivate()
                                    }
                                }
                            )) {
                                Text("Test prompt · \(hotkeyDisplay)")
                                    .font(.fluidSystem(.caption))
                            }
                            .toggleStyle(.switch)
                            .disabled(!canTest)

                            if !canTest {
                                Text("Choose a provider and model to test your prompt.")
                                    .font(.fluidSystem(.caption2))
                                    .foregroundStyle(.secondary)
                            } else if self.promptTest.isActive {
                                Text(
                                    "Press the hotkey to start/stop recording. The transcription will be post-processed using your draft prompt and shown below (nothing will be typed into other apps)."
                                )
                                .font(.fluidSystem(.caption2))
                                .foregroundStyle(.secondary)
                            }

                            if self.promptTest.isActive {
                                if self.promptTest.isProcessing {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small).fixedSize()
                                        Text("Processing…")
                                            .font(.fluidSystem(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if !self.promptTest.lastError.isEmpty {
                                    Text(self.promptTest.lastError)
                                        .font(.fluidSystem(.caption2))
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Raw transcription")
                                        .font(.fluidSystem(.caption2))
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: Binding(
                                        get: { self.promptTest.lastTranscriptionText },
                                        set: { _ in }
                                    ))
                                    .font(.fluidSystem(.caption, design: .monospaced))
                                    .frame(minHeight: 70)
                                    .scrollContentBackground(.hidden)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(self.theme.palette.contentBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                                            )
                                    )
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Post-processed output")
                                        .font(.fluidSystem(.caption2))
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: Binding(
                                        get: { self.promptTest.lastOutputText },
                                        set: { _ in }
                                    ))
                                    .font(.fluidSystem(.caption, design: .monospaced))
                                    .frame(minHeight: 110)
                                    .scrollContentBackground(.hidden)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(self.theme.palette.contentBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                                            )
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(self.theme.palette.contentBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(self.theme.palette.cardBorder, lineWidth: 1)
                                )
                        )
                    } else if self.promptTest.isActive {
                        Text("Prompt test mode is available only for Dictate prompts.")
                            .font(.fluidSystem(.caption2))
                            .foregroundStyle(.secondary)
                            .onAppear { self.promptTest.deactivate() }
                    }
                }
                .padding()
            }

            Divider()

            HStack(spacing: 10) {
                if mode.isDefault,
                   let promptMode = mode.mode,
                   self.hasDefaultPromptCustomization(for: promptMode)
                {
                    Button("Reset Default") {
                        self.resetDefaultPrompt(for: promptMode)
                    }
                    .fluidButton(.compact, size: .compact)
                    .frame(minWidth: AISettingsLayout.primaryActionMinWidth, minHeight: AISettingsLayout.controlHeight)
                    .help("Clear the custom prompt, provider, model, and shortcut")
                }

                Spacer(minLength: 0)

                Button("Cancel") {
                    self.restorePromptEditorConfigurationDraft(mode: mode)
                    self.viewModel.closePromptEditor()
                }
                .fluidButton(.compact, size: .compact)
                .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)

                Button("Save") {
                    self.applyPromptEditorConfigurationDraft(mode: mode)
                    self.viewModel.savePromptEditor(mode: mode)
                }
                .fluidButton(.glass, size: .compact)
                .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(!mode.isDefault && self.viewModel.draftPromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(
            minWidth: mode.isPrivateAI ? 620 : 780,
            idealWidth: mode.isPrivateAI ? 620 : 820,
            minHeight: mode.isPrivateAI ? 230 : 420,
            idealHeight: mode.isPrivateAI ? 230 : 700,
            maxHeight: mode.isPrivateAI ? 260 : 720
        )
        .onAppear {
            self.preparePromptEditorConfigurationDraft(mode: mode)
        }
        .onDisappear {
            self.promptTest.deactivate()
        }
        .onChange(of: self.viewModel.promptEditorSessionID) { _, _ in
            self.preparePromptEditorConfigurationDraft(mode: mode)
        }
        .onChange(of: self.promptEditorProviderIDDraft) { _, providerID in
            self.promptTest.updateDraftConfiguration(providerID: providerID, model: self.promptEditorModelDraft)
        }
        .onChange(of: self.promptEditorModelDraft) { _, model in
            self.promptTest.updateDraftConfiguration(providerID: self.promptEditorProviderIDDraft, model: model)
        }
        .onChange(of: self.activeShortcutRecordingTarget) { oldValue, newValue in
            if case .newPrompt = mode {
                if newValue == nil, oldValue != nil {
                    if let pending = self.viewModel.pendingNewPromptConfiguration {
                        self.promptEditorShortcutDraft = pending.shortcut
                    } else {
                        self.promptEditorShortcutDraft = nil
                    }
                }
                return
            }
            guard newValue == nil, oldValue != nil,
                  let selection = self.promptEditorSelection(for: mode)
            else {
                return
            }
            self.promptEditorShortcutDraft = self.settings.dictationPromptConfiguration(for: selection).shortcut
        }
        .onChange(of: self.viewModel.selectedProviderID) { _, _ in
            self.autoDisablePromptTestIfNeeded()
        }
        .onChange(of: self.viewModel.providerAPIKeys) { _, _ in
            self.autoDisablePromptTestIfNeeded()
        }
        .onChange(of: self.viewModel.savedProviders) { _, _ in
            self.autoDisablePromptTestIfNeeded()
        }
    }

    private func autoDisablePromptTestIfNeeded() {
        guard self.promptTest.isActive else { return }
        if !self.viewModel.isAIPostProcessingConfiguredForDictation() {
            self.promptTest.deactivate()
        }
    }

    func openDefaultPromptViewer(for mode: SettingsStore.PromptMode) {
        self.viewModel.openDefaultPromptViewer(for: mode)
    }

    func openNewPromptEditor(prefillMode: SettingsStore.PromptMode = .edit) {
        self.viewModel.openNewPromptEditor(prefillMode: prefillMode)
    }

    func openPrivateAIPromptEditor() {
        self.viewModel.openPrivateAIPromptEditor()
    }

    func openEditor(for profile: SettingsStore.DictationPromptProfile) {
        self.viewModel.openEditor(for: profile)
    }

    func closePromptEditor() {
        self.viewModel.closePromptEditor()
    }

    // MARK: - Prompt Test Gating

    func isAIPostProcessingConfiguredForDictation() -> Bool {
        self.viewModel.isAIPostProcessingConfiguredForDictation()
    }

    func savePromptEditor(mode: PromptEditorMode) {
        self.viewModel.savePromptEditor(mode: mode)
    }
}
