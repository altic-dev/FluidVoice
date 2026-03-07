//
//  AISettingsView+AdvancedSettings.swift
//  fluid
//
//  Extracted from AISettingsView.swift to keep view body under lint limit.
//

import AppKit
import SwiftUI

extension AIEnhancementSettingsView {
    // MARK: - Advanced Settings Card

    var advancedSettingsCard: some View {
        ThemedCard(style: .prominent, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("Prompt Profiles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(self.theme.palette.primaryText)
                            Text(" - Pick one prompt for Dictate and one for Edit Text.")
                                .font(.system(size: 13))
                                .foregroundColor(self.theme.palette.secondaryText)
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Spacer()
                        Button("+ Add Prompt") {
                            self.viewModel.openNewPromptEditor(prefillMode: .edit)
                        }
                        .buttonStyle(CompactButtonStyle(isReady: true))
                        .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(SettingsStore.PromptMode.visiblePromptModes) { mode in
                                self.promptModeSection(mode: mode)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }

                        VStack(spacing: 14) {
                            ForEach(SettingsStore.PromptMode.visiblePromptModes) { mode in
                                self.promptModeSection(mode: mode)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(14)
        }
        .sheet(item: self.$viewModel.promptEditorMode) { mode in
            self.promptEditorSheet(mode: mode)
        }
    }

    func promptProfileCard(
        cardKey: String,
        title: String,
        subtitle: String,
        mode: SettingsStore.PromptMode,
        isSelected: Bool,
        onUse: @escaping () -> Void,
        onManage: @escaping () -> Void,
        onResetDefault: (() -> Void)? = nil,
        canResetDefault: Bool = false,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        let tone = self.modeAccentColor(mode)
        let selectedStrokeOpacity: Double = mode.normalized == .dictate ? 0.52 : 0.38
        let isHovering = self.hoveredPromptCardKey == cardKey
        return HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isHovering ? tone.opacity(0.5) : .clear)
                .frame(width: 3, height: 34)

            Button(action: onUse) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(self.theme.palette.primaryText)
                        if mode.normalized == .edit {
                            Text("Context: Auto")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(tone.opacity(0.12))
                                )
                                .foregroundColor(tone)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? tone : self.theme.palette.secondaryText.opacity(0.35))
                    .frame(width: 18, height: 18)

                Menu {
                    Button("Edit Prompt") { onManage() }
                    if mode == .edit {
                        Divider()
                        Text("Selected text context is added automatically when text is selected.")
                    }
                    if let onDelete {
                        Divider()
                        Button( action: { onDelete() }) {
                            Label("Delete Prompt", systemImage: "trash")
                        }
                    } else if let onResetDefault {
                        Divider()
                        Button("Reset to Built-in Default")  { onResetDefault() }
                            .disabled(!canResetDefault)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: AISettingsLayout.controlHeight, height: AISettingsLayout.controlHeight)
                }
                .buttonStyle(.plain)
                .foregroundColor(self.theme.palette.secondaryText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isHovering ? tone.opacity(mode.normalized == .dictate ? 0.06 : 0.045) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isHovering ? tone.opacity(selectedStrokeOpacity) : self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                )
        )
        .onHover { hovering in
            if hovering {
                self.hoveredPromptCardKey = cardKey
            } else if self.hoveredPromptCardKey == cardKey {
                self.hoveredPromptCardKey = nil
            }
        }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    @ViewBuilder
    private func promptModeSection(mode: SettingsStore.PromptMode) -> some View {
        let customProfiles = self.viewModel.dictationPromptProfiles
            .filter { $0.mode.normalized == mode }
        let tone = self.modeAccentColor(mode)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: self.modeSymbol(mode))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(tone.opacity(mode.normalized == .dictate ? 0.85 : 0.65)))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(mode.normalized == .dictate ? "Dictate Mode" : "Edit Text Mode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(self.theme.palette.primaryText)
                    Text(" - \(self.promptSectionDescription(for: mode))")
                        .font(.caption)
                        .foregroundColor(self.theme.palette.secondaryText)
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .padding(.horizontal, 2)

            if mode.normalized == .edit {
                self.editModeProviderModelRow
            }

            self.promptProfileCard(
                cardKey: "\(mode.normalized.rawValue)-default",
                title: "Default \(self.friendlyModeName(mode))",
                subtitle: self.viewModel.promptPreview(self.viewModel.defaultPromptBodyPreview(for: mode)),
                mode: mode,
                isSelected: self.viewModel.selectedPromptID(for: mode) == nil,
                onUse: {
                    self.viewModel.setSelectedPromptID(nil, for: mode)
                },
                onManage: { self.viewModel.openDefaultPromptViewer(for: mode) },
                onResetDefault: { self.viewModel.resetDefaultPromptOverride(for: mode) },
                canResetDefault: self.viewModel.hasDefaultPromptOverride(for: mode)
            )

            if customProfiles.isEmpty {
                Text("No custom \(self.friendlyModeName(mode).lowercased()) prompts yet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(customProfiles) { profile in
                    self.promptProfileCard(
                        cardKey: "\(profile.mode.normalized.rawValue)-\(profile.id)",
                        title: profile.name.isEmpty ? "Untitled Prompt" : profile.name,
                        subtitle: SettingsStore.stripBasePrompt(for: profile.mode, from: profile.prompt).isEmpty
                            ? "Empty prompt (uses Default)"
                            : self.viewModel.promptPreview(SettingsStore.stripBasePrompt(for: profile.mode, from: profile.prompt)),
                        mode: profile.mode,
                        isSelected: self.viewModel.selectedPromptID(for: profile.mode) == profile.id,
                        onUse: {
                            self.viewModel.setSelectedPromptID(profile.id, for: profile.mode)
                        },
                        onManage: { self.viewModel.openEditor(for: profile) },
                        onDelete: { self.viewModel.requestDeletePrompt(profile) }
                    )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tone.opacity(mode.normalized == .dictate ? 0.14 : 0.08),
                            self.theme.palette.contentBackground.opacity(0.28),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tone.opacity(mode.normalized == .dictate ? 0.34 : 0.22), lineWidth: 1)
                )
        )
    }

    private var editModeProviderModelRow: some View {
        let verified = self.editModeVerifiedProviders

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Edit mode model selection (optional)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if verified.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("No verified providers yet. Verify a provider above to enable Edit Text model selection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.theme.palette.cardBackground.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                        )
                )
            } else {
                let providerID = self.activeEditModeProviderID
                let models = self.viewModel.models(for: providerID)
                HStack(alignment: .center, spacing: 12) {
                    Toggle("Sync with AI Enhancement model", isOn: self.editModeLinkedToGlobalBinding)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .onChange(of: self.settings.rewriteModeLinkedToGlobal) { linked in
                            if linked {
                                self.syncEditModeToGlobalSelection()
                            } else {
                                self.normalizeEditModeProviderSelection()
                            }
                        }

                    HStack(alignment: .center, spacing: 10) {
                        Text("Provider")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: self.editModeProviderBinding) {
                            ForEach(verified) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 170)
                        .disabled(self.settings.rewriteModeLinkedToGlobal)

                        Text("Model")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SearchableModelPicker(
                            models: models,
                            selectedModel: self.editModeModelBinding(for: providerID),
                            onRefresh: { await self.viewModel.fetchModels(for: providerID) },
                            isRefreshing: self.viewModel.refreshingProviderID == providerID,
                            refreshEnabled: !self.settings.rewriteModeLinkedToGlobal && self.canFetchModels(for: providerID),
                            selectionEnabled: !self.settings.rewriteModeLinkedToGlobal && !models.isEmpty,
                            controlWidth: 190,
                            controlHeight: 28
                        )
                        .disabled(self.settings.rewriteModeLinkedToGlobal)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(self.settings.rewriteModeLinkedToGlobal ? 0.65 : 1)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.theme.palette.cardBackground.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                        )
                )
                .onAppear {
                    self.normalizeEditModeProviderSelection()
                }
            }
        }
        .padding(.horizontal, 2)
        .onAppear {
            self.ensureDefaultEditModeSyncState()
        }
    }

    private var editModeVerifiedProviders: [AIEnhancementSettingsViewModel.ProviderItemData] {
        self.viewModel.cachedVerifiedProviderItems.sorted { lhs, rhs in
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
            let global = self.viewModel.selectedProviderID
            if self.editModeVerifiedProviders.contains(where: { $0.id == global }) {
                return global
            }
            return self.editModeSelectedProviderID
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
                let models = self.viewModel.models(for: newProviderID)
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
                if self.settings.rewriteModeLinkedToGlobal {
                    let key = self.viewModel.providerKey(for: providerID)
                    return self.settings.selectedModelByProvider[key]
                        ?? self.settings.selectedModel
                        ?? self.viewModel.models(for: providerID).first
                        ?? ""
                }
                return self.settings.rewriteModeSelectedModel ?? self.viewModel.models(for: providerID).first ?? ""
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
        let models = self.viewModel.models(for: providerID)
        let currentModel = self.settings.rewriteModeSelectedModel ?? ""
        if !models.contains(currentModel) {
            self.settings.rewriteModeSelectedModel = models.first
        }
    }

    private func syncEditModeToGlobalSelection() {
        let global = self.viewModel.selectedProviderID
        let providerID: String
        if self.editModeVerifiedProviders.contains(where: { $0.id == global }) {
            providerID = global
        } else if let fallback = self.editModeVerifiedProviders.first?.id {
            providerID = fallback
        } else {
            providerID = global
        }
        self.settings.rewriteModeSelectedProviderID = providerID

        let key = self.viewModel.providerKey(for: providerID)
        let model = self.settings.selectedModelByProvider[key]
            ?? self.settings.selectedModel
            ?? self.viewModel.models(for: providerID).first
        self.settings.rewriteModeSelectedModel = model
    }

    private func ensureDefaultEditModeSyncState() {
        // If no persisted value exists yet, default Sync to ON.
        if UserDefaults.standard.object(forKey: "RewriteModeLinkedToGlobal") == nil {
            self.settings.rewriteModeLinkedToGlobal = true
            self.syncEditModeToGlobalSelection()
        }
    }

    private func canFetchModels(for providerID: String) -> Bool {
        let key = self.viewModel.providerKey(for: providerID)
        let apiKey = self.viewModel.providerAPIKeys[key] ?? ""
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
            return "No selected-text context - Process raw voice text - clean, write into email, convert terminal commands, translate etc."
        case .edit, .write, .rewrite:
            return "Uses selected text as context (when text is selected) - Edit or rewrite selected text - answer questions, summarize, convert to bullets etc."
        }
    }

    private func modeAccentColor(_ mode: SettingsStore.PromptMode) -> Color {
        _ = mode
        return Color.fluidGreen
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
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text({
                        switch mode {
                        case let .defaultPrompt(promptMode): return "Default \(self.friendlyModeName(promptMode)) Prompt"
                        case let .newPrompt(prefillMode): return "New \(self.friendlyModeName(prefillMode)) Prompt"
                        case .edit: return "Edit Prompt"
                        }
                    }())
                        .font(.headline)
                    Text(mode.isDefault
                        ? "This is the built-in prompt. Create a custom prompt to override it."
                        : "Prompt text is appended to the hidden base prompt for the selected mode."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Mode", selection: self.$viewModel.draftPromptMode) {
                    ForEach(SettingsStore.PromptMode.visiblePromptModes) { mode in
                        Text(self.friendlyModeName(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(mode.isDefault)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                let isDefaultNameLocked = mode.isDefault
                TextField("Prompt name", text: self.$viewModel.draftPromptName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDefaultNameLocked)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                PromptTextView(
                    text: self.$viewModel.draftPromptText,
                    isEditable: true,
                    font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                )
                .id(self.viewModel.promptEditorSessionID)
                .frame(minHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.contentBackground.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                        )
                )
                .onChange(of: self.viewModel.draftPromptText) { newValue in
                    guard self.viewModel.draftPromptMode == .dictate else { return }
                    let combined = self.viewModel.combinedDraftPrompt(newValue, mode: self.viewModel.draftPromptMode)
                    self.promptTest.updateDraftPromptText(combined)
                }
            }

            if self.viewModel.draftPromptMode != .dictate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected text is added automatically when text is selected.")
                        .font(.caption)
                        .foregroundColor(self.theme.palette.secondaryText)

                    Text("Context block added automatically:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(SettingsStore.contextTemplateText())
                        .font(.system(.caption2, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(self.theme.palette.contentBackground.opacity(0.7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                                )
                        )
                }
            }

            // MARK: - Test Mode

            if self.viewModel.draftPromptMode == .dictate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .foregroundColor(self.theme.palette.accent)
                        Text("Test")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                    }

                    let hotkeyDisplay = self.settings.hotkeyShortcut.displayString
                    let canTest = self.viewModel.isAIPostProcessingConfiguredForDictation()

                    Toggle(isOn: Binding(
                        get: { self.promptTest.isActive },
                        set: { enabled in
                            if enabled {
                                let combined = self.viewModel.combinedDraftPrompt(self.viewModel.draftPromptText, mode: self.viewModel.draftPromptMode)
                                self.promptTest.activate(draftPromptText: combined)
                            } else {
                                self.promptTest.deactivate()
                            }
                        }
                    )) {
                        Text("Enable Test Mode (Hotkey: \(hotkeyDisplay))")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .disabled(!canTest)

                    if !canTest {
                        Text("Testing is disabled because AI post-processing is not configured.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if self.promptTest.isActive {
                        Text("Press the hotkey to start/stop recording. The transcription will be post-processed using your draft prompt and shown below (nothing will be typed into other apps).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if self.promptTest.isActive {
                        if self.promptTest.isProcessing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Processing…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !self.promptTest.lastError.isEmpty {
                            Text(self.promptTest.lastError)
                                .font(.caption2)
                                .foregroundColor(.red)
                                
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Raw transcription")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            TextEditor(text: Binding(
                                get: { self.promptTest.lastTranscriptionText },
                                set: { _ in }
                            ))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 70)
                            
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(self.theme.palette.contentBackground.opacity(0.7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                                    )
                            )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Post-processed output")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            TextEditor(text: Binding(
                                get: { self.promptTest.lastOutputText },
                                set: { _ in }
                            ))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 110)
                            
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(self.theme.palette.contentBackground.opacity(0.7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(self.theme.palette.accent.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
            } else if self.promptTest.isActive {
                Text("Prompt test mode is available only for Dictate prompts.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .onAppear { self.promptTest.deactivate() }
            }

            HStack(spacing: 10) {
                Button(mode.isDefault ? "Close" : "Cancel") {
                    self.viewModel.closePromptEditor()
                }
                .buttonStyle(CompactButtonStyle())
                .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)

                Button("Save") {
                    self.viewModel.savePromptEditor(mode: mode)
                }
                .buttonStyle(GlassButtonStyle(height: AISettingsLayout.controlHeight))
                .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(!mode.isDefault && self.viewModel.draftPromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
        .onDisappear {
            self.promptTest.deactivate()
        }
        .onChange(of: self.viewModel.enableAIProcessing) { _ in
            self.autoDisablePromptTestIfNeeded()
        }
        .onChange(of: self.viewModel.selectedProviderID) { _ in
            self.autoDisablePromptTestIfNeeded()
        }
        .onChange(of: self.viewModel.providerAPIKeys) { _ in
            self.autoDisablePromptTestIfNeeded()
        }
        .onChange(of: self.viewModel.savedProviders) { _ in
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
