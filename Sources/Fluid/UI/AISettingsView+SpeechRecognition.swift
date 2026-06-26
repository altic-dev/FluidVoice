//
//  AISettingsView+SpeechRecognition.swift
//  fluid
//
//  Extracted from AISettingsView.swift to keep view body under lint limit.
//

import SwiftUI

extension VoiceEngineSettingsView {
    // MARK: - Speech Recognition Card

    var speechRecognitionCard: some View {
        let selectedModel = self.settings.selectedSpeechModel
        let activeModel = selectedModel.isInstalled ? selectedModel : nil
        let hasActiveModel = activeModel != nil
        let otherModels = self.viewModel.filteredSpeechModels.filter { model in
            guard let activeModel else { return true }
            return model != activeModel
        }

        return ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(self.theme.palette.accent)
                    Text("Voice Engine")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                }

                // Stats Panel - Dynamic bars that update based on selected model
                self.modelStatsPanel
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(self.theme.palette.contentBackground.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                            )
                            .shadow(color: self.theme.metrics.cardShadow.color.opacity(self.theme.metrics.cardShadow.opacity), radius: self.theme.metrics.cardShadow.radius, x: self.theme.metrics.cardShadow.x, y: self.theme.metrics.cardShadow.y)
                    )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.voiceEngineSecondaryText)
                            Text("Click a row to preview. Press Activate to load the model.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.voiceEngineSecondaryText)
                            Spacer()
                            Menu {
                                ForEach(SpeechProviderFilter.allCases) { option in
                                    Button(option.rawValue) {
                                        self.viewModel.providerFilter = option
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .font(self.theme.typography.bodySmallStrong)
                                    Text("Filter: \(self.viewModel.providerFilter.rawValue)")
                                        .font(self.theme.typography.bodySmallStrong)
                                }
                                .foregroundStyle(self.voiceEngineTitleText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(self.theme.palette.cardBackground.opacity(0.8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9)
                                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                                        )
                                )
                            }
                            Menu {
                                ForEach(ModelSortOption.allCases) { option in
                                    Button(option.rawValue) {
                                        self.viewModel.modelSortOption = option
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text("Sort by: \(self.viewModel.modelSortOption.rawValue)")
                                        .font(self.theme.typography.bodySmallStrong)
                                }
                                .foregroundStyle(self.voiceEngineTitleText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(self.theme.palette.cardBackground.opacity(0.8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9)
                                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                                        )
                                )
                            }
                        }

                        // Active + Other models list
                        VStack(alignment: .leading, spacing: 10) {
                            if let activeModel {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Active Model")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.voiceEngineTitleText)
                                    self.speechModelCard(for: activeModel)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Active Model")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.voiceEngineTitleText)
                                    Label("No active model yet. Download and activate one below.", systemImage: "arrow.down.circle")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.voiceEngineSecondaryText)
                                }
                            }

                            Divider().padding(.vertical, 2)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(hasActiveModel ? "Other Models" : "Available Models")
                                    .font(self.theme.typography.sectionTitle)
                                    .foregroundStyle(self.voiceEngineTitleText)
                                VStack(spacing: 8) {
                                    ForEach(otherModels) { model in
                                        self.speechModelCard(for: model)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(self.theme.palette.cardBackground.opacity(0.9))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                                )
                                .shadow(color: self.theme.metrics.cardShadow.color.opacity(self.theme.metrics.cardShadow.opacity), radius: self.theme.metrics.cardShadow.radius, x: self.theme.metrics.cardShadow.x, y: self.theme.metrics.cardShadow.y)
                        )

                        Divider().padding(.vertical, 4)

                        // Filler Words Section
                        self.fillerWordsSection
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Stats panel showing speed/accuracy bars that animate when model changes
    var modelStatsPanel: some View {
        let model = self.viewModel.previewSpeechModel
        let supportsCustomWords = model.supportsCustomVocabulary

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.humanReadableName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(self.theme.palette.primaryText)

                            if let badge = model.badgeText {
                                Text(badge)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(badge == "FluidVoice Pick" ? .cyan.opacity(0.2) : .orange.opacity(0.2)))
                                    .foregroundStyle(badge == "FluidVoice Pick" ? .cyan : .orange)
                            }

                            Spacer()
                        }

                        Text(model.cardDescription)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Label(model.downloadSize, systemImage: "internaldrive")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.voiceEngineSecondaryText)

                        if model.requiresAppleSilicon {
                            Text("Apple Silicon")
                                .font(self.theme.typography.bodySmallStrong)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(self.theme.palette.accent.opacity(0.2)))
                                .foregroundStyle(self.theme.palette.accent)
                        }

                        Text(model.languageSupport)
                            .font(self.theme.typography.bodySmallStrong)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(self.voiceEngineSecondaryText)

                        Spacer()
                    }

                    if let supportedLanguageCodes = model.supportedLanguageCodes {
                        Text(supportedLanguageCodes)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                            .lineLimit(2)
                    }

                    // Memory warning for large models
                    if let memoryWarning = model.memoryWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(.orange)
                            Text(memoryWarning)
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.orange.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.orange.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    LiquidBar(
                        fillPercent: model.speedPercent,
                        color: .yellow,
                        secondaryColor: .orange,
                        icon: "bolt.fill",
                        label: "Speed"
                    )

                    LiquidBar(
                        fillPercent: model.accuracyPercent,
                        color: Color.fluidGreen,
                        secondaryColor: .cyan,
                        icon: "target",
                        label: "Accuracy"
                    )
                }
                .frame(width: 140, alignment: .center)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: model.id)
            }

            if supportsCustomWords {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(Color.fluidGreen)

                    Text("Custom Words supported on Parakeet. Teach names, product terms, and uncommon words for better accuracy.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.voiceEngineSecondaryText)
                        .lineLimit(3)

                    Spacer(minLength: 8)

                    Button("Open Custom Dictionary") {
                        NotificationCenter.default.post(name: .openCustomDictionaryFromVoiceEngine, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.fluidGreen)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.fluidGreen.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.fluidGreen.opacity(0.30), lineWidth: 1)
                        )
                )
            }
        }
        .padding(.vertical, 6)
    }

    func speechModelCard(for model: SettingsStore.SpeechModel) -> some View {
        let isSelected = self.viewModel.previewSpeechModel == model
        let isConfiguredActive = self.viewModel.isActiveSpeechModel(model)
        let isActive = isConfiguredActive && model.isInstalled

        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isSelected ? Color.fluidGreen : self.theme.palette.cardBorder.opacity(0.25))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.fluidGreen : self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                )

            self.speechModelLogoView(for: model)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.humanReadableName)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.voiceEngineTitleText)
                Text(self.speechModelSubtitle(for: model))
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.voiceEngineSecondaryText)

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.yellow)
                        Text("Speed \(Int(model.speedPercent * 100))%")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "target")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fluidGreen)
                        Text("Acc \(Int(model.accuracyPercent * 100))%")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                    }

                    if isSelected && !isActive {
                        Text("Previewing")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action area: Show progress if THIS model is being downloaded
            if self.viewModel.downloadingModel == model {
                // This specific model is currently being downloaded
                VStack(alignment: .trailing, spacing: 4) {
                    if self.viewModel.downloadProgress >= 0.82 {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Downloading…")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.voiceEngineSecondaryText)
                        }
                    } else {
                        ProgressView(value: self.viewModel.downloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 90)
                        Text("\(Int(self.viewModel.downloadProgress * 100))%")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                    }
                }
            } else if (self.viewModel.asr.isDownloadingModel || self.viewModel.asr.isLoadingModel) && isConfiguredActive && !self.viewModel.asr.isAsrReady {
                // Active model is loading/downloading (for Activate flow)
                VStack(alignment: .trailing, spacing: 4) {
                    if let progress = self.viewModel.asr.downloadProgress, self.viewModel.asr.isDownloadingModel {
                        if progress >= 0.82 {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Downloading…")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.voiceEngineSecondaryText)
                            }
                        } else {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 90)
                            Text("\(Int(progress * 100))%")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.voiceEngineSecondaryText)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                        Text(self.viewModel.asr.isLoadingModel ? "Loading…" : "Downloading…")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.voiceEngineSecondaryText)
                    }
                }
            } else if model.isInstalled {
                HStack(spacing: 8) {
                    if isConfiguredActive {
                        let isLoading = (self.viewModel.asr.isLoadingModel || self.viewModel.asr.isDownloadingModel) && !self.viewModel.asr.isAsrReady
                        self.speechModelLanguagePicker(for: model)
                            .disabled(self.viewModel.asr.isRunning)

                        Text(isLoading ? "Loading…" : "Active")
                            .font(self.theme.typography.bodySmallStrong)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isLoading ? .orange.opacity(0.25) : Color.fluidGreen.opacity(0.25)))
                            .foregroundStyle(isLoading ? .orange : Color.fluidGreen)
                    } else {
                        Button("Activate") {
                            self.viewModel.activateSpeechModel(model)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Color.fluidGreen)
                        .fontWeight(.semibold)
                        .shadow(color: Color.fluidGreen.opacity(0.35), radius: 4, x: 0, y: 1)
                        .disabled(self.viewModel.asr.isRunning || self.viewModel.downloadingModel != nil)
                    }

                    if !model.usesAppleLogo {
                        if isSelected {
                            Button {
                                self.viewModel.deleteSpeechModel(model)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .disabled(self.viewModel.asr.isRunning || self.viewModel.downloadingModel != nil)
                            .offset(x: isSelected ? 0 : 12)
                            .opacity(isSelected ? 1 : 0)
                        }
                    }
                }
            } else {
                ZStack(alignment: .trailing) {
                    if model.requiresExternalArtifacts {
                        HStack(spacing: 8) {
                            if model.externalCoreMLSpec?.sourceURL != nil {
                                Button {
                                    self.viewModel.openExternalModelSource(for: model)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(self.voiceEngineTertiaryText)
                                .disabled(self.viewModel.asr.isRunning || self.viewModel.downloadingModel != nil)
                            }

                            Button("Download") {
                                self.viewModel.previewSpeechModel = model
                                self.viewModel.downloadSpeechModel(model)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.blue)
                            .disabled(self.viewModel.asr.isRunning || self.viewModel.downloadingModel != nil)
                        }
                        .offset(x: isSelected ? 0 : 16)
                        .opacity(isSelected ? 1 : 0)
                    } else {
                        Text("Not downloaded")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.voiceEngineTertiaryText)
                            .opacity(isSelected ? 0 : 1)

                        Button("Download") {
                            self.viewModel.previewSpeechModel = model
                            self.viewModel.downloadSpeechModel(model)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.blue)
                        .disabled(self.viewModel.asr.isRunning || self.viewModel.downloadingModel != nil)
                        .offset(x: isSelected ? 0 : 16)
                        .opacity(isSelected ? 1 : 0)
                    }
                }
                .frame(width: model.requiresExternalArtifacts ? 150 : 120, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? self.theme.palette.cardBackground.opacity(0.8) : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? self.theme.palette.cardBorder.opacity(0.6) : self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isActive ? Color.fluidGreen.opacity(0.9) : .clear, lineWidth: 2)
                )
        )
        .onTapGesture {
            self.viewModel.previewSpeechModel = model
        }
        .opacity(self.viewModel.asr.isRunning ? 0.6 : 1.0)
        .allowsHitTesting(!self.viewModel.asr.isRunning)
    }

    @ViewBuilder
    private func speechModelLanguagePicker(for model: SettingsStore.SpeechModel) -> some View {
        if model == .cohereTranscribeSixBit {
            Menu {
                ForEach(SettingsStore.CohereLanguage.allCases) { language in
                    Button {
                        guard language != self.settings.selectedCohereLanguage else { return }
                        self.settings.selectedCohereLanguage = language
                    } label: {
                        HStack {
                            Text(language.displayName)
                            if language == self.settings.selectedCohereLanguage {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                self.languageChipLabel(self.settings.selectedCohereLanguage.displayName)
            }
            .buttonStyle(.plain)
        } else if model == .nemotronOffline || model == .nemotronStreaming || model == .nemotronStreaming320 {
            self.nemotronLanguagePickerButton
        }
    }

    private func languageChipLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "globe")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.accent)
            Text(title)
                .lineLimit(1)
                .fontWeight(.semibold)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(self.voiceEngineTertiaryText)
        }
        .font(self.theme.typography.bodySmallStrong)
        .frame(minHeight: 24)
        .padding(.horizontal, 9)
        .background(
            Capsule()
                .fill(self.theme.palette.accent.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(self.theme.palette.accent.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private func speechModelSubtitle(for model: SettingsStore.SpeechModel) -> String {
        switch model {
        case .nemotronStreaming, .nemotronStreaming320:
            return "Nemotron Speech 3.5 - Streaming Capable"
        default:
            return model.displayName
        }
    }

    private var nemotronLanguagePickerButton: some View {
        Button {
            self.isShowingNemotronLanguagePicker.toggle()
        } label: {
            self.languageChipLabel(self.settings.selectedNemotronLanguage.compactDisplayName)
        }
        .buttonStyle(.plain)
        .popover(isPresented: self.$isShowingNemotronLanguagePicker, arrowEdge: .bottom) {
            self.nemotronLanguagePickerPopover
        }
    }

    private var nemotronLanguagePickerPopover: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(SettingsStore.NemotronLanguage.allCases) { language in
                    Button {
                        self.settings.selectedNemotronLanguage = language
                        self.isShowingNemotronLanguagePicker = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(language.displayName)
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 12)
                            if language == self.settings.selectedNemotronLanguage {
                                Image(systemName: "checkmark")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.theme.palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 260, height: 532)
    }

    var modelStatusView: some View {
        HStack(spacing: 12) {
            if (self.viewModel.asr.isDownloadingModel || self.viewModel.asr.isLoadingModel) && !self.viewModel.asr.isAsrReady {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).fixedSize()
                    Text(self.viewModel.asr.isLoadingModel ? "Loading model…" : "Downloading model…")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.voiceEngineSecondaryText)
                }
            } else if self.viewModel.asr.isAsrReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fluidGreen).font(self.theme.typography.bodySmall)
                Text("Ready").font(self.theme.typography.bodySmall).foregroundStyle(self.voiceEngineSecondaryText)

                Button(action: { Task { await self.viewModel.deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else if self.viewModel.asr.modelsExistOnDisk {
                Image(systemName: "doc.fill").foregroundStyle(self.theme.palette.accent).font(self.theme.typography.bodySmall)
                Text("Cached")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.voiceEngineSecondaryText)

                Button(action: { Task { await self.viewModel.deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    if self.settings.selectedSpeechModel.requiresExternalArtifacts,
                       self.settings.selectedSpeechModel.externalCoreMLSpec?.sourceURL != nil
                    {
                        Button(action: { self.viewModel.openExternalModelSource(for: self.settings.selectedSpeechModel) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                Text("Hugging Face")
                            }
                            .font(self.theme.typography.bodySmall)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(self.theme.palette.accent)
                    }

                    Button(action: { Task { await self.viewModel.downloadModels() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download")
                        }
                        .font(self.theme.typography.bodySmall)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground.opacity(0.8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)))
    }

    var fillerWordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Filler Words")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.voiceEngineTitleText)
                    Text("Automatically remove filler sounds like 'um', 'uh', 'er' from transcriptions")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.voiceEngineSecondaryText)
                }
                Spacer()
                Toggle("", isOn: self.$viewModel.removeFillerWordsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: self.viewModel.removeFillerWordsEnabled) { _, newValue in
                        self.settings.removeFillerWordsEnabled = newValue
                    }
            }

            if self.viewModel.removeFillerWordsEnabled {
                FillerWordsEditor()
            }
        }
    }

    // MARK: - Speech Model Logo View

    private func speechModelLogoView(for model: SettingsStore.SpeechModel) -> some View {
        let bgColor = self.speechModelBackgroundColor(for: model)
        let imageName = self.speechModelImageName(for: model)
        let isNvidia = model.brandName.lowercased().contains("nvidia")

        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(bgColor)

            if model.usesAppleLogo {
                Image(systemName: "apple.logo")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            } else if let imageName {
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // NVIDIA logo larger to fill more of the container
                    .frame(width: isNvidia ? 24 : 18, height: isNvidia ? 24 : 18)
            } else {
                Text(String(model.brandName.prefix(2)).uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(self.theme.palette.primaryText)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func speechModelBackgroundColor(for model: SettingsStore.SpeechModel) -> Color {
        let brand = model.brandName.lowercased()

        // Both NVIDIA and OpenAI use white/light gray bg (transparent logos)
        if brand.contains("nvidia") || brand.contains("openai") || brand.contains("whisper") {
            return Color(red: 0.97, green: 0.97, blue: 0.97)
        }
        if brand.contains("apple") || model.usesAppleLogo {
            return self.theme.palette.cardBackground.opacity(0.9)
        }
        return Color(hex: model.brandColorHex)?.opacity(0.2) ?? self.theme.palette.cardBackground
    }

    private func speechModelImageName(for model: SettingsStore.SpeechModel) -> String? {
        let brand = model.brandName.lowercased()

        if brand.contains("nvidia") {
            return "Provider_NVIDIA"
        }
        if brand.contains("cohere") {
            return "Provider_Cohere"
        }
        if brand.contains("openai") || brand.contains("whisper") {
            return "Provider_OpenAI"
        }
        return nil
    }
}

extension Notification.Name {
    static let openCustomDictionaryFromVoiceEngine = Notification.Name("OpenCustomDictionaryFromVoiceEngine")
}
