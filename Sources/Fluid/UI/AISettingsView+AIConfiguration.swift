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

    func aiOnboardingInfoRow(_ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(self.theme.palette.accent.opacity(0.9))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - AI Configuration Card

    var aiConfigurationCard: some View {
        VStack(spacing: 14) {
            ThemedCard(style: .prominent, hoverEffect: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "brain")
                                .font(.title3)
                                .foregroundStyle(self.theme.palette.accent)
                            Text("AI Setup")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }

                    Divider()
                        .background(self.theme.palette.separator.opacity(0.5))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose a provider, model, and dictation prompt. Select `Off` in Dictate prompts for raw transcription.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        self.aiOnboardingInfoRow("Local models run on your Mac. Examples: Ollama and LM Studio.")
                        self.aiOnboardingInfoRow("Cloud models use a provider of your choice. Examples: OpenAI, Anthropic, Groq, and OpenRouter.")
                        self.aiOnboardingInfoRow("Dictation uses AI when Dictate prompt is `Default` or a custom prompt.")
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Providers")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Configure your AI provider")
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

                    Divider()
                        .background(self.theme.palette.separator.opacity(0.5))

                    self.promptsStepContent

                    Divider()
                        .background(self.theme.palette.separator.opacity(0.5))

                    self.streamingToggleRow
                }
                .padding(16)
            }
        }
    }

    var streamingToggleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stream responses")
                    .font(.system(size: 14, weight: .semibold))
                Text("Send \"stream\": true in AI requests. Turn off if your provider defaults to streaming but the response fails to parse (e.g. some Ollama or self-hosted setups).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { self.settings.enableAIStreaming },
                set: { self.settings.enableAIStreaming = $0 }
            ))
            .toggleStyle(.switch)
            .tint(self.theme.palette.accent)
            .labelsHidden()
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

            if self.viewModel.showingEditProvider { self.editProviderSection }
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
                .onChange(of: self.expandedProviderID) { newID in
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

    private func providerCard(_ item: ProviderItem) -> some View {
        let isAppleDisabled = item.id == "apple-intelligence-disabled"
        let isFluidInterest = item.id == "fluid-1"
        let isComingSoon = isAppleDisabled
        let isExpanded = self.expandedProviderID == item.id && !isAppleDisabled
        let status = self.providerStatus(for: item)
        let borderColor = isExpanded
            ? self.theme.palette.accent.opacity(0.5)
            : (isFluidInterest ? self.theme.palette.accent.opacity(0.3) : self.theme.palette.cardBorder.opacity(0.3))
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

                        if isFluidInterest {
                            statusView
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(self.theme.palette.accent.opacity(0.12))
                                        .overlay(
                                            Capsule()
                                                .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
                                        )
                                )
                        } else {
                            statusView
                        }
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

            if isExpanded {
                Divider()
                    .background(self.theme.palette.separator.opacity(0.5))
                    .padding(.horizontal, 14)

                if isFluidInterest {
                    self.fluid1InterestSection
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
        if item.id == "fluid-1" {
            let hasInterest = self.settings.fluid1InterestCaptured
            if hasInterest {
                return ("Thanks · Coming soon", self.theme.palette.accent, "checkmark.circle.fill")
            }
            return ("Early access · Tap to join", self.theme.palette.accent, "hand.tap")
        }
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
        if providerID == "fluid-1" {
            if self.expandedProviderID == providerID {
                self.expandedProviderID = nil
            } else {
                self.expandedProviderID = providerID
                self.fluid1InterestErrorMessage = ""
            }
            return
        }
        if self.expandedProviderID == providerID {
            self.expandedProviderID = nil
            self.viewModel.showingEditProvider = false
            self.viewModel.editProviderName = ""
            self.viewModel.editProviderBaseURL = ""
            self.viewModel.setEditingAPIKey(false, for: providerID)
        } else {
            self.expandedProviderID = providerID
            self.selectProvider(providerID)
        }
    }

    private var fluid1InterestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let hasInterest = self.settings.fluid1InterestCaptured
            if hasInterest {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(self.theme.palette.accent)
                    Text("Thank you — coming soon")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text("We saved your interest in Fluid-1, our private on-device model. We'll notify you when it's ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(self.theme.palette.accent)
                    Text("Join Fluid-1 early access")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text("Share your email to get notified when our private on-device model is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Email")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("you@example.com", text: self.$fluid1InterestEmail)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: self.fluid1InterestEmail) { _, _ in
                            if !self.fluid1InterestErrorMessage.isEmpty {
                                self.fluid1InterestErrorMessage = ""
                            }
                        }
                }

                HStack(spacing: 10) {
                    Button(action: { self.submitFluid1Interest() }) {
                        HStack(spacing: 6) {
                            if self.fluid1InterestIsSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                    .fixedSize()
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11))
                            }
                            Text("Join early access")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(GlassButtonStyle(height: AISettingsLayout.controlHeight))
                    .disabled(self.fluid1InterestIsSubmitting)
                }

                if !self.fluid1InterestErrorMessage.isEmpty {
                    Text(self.fluid1InterestErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.theme.palette.accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func submitFluid1Interest() {
        guard !self.settings.fluid1InterestCaptured else { return }
        let email = self.fluid1InterestEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            self.fluid1InterestErrorMessage = "Enter your email to join early access."
            return
        }
        guard self.isValidEmail(email) else {
            self.fluid1InterestErrorMessage = "Enter a valid email address."
            return
        }
        self.fluid1InterestErrorMessage = ""
        self.fluid1InterestIsSubmitting = true

        Task {
            let success = await self.sendFluid1Interest(email: email)
            await MainActor.run {
                self.fluid1InterestIsSubmitting = false
                if success {
                    self.settings.fluid1InterestCaptured = true
                    self.fluid1InterestEmail = ""
                } else {
                    self.fluid1InterestErrorMessage = "We couldn't save your interest. Please try again."
                }
            }
        }
    }

    private func sendFluid1Interest(email: String) async -> Bool {
        guard let url = URL(string: "https://altic.dev/api/fluid/fluid-model-interest") else {
            DebugLogger.shared.error("Invalid Fluid-1 interest API URL", source: "AISettingsView")
            return false
        }

        let payload: [String: Any] = [
            "emailId": email,
            "modelName": "Fluid-1",
        ]

        guard JSONSerialization.isValidJSONObject(payload) else { return false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let success = (200...299).contains(httpResponse.statusCode)
                if success {
                    DebugLogger.shared.info("Fluid-1 interest submitted", source: "AISettingsView")
                } else {
                    DebugLogger.shared.error(
                        "Fluid-1 interest submission failed with status: \(httpResponse.statusCode)",
                        source: "AISettingsView"
                    )
                }
                return success
            }
            return false
        } catch {
            DebugLogger.shared.error(
                "Network error submitting Fluid-1 interest: \(error.localizedDescription)",
                source: "AISettingsView"
            )
            return false
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }

        let local = String(parts[0])
        let domain = String(parts[1])
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard !local.hasPrefix("."), !local.hasSuffix(".") else { return false }
        guard !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        guard !local.contains(".."), !domain.contains("..") else { return false }

        let domainParts = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domainParts.count >= 2 else { return false }
        guard domainParts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = domainParts.last, tld.count >= 2 else { return false }

        return true
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
        let apiKeyValue = self.viewModel.providerAPIKeys[providerKey] ?? ""
        let hasAPIKey = !apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let models = self.viewModel.availableModelsByProvider[providerKey] ?? []
        let hasModels = !models.isEmpty
        let isRefreshing = self.viewModel.isFetchingModels && self.viewModel.selectedProviderID == item.id
        let hasName = isCustom ? !(self.viewModel.savedProviders.first { $0.id == item.id }?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true
        let canFetchModels = hasName && (isLocal ? !baseURL.isEmpty : (hasAPIKey && !baseURL.isEmpty))
        let canVerify = hasModels && !self.viewModel.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canFetchModels
        let isVerified = self.viewModel.connectionStatus(for: item.id) == .success
        let apiKeyBinding = Binding(
            get: { self.viewModel.providerAPIKeys[providerKey] ?? "" },
            set: { self.viewModel.providerAPIKeys[providerKey] = $0 }
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
                    .buttonStyle(GlassButtonStyle(height: AISettingsLayout.controlHeight))
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

                HStack(spacing: 10) {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)

                    SearchableModelPicker(
                        models: models,
                        selectedModel: self.modelBinding(for: item.id),
                        onRefresh: {
                            self.viewModel.saveProviderAPIKeys()
                            Task { await self.viewModel.fetchModelsForCurrentProvider() }
                        },
                        isRefreshing: isRefreshing,
                        refreshEnabled: canFetchModels,
                        selectionEnabled: hasModels,
                        controlWidth: 180,
                        controlHeight: 30
                    )

                    self.reasoningButton(for: item.id)
                }

                if self.viewModel.showingReasoningConfig && self.viewModel.selectedProviderID == item.id {
                    self.reasoningConfigSection
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
                        self.viewModel.saveProviderAPIKeys()
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
                    .buttonStyle(AccentButtonStyle(compact: true))
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
                    .buttonStyle(CompactButtonStyle(foreground: .red, borderColor: .red.opacity(0.6)))
                }
            }
        })
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
        let isRefreshing = self.viewModel.isFetchingModels && self.viewModel.selectedProviderID == item.id
        let baseURL = self.providerBaseURL(for: item).trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.viewModel.isLocalEndpoint(baseURL)
        let apiKeyValue = self.viewModel.providerAPIKeys[providerKey] ?? ""
        let hasAPIKey = !apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canFetchModels = isLocal ? !baseURL.isEmpty : (hasAPIKey && !baseURL.isEmpty)
        let hasModels = !models.isEmpty
        let isEditing = self.viewModel.showingEditProvider && self.viewModel.selectedProviderID == item.id

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

                SearchableModelPicker(
                    models: models,
                    selectedModel: self.modelBinding(for: item.id),
                    onRefresh: {
                        self.activateProvider(item.id)
                        await self.viewModel.fetchModelsForCurrentProvider()
                    },
                    isRefreshing: isRefreshing,
                    refreshEnabled: canFetchModels,
                    selectionEnabled: hasModels,
                    controlWidth: 180,
                    controlHeight: 28
                )

                self.reasoningButton(for: item.id)

                Button("Edit") {
                    self.activateProvider(item.id)
                    if isEditing {
                        self.viewModel.showingEditProvider = false
                        self.viewModel.editProviderName = ""
                        self.viewModel.editProviderBaseURL = ""
                        self.viewModel.setEditingAPIKey(false, for: item.id)
                    } else {
                        self.viewModel.startEditingProvider()
                        self.viewModel.setEditingAPIKey(true, for: item.id)
                    }
                }
                .buttonStyle(CompactButtonStyle())
            }

            if isEditing {
                Divider()
                    .background(self.theme.palette.separator.opacity(0.5))
                    .padding(.vertical, 10)

                self.editProviderSection
            }

            if self.viewModel.showingReasoningConfig && self.viewModel.selectedProviderID == item.id {
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

        if id.contains("fluid-1") || name.contains("fluid") {
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

        if id.contains("fluid-1") || name.contains("fluid") {
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
                let key = self.viewModel.providerKey(for: providerID)
                self.viewModel.selectedModelByProvider[key] = newValue
                self.viewModel.settings.selectedModelByProvider = self.viewModel.selectedModelByProvider
                if providerID == self.viewModel.selectedProviderID {
                    self.viewModel.selectedModel = newValue
                }
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
                .font(.system(size: 12))
        }
        .buttonStyle(CompactButtonStyle(
            foreground: hasEnabledConfig ? self.theme.palette.accent : nil,
            borderColor: hasEnabledConfig ? self.theme.palette.accent.opacity(0.6) : nil
        ))
        .frame(width: 28, height: 28)
        .help("Configure reasoning parameters")
    }

    var promptsStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(self.theme.palette.accent)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Prompts & Advanced")
                        .font(.system(size: 14, weight: .semibold))
                    Text(" - Choose how to process your speech — email, code, terminal, and more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
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

    var editProviderSection: some View {
        let providerKey = self.viewModel.providerKey(for: self.viewModel.selectedProviderID)
        let isBuiltIn = ModelRepository.shared.isBuiltIn(self.viewModel.selectedProviderID)
        let apiKeyBinding = Binding(
            get: { self.viewModel.providerAPIKeys[providerKey] ?? "" },
            set: { self.viewModel.providerAPIKeys[providerKey] = $0 }
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
                    self.viewModel.saveProviderAPIKeys()
                    if !isBuiltIn {
                        self.viewModel.saveEditedProvider()
                    } else {
                        self.viewModel.showingEditProvider = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Save")
                    }
                }
                .buttonStyle(GlassButtonStyle(height: AISettingsLayout.controlHeight))
                .disabled(!isBuiltIn &&
                    (self.viewModel.editProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        self.viewModel.editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                Button("Cancel") {
                    self.viewModel.showingEditProvider = false
                    self.viewModel.editProviderName = ""
                    self.viewModel.editProviderBaseURL = ""
                }
                .buttonStyle(CompactButtonStyle())
            }

            HStack(spacing: 10) {
                if isVerified {
                    Button("Reset Verification") {
                        self.viewModel.resetVerification(for: self.viewModel.selectedProviderID)
                        self.viewModel.showingEditProvider = false
                    }
                    .buttonStyle(CompactButtonStyle(foreground: .red, borderColor: .red.opacity(0.6)))
                }

                if !isBuiltIn {
                    Button(role: .destructive) {
                        self.viewModel.deleteCurrentProvider()
                        self.viewModel.showingEditProvider = false
                        self.expandedProviderID = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Delete Provider")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(CompactButtonStyle(foreground: .red, borderColor: .red.opacity(0.6)))
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
                .buttonStyle(CompactButtonStyle(foreground: .red, borderColor: .red.opacity(0.6)))
                .frame(minWidth: AISettingsLayout.compactActionMinWidth, minHeight: AISettingsLayout.controlHeight)
            }

            if !self.viewModel.showingAddModel {
                Button("+ Add Model") {
                    self.viewModel.showingAddModel = true
                    self.viewModel.newModelName = ""
                }
                .buttonStyle(CompactButtonStyle(isReady: true))
                .frame(minWidth: AISettingsLayout.wideActionMinWidth, minHeight: AISettingsLayout.controlHeight)
            }

            Button(action: { self.viewModel.openReasoningConfig() }) {
                HStack(spacing: 4) {
                    Image(systemName: self.viewModel.hasReasoningConfigForCurrentModel() ? "brain.fill" : "brain")
                    Text("Reasoning")
                }
                .font(.caption)
            }
            .buttonStyle(CompactButtonStyle(
                foreground: self.viewModel.hasReasoningConfigForCurrentModel() ? self.theme.palette.accent : nil,
                borderColor: self.viewModel.hasReasoningConfigForCurrentModel() ? self.theme.palette.accent.opacity(0.6) : nil
            ))
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
                .buttonStyle(CompactButtonStyle(isReady: true))
                .frame(minWidth: AISettingsLayout.compactActionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(self.viewModel.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") {
                self.viewModel.showingAddModel = false
                self.viewModel.newModelName = ""
            }
            .buttonStyle(CompactButtonStyle())
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
                .buttonStyle(AccentButtonStyle(compact: true))
                .frame(minWidth: 60, minHeight: 26)

                Button("Cancel") { self.viewModel.showingReasoningConfig = false }
                    .buttonStyle(CompactButtonStyle())
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { Task { await self.viewModel.testAPIConnection() } }) {
                    Text(self.viewModel.isTestingConnection ? "Verifying..." : "Verify Connection")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(CompactButtonStyle(isReady: true))
                .frame(minWidth: AISettingsLayout.primaryActionMinWidth, minHeight: AISettingsLayout.controlHeight)
                .disabled(self.viewModel.isTestingConnection ||
                    (!self.viewModel.isLocalEndpoint(self.viewModel.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) &&
                        (self.viewModel.providerAPIKeys[self.viewModel.currentProvider] ?? "").isEmpty))
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
            .buttonStyle(CompactButtonStyle(isReady: true))
            .frame(minWidth: AISettingsLayout.primaryActionMinWidth, minHeight: AISettingsLayout.controlHeight)

            if let websiteInfo = ModelRepository.shared.providerWebsiteURL(for: self.viewModel.selectedProviderID),
               let url = URL(string: websiteInfo.url)
            {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    Label(websiteInfo.label, systemImage: websiteInfo.label.contains("Download") ? "arrow.down.circle.fill" : (websiteInfo.label.contains("Guide") ? "book.fill" : "link"))
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(CompactButtonStyle())
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
            HStack(spacing: 12) {
                Button("Cancel") { self.viewModel.showAPIKeyEditor = false }
                    .buttonStyle(CompactButtonStyle())
                    .frame(minWidth: AISettingsLayout.actionMinWidth, minHeight: AISettingsLayout.controlHeight)
                Button("OK") {
                    let trimmedKey = self.viewModel.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.viewModel.providerAPIKeys[self.viewModel.currentProvider] = trimmedKey
                    self.viewModel.saveProviderAPIKeys()
                    if self.viewModel.connectionStatus != .unknown {
                        self.viewModel.connectionStatus = .unknown
                        self.viewModel.connectionErrorMessage = ""
                    }
                    self.viewModel.showAPIKeyEditor = false
                }
                .buttonStyle(GlassButtonStyle(height: AISettingsLayout.controlHeight))
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
                .buttonStyle(GlassButtonStyle(height: AISettingsLayout.controlHeight))
                .disabled(self.viewModel.newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel") {
                    self.viewModel.showingSaveProvider = false
                    self.viewModel.newProviderName = ""
                    self.viewModel.newProviderBaseURL = ""
                    self.viewModel.newProviderApiKey = ""
                    self.viewModel.newProviderModels = ""
                }
                .buttonStyle(CompactButtonStyle())
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
