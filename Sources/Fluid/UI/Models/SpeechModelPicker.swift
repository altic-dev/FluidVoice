import Combine
import SwiftUI

/// What the speech pop-up lists for one language. Pure so it can be tested without the UI.
struct SpeechModelPickerContent: Equatable {
    let language: VoiceEngineLanguage
    /// One route per model that can transcribe the language; the recommended model comes first.
    let routes: [VoiceEngineLanguageRoute]
    let recommended: SettingsStore.SpeechModel?
    /// Fluid Speech models that exist on this Mac but can't transcribe the language.
    let unsupportedFluidModels: [SettingsStore.SpeechModel]

    static let fluidModels: [SettingsStore.SpeechModel] = [.fluidParakeetPro, .fluidParakeetMini, .fluidParakeetPico]

    init(languageID: String, memoryBytes: UInt64?, availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels) {
        let language = VoiceEngineLanguageCatalog.language(id: languageID, availableModels: availableModels)
            ?? VoiceEngineLanguageCatalog.language(id: "en", availableModels: availableModels)
            ?? VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
        var seen = Set<SettingsStore.SpeechModel>()
        let routes = VoiceEngineLanguageCatalog.routes(for: language, availableModels: availableModels).filter { seen.insert($0.model).inserted }
        let recommended = memoryBytes.flatMap {
            DashboardModelRecommendationPolicy.speechModel(memoryBytes: $0, language: language.id, available: routes.map(\.model))
        }
        self.language = language
        self.recommended = recommended
        self.routes = routes.filter { $0.model == recommended } + routes.filter { $0.model != recommended }
        self.unsupportedFluidModels = Self.fluidModels.filter { model in
            availableModels.contains(model) && !routes.contains { $0.model == model }
        }
    }

    /// True when this route is what dictation uses now. Models that detect the language
    /// count for every language; models with a language setting only for that language.
    static func isInUse(_ route: VoiceEngineLanguageRoute, settings: SettingsStore) -> Bool {
        guard route.model == settings.selectedSpeechModel else { return false }
        guard let bound = VoiceEngineLanguageCatalog.boundLanguageID(settings: settings) else { return true }
        return bound == route.language.id
    }
}

/// Picker state, created once per opening so page redraws never redo the catalog work.
@MainActor
final class SpeechModelPickerState: ObservableObject {
    @Published var languageID: String {
        didSet {
            guard self.languageID != oldValue else { return }
            self.content = SpeechModelPickerContent(languageID: self.languageID, memoryBytes: self.memoryBytes)
            self.selectedModel = self.content.recommended ?? self.content.routes.first?.model
        }
    }

    @Published private(set) var content: SpeechModelPickerContent
    @Published var selectedModel: SettingsStore.SpeechModel?
    @Published private(set) var languageNames: [SettingsStore.SpeechModel: [String]] = [:]
    let popularLanguages = VoiceEngineLanguageCatalog.popularLanguages()
    let allLanguages = VoiceEngineLanguageCatalog.allLanguages()
    private(set) var memoryBytes: UInt64?

    init(settings: SettingsStore, memoryBytes: UInt64?) {
        let content = SpeechModelPickerContent(
            languageID: VoiceEngineLanguageCatalog.preferredLanguageID(settings: settings),
            memoryBytes: memoryBytes
        )
        self.memoryBytes = memoryBytes
        self.content = content
        self.languageID = content.language.id
        let inUse = content.routes.first { SpeechModelPickerContent.isInUse($0, settings: settings) }?.model
        self.selectedModel = content.recommended ?? inUse ?? content.routes.first?.model
    }

    func updateMemory(_ memoryBytes: UInt64?) {
        guard memoryBytes != self.memoryBytes else { return }
        self.memoryBytes = memoryBytes
        self.content = SpeechModelPickerContent(languageID: self.languageID, memoryBytes: memoryBytes)
    }

    func loadLanguageNames(for model: SettingsStore.SpeechModel) {
        guard self.languageNames[model] == nil else { return }
        self.languageNames[model] = VoiceEngineLanguageCatalog.languages(supportedBy: model).map(\.displayName)
    }
}

struct SpeechModelPicker: View {
    @Environment(\.theme) private var theme
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    let memoryBytes: UInt64?
    let close: () -> Void
    @StateObject private var state: SpeechModelPickerState
    @State private var sort = ModelPickerSort.suggested

    init(viewModel: VoiceEngineSettingsViewModel, settings: SettingsStore, memoryBytes: UInt64?, close: @escaping () -> Void) {
        self.viewModel = viewModel
        self.settings = settings
        self.memoryBytes = memoryBytes
        self.close = close
        self._state = StateObject(wrappedValue: SpeechModelPickerState(settings: settings, memoryBytes: memoryBytes))
    }

    private var content: SpeechModelPickerContent { self.state.content }

    private static let columns = ModelPickerColumns(first: "Speed", second: "Accuracy")

    private var rows: [ModelPickerRow] {
        self.content.routes.map { route in
            ModelPickerRow(
                id: route.model.id,
                name: route.model.humanReadableName,
                logo: .speech(route.model),
                firstValue: Int((route.model.speedPercent * 100).rounded()),
                secondValue: Int((route.model.accuracyPercent * 100).rounded()),
                badge: route.model.isNew ? "New" : nil,
                isInUse: SpeechModelPickerContent.isInUse(route, settings: self.settings),
                tag: route.model == self.content.recommended ? .recommended : nil
            )
        }
    }

    private var selectedRoute: VoiceEngineLanguageRoute? {
        self.content.routes.first { $0.model == self.state.selectedModel } ?? self.content.routes.first
    }

    var body: some View {
        let rows = self.sort.apply(self.rows)
        let best = ModelPickerColumns.bestValues(rows)
        ModelPickerSheet(title: "Speech model", close: self.close) {
            if let memory = self.memoryText { Text("This Mac: \(memory) ·") }
            Text("Your language:")
            self.languageMenu
            Text("· Sort by:")
            ModelPickerSortMenu(columns: Self.columns, sort: self.$sort)
        } notice: {
            EmptyView()
        } list: {
            ModelPickerListHeader(columns: Self.columns)
            ForEach(rows) { row in
                ModelPickerRowView(row: row, columns: Self.columns, best: best, isSelected: row.id == self.selectedRoute?.model.id, isFirst: row.id == rows.first?.id) {
                    self.state.selectedModel = SettingsStore.SpeechModel(rawValue: row.id)
                }
            }
            if !self.content.unsupportedFluidModels.isEmpty {
                ModelPickerListNote(text: "\(Self.naturalList(self.content.unsupportedFluidModels.map(\.humanReadableName))) don’t support \(self.content.language.displayName) yet.")
            }
        } detail: {
            if let route = self.selectedRoute {
                self.detail(route)
            }
        } footer: {
            if let route = self.selectedRoute {
                self.footer(route)
            }
        }
        .onChange(of: self.memoryBytes) { _, newValue in self.state.updateMemory(newValue) }
        .task(id: self.selectedRoute?.model) {
            if let model = self.selectedRoute?.model { self.state.loadLanguageNames(for: model) }
        }
    }

    private var memoryText: String? {
        ModelPickerFormat.memory(self.memoryBytes)
    }

    private var languageMenu: some View {
        FluidDropdownPicker("Your language", selectedTitle: self.content.language.displayName, selection: self.$state.languageID) {
            Section("Popular") {
                ForEach(self.state.popularLanguages) { Text($0.popularDisplayName).tag($0.id) }
            }
            Section("All languages") {
                ForEach(self.state.allLanguages) { Text($0.displayName).tag($0.id) }
            }
        }
        .fluidDropdownStyle(appearance: .text, tone: self.theme.look.secondaryText)
        .fixedSize()
    }

    @ViewBuilder
    private func detail(_ route: VoiceEngineLanguageRoute) -> some View {
        let model = route.model
        let isRecommended = model == self.content.recommended
        ModelPickerDetailHeader(
            title: model.humanReadableName,
            logo: .speech(model),
            summary: isRecommended ? self.recommendationReason : model.cardDescription
        )
        ModelPickerLanguagesRow(
            yourLanguage: route.language.displayName,
            supportsYourLanguage: true,
            otherLanguages: (self.state.languageNames[model] ?? []).filter { $0 != route.language.displayName }.sorted()
        )
        FluidFactRow(label: "Words while you talk", value: model.supportsStreaming ? "Yes" : "No, they appear when you stop")
        if let minimum = DashboardModelRecommendationPolicy.minimumMemoryGB(for: model) {
            FluidFactRow(label: "Good for", value: "\(minimum) GB Macs and up")
        }
        FluidFactRow(label: "Size", value: self.sizeText(model))
    }

    /// The header already shows this Mac's memory, so the reason does not repeat it.
    private var recommendationReason: String {
        guard self.memoryBytes != nil else { return "Recommended for \(self.content.language.displayName)." }
        return "Recommended because it works with \(self.content.language.displayName) and fits your Mac."
    }

    private func sizeText(_ model: SettingsStore.SpeechModel) -> String {
        self.viewModel.speechModelDownloadSize(model)
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    @ViewBuilder
    private func footer(_ route: VoiceEngineLanguageRoute) -> some View {
        let model = route.model
        let inUse = SpeechModelPickerContent.isInUse(route, settings: self.settings)
        if self.viewModel.downloadingModel == model {
            Text(self.viewModel.isCancellingModelDownload ? "Cancelling…" : "Downloading… \(Int((self.viewModel.downloadProgress * 100).rounded()))%")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 0)
            Button("Cancel download", action: self.viewModel.cancelSpeechModelDownload)
                .fluidAction(size: .large)
                .disabled(self.viewModel.isCancellingModelDownload)
        } else if inUse {
            if self.viewModel.isPreparingSelectedModel {
                Text("Preparing…").fluidText(.label).foregroundStyle(self.theme.look.secondaryText)
            }
            Spacer(minLength: 0)
            Button("Done", action: self.close)
                .fluidAction(.primary, size: .large)
                .keyboardShortcut(.cancelAction)
        } else {
            if self.viewModel.areSpeechModelActionsBlocked {
                Text("Another model is busy. Try again in a moment.")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: self.close)
                .fluidAction(size: .large)
                .keyboardShortcut(.cancelAction)
            let installed = self.viewModel.isSpeechModelInstalled(model)
            Button(installed ? "Use this model" : "Download and use") {
                if installed {
                    self.viewModel.activateSpeechRoute(route)
                    self.close()
                } else {
                    self.viewModel.downloadAndActivateSpeechRoute(route)
                }
            }
            .fluidAction(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(self.viewModel.areSpeechModelActionsBlocked)
        }
    }

    static func naturalList(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }
}
