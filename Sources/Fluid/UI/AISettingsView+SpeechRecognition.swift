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
        let activeModel = self.settings.selectedSpeechModel
        let otherModels = self.viewModel.filteredSpeechModels.filter { $0 != activeModel }

        return ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundColor(self.theme.palette.accent)
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

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Click a row to preview. Press Activate to load the model.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                                .font(.caption)
                            Text("Filter: \(self.viewModel.providerFilter.rawValue)")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.primary)
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
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.primary)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Active Model")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        self.speechModelCard(for: activeModel)
                    }

                    Divider().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Other Models")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
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
            .padding(14)
        }
    }

    /// Stats panel showing speed/accuracy bars that animate when model changes
    var modelStatsPanel: some View {
        let model = self.viewModel.previewSpeechModel
        let supportsParakeetCustomWords = model == .parakeetTDT || model == .parakeetTDTv2

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.humanReadableName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(self.theme.palette.primaryText)

                            if let badge = model.badgeText {
                                Text(badge)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(badge == "FluidVoice Pick" ? .cyan.opacity(0.2) : .orange.opacity(0.2)))
                                    .foregroundColor(badge == "FluidVoice Pick" ? .cyan : .orange)
                            }

                            Spacer()
                        }

                        Text(model.cardDescription)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Label(model.downloadSize, systemImage: "internaldrive")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if model.requiresAppleSilicon {
                            Text("Apple Silicon")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(self.theme.palette.accent.opacity(0.2)))
                                .foregroundColor(self.theme.palette.accent)
                        }

                        Text(model.languageSupport)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            .foregroundColor(.secondary)

                        Spacer()
                    }

                    // Memory warning for large models
                    if let memoryWarning = model.memoryWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Text(memoryWarning)
                                .font(.caption2)
                                .foregroundColor(.orange)
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

            if supportsParakeetCustomWords {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundColor(Color.fluidGreen)

                    Text("Custom Words supported on Parakeet. Teach names, product terms, and uncommon words for better accuracy.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)

                    Spacer(minLength: 8)

                    Button("Open Custom Dictionary") {
                        NotificationCenter.default.post(name: .openCustomDictionaryFromVoiceEngine, object: nil)
                    }
                    
                    .accentColor(Color.fluidGreen)
                    
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
        let isActive = self.viewModel.isActiveSpeechModel(model)

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

            VStack(alignment: .leading, spacing: 2) {
                Text(model.humanReadableName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? self.theme.palette.primaryText : .secondary)
                Text(model.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                        Text("Speed \(Int(model.speedPercent * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "target")
                            .font(.system(size: 10))
                            .foregroundColor(Color.fluidGreen)
                        Text("Acc \(Int(model.accuracyPercent * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if isSelected && !isActive {
                        Text("Previewing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action area: Show progress if THIS model is being downloaded
            if self.viewModel.downloadingModel == model {
                // This specific model is currently being downloaded
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: self.viewModel.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Text("\(Int(self.viewModel.downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if (self.viewModel.asr.isDownloadingModel || self.viewModel.asr.isLoadingModel) && isActive && !self.viewModel.asr.isAsrReady {
                // Active model is loading/downloading (for Activate flow)
                VStack(alignment: .trailing, spacing: 4) {
                    if let progress = self.viewModel.asr.downloadProgress, self.viewModel.asr.isDownloadingModel {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 90)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                            
                        Text(self.viewModel.asr.isLoadingModel ? "Loading…" : "Downloading…")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else if model.isInstalled {
                HStack(spacing: 8) {
                    if isActive {
                        let isLoading = (self.viewModel.asr.isLoadingModel || self.viewModel.asr.isDownloadingModel) && !self.viewModel.asr.isAsrReady
                        Text(isLoading ? "Loading…" : "Active")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isLoading ? .orange.opacity(0.25) : Color.fluidGreen.opacity(0.25)))
                            .foregroundColor(isLoading ? .orange : Color.fluidGreen)
                    } else {
                        Button("Activate") {
                            self.viewModel.activateSpeechModel(model)
                        }
                        
                        
                        .accentColor(Color.fluidGreen)
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
                                    .foregroundColor(.red.opacity(0.7))
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
                    Text("Not downloaded")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .opacity(isSelected ? 0 : 1)

                    Button("Download") {
                        self.viewModel.previewSpeechModel = model
                        self.viewModel.downloadSpeechModel(model)
                    }
                    
                    
                    .accentColor(.blue)
                    .disabled(self.viewModel.asr.isRunning || self.viewModel.downloadingModel != nil)
                    .offset(x: isSelected ? 0 : 16)
                    .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 120, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    var modelStatusView: some View {
        HStack(spacing: 12) {
            if (self.viewModel.asr.isDownloadingModel || self.viewModel.asr.isLoadingModel) && !self.viewModel.asr.isAsrReady {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(self.viewModel.asr.isLoadingModel ? "Loading model…" : "Downloading…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if self.viewModel.asr.isAsrReady {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Color.fluidGreen).font(.caption)
                Text("Ready").font(.caption).foregroundColor(.secondary)

                Button(action: { Task { await self.viewModel.deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else if self.viewModel.asr.modelsExistOnDisk {
                Image(systemName: "doc.fill").foregroundColor(self.theme.palette.accent).font(.caption)
                Text("Cached").font(.caption).foregroundColor(.secondary)

                Button(action: { Task { await self.viewModel.deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { Task { await self.viewModel.downloadModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                    .font(.caption)
                }
                
                
                .accentColor(.blue)
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
                    Text("Remove Filler Words").font(.body)
                    Text("Automatically remove filler sounds like 'um', 'uh', 'er' from transcriptions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: self.$viewModel.removeFillerWordsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: self.viewModel.removeFillerWordsEnabled) { newValue in
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
                    .foregroundColor(.primary)
            } else if let imageName {
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // NVIDIA logo larger to fill more of the container
                    .frame(width: isNvidia ? 24 : 18, height: isNvidia ? 24 : 18)
            } else {
                Text(String(model.brandName.prefix(2)).uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
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
        if brand.contains("openai") || brand.contains("whisper") {
            return "Provider_OpenAI"
        }
        return nil
    }
}

extension Notification.Name {
    static let openCustomDictionaryFromVoiceEngine = Notification.Name("OpenCustomDictionaryFromVoiceEngine")
}
