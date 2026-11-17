import SwiftUI

/// What the cleanup pop-up lists for one language. Pure so it can be tested without the UI.
struct CleanupModelPickerContent: Equatable {
    enum Support: Equatable {
        case yes
        case no
        /// The model registry lists no languages for this model.
        case notListed
    }

    let languageID: String
    let languageName: String
    let listed: [PrivateAIRegisteredModel]
    /// Models whose language list leaves out the user's language.
    let hidden: [PrivateAIRegisteredModel]
    /// No model is trained for the language, so every model is listed to try.
    let isUntrained: Bool
    let suggestedModelID: String?

    init(languageID: String, languageName: String, models: [PrivateAIRegisteredModel], recommendedModelID: String?) {
        let support = { (model: PrivateAIRegisteredModel) in Self.support(model, languageID: languageID) }
        let isUntrained = !models.contains { support($0) == .yes }
        let visible = isUntrained ? models : models.filter { support($0) != .no }
        let suggested = visible.first { model in
            model.id == recommendedModelID && (isUntrained || support(model) == .yes)
        }
        self.languageID = languageID
        self.languageName = languageName
        self.isUntrained = isUntrained
        self.suggestedModelID = suggested?.id
        self.listed = visible.filter { $0.id == suggested?.id } + visible.filter { $0.id != suggested?.id }
        self.hidden = isUntrained ? [] : models.filter { support($0) == .no }
    }

    var tag: ModelPickerTag { self.isUntrained ? .tryFirst : .recommended }

    static func support(_ model: PrivateAIRegisteredModel, languageID: String) -> Support {
        if model.supportedLanguageIDs.isEmpty { return .notListed }
        return model.supportedLanguageIDs.contains(languageID) ? .yes : .no
    }

    func support(_ model: PrivateAIRegisteredModel) -> Support {
        Self.support(model, languageID: self.languageID)
    }
}

extension PrivateAIRegisteredModel {
    /// The bridge's copy first; the local fallback only for builds without it.
    var shownPresentation: PrivateAIModelPresentation {
        self.presentation ?? .forModel(id: self.id)
    }
}

struct CleanupModelPicker: View {
    @Environment(\.theme) private var theme
    @ObservedObject var controller: PrivateAISettingsController
    let content: CleanupModelPickerContent
    let memoryBytes: UInt64?
    let close: () -> Void
    let sendFeedback: (PrivateAIRegisteredModel) -> Void

    @State private var selectedModelID: String?
    @State private var files: [String: PrivateAIModelFiles] = [:]
    @State private var sort = ModelPickerSort.suggested

    private static let columns = ModelPickerColumns(first: "Speed", second: "Quality", scale: 5)

    private struct ReadIdentity: Equatable {
        let selectedID: String
        let busy: Bool
    }

    private var selectedModel: PrivateAIRegisteredModel? {
        self.content.listed.first { $0.id == self.selectedModelID } ?? self.content.listed.first
    }

    private var rows: [ModelPickerRow] {
        self.content.listed.map { model in
            let presentation = model.shownPresentation
            let support = self.content.support(model)
            return ModelPickerRow(
                id: model.id,
                name: model.displayName,
                logo: .cleanup,
                firstValue: presentation.speed,
                secondValue: presentation.intelligence,
                notListedNote: !self.content.isUntrained && support == .notListed,
                badge: presentation.badge,
                isInUse: self.controller.isActive(model, installed: self.files[model.id]?.installed == true),
                tag: model.id == self.content.suggestedModelID ? self.content.tag : nil
            )
        }
    }

    var body: some View {
        let rows = self.sort.apply(self.rows)
        let best = ModelPickerColumns.bestValues(rows)
        ModelPickerSheet(title: "Cleanup model", close: self.close) {
            if let memory = self.memoryText { Text("This Mac: \(memory) ·") }
            Text("Your language: \(self.content.languageName) · Sort by:")
            ModelPickerSortMenu(columns: Self.columns, sort: self.$sort)
        } notice: {
            if self.content.isUntrained {
                self.untrainedNotice
            }
        } list: {
            ModelPickerListHeader(columns: Self.columns)
            ForEach(rows) { row in
                ModelPickerRowView(row: row, columns: Self.columns, best: best, isSelected: row.id == self.selectedModel?.id, isFirst: row.id == rows.first?.id) {
                    self.selectedModelID = row.id
                }
            }
            if let note = self.listNote {
                ModelPickerListNote(text: note)
            }
        } detail: {
            if let model = self.selectedModel {
                self.detail(model)
            }
        } footer: {
            if let model = self.selectedModel {
                self.footer(model)
            }
        }
        .task(id: ReadIdentity(selectedID: self.controller.privateAISelectedModelID, busy: self.controller.isBusy)) {
            guard !self.controller.isBusy else { return }
            let files = await PrivateAISettingsController.readModelFiles(self.content.listed)
            guard !Task.isCancelled else { return }
            self.files = files
        }
    }

    private var memoryText: String? {
        ModelPickerFormat.memory(self.memoryBytes)
    }

    private var listNote: String? {
        var notes: [String] = []
        if !self.content.hidden.isEmpty {
            let names = ListFormatter.localizedString(byJoining: self.content.hidden.map(\.displayName))
            notes.append("\(names) \(self.content.hidden.count == 1 ? "doesn’t" : "don’t") support \(self.content.languageName).")
        }
        let listedNames = Set(self.content.listed.map(\.displayName))
        let upcoming = PrivateAIUpcomingModel.allCases.map(\.title).filter { !listedNames.contains($0) }
        if !upcoming.isEmpty {
            notes.append("Coming soon: \(ListFormatter.localizedString(byJoining: upcoming)).")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private var untrainedNotice: some View {
        FluidNoticeBanner(
            title: "No cleanup model is trained for \(self.content.languageName) yet",
            message: "You can still try one, and it may work well. If it doesn’t, tell us and we’ll work on it."
        ) {
            Button("Send feedback") {
                if let model = self.selectedModel { self.sendFeedback(model) }
            }
            .fluidAction()
        }
    }

    @ViewBuilder
    private func detail(_ model: PrivateAIRegisteredModel) -> some View {
        let presentation = model.shownPresentation
        let isSuggested = model.id == self.content.suggestedModelID
        let languageNames = model.supportedLanguageIDs.map(VoiceEngineLanguageCatalog.displayName(forLanguageID:))
        ModelPickerDetailHeader(
            title: model.displayName,
            logo: .cleanup,
            summary: self.summary(model, presentation: presentation, isSuggested: isSuggested)
        )
        if languageNames.isEmpty {
            FluidFactRow(label: "Supported languages", value: "Not listed")
        } else {
            ModelPickerLanguagesRow(
                yourLanguage: self.content.languageName,
                supportsYourLanguage: self.content.support(model) == .yes,
                otherLanguages: languageNames.filter { $0 != self.content.languageName }.sorted()
            )
        }
        if let memory = model.recommendedMemoryGB {
            FluidFactRow(label: "Good for", value: "\(memory) GB Macs and up")
        }
        if let bytes = model.artifact.byteCount, bytes > 0 {
            FluidFactRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
    }

    private func summary(_ model: PrivateAIRegisteredModel, presentation: PrivateAIModelPresentation, isSuggested: Bool) -> String {
        guard isSuggested else { return presentation.useCase }
        if self.content.isUntrained {
            return "Not trained for \(self.content.languageName), but it’s the best fit for your Mac, so try it first."
        }
        // The header already shows this Mac's memory, so the reason does not repeat it.
        guard self.memoryBytes != nil else { return "Recommended for \(self.content.languageName)." }
        return "Recommended because it works with \(self.content.languageName) and fits your Mac."
    }

    @ViewBuilder
    private func footer(_ model: PrivateAIRegisteredModel) -> some View {
        let state = self.controller.privateAILoadState
        let files = self.files[model.id]
        let needsDownload = state.needsDownload(model.id)
        let installed = files?.installed == true && !needsDownload
        if state.isDownloading(model.id) {
            self.status(PrivateAIModelDownloadProgressText.detailText(for: state.downloadProgress(for: model.id)))
            Spacer(minLength: 0)
            Button("Close", action: self.close).fluidAction(size: .large).keyboardShortcut(.cancelAction)
        } else if state.isLoading(model.id) {
            self.status("Preparing…")
            Spacer(minLength: 0)
            Button("Close", action: self.close).fluidAction(size: .large).keyboardShortcut(.cancelAction)
        } else if self.controller.isActive(model, installed: files?.installed == true) {
            Spacer(minLength: 0)
            Button("Done", action: self.close)
                .fluidAction(.primary, size: .large)
                .keyboardShortcut(.cancelAction)
        } else {
            if let failure = state.failureMessage(for: model.id) {
                Text(failure).fluidText(.label).foregroundStyle(self.theme.palette.warning).lineLimit(1).help(failure)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: self.close)
                .fluidAction(size: .large)
                .keyboardShortcut(.cancelAction)
            Button(self.primaryTitle(installed: installed, needsDownload: needsDownload)) {
                self.controller.previewModel(model.id)
                self.controller.usePreviewModel(isInstalled: installed, onReady: {})
            }
            .fluidAction(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(self.controller.isBusy || files == nil || (!installed && !model.canDownload))
        }
    }

    private func primaryTitle(installed: Bool, needsDownload: Bool) -> String {
        if needsDownload { return "Download again" }
        let verb = self.content.isUntrained ? "try" : "use"
        return installed ? (self.content.isUntrained ? "Try this model" : "Use this model") : "Download and \(verb)"
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .fluidText(.label)
            .foregroundStyle(self.theme.look.secondaryText)
            .lineLimit(1)
            .monospacedDigit()
    }
}
