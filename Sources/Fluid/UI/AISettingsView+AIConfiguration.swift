//
//  AISettingsView+AIConfiguration.swift
//  fluid
//
//  Extracted from AISettingsView.swift to keep view body under lint limit.
//

import AppKit
import SwiftUI

// MARK: - Conditional Drawing Group Modifier

/// Applies drawingGroup() only when enabled, allowing conditional GPU rasterization.
/// Used for collapsed provider cards to improve scroll performance while
/// preserving interactive elements in expanded cards.
private struct ConditionalDrawingGroup: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if self.enabled {
            content.drawingGroup()
        } else {
            content
        }
    }
}

extension AIEnhancementSettingsView {
    // MARK: - Helper Functions

    func formLabel(_ title: String) -> some View {
        Text(title)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(width: AISettingsLayout.labelWidth, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [self.theme.palette.accent.opacity(0.15), self.theme.palette.accent.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(6)
    }

    // MARK: - AI Configuration Card

    var aiConfigurationCard: some View {
        VStack(spacing: 14) {
            ThemedCard(style: .prominent, hoverEffect: false) {
                VStack(alignment: .leading, spacing: 16) {
                    self.aiSetupHeader
                    self.aiConfigurationSectionPicker

                    Group {
                        switch self.selectedConfigurationSection {
                        case .providers:
                            self.providerConfigurationContent
                        case .advancedPrompts:
                            self.promptsStepContent
                        }
                    }
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: self.selectedConfigurationSection)
                }
                .padding(16)
            }
        }
    }

    private var aiSetupHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(self.theme.palette.contentBackground.opacity(0.82))
                    .overlay(
                        LinearGradient(
                            colors: [.white.opacity(0.1), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                    )

                Image(systemName: "brain")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(self.theme.palette.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Enhancement")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("Set up providers and prompt behavior separately.")
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            Spacer()
        }
    }

    private var aiConfigurationSectionPicker: some View {
        HStack(spacing: 3) {
            ForEach(AIEnhancementConfigurationSection.allCases) { section in
                self.aiConfigurationSectionButton(section)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.78))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.24), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private func aiConfigurationSectionButton(_ section: AIEnhancementConfigurationSection) -> some View {
        let isSelected = self.selectedConfigurationSection == section
        let isHovering = self.hoveredConfigurationSection == section
        let tone = self.theme.palette.accent
        let shape = Capsule(style: .continuous)

        return Button {
            self.selectedConfigurationSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? tone : (isHovering ? self.theme.palette.primaryText : self.theme.palette.secondaryText))
            .frame(width: 176, height: 36)
            .contentShape(shape)
            .background(
                shape
                    .fill(isSelected ? tone.opacity(0.13) : (isHovering ? self.theme.palette.cardBackground.opacity(0.66) : .clear))
                    .overlay(
                        shape
                            .stroke(isSelected ? tone.opacity(0.46) : (isHovering ? self.theme.palette.cardBorder.opacity(0.36) : .clear), lineWidth: 1)
                    )
                    .shadow(color: isSelected ? tone.opacity(0.18) : .clear, radius: 8, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            self.hoveredConfigurationSection = hovering ? section : nil
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var providerConfigurationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.aiSetupSummaryBar

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Providers")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Configure local models and API providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: { self.viewModel.showHelp.toggle() }) {
                    HStack(spacing: 5) {
                        Image(systemName: self.viewModel.showHelp ? "questionmark.circle.fill" : "questionmark.circle")
                            .font(.system(size: 14))
                        Text("Help")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(self.viewModel.showHelp ? self.theme.palette.accent : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(self.viewModel.showHelp ? self.theme.palette.accent.opacity(0.12) : self.theme.palette.cardBackground.opacity(0.8))
                            .overlay(
                                Capsule()
                                    .stroke(self.viewModel.showHelp ? self.theme.palette.accent.opacity(0.3) : self.theme.palette.cardBorder.opacity(0.4), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            if self.viewModel.showHelp { self.helpSectionView }

            self.providerStepContent
        }
    }

    private var aiSetupSummaryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                self.aiSetupSummaryItem(icon: "cpu", text: "Local models run on Mac")
                self.aiSetupSummaryDivider
                self.aiSetupSummaryItem(icon: "cloud", text: "Cloud models use provider APIs")
                self.aiSetupSummaryDivider
                self.aiSetupSummaryItem(icon: "keyboard", text: "Shortcuts choose when prompts run")
            }

            VStack(alignment: .leading, spacing: 7) {
                self.aiSetupSummaryItem(icon: "cpu", text: "Local models run on Mac")
                self.aiSetupSummaryItem(icon: "cloud", text: "Cloud models use provider APIs")
                self.aiSetupSummaryItem(icon: "keyboard", text: "Shortcuts choose when prompts run")
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiSetupSummaryDivider: some View {
        Rectangle()
            .fill(self.theme.palette.separator.opacity(0.45))
            .frame(width: 1, height: 14)
    }

    private func aiSetupSummaryItem(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent.opacity(0.95))
                .frame(width: 14)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(self.theme.palette.secondaryText)
                .lineLimit(1)
        }
    }

    var apiKeyWarningView: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            Text("API key required for AI enhancement to work")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 4)
    }

    var helpSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.yellow)
                Text("Quick Start Guide")
                    .font(.system(size: 13, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                self.helpStep("1", "Choose a provider", "building.2")
                self.helpStep("2", "Add an API key if needed", "key")
                self.helpStep("3", "Pick the model you want", "cpu")
                self.helpStep("4", "Verify the connection", "checkmark.shield")
                self.helpStep("5", "Set Dictate to Off, Default, or a custom prompt", "text.bubble")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.accent.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.2), lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    func helpStep(_ number: String, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.15))
                    .frame(width: 22, height: 22)
                Text(number)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(self.theme.palette.accent)
            }
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    var providerStepContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.verifiedProvidersSection

            self.allProvidersSection

            if self.viewModel.showingEditProvider,
               self.viewModel.selectedProviderID != PrivateAIProviderFeature.shared.providerID
            {
                self.editProviderSection
            }
        }
        .padding(.top, 4)
    }

    private var allProvidersSection: some View {
        let query = self.providerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = self.unverifiedProviderItems
        let filteredItems = query.isEmpty
            ? items
            : items.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.id.localizedCaseInsensitiveContains(query)
            }
        let count = filteredItems.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text("All providers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text("(\(count))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search providers", text: self.$providerSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                    )
            )

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredItems) { item in
                            self.providerCard(item)
                                .id(item.id)
                        }
                        if filteredItems.isEmpty, !query.isEmpty {
                            Text("No providers match \"\(query)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        self.customProviderButton
                            .id("custom-provider")
                    }
                    .padding(4)
                }
                .onChange(of: self.expandedProviderID) { _, newID in
                    if let id = newID {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
            .padding(8)
            .background(self.theme.palette.contentBackground.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var verifiedProvidersSection: some View {
        let verified = self.verifiedProviderItems
        let count = verified.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.fluidGreen)
                Text("Verified providers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text("(\(count))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }

            if verified.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No verified providers yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Set up a provider below and verify its connection")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(self.theme.palette.contentBackground.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                        )
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(verified) { item in
                        self.verifiedProviderRow(item)
                    }
                }
            }
        }
    }

    private struct ProviderItem: Identifiable, Hashable {
        let id: String
        let name: String
        let isBuiltIn: Bool
    }

    private struct PrivateAIProviderModelStatus {
        let detail: String
        let color: Color
    }

    // Use cached provider items from ViewModel for scroll performance
    private var verifiedProviderItems: [ProviderItem] {
        self.viewModel.cachedVerifiedProviderItems.map {
            ProviderItem(id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn)
        }
    }

    private var unverifiedProviderItems: [ProviderItem] {
        self.viewModel.cachedUnverifiedProviderItems.map {
            ProviderItem(id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn)
        }
    }

    /// Shared companion button for provider picker rows — identical size/style everywhere.
    /// Uses a fixed square frame so icon-only buttons don't get horizontal padding from CompactButtonStyle.
    @ViewBuilder
    func companionIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: AISettingsLayout.providerRowControlHeight, height: AISettingsLayout.providerRowControlHeight)
        }
        .buttonStyle(SquareIconButtonStyle())
        .help(help)
    }

    /// Shared companion button with loading state — for refresh buttons.
    @ViewBuilder
    func companionIconButton(
        isRefreshing: Bool,
        disabled: Bool = false,
        opacity: Double = 1,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: AISettingsLayout.providerRowControlHeight, height: AISettingsLayout.providerRowControlHeight)
        }
        .buttonStyle(SquareIconButtonStyle())
        .disabled(disabled)
        .opacity(opacity)
        .help(help)
    }

    private func providerCard(_ item: ProviderItem) -> some View {
        let isAppleDisabled = item.id == "apple-intelligence-disabled"
        let isPrivateAIProvider = item.id == PrivateAIProviderFeature.shared.providerID
        let isComingSoon = isAppleDisabled
        let isExpanded = self.expandedProviderID == item.id && !isAppleDisabled
        let status = self.providerStatus(for: item)
        let borderColor = isExpanded
            ? self.theme.palette.accent.opacity(0.5)
            : self.theme.palette.cardBorder.opacity(0.3)
        let statusView = HStack(spacing: 5) {
            if !status.icon.isEmpty {
                Image(systemName: status.icon)
                    .font(.system(size: 10))
            }
            Text(status.text)
        }
        .font(.caption2)
        .foregroundStyle(status.color)

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { if !isComingSoon { self.toggleProviderExpansion(item.id) } }) {
                HStack(alignment: .center, spacing: 10) {
                    self.providerLogoView(for: item)
                        .frame(width: 34, height: 34)

                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isComingSoon ? self.theme.palette.accent : self.theme.palette.primaryText)

                        statusView
                    }

                    Spacer()

                    if !isComingSoon {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isComingSoon)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !isExpanded,
               self.viewModel.connectionStatus(for: item.id) == .failed,
               !self.viewModel.connectionErrorMessage(for: item.id).isEmpty
            {
                self.providerErrorPreview(self.viewModel.connectionErrorMessage(for: item.id), lineLimit: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if isExpanded {
                Divider()
                    .background(self.theme.palette.separator.opacity(0.5))
                    .padding(.horizontal, 14)

                if isPrivateAIProvider {
                    self.privateAIRuntimeSection
                        .padding(14)
                        .padding(.top, 4)
                } else {
                    self.providerDetailsSection(for: item)
                        .padding(14)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isExpanded ? self.theme.palette.elevatedCardBackground : self.theme.palette.cardBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: isExpanded ? 1.5 : 1)
        )
    }

    private func providerStatus(for item: ProviderItem) -> (text: String, color: Color, icon: String) {
        if item.id == "apple-intelligence-disabled" {
            return ("Unavailable", .secondary, "lock.slash")
        }
        if item.id == "apple-intelligence" {
            return ("On-device", .secondary, "lock.shield")
        }
        switch self.viewModel.connectionStatus(for: item.id) {
        case .success:
            return ("Connection verified", Color.fluidGreen, "checkmark.circle.fill")
        case .failed:
            return ("Connection failed", .red, "exclamationmark.circle.fill")
        case .testing:
            return ("Verifying...", self.theme.palette.accent, "arrow.triangle.2.circlepath")
        case .unknown:
            return ("Connection not tested", .orange, "exclamationmark.circle.fill")
        }
    }

    private var isComingSoonProvider: (ProviderItem) -> Bool {
        { $0.id == "apple-intelligence-disabled" }
    }

    private func toggleProviderExpansion(_ providerID: String) {
        if self.expandedProviderID == providerID {
            self.expandedProviderID = nil
            self.viewModel.clearEditProviderDraft()
            self.viewModel.setEditingAPIKey(false, for: providerID)
        } else {
            self.expandedProviderID = providerID
            self.selectProvider(providerID)
        }
    }

    private var privateAIRuntimeSection: some View {
        let model = self.selectedPrivateAIModel
        let status = self.privateAIModelStatus(for: model)
        let isInstalled = PrivateAIIntegrationService.isModelInstalled(model)
        let isDownloading = self.privateAILoadState.isDownloading(model.id)
        let downloadProgress = self.privateAILoadState.downloadProgress(for: model.id)
        let isLoading = self.privateAILoadState.isLoading(model.id)
        let isLoaded = self.privateAILoadState.isLoaded(model.id)
        let hasLoadFailure = self.privateAILoadState.failureMessage(for: model.id) != nil
        let isVerified = self.isPrivateAIModelVerified(model)
        let isTesting = self.viewModel.isTestingConnection && self.viewModel.selectedProviderID == PrivateAIProviderFeature.shared.providerID
        let isBusy = isDownloading || isLoading || isTesting
        let canVerify = isInstalled && (!isVerified || hasLoadFailure) && !self.privateAISelectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                SearchableModelPicker(
                    models: PrivateAIModelRegistry.modelIDs(),
                    selectedModel: self.privateAIModelBinding,
                    selectionEnabled: !isBusy,
                    controlWidth: 180,
                    controlHeight: AISettingsLayout.providerRowControlHeight
                )

                self.companionIconButton(systemName: "folder", help: "Open downloaded model folder") {
                    self.revealPrivateAIModelFolder()
                }
            }

            if isDownloading || isLoading || isLoaded || hasLoadFailure || isVerified || !isInstalled {
                self.privateAIModelStatusRow(
                    status: status,
                    progress: downloadProgress,
                    isDownloading: isDownloading,
                    showsLoadingIndicator: isLoading
                )
            }

            self.privateAIPrefixCacheRow(isBusy: isBusy)
            self.privateAIBoostRow(isBusy: isBusy)

            if self.viewModel.connectionStatus(for: PrivateAIProviderFeature.shared.providerID) == .failed,
               !self.viewModel.connectionErrorMessage.isEmpty
            {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(self.viewModel.connectionErrorMessage)
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.1))
                )
            }

            if !isInstalled {
                if model.canDownload {
                    Button(action: { self.downloadPrivateAIModel(model) }) {
                        HStack(spacing: 6) {
                            if isDownloading {
                                ProgressView()
                                    .controlSize(.mini)
                                    .fixedSize()
                            }
                            Text(isDownloading ? Self.downloadButtonText(progress: downloadProgress) : "Download & Verify")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .fluidButton(.accent, size: .small)
                    .disabled(isBusy)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("Install the selected model to enable verification")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            } else if canVerify {
                Button(action: { self.verifyPrivateAIConnection(model) }) {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.mini)
                                .fixedSize()
                        }
                        Text(isTesting ? "Loading..." : "Verify")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .fluidButton(.accent, size: .small)
                .disabled(isBusy)
            }
        }
    }

    private func privateAIPrefixCacheRow(isBusy: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Faster first result")
                .font(.caption)
                .frame(width: 124, alignment: .leading)

            Toggle("", isOn: self.privateAIPrefixCacheBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(isBusy)
                .help("Keeps Fluid-1 ready so your first dictation finishes sooner.")
                .accessibilityLabel("Faster first result")

            Spacer(minLength: 0)
        }
    }

    private func privateAIBoostRow(isBusy: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Faster results")
                .font(.caption)
                .frame(width: 124, alignment: .leading)

            Toggle("", isOn: self.privateAIBoostBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(isBusy)
                .help("Uses extra local acceleration so Fluid-1 finishes faster.")
                .accessibilityLabel("Faster results")

            Text("Finishes dictation up to 15% faster. Uses about 100 MB more memory.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private func privateAIModelStatusRow(
        status: PrivateAIProviderModelStatus,
        progress: PrivateAIModelDownloadProgress?,
        isDownloading: Bool,
        showsLoadingIndicator: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if showsLoadingIndicator, !isDownloading {
                    ProgressView()
                        .controlSize(.mini)
                        .fixedSize()
                }

                Text(status.detail)
                    .font(.caption)
                    .lineLimit(2)
            }

            if isDownloading {
                self.privateAIDownloadProgressBar(progress: progress, color: status.color)

                Text(Self.downloadProgressText(progress))
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(status.color)
    }

    @ViewBuilder
    private func privateAIDownloadProgressBar(
        progress: PrivateAIModelDownloadProgress?,
        color: Color
    ) -> some View {
        if let fractionCompleted = progress?.fractionCompleted {
            ProgressView(value: fractionCompleted)
                .controlSize(.mini)
                .frame(maxWidth: 260)
                .tint(color)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(maxWidth: 260)
                .tint(color)
        }
    }

    private var privateAIPrefixCacheBinding: Binding<Bool> {
        Binding(
            get: { self.settings.privateAIPrefixKVCacheEnabled },
            set: { enabled in
                guard self.settings.privateAIPrefixKVCacheEnabled != enabled else { return }
                self.settings.privateAIPrefixKVCacheEnabled = enabled
                self.privateAILoadState = .idle
                Task { @MainActor in
                    await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                        reason: enabled ? "prefix cache enabled" : "prefix cache disabled"
                    )
                    self.viewModel.refreshProviderItems()
                }
            }
        )
    }

    private var privateAIBoostBinding: Binding<Bool> {
        Binding(
            get: { self.settings.privateAIBoostEnabled },
            set: { enabled in
                guard self.settings.privateAIBoostEnabled != enabled else { return }
                self.settings.privateAIBoostEnabled = enabled
                self.privateAILoadState = .idle
                Task { @MainActor in
                    await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                        reason: enabled ? "Fluid-1 Boost enabled" : "Fluid-1 Boost disabled"
                    )
                    self.viewModel.refreshProviderItems()
                }
            }
        )
    }

    private var privateAIContextTokenLimitBinding: Binding<Int> {
        Binding(
            get: { self.settings.privateAIContextTokenLimit },
            set: { value in
                let clamped = SettingsStore.clampPrivateAIContextTokenLimit(value)
                guard self.settings.privateAIContextTokenLimit != clamped else { return }
                self.settings.privateAIContextTokenLimit = clamped
                self.privateAILoadState = .idle
                Task { @MainActor in
                    await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                        reason: "Fluid Intelligence context changed"
                    )
                    self.viewModel.refreshProviderItems()
                }
            }
        )
    }

    private var privateAIModelBinding: Binding<String> {
        Binding(
            get: { self.privateAISelectedModelID },
            set: { self.persistPrivateAIModelSelection($0) }
        )
    }

    private func refreshPrivateAIProviderModels() {
        let providerKey = self.viewModel.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let models = PrivateAIModelRegistry.modelIDs()
        let selected = PrivateAIModelRegistry.canonicalModelID(for: self.privateAISelectedModelID) ?? PrivateAIModelRegistry.defaultModel.id

        self.privateAISelectedModelID = selected
        self.viewModel.availableModelsByProvider[providerKey] = models
        self.viewModel.selectedModelByProvider[providerKey] = selected
        self.viewModel.settings.availableModelsByProvider = self.viewModel.availableModelsByProvider
        self.viewModel.settings.selectedModelByProvider = self.viewModel.selectedModelByProvider

        if self.viewModel.selectedProviderID == PrivateAIProviderFeature.shared.providerID {
            self.viewModel.availableModels = models
            self.viewModel.selectedModel = selected
        }

        self.refreshPrivateAILoadState()
        self.viewModel.refreshProviderItems()
    }

    private func downloadPrivateAIModel(_ model: PrivateAIRegisteredModel) {
        guard model.canDownload else {
            self.privateAILoadState = .failed(modelID: model.id, message: "Download URL is not configured yet.")
            return
        }

        guard !self.privateAILoadState.isDownloading(model.id) else { return }

        self.privateAILoadState = .downloading(
            modelID: model.id,
            progress: PrivateAIModelDownloadProgress(initialExpectedBytes: model.artifact.byteCount)
        )
        Task { @MainActor in
            do {
                DebugLogger.shared.info(
                    "Private provider download button pressed model=\(model.id)",
                    source: "AISettingsView"
                )
                _ = try await PrivateAIIntegrationService.prepareModel(model) { progress in
                    await MainActor.run {
                        guard self.privateAISelectedModelID == model.id else { return }
                        self.privateAILoadState = .downloading(
                            modelID: model.id,
                            progress: progress.withFallbackExpectedBytes(model.artifact.byteCount)
                        )
                    }
                }
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .loading(modelID: model.id)
                let start = ContinuousClock.now
                let verified = await self.viewModel.verifyPrivateAIProvider(model: model)
                let latencyMilliseconds = Self.elapsedMilliseconds(since: start)
                guard self.privateAISelectedModelID == model.id else { return }
                if verified {
                    self.privateAILoadState = .loaded(modelID: model.id, latencyMilliseconds: latencyMilliseconds)
                } else {
                    let message = self.viewModel.connectionErrorMessage.isEmpty
                        ? "Model downloaded, but verification failed."
                        : self.viewModel.connectionErrorMessage
                    self.privateAILoadState = .failed(modelID: model.id, message: message)
                }
            } catch {
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .failed(
                    modelID: model.id,
                    message: Self.errorMessage(for: error)
                )
            }
            self.viewModel.refreshProviderItems()
        }
    }

    private func verifyPrivateAIConnection(_ model: PrivateAIRegisteredModel) {
        self.privateAILoadState = .loading(modelID: model.id)
        Task { @MainActor in
            let start = ContinuousClock.now
            let verified = await self.viewModel.verifyPrivateAIProvider(model: model)
            let latencyMilliseconds = Self.elapsedMilliseconds(since: start)
            guard self.privateAISelectedModelID == model.id else { return }
            if verified {
                self.privateAILoadState = .loaded(modelID: model.id, latencyMilliseconds: latencyMilliseconds)
            } else {
                let message = self.viewModel.connectionErrorMessage.isEmpty
                    ? "Model verification failed."
                    : self.viewModel.connectionErrorMessage
                self.privateAILoadState = .failed(modelID: model.id, message: message)
            }
            self.viewModel.refreshProviderItems()
        }
    }

    private var selectedPrivateAIModel: PrivateAIRegisteredModel {
        PrivateAIModelRegistry.model(id: self.privateAISelectedModelID) ?? PrivateAIModelRegistry.defaultModel
    }

    private func isPrivateAIModelVerified(_ model: PrivateAIRegisteredModel) -> Bool {
        guard PrivateAIIntegrationService.isModelInstalled(model) else { return false }
        let key = self.viewModel.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        return self.viewModel.settings.verifiedProviderFingerprints[key] == PrivateAIProviderFeature.verificationFingerprint(for: model.id)
    }

    private func privateAIModelStatus(
        for model: PrivateAIRegisteredModel
    ) -> PrivateAIProviderModelStatus {
        if self.privateAILoadState.isDownloading(model.id) {
            return PrivateAIProviderModelStatus(
                detail: "Downloading model.",
                color: self.theme.palette.accent
            )
        }

        if self.privateAILoadState.isLoading(model.id) {
            return PrivateAIProviderModelStatus(
                detail: "Loading...",
                color: self.theme.palette.accent
            )
        }

        if self.privateAILoadState.isLoaded(model.id) {
            return PrivateAIProviderModelStatus(
                detail: "For dictation only.",
                color: Color.fluidGreen
            )
        }

        if let message = self.privateAILoadState.failureMessage(for: model.id) {
            return PrivateAIProviderModelStatus(
                detail: message,
                color: .red
            )
        }

        if self.isPrivateAIModelVerified(model) {
            return PrivateAIProviderModelStatus(
                detail: "For dictation only.",
                color: Color.fluidGreen
            )
        }

        if PrivateAIIntegrationService.isModelInstalled(model) {
            return PrivateAIProviderModelStatus(
                detail: "Ready to verify.",
                color: Color.fluidGreen
            )
        }

        if PrivateAIIntegrationService.isLocalRuntimeConfigured {
            return PrivateAIProviderModelStatus(
                detail: "Local model configured.",
                color: Color.fluidGreen
            )
        }

        if model.canDownload {
            return PrivateAIProviderModelStatus(
                detail: "Model not downloaded.",
                color: self.theme.palette.accent
            )
        }

        return PrivateAIProviderModelStatus(
            detail: "Model unavailable.",
            color: .orange
        )
    }

    private func revealPrivateAIModelFolder() {
        let directoryURL = PrivateAIIntegrationService.modelDirectoryURL
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directoryURL)
        } catch {
            DebugLogger.shared.error(
                "Failed to open Private AI Provider models folder: \(error.localizedDescription)",
                source: "AISettingsView"
            )
        }
    }

    func refreshPrivateAILoadState() {
        Task { @MainActor in
            guard let loaded = await PrivateAIIntegrationService.shared.loadedModelState(),
                  loaded.state == .ready
            else {
                self.privateAILoadState = .idle
                return
            }

            self.privateAILoadState = .loaded(modelID: loaded.modelID, latencyMilliseconds: nil)
        }
    }

    private func loadPrivateAIModel(_ model: PrivateAIRegisteredModel) {
        guard PrivateAIIntegrationService.isModelInstalled(model) else {
            self.privateAILoadState = .failed(modelID: model.id, message: "Model file is not installed.")
            return
        }

        self.privateAILoadState = .loading(modelID: model.id)
        Task { @MainActor in
            do {
                let start = ContinuousClock.now
                let status = try await PrivateAIIntegrationService.shared.loadModel(model)
                let latencyMilliseconds = Self.elapsedMilliseconds(since: start)
                guard self.privateAISelectedModelID == model.id else { return }
                switch status.state {
                case .ready:
                    self.privateAILoadState = .loaded(modelID: model.id, latencyMilliseconds: latencyMilliseconds)
                default:
                    self.privateAILoadState = .failed(
                        modelID: model.id,
                        message: status.message ?? "Model did not report ready."
                    )
                }
            } catch {
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .failed(
                    modelID: model.id,
                    message: Self.errorMessage(for: error)
                )
            }
            self.viewModel.refreshProviderItems()
        }
    }

    private func resetPrivateAIVerification(for model: PrivateAIRegisteredModel) {
        self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)
        self.privateAILoadState = .idle
        Task { @MainActor in
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "Fluid Intelligence verification reset")
            if PrivateAIIntegrationService.isModelInstalled(model) {
                self.privateAILoadState = .idle
            }
            self.viewModel.refreshProviderItems()
        }
    }

    private func deletePrivateAIModel(_ model: PrivateAIRegisteredModel) {
        guard PrivateAIIntegrationService.canRemoveInstalledModel(model) else { return }
        self.privateAILoadState = .loading(modelID: model.id)
        Task { @MainActor in
            do {
                try await PrivateAIIntegrationService.shared.unloadAndRemoveInstalledModel(
                    model,
                    reason: "settings-delete"
                )
                self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)
                if self.privateAISelectedModelID == model.id {
                    self.privateAILoadState = .idle
                }
                self.viewModel.refreshProviderItems()
            } catch {
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .failed(modelID: model.id, message: Self.errorMessage(for: error))
            }
        }
    }

    private static func errorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return String(describing: error)
    }

    private static func downloadButtonText(progress: PrivateAIModelDownloadProgress?) -> String {
        PrivateAIModelDownloadProgressText.buttonTitle(for: progress)
    }

    private static func downloadProgressText(_ progress: PrivateAIModelDownloadProgress?) -> String {
        PrivateAIModelDownloadProgressText.detailText(for: progress)
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func persistPrivateAIModelSelection(_ value: String) {
        let model = PrivateAIModelRegistry.model(id: value) ?? PrivateAIModelRegistry.defaultModel
        let providerKey = self.viewModel.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let models = PrivateAIModelRegistry.modelIDs()

        self.privateAISelectedModelID = model.id
        UserDefaults.standard.set(model.id, forKey: PrivateAIIntegrationService.selectedModelDefaultsKey)
        UserDefaults.standard.removeObject(forKey: PrivateAIIntegrationService.localModelPathDefaultsKey)

        self.viewModel.availableModelsByProvider[providerKey] = models
        self.viewModel.selectedModelByProvider[providerKey] = model.id
        self.viewModel.settings.availableModelsByProvider = self.viewModel.availableModelsByProvider
        self.viewModel.settings.selectedModelByProvider = self.viewModel.selectedModelByProvider

        if self.viewModel.selectedProviderID == PrivateAIProviderFeature.shared.providerID {
            self.viewModel.availableModels = models
            self.viewModel.selectedModel = model.id
        }
        self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)
        self.viewModel.refreshProviderItems()
        if PrivateAIIntegrationService.isModelInstalled(model) {
            self.loadPrivateAIModel(model)
        } else {
            self.privateAILoadState = .idle
        }
    }

    private func providerDetailsSection(for item: ProviderItem) -> AnyView {
        let isAppleDisabled = item.id == "apple-intelligence-disabled"
        let isApple = item.id == "apple-intelligence"
        let providerKey = self.viewModel.providerKey(for: item.id)
        if isAppleDisabled {
            return AnyView(
                HStack(spacing: 10) {
                    Image(systemName: "lock.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("Apple Intelligence is unavailable on this device. Enable it in System Settings → Apple Intelligence & Siri.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.theme.palette.contentBackground.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                        )
                )
            )
        }
        let isCustom = !ModelRepository.shared.isBuiltIn(item.id)
        let baseURL = self.viewModel.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.viewModel.isLocalEndpoint(baseURL)
        let apiKeyValue = self.viewModel.providerAPIKey(for: item.id)
        let hasAPIKey = !apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let models = self.viewModel.availableModelsByProvider[providerKey] ?? []
        let hasModels = !models.isEmpty
        let isRefreshing = self.viewModel.isFetchingModels && self.viewModel.selectedProviderID == item.id
        let hasName = isCustom ? !(self.viewModel.savedProviders.first { $0.id == item.id }?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true
        let canFetchModels = hasName && (isLocal ? !baseURL.isEmpty : (hasAPIKey && !baseURL.isEmpty))
        let canVerify = hasModels && !self.viewModel.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canFetchModels
        let isVerified = self.viewModel.connectionStatus(for: item.id) == .success
        let apiKeyBinding = Binding(
            get: { self.viewModel.providerAPIKey(for: item.id) },
            set: { self.viewModel.updateProviderAPIKey($0, for: item.id, persistEmptyValue: true) }
        )
        let nameBinding = Binding(
            get: { self.viewModel.savedProviders.first(where: { $0.id == item.id })?.name ?? "" },
            set: { newValue in
                self.viewModel.updateCustomProviderName(newValue, for: item.id)
            }
        )
        let baseURLBinding = Binding(
            get: { self.viewModel.savedProviders.first(where: { $0.id == item.id })?.baseURL ?? self.viewModel.openAIBaseURL },
            set: { newValue in
                self.viewModel.updateCustomProviderBaseURL(newValue, for: item.id)
            }
        )

        return AnyView(VStack(alignment: .leading, spacing: 10) {
            if isApple {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.fluidGreen)
                        Text("Apple Intelligence runs on-device and does not require an API key.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Text("Output quality can be poor and inconsistent. Use it at your discretion.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.fluidGreen.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.fluidGreen.opacity(0.2), lineWidth: 1)
                        )
                )
                if !isVerified {
                    Button("Verify") {
                        self.viewModel.verifyAppleIntelligence()
                    }
                    .fluidButton(.glass, size: .compact)
                }
            } else {
                if isCustom {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "textformat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Provider Name")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        TextField("Custom Provider", text: nameBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Base URL")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        TextField("https://api.yourprovider.com/v1", text: baseURLBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 8) {
                        SecureField("Enter API key", text: apiKeyBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .frame(maxWidth: 200)
                            .onTapGesture {
                                self.viewModel.ensureKeychainAccessForAPIKeyEdit()
                            }
                        if let websiteInfo = ModelRepository.shared.providerWebsiteURL(for: item.id),
                           let url = URL(string: websiteInfo.url)
                        {
                            Button(action: { NSWorkspace.shared.open(url) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: websiteInfo.label.contains("Guide") ? "book.fill" : "key.fill")
                                        .font(.system(size: 10))
                                    Text(websiteInfo.label)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(self.theme.palette.accent)
                                )
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)

                    SearchableModelPicker(
                        models: models,
                        selectedModel: self.modelBinding(for: item.id),
                        selectionEnabled: hasModels,
                        controlWidth: 180,
                        controlHeight: AISettingsLayout.providerRowControlHeight
                    )

                    self.companionIconButton(
                        isRefreshing: isRefreshing,
                        disabled: isRefreshing || !canFetchModels,
                        opacity: canFetchModels ? 1 : 0.45,
                        help: "Refresh model list"
                    ) {
                        self.activateProvider(item.id)
                        Task { await self.viewModel.fetchModelsForCurrentProvider() }
                    }
                }

                HStack(spacing: 8) {
                    Color.clear
                        .frame(width: 50, alignment: .leading)
                    self.reasoningButton(for: item.id)
                }

                if self.viewModel.showingReasoningConfig && self.viewModel.selectedProviderID == item.id {
                    self.reasoningConfigSection
                }

                if self.viewModel.connectionStatus(for: item.id) == .failed,
                   !self.viewModel.connectionErrorMessage(for: item.id).isEmpty
                {
                    self.providerErrorPreview(self.viewModel.connectionErrorMessage(for: item.id), lineLimit: 8)
                }

                if let error = self.viewModel.fetchModelsError, !error.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                    }
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.1))
                    )
                }

                if canVerify {
                    Button(action: {
                        Task { await self.viewModel.testAPIConnection() }
                    }) {
                        HStack(spacing: 6) {
                            if self.viewModel.isTestingConnection {
                                ProgressView()
                                    .controlSize(.mini)
                                    .fixedSize()
                            } else {
                                Image(systemName: "checkmark.shield")
                                    .font(.system(size: 12))
                            }
                            Text(self.viewModel.isTestingConnection ? "Verifying..." : "Verify Connection")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .fluidButton(.accent, size: .small)
                    .disabled(self.viewModel.isTestingConnection)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text(hasModels ? "Select a model to enable verification" : "Refresh models to enable verification")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if isCustom {
                    Divider()
                        .background(self.theme.palette.separator.opacity(0.5))

                    Button(role: .destructive) {
                        self.viewModel.deleteCurrentProvider()
                        self.expandedProviderID = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Delete Provider")
                        }
                        .font(.caption)
                    }
                    .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.6))
                }
            }
        })
    }

    private func providerErrorPreview(_ message: String, lineLimit: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red.opacity(0.9))
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
    }

    private var customProviderButton: some View {
        Button(action: { self.startCustomProvider() }) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.theme.palette.accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
                        )

                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(self.theme.palette.accent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Custom Provider")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("OpenAI-compatible endpoint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(self.theme.palette.cardBackground.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(self.theme.palette.accent.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func startCustomProvider() {
        let name = self.uniqueCustomProviderName()
        if let providerID = self.viewModel.createDraftProvider(named: name) {
            self.expandedProviderID = providerID
        }
    }

    private func uniqueCustomProviderName() -> String {
        let base = "Custom Provider"
        let existing = Set(self.viewModel.savedProviders.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func verifiedProviderRow(_ item: ProviderItem) -> some View {
        let providerKey = self.viewModel.providerKey(for: item.id)
        let models = self.viewModel.availableModelsByProvider[providerKey] ?? []
        let isSelected = item.id == self.viewModel.selectedProviderID
        let isPrivateAIProvider = item.id == PrivateAIProviderFeature.shared.providerID
        let fluidModel = self.selectedPrivateAIModel
        let fluidStatus = self.privateAIModelStatus(for: fluidModel)
        let isFluidInstalled = PrivateAIIntegrationService.isModelInstalled(fluidModel)
        let isFluidDownloading = self.privateAILoadState.isDownloading(fluidModel.id)
        let fluidDownloadProgress = self.privateAILoadState.downloadProgress(for: fluidModel.id)
        let isFluidLoading = self.privateAILoadState.isLoading(fluidModel.id)
        let isFluidLoaded = self.privateAILoadState.isLoaded(fluidModel.id)
        let hasFluidLoadFailure = self.privateAILoadState.failureMessage(for: fluidModel.id) != nil
        let isFluidVerified = self.isPrivateAIModelVerified(fluidModel)
        let isFluidTesting = self.viewModel.isTestingConnection && self.viewModel.selectedProviderID == PrivateAIProviderFeature.shared.providerID
        let isFluidBusy = isFluidDownloading || isFluidLoading || isFluidTesting
        let isRefreshing = self.viewModel.isFetchingModels && self.viewModel.selectedProviderID == item.id
        let baseURL = self.providerBaseURL(for: item).trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.viewModel.isLocalEndpoint(baseURL)
        let apiKeyValue = self.viewModel.providerAPIKey(for: item.id)
        let hasAPIKey = !apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canFetchModels = isLocal ? !baseURL.isEmpty : (hasAPIKey && !baseURL.isEmpty)
        let hasModels = !models.isEmpty
        let isEditing = self.viewModel.showingEditProvider && self.viewModel.selectedProviderID == item.id
        let iconColumnWidth = AISettingsLayout.providerRowControlHeight
        let actionColumnWidth: CGFloat = 76

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                self.providerLogoView(for: item)
                    .frame(width: 36, height: 36)

                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)

                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.fluidGreen)

                    if isSelected {
                        Text("Active")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.fluidGreen.opacity(0.2)))
                            .foregroundStyle(Color.fluidGreen)
                    }
                }

                Spacer()

                // Fixed action grid: companion icon, optional reasoning, primary action.
                HStack(spacing: 8) {
                    if isPrivateAIProvider {
                        SearchableModelPicker(
                            models: PrivateAIModelRegistry.modelIDs(),
                            selectedModel: self.privateAIModelBinding,
                            selectionEnabled: !isFluidBusy,
                            controlWidth: 180,
                            controlHeight: AISettingsLayout.providerRowControlHeight
                        )

                        self.companionIconButton(systemName: "folder", help: "Open downloaded model folder") {
                            self.revealPrivateAIModelFolder()
                        }
                        .frame(width: iconColumnWidth, height: AISettingsLayout.providerRowControlHeight)

                        Color.clear
                            .frame(width: iconColumnWidth, height: AISettingsLayout.providerRowControlHeight)

                        Button(action: {
                            self.activateProvider(item.id)
                            if isEditing {
                                self.viewModel.clearEditProviderDraft()
                            } else {
                                self.viewModel.startEditingProvider()
                            }
                        }) {
                            Text("Edit")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: actionColumnWidth, height: AISettingsLayout.providerRowControlHeight)
                        }
                        .buttonStyle(SquareIconButtonStyle())
                        .frame(width: actionColumnWidth, height: AISettingsLayout.providerRowControlHeight)
                        .help("Edit provider")
                    } else {
                        SearchableModelPicker(
                            models: models,
                            selectedModel: self.modelBinding(for: item.id),
                            selectionEnabled: hasModels,
                            controlWidth: 180,
                            controlHeight: AISettingsLayout.providerRowControlHeight
                        )

                        self.companionIconButton(
                            isRefreshing: isRefreshing,
                            disabled: isRefreshing || !canFetchModels,
                            opacity: canFetchModels ? 1 : 0.45,
                            help: "Refresh model list"
                        ) {
                            self.activateProvider(item.id)
                            Task { await self.viewModel.fetchModelsForCurrentProvider() }
                        }
                        .frame(width: iconColumnWidth, height: AISettingsLayout.providerRowControlHeight)

                        self.reasoningButton(for: item.id)
                            .frame(width: iconColumnWidth, height: AISettingsLayout.providerRowControlHeight)

                        Button(action: {
                            self.activateProvider(item.id)
                            if isEditing {
                                self.viewModel.clearEditProviderDraft()
                                self.viewModel.setEditingAPIKey(false, for: item.id)
                            } else {
                                self.viewModel.startEditingProvider()
                                self.viewModel.setEditingAPIKey(true, for: item.id)
                            }
                        }) {
                            Text("Edit")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: actionColumnWidth, height: AISettingsLayout.providerRowControlHeight)
                        }
                        .buttonStyle(SquareIconButtonStyle())
                        .frame(width: actionColumnWidth, height: AISettingsLayout.providerRowControlHeight)
                        .help("Edit provider")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if isPrivateAIProvider, isFluidDownloading || isFluidLoading || isFluidLoaded || hasFluidLoadFailure || isFluidVerified || !isFluidInstalled {
                self.privateAIModelStatusRow(
                    status: fluidStatus,
                    progress: fluidDownloadProgress,
                    isDownloading: isFluidDownloading,
                    showsLoadingIndicator: isFluidLoading || isFluidTesting
                )
                .padding(.top, 8)
            }

            if isPrivateAIProvider, isEditing {
                Divider()
                    .background(self.theme.palette.separator.opacity(0.5))
                    .padding(.vertical, 10)

                self.privateAIEditProviderSection(
                    model: fluidModel,
                    isInstalled: isFluidInstalled,
                    isBusy: isFluidBusy,
                    isVerified: isFluidVerified
                )
            } else if !isPrivateAIProvider, isEditing {
                Divider()
                    .background(self.theme.palette.separator.opacity(0.5))
                    .padding(.vertical, 10)

                self.editProviderSection
            }

            if !isPrivateAIProvider,
               self.viewModel.showingReasoningConfig,
               self.viewModel.selectedProviderID == item.id
            {
                Divider()
                    .background(self.theme.palette.separator.opacity(0.5))
                    .padding(.vertical, 10)

                self.reasoningConfigSection
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 0.8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.fluidGreen.opacity(0.9) : .clear, lineWidth: 2)
        )
        // Verified rows always have interactive elements, don't use drawingGroup
        .contentShape(Rectangle())
        .onTapGesture {
            self.activateProvider(item.id)
            self.expandedProviderID = nil
        }
    }

    private func providerBaseURL(for item: ProviderItem) -> String {
        if item.id == self.viewModel.selectedProviderID {
            return self.viewModel.openAIBaseURL
        }
        if let saved = self.viewModel.savedProviders.first(where: { $0.id == item.id }) {
            return saved.baseURL
        }
        if ModelRepository.shared.isBuiltIn(item.id) {
            return ModelRepository.shared.defaultBaseURL(for: item.id)
        }
        return ""
    }

    private func providerLogoView(for item: ProviderItem) -> some View {
        let name = self.providerLogoName(for: item)
        let bgColor = self.providerBackgroundColor(for: item)

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bgColor)

            if let name {
                let isFluid = name == "Provider_Fluid1"
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: isFluid ? .fill : .fit)
                    .frame(width: isFluid ? 34 : 26, height: isFluid ? 34 : 26)
            } else {
                Text(self.providerInitials(for: item))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(self.theme.palette.primaryText)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func providerBackgroundColor(for item: ProviderItem) -> Color {
        let id = item.id.lowercased()
        let name = item.name.lowercased()

        if id.contains(PrivateAIProviderFeature.shared.providerID) || name.contains("fluid") {
            return Color(red: 0.1, green: 0.1, blue: 0.12) // Dark/black
        }
        if id.contains("anthropic") || name.contains("anthropic") {
            return Color(red: 0.85, green: 0.75, blue: 0.62) // Warm tan
        }
        if id.contains("openai") || name.contains("openai") {
            return Color(red: 0.95, green: 0.95, blue: 0.95) // Light gray
        }
        if id.contains("google") || name.contains("google") || name.contains("gemini") {
            return Color(red: 0.95, green: 0.95, blue: 0.97) // Soft white-blue
        }
        if id.contains("groq") || name.contains("groq") {
            return Color(red: 0.95, green: 0.6, blue: 0.2) // Orange
        }
        if id.contains("cerebras") || name.contains("cerebras") {
            return Color(red: 0.92, green: 0.92, blue: 0.94) // Light silver
        }
        if id.contains("openrouter") || name.contains("openrouter") {
            return Color(red: 0.2, green: 0.2, blue: 0.25) // Dark slate
        }
        if id.contains("xai") || name.contains("xai") || name.contains("x.ai") {
            return Color(red: 0.95, green: 0.95, blue: 0.95) // Light gray
        }
        if id.contains("ollama") || name.contains("ollama") {
            return Color(red: 0.95, green: 0.95, blue: 0.95) // Light gray
        }
        if id.contains("lmstudio") || name.contains("lm studio") || name.contains("lmstudio") {
            return Color(red: 0.15, green: 0.55, blue: 0.35) // Green
        }
        if id.contains("apple") || name.contains("apple intelligence") {
            return Color(red: 0.6, green: 0.4, blue: 0.7) // Purple for Apple Intelligence
        }
        // Default fallback
        return Color(red: 0.9, green: 0.9, blue: 0.92)
    }

    private func providerInitials(for item: ProviderItem) -> String {
        let parts = item.name.split(separator: " ")
        let initials = parts.prefix(2).compactMap { $0.first }
        return String(initials)
    }

    private func providerLogoName(for item: ProviderItem) -> String? {
        let id = item.id.lowercased()
        let name = item.name.lowercased()

        if id.contains(PrivateAIProviderFeature.shared.providerID) || name.contains("fluid") {
            return "Provider_Fluid1"
        }
        if id.contains("openai") || name.contains("openai") {
            return "Provider_OpenAI"
        }
        if id.contains("anthropic") || name.contains("anthropic") {
            return "Provider_Anthropic"
        }
        if id.contains("openrouter") || name.contains("openrouter") {
            return "Provider_OpenRouter"
        }
        if id.contains("xai") || name.contains("xai") || name.contains("x.ai") {
            return "Provider_xAI"
        }
        if id.contains("google") || name.contains("google") || name.contains("gemini") {
            return "Provider_Gemini"
        }
        if id.contains("groq") || name.contains("groq") {
            return "Provider_Groq"
        }
        if id.contains("cerebras") || name.contains("cerebras") {
            return "Provider_Cerebras"
        }
        if id.contains("ollama") || name.contains("ollama") {
            return "Provider_Ollama"
        }
        if id.contains("lmstudio") || name.contains("lm studio") || name.contains("lmstudio") {
            return "Provider_LMStudio"
        }
        if id.contains("apple") || name.contains("apple intelligence") {
            return "Provider_AppleIntelligence"
        }
        if id.contains("compatible") || name.contains("compatible") {
            return "Provider_Compatible"
        }

        return nil
    }

    private func selectProvider(_ providerID: String) {
        self.viewModel.selectProvider(providerID)
    }

    private func activateProvider(_ providerID: String) {
        self.viewModel.selectedProviderID = providerID
        self.viewModel.handleProviderChange(providerID)
        self.viewModel.connectionStatus = self.viewModel.connectionStatus(for: providerID)
    }

    private func modelBinding(for providerID: String) -> Binding<String> {
        Binding(
            get: {
                let key = self.viewModel.providerKey(for: providerID)
                return self.viewModel.selectedModelByProvider[key] ?? ""
            },
            set: { newValue in
                self.viewModel.selectModel(newValue, for: providerID)
            }
        )
    }

    private func reasoningButton(for providerID: String) -> some View {
        let hasEnabledConfig = self.viewModel.isReasoningEnabled(for: providerID)

        return Button(action: {
            self.activateProvider(providerID)
            self.viewModel.openReasoningConfig()
        }) {
            Image(systemName: hasEnabledConfig ? "brain.fill" : "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hasEnabledConfig ? self.theme.palette.accent : self.theme.palette.primaryText)
                .frame(width: AISettingsLayout.providerRowControlHeight, height: AISettingsLayout.providerRowControlHeight)
        }
        .buttonStyle(SquareIconButtonStyle(
            foreground: hasEnabledConfig ? self.theme.palette.accent : nil,
            borderColor: hasEnabledConfig ? self.theme.palette.accent.opacity(0.6) : nil
        ))
        .help("Configure reasoning parameters")
    }

    var promptsStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(self.theme.palette.accent)
                Text("Advanced Prompts")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button {
                    self.isPromptProfilesHelpPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(self.theme.palette.secondaryText.opacity(0.78))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("About prompt profiles")
                .popover(isPresented: self.$isPromptProfilesHelpPresented, arrowEdge: .top) {
                    self.promptProfilesHelpPopover
                }

                Spacer()
            }

            self.advancedSettingsCard
        }
    }

    var builtInProvidersList: [(id: String, name: String)] {
        ModelRepository.shared.builtInProvidersList(
            includeAppleIntelligence: true,
            appleIntelligenceAvailable: self.viewModel.appleIntelligenceAvailable
        )
    }

    func privateAIEditProviderSection(
        model: PrivateAIRegisteredModel,
        isInstalled: Bool,
        isBusy: Bool,
        isVerified: Bool
    ) -> some View {
        let canDelete = isInstalled && PrivateAIIntegrationService.canRemoveInstalledModel(model)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(self.theme.palette.accent)
                Text("Edit Provider")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    self.privateAISettingLabel("Model", systemImage: "cube.box")

                    SearchableModelPicker(
                        models: PrivateAIModelRegistry.modelIDs(),
                        selectedModel: self.privateAIModelBinding,
                        selectionEnabled: !isBusy,
                        controlWidth: 260,
                        controlHeight: AISettingsLayout.providerRowControlHeight
                    )

                    Spacer(minLength: 0)
                }

                HStack(alignment: .center, spacing: 12) {
                    self.privateAISettingLabel("Dictation window", systemImage: "memorychip")

                    self.privateAIContextControl(isBusy: isBusy)

                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.top, 1)
                        Text("\(self.privateAIContextCueText). Higher values help long transcripts but use more RAM.")
                            .font(.caption2)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }

                self.privateAIPrefixCacheRow(isBusy: isBusy)
                self.privateAIBoostRow(isBusy: isBusy)
            }

            HStack(spacing: 8) {
                if isVerified {
                    Button {
                        self.resetPrivateAIVerification(for: model)
                        self.viewModel.clearEditProviderDraft()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset Verification")
                        }
                        .font(.caption)
                    }
                    .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.6))
                }

                if canDelete {
                    Button(role: .destructive) {
                        self.deletePrivateAIModel(model)
                        self.viewModel.clearEditProviderDraft()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Delete Model")
                        }
                        .font(.caption)
                    }
                    .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.6))
                    .disabled(isBusy)
                }

                Spacer(minLength: 0)

                Button {
                    self.viewModel.clearEditProviderDraft()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("Done")
                    }
                }
                .fluidButton(.glass, size: .compact)
            }
        }
    }

    private func privateAISettingLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 110, alignment: .leading)
    }

    private func privateAIContextControl(isBusy: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                self.decreasePrivateAIContextTokenLimit()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 32, height: AISettingsLayout.providerRowControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy || self.settings.privateAIContextTokenLimit <= SettingsStore.privateAIContextTokenLimitRange.lowerBound)

            Text("\(self.settings.privateAIContextTokenLimit.formatted())")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 74, height: AISettingsLayout.providerRowControlHeight)

            Text("tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: AISettingsLayout.providerRowControlHeight, alignment: .leading)

            Button {
                self.increasePrivateAIContextTokenLimit()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 32, height: AISettingsLayout.providerRowControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy || self.settings.privateAIContextTokenLimit >= SettingsStore.privateAIContextTokenLimitRange.upperBound)
        }
        .foregroundStyle(self.theme.palette.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.elevatedCardBackground.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 0.8)
        )
        .fixedSize()
        .help("How much raw dictation Fluid-1 can clean at once. Higher values help long transcripts but use more RAM and can slow first response.")
    }

    private func decreasePrivateAIContextTokenLimit() {
        self.privateAIContextTokenLimitBinding.wrappedValue = self.settings.privateAIContextTokenLimit - SettingsStore.privateAIContextTokenLimitStep
    }

    private func increasePrivateAIContextTokenLimit() {
        self.privateAIContextTokenLimitBinding.wrappedValue = self.settings.privateAIContextTokenLimit + SettingsStore.privateAIContextTokenLimitStep
    }

    private var privateAIContextCueText: String {
        let estimatedWords = SettingsStore.estimatedPrivateAIDictationWords(for: self.settings.privateAIContextTokenLimit)
        let estimatedMinutes = max(1, Int((Double(estimatedWords) / 150.0).rounded()))
        let minuteText = estimatedMinutes == 1 ? "1 minute" : "\(estimatedMinutes) minutes"
        return "Good for about \(estimatedWords.formatted()) words or \(minuteText) of dictation"
    }

    var editProviderSection: some View {
        let isBuiltIn = ModelRepository.shared.isBuiltIn(self.viewModel.selectedProviderID)
        let apiKeyBinding = Binding(
            get: { self.viewModel.editProviderApiKey },
            set: { self.viewModel.editProviderApiKey = $0 }
        )
        let isVerified = self.viewModel.connectionStatus(for: self.viewModel.selectedProviderID) == .success

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(self.theme.palette.accent)
                Text("Edit Provider")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                if !isBuiltIn {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "textformat")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Name")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            TextField("Provider name", text: self.$viewModel.editProviderName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                        }
                        .frame(maxWidth: 200)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Base URL")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            TextField("e.g., http://localhost:11434/v1", text: self.$viewModel.editProviderBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("API Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .center, spacing: 8) {
                        SecureField("Enter API key", text: apiKeyBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .frame(maxWidth: 200)
                            .onTapGesture {
                                self.viewModel.ensureKeychainAccessForAPIKeyEdit()
                            }
                        if let websiteInfo = ModelRepository.shared.providerWebsiteURL(for: self.viewModel.selectedProviderID),
                           let url = URL(string: websiteInfo.url)
                        {
                            Button(action: { NSWorkspace.shared.open(url) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: websiteInfo.label.contains("Guide") ? "book.fill" : "key.fill")
                                        .font(.system(size: 10))
                                    Text(websiteInfo.label)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(self.theme.palette.accent)
                                )
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: {
                    guard self.viewModel.saveEditedProviderAPIKey() else { return }
                    if !isBuiltIn {
                        self.viewModel.saveEditedProvider()
                    } else {
                        self.viewModel.clearEditProviderDraft()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Save")
                    }
                }
                .fluidButton(.glass, size: .compact)
                .disabled(!isBuiltIn &&
                    (self.viewModel.editProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        self.viewModel.editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                Button("Cancel") {
                    self.viewModel.clearEditProviderDraft()
                }
                .fluidButton(.compact, size: .compact)
            }

            HStack(spacing: 10) {
                if isVerified {
                    Button("Reset Verification") {
                        self.viewModel.resetVerification(for: self.viewModel.selectedProviderID)
                        self.viewModel.clearEditProviderDraft()
                    }
                    .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.6))
                }

                if !isBuiltIn {
                    Button(role: .destructive) {
                        self.viewModel.deleteCurrentProvider()
                        self.viewModel.clearEditProviderDraft()
                        self.expandedProviderID = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Delete Provider")
                        }
                        .font(.caption)
                    }
                    .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.6))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.elevatedCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )
                .shadow(
                    color: self.theme.metrics.cardShadow.color.opacity(self.theme.metrics.cardShadow.opacity * 0.6),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        )
        .padding(.vertical, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    var appleIntelligenceBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.logo").font(.system(size: 14))
            Text("On-Device").fontWeight(.medium)
            Text("•").foregroundStyle(.secondary)
            Image(systemName: "lock.shield.fill").font(.system(size: 12))
            Text("Private").fontWeight(.medium)
        }
        .font(.caption).foregroundStyle(Color.fluidGreen)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.fluidGreen.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                Color.fluidGreen.opacity(0.3),
                lineWidth: 1
            )))
    }

    var appleIntelligenceModelRow: some View {
        HStack(spacing: 12) {
            self.formLabel("Model:")
            Text("System Language Model").foregroundStyle(.secondary).font(.system(.body))
            Spacer()
        }
    }

    var standardModelRow: some View {
        HStack(spacing: 12) {
            self.formLabel("Model:")

            // Searchable model picker with refresh button
            SearchableModelPicker(
                models: self.viewModel.availableModels,
                selectedModel: self.$viewModel.selectedModel,
                onRefresh: { await self.viewModel.fetchModelsForCurrentProvider() },
                isRefreshing: self.viewModel.isFetchingModels,
                controlWidth: AISettingsLayout.pickerWidth,
                controlHeight: AISettingsLayout.controlHeight
            )

            if !ModelRepository.shared.isBuiltIn(self.viewModel.selectedProviderID) {
                Button(action: { self.viewModel.deleteSelectedModel() }) {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete") }.font(.caption)
                }
                .fluidCompactButton(foreground: .red, borderColor: .red.opacity(0.6))
                .frame(minWidth: AISettingsLayout.compactActionMinWidth, minHeight: AISettingsLayout.controlHeight)
            }

            if !self.viewModel.showingAddModel {
                Button("+ Add Model") {
                    self.viewModel.showingAddModel = true
                    self.viewModel.newModelName = ""
                }
                .fluidCompactButton(isReady: true)
                .frame(minWidth: AISettingsLayout.wideActionMinWidth, minHeight: AISettingsLayout.controlHeight)
            }

            Button(action: { self.viewModel.openReasoningConfig() }) {
                HStack(spacing: 4) {
                    Image(systemName: self.viewModel.hasReasoningConfigForCurrentModel() ? "brain.fill" : "brain")
                    Text("Reasoning")
                }
                .font(.caption)
            }
            .fluidCompactButton(
                foreground: self.viewModel.hasReasoningConfigForCurrentModel() ? self.theme.palette.accent : nil,
                borderColor: self.viewModel.hasReasoningConfigForCurrentModel() ? self.theme.palette.accent.opacity(0.6) : nil
            )
            .frame(minWidth: AISettingsLayout.compactActionMinWidth, minHeight: AISettingsLayout.controlHeight)
        }
    }

    func openReasoningConfig() {
        self.viewModel.openReasoningConfig()
    }

    var addModelSection: some View {
        HStack(spacing: 8) {
            TextField("Enter model name", text: self.$viewModel.newModelName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !self.viewModel.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.viewModel.addNewModel()
                    }
                }
            Button("Add") { self.viewModel.addNewModel() }
                .fluidCompactButton(isReady: true)
                .frame(minWidth: AISettingsLayout.compactActionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(self.viewModel.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") {
                self.viewModel.showingAddModel = false
                self.viewModel.newModelName = ""
            }
            .fluidButton(.compact, size: .compact)
            .frame(minWidth: AISettingsLayout.compactActionMinWidth, minHeight: AISettingsLayout.controlHeight)
        }
        .padding(.leading, AISettingsLayout.rowLeadingIndent)
    }

    var reasoningConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14))
                    .foregroundStyle(self.theme.palette.accent)
                Text("Reasoning for \(self.viewModel.selectedModel)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                Spacer()
                Button(action: { self.viewModel.showingReasoningConfig = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            HStack(spacing: 16) {
                Toggle("", isOn: self.$viewModel.editingReasoningEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text(self.viewModel.editingReasoningEnabled ? "Enabled" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(self.viewModel.editingReasoningEnabled ? self.theme.palette.accent : .secondary)
            }

            if self.viewModel.editingReasoningEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    // Parameter type picker
                    HStack(spacing: 12) {
                        Text("Parameter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Picker("", selection: Binding(
                            get: {
                                if self.viewModel.editingReasoningParamName == "reasoning_effort" {
                                    return "reasoning_effort"
                                } else if self.viewModel.editingReasoningParamName == "enable_thinking" {
                                    return "enable_thinking"
                                } else {
                                    return "custom"
                                }
                            },
                            set: { newValue in
                                if newValue == "custom" {
                                    if self.viewModel.editingReasoningParamName == "reasoning_effort" ||
                                        self.viewModel.editingReasoningParamName == "enable_thinking"
                                    {
                                        self.viewModel.editingReasoningParamName = ""
                                    }
                                } else {
                                    self.viewModel.editingReasoningParamName = newValue
                                    // Set sensible default value when switching
                                    if newValue == "reasoning_effort", !["none", "minimal", "low", "medium", "high"].contains(self.viewModel.editingReasoningParamValue) {
                                        self.viewModel.editingReasoningParamValue = "low"
                                    } else if newValue == "enable_thinking", !["true", "false"].contains(self.viewModel.editingReasoningParamValue) {
                                        self.viewModel.editingReasoningParamValue = "true"
                                    }
                                }
                            }
                        )) {
                            Text("reasoning_effort").tag("reasoning_effort")
                            Text("enable_thinking").tag("enable_thinking")
                            Text("Custom...").tag("custom")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    // Custom parameter name field
                    if self.viewModel.editingReasoningParamName != "reasoning_effort" &&
                        self.viewModel.editingReasoningParamName != "enable_thinking"
                    {
                        HStack(spacing: 12) {
                            Text("Name")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                            TextField("e.g., thinking_budget", text: self.$viewModel.editingReasoningParamName)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .frame(width: 140)
                        }
                    }

                    // Value picker/field
                    HStack(spacing: 12) {
                        Text("Value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        if self.viewModel.editingReasoningParamName == "reasoning_effort" {
                            Picker("", selection: self.$viewModel.editingReasoningParamValue) {
                                Text("none").tag("none")
                                Text("minimal").tag("minimal")
                                Text("low").tag("low")
                                Text("medium").tag("medium")
                                Text("high").tag("high")
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 100)
                        } else if self.viewModel.editingReasoningParamName == "enable_thinking" {
                            Picker("", selection: self.$viewModel.editingReasoningParamValue) {
                                Text("true").tag("true")
                                Text("false").tag("false")
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 100)
                        } else {
                            TextField("value", text: self.$viewModel.editingReasoningParamValue)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .frame(width: 100)
                        }
                    }
                }
                .padding(.leading, 4)
            }

            HStack(spacing: 8) {
                Button(action: { self.saveReasoningConfig() }) {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                }
                .fluidButton(.accent, size: .small)
                .frame(minWidth: 60, minHeight: 26)

                Button("Cancel") { self.viewModel.showingReasoningConfig = false }
                    .fluidButton(.compact, size: .compact)
                    .font(.system(size: 12))
                    .frame(minWidth: 60, minHeight: 26)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: self.theme.palette.accent.opacity(0.1), radius: 8, x: 0, y: 4)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    func saveReasoningConfig() {
        self.viewModel.saveReasoningConfig()
    }

    var connectionTestSection: some View {
        let selectedProviderAPIKey = self.viewModel.providerAPIKey(for: self.viewModel.selectedProviderID)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { Task { await self.viewModel.testAPIConnection() } }) {
                    Text(self.viewModel.isTestingConnection ? "Verifying..." : "Verify Connection")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .fluidCompactButton(isReady: true)
                .frame(minWidth: AISettingsLayout.primaryActionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(self.viewModel.isTestingConnection ||
                    (!self.viewModel.isLocalEndpoint(self.viewModel.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) &&
                        selectedProviderAPIKey.isEmpty))
            }

            // Connection Status Display
            if self.viewModel.connectionStatus == .success {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fluidGreen).font(.caption)
                    Text("Connection verified").font(.caption).foregroundStyle(Color.fluidGreen)
                }
            } else if self.viewModel.connectionStatus == .failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection failed").font(.caption).foregroundStyle(.red)
                        if !self.viewModel.connectionErrorMessage.isEmpty {
                            Text(self.viewModel.connectionErrorMessage)
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            } else if self.viewModel.connectionStatus == .testing {
                HStack(spacing: 8) {
                    ProgressView().frame(width: 16, height: 16)
                    Text("Verifying...").font(.caption).foregroundStyle(self.theme.palette.accent)
                }
            }

            // API Key Editor Sheet
            Color.clear.frame(height: 0)
                .sheet(isPresented: self.$viewModel.showAPIKeyEditor) {
                    self.apiKeyEditorSheet
                }
        }
    }

    var apiKeyManagementRow: some View {
        HStack(spacing: 8) {
            Button(action: { self.viewModel.handleAPIKeyButtonTapped() }) {
                Label("Add or Modify API Key", systemImage: "key.fill")
                    .labelStyle(.titleAndIcon).font(.caption)
            }
            .fluidCompactButton(isReady: true)
            .frame(minWidth: AISettingsLayout.primaryActionMinWidth, minHeight: AISettingsLayout.controlHeight)

            if let websiteInfo = ModelRepository.shared.providerWebsiteURL(for: self.viewModel.selectedProviderID),
               let url = URL(string: websiteInfo.url)
            {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    Label(websiteInfo.label, systemImage: websiteInfo.label.contains("Download") ? "arrow.down.circle.fill" : (websiteInfo.label.contains("Guide") ? "book.fill" : "link"))
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .fluidButton(.compact, size: .compact)
                .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
            }
        }
    }

    var apiKeyEditorSheet: some View {
        VStack(spacing: 14) {
            Text("Enter \(self.viewModel.providerDisplayName(for: self.viewModel.selectedProviderID)) API Key")
                .font(.headline)
            SecureField("API Key (optional for local endpoints)", text: self.$viewModel.newProviderApiKey)
                .textFieldStyle(.roundedBorder).frame(width: 300)
                .onTapGesture {
                    self.viewModel.ensureKeychainAccessForAPIKeyEdit()
                }
            HStack(spacing: 12) {
                Button("Cancel") { self.viewModel.showAPIKeyEditor = false }
                    .fluidButton(.compact, size: .compact)
                    .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
                Button("OK") {
                    let trimmedKey = self.viewModel.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.viewModel.updateProviderAPIKey(trimmedKey, for: self.viewModel.selectedProviderID)
                    guard self.viewModel.saveProviderAPIKeys() else { return }
                    if self.viewModel.connectionStatus != .unknown {
                        self.viewModel.connectionStatus = .unknown
                        self.viewModel.connectionErrorMessage = ""
                    }
                    self.viewModel.showAPIKeyEditor = false
                }
                .fluidButton(.glass, size: .compact)
                .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(!self.viewModel.isLocalEndpoint(self.viewModel.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) &&
                    self.viewModel.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 350, minHeight: 150)
    }

    var addProviderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(self.theme.palette.accent)
                Text("Add Custom Provider")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("OpenAI-compatible base URL")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    TextField("https://api.yourprovider.com/v1", text: self.$viewModel.newProviderBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("API Key (optional for local endpoints)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    SecureField("Enter API key", text: self.$viewModel.newProviderApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onTapGesture {
                            self.viewModel.ensureKeychainAccessForAPIKeyEdit()
                        }
                }
            }

            HStack(spacing: 10) {
                Button(action: { self.saveNewProvider() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Save Provider")
                    }
                }
                .fluidButton(.glass, size: .compact)
                .disabled(self.viewModel.newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel") {
                    self.viewModel.showingSaveProvider = false
                    self.viewModel.newProviderName = ""
                    self.viewModel.newProviderBaseURL = ""
                    self.viewModel.newProviderApiKey = ""
                    self.viewModel.newProviderModels = ""
                }
                .fluidButton(.compact, size: .compact)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.elevatedCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )
                .shadow(
                    color: self.theme.metrics.cardShadow.color.opacity(self.theme.metrics.cardShadow.opacity * 0.6),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    func saveNewProvider() {
        self.viewModel.saveNewProvider()
    }
}
