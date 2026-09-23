import SwiftUI

struct AddProviderSheet<Logo: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    @ViewBuilder let logo: (String, String) -> Logo
    @State private var draft = ProviderSetupDraft()
    @State private var isEditing = false
    @State private var saveFailed = false
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var modelFetchID: UUID?
    @State private var modelFetchError: String?
    @State private var showingManualModel = false

    private var providers: [AIEnhancementSettingsViewModel.ProviderItemData] {
        let added = Set(self.viewModel.cachedAddedProviderItems.map(\.id))
        return self.viewModel.cachedProviderItems.filter {
            $0.isBuiltIn && $0.id != PrivateAIProviderFeature.shared.providerID && !added.contains($0.id)
        }
    }

    var body: some View {
        FluidGlassControlGroup {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                HStack {
                    if self.isEditing && !self.draft.providerID.isEmpty {
                        self.logo(self.draft.providerID, self.draft.name)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.fluidSystem(size: 26)).foregroundStyle(FluidBrandColors.blue)
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(self.isEditing ? self.draft.name : "Add a provider").font(self.theme.typography.title)
                        Text(self.isEditing ? "Add connection details to get started." : "Your preferred models. Connected to FluidVoice.")
                            .font(self.theme.typography.body).foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Spacer()
                    Button("Cancel") { self.dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .fluidGlassAction()
                }
                Divider()
                if self.isEditing {
                    self.form
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Choose a provider").font(self.theme.typography.bodyStrong)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(self.providers) { provider in
                                    Button {
                                        self.draft = ProviderSetupDraft(
                                            providerID: provider.id,
                                            name: provider.name,
                                            baseURL: ModelRepository.shared.defaultBaseURL(for: provider.id)
                                        )
                                        self.isEditing = true
                                    } label: {
                                        HStack(spacing: 14) {
                                            self.logo(provider.id, provider.name).accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(provider.name).font(self.theme.typography.bodyStrong)
                                                Text(["ollama", "lmstudio"].contains(provider.id) ? "Local connection" : "Connect with an API key")
                                                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").accessibilityHidden(true)
                                        }
                                        .padding(16).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                                        .contentShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                    .buttonStyle(ProviderChoiceStyle())
                                }
                                Button {
                                    self.draft = ProviderSetupDraft(name: "Custom Provider")
                                    self.isEditing = true
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "server.rack").font(.fluidSystem(size: 24))
                                            .foregroundStyle(FluidBrandColors.blue).frame(width: 38, height: 38)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("Custom Provider").font(self.theme.typography.bodyStrong)
                                            Text("Your service or server")
                                                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                                        }
                                        Spacer()
                                        Image(systemName: "plus").foregroundStyle(FluidBrandColors.blue)
                                    }.padding(16).contentShape(RoundedRectangle(cornerRadius: 16))
                                }
                                .buttonStyle(ProviderChoiceStyle())
                            }
                        }
                    }
                    Label("Adding a provider won’t change your current dictation setup.", systemImage: "info.circle")
                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                }
            }
        }
        .padding(28)
        .frame(width: 720, height: 650)
        .background(self.theme.palette.windowBackground)
        .onChange(of: self.draft.connectionIdentity) { _, _ in
            self.cancelModelFetch()
            self.modelFetchError = nil
        }
        .onDisappear { self.cancelModelFetch() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FluidManagementGroup(title: "Connection details") {
                        if self.draft.providerID.isEmpty {
                            self.field("Name") { TextField("Custom Provider", text: self.$draft.name) }
                            self.field("Server URL") { TextField("https://your-server.com/v1", text: self.$draft.baseURL) }
                        }
                        self.field(self.draft.requiresAPIKey ? "API key" : "API key · Optional") {
                            SecureField("Enter API key", text: self.$draft.apiKey)
                        }
                        if let website = ModelRepository.shared.providerWebsiteURL(for: self.draft.providerID), let url = URL(string: website.url) {
                            Link(destination: url) { Label(website.label, systemImage: "arrow.up.right").font(self.theme.typography.caption) }
                        }
                    }
                    self.modelSection
                    Label("Your current dictation setup stays unchanged.", systemImage: "info.circle")
                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                }
            }
            .textFieldStyle(.roundedBorder)
            if self.saveFailed {
                Text("Couldn’t save this provider. Check Keychain access and try again.")
                    .font(self.theme.typography.caption).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Button("Back") { self.cancelModelFetch(); self.isEditing = false; self.saveFailed = false; self.showingManualModel = false }
                    .fluidGlassAction()
                Spacer()
                Button("Add Provider") {
                    if self.viewModel.addProvider(self.draft) { self.dismiss() } else { self.saveFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .fluidGlassAction(prominent: true)
                .disabled(self.modelFetchID != nil || !self.draft.isValid || self.viewModel.isTestingConnection || self.viewModel.isFetchingModels)
            }
        }
    }

    private var modelSection: some View {
        FluidManagementGroup(title: "Model") {
            HStack(spacing: 8) {
                SearchableModelPicker(
                    models: self.draft.fetchedModels,
                    selectedModel: Binding(
                        get: { self.draft.model },
                        set: { self.draft.selectFetchedModel($0) }
                    ),
                    selectionEnabled: !self.draft.fetchedModels.isEmpty,
                    controlWidth: 430,
                    controlHeight: 36
                )
                Button(action: self.fetchModels) {
                    if self.modelFetchID != nil {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .fluidGlassAction()
                .disabled(!self.draft.isValid || self.modelFetchID != nil)
                .help("Load models from this provider")
                .accessibilityLabel("Load models")
                Button { self.showingManualModel.toggle() } label: {
                    Image(systemName: "plus")
                }
                .fluidGlassAction()
                .help("Enter a model ID manually")
                .accessibilityLabel("Enter model ID manually")
            }
            if self.showingManualModel {
                self.field("Model ID") { TextField("Enter a model ID", text: self.$draft.model) }
            }
            Text(self.draft.requiresAPIKey && self.draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter your API key, then load models with the reload button."
                : "Load models with the reload button, or use + to enter a model ID.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if let error = self.modelFetchError {
                Text(error).font(self.theme.typography.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func cancelModelFetch() {
        self.modelFetchTask?.cancel()
        self.modelFetchTask = nil
        self.modelFetchID = nil
    }

    private func fetchModels() {
        guard self.draft.isValid, self.modelFetchID == nil else { return }
        let snapshot = self.draft
        let requestID = UUID()
        self.modelFetchID = requestID
        self.modelFetchError = nil
        self.modelFetchTask = Task { @MainActor in
            defer {
                if self.modelFetchID == requestID {
                    self.modelFetchID = nil
                    self.modelFetchTask = nil
                }
            }
            do {
                let models = try await ModelRepository.shared.fetchModels(
                    for: snapshot.providerID,
                    baseURL: snapshot.trimmedBaseURL,
                    apiKey: snapshot.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard !Task.isCancelled, self.modelFetchID == requestID,
                      self.draft.connectionIdentity == snapshot.connectionIdentity else { return }
                self.draft.applyFetchedModels(models, for: snapshot.connectionIdentity)
                if models.isEmpty { self.modelFetchError = "No models returned. Load a model on your server and retry, or enter its ID with +." }
            } catch {
                guard !Task.isCancelled, self.modelFetchID == requestID,
                      self.draft.connectionIdentity == snapshot.connectionIdentity else { return }
                self.modelFetchError = error.localizedDescription
            }
        }
    }

    private func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(self.theme.typography.bodyStrong)
            control().textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel(title)
        }
    }
}

private struct ProviderChoiceStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(self.theme.palette.primaryText)
            .background(
                configuration.isPressed ? FluidBrandColors.blue.opacity(0.12) : self.theme.palette.cardBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}
