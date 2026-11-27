import AppKit
import Combine
import SwiftUI

/// Picks a model storage folder, measures what would move, and asks before moving anything.
@MainActor
final class ModelStorageChoiceFlow: ObservableObject {
    @Published var pendingPlan: ModelStorageMovePlan?
    @Published private(set) var isPlanning = false
    @Published var errorMessage: String?

    private let monitor: ModelStorageMonitor

    init(monitor: ModelStorageMonitor = .shared) {
        self.monitor = monitor
    }

    /// With `switchWhenNothingToMove`, a folder change that moves nothing happens without a dialog.
    func chooseFolder(switchWhenNothingToMove: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for FluidVoice models."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = ModelStorageLocation.unsuitableFolderReason(url) {
            self.errorMessage = problem
            return
        }
        self.prepare(.custom(root: url), switchWhenNothingToMove: switchWhenNothingToMove)
    }

    func prepare(_ target: ModelStorageConfiguration, switchWhenNothingToMove: Bool = false) {
        self.errorMessage = nil
        self.monitor.dismissMessages()
        if let message = self.monitor.blockingActivityMessage() {
            self.errorMessage = message
            return
        }
        let isSameFolder = target.resolvedRootURL?.path == self.monitor.configuration.resolvedRootURL?.path
        guard !isSameFolder || !self.monitor.availability.isUsable else { return }
        self.isPlanning = true
        Task {
            defer { self.isPlanning = false }
            // A read-only or unreachable folder would leave every download blocked after the switch.
            let availability = await Task.detached { ModelStorageLocation.probe(target) }.value
            if let problem = availability.problemDescription {
                self.errorMessage = problem
                return
            }
            if isSameFolder {
                // Picking the current folder again records the drive that holds it now, for example a replacement drive.
                ModelStorageLocation.apply(target)
                await self.monitor.refresh()
                return
            }
            do {
                let plan = try await self.monitor.plan(for: target)
                if switchWhenNothingToMove, plan.items.isEmpty, !plan.destinationHasModels {
                    self.monitor.start(plan, choice: .useExisting)
                } else {
                    self.pendingPlan = plan
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Text

    var dialogTitle: String {
        self.pendingPlan?.to.usesCustomRoot == false ? "Move models back to the default location?" : "Move models to this folder?"
    }

    static func dialogMessage(for plan: ModelStorageMovePlan) -> String {
        var lines: [String] = []
        if plan.items.isEmpty {
            lines.append("There are no models to move.")
        } else {
            lines.append("\(Self.bytes(plan.totalBytes)) of models can be moved. The originals are deleted only after the copy is verified.")
            if !plan.hasEnoughSpace {
                let free = plan.availableBytes.map(Self.bytes) ?? "an unknown amount"
                lines.append("The new location needs \(Self.bytes(plan.requiredBytes)) free, but only \(free) is available.")
            }
        }
        if plan.destinationHasModels {
            lines.append("This folder already has models for \(plan.alreadyAtDestination.map(\.name).joined(separator: ", ")). They are used as they are.")
        }
        return lines.joined(separator: "\n\n")
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct ModelStorageChoiceDialog: ViewModifier {
    @ObservedObject var flow: ModelStorageChoiceFlow
    @ObservedObject var monitor: ModelStorageMonitor

    func body(content: Content) -> some View {
        content.confirmationDialog(
            self.flow.dialogTitle,
            isPresented: Binding(get: { self.flow.pendingPlan != nil }, set: { if !$0 { self.flow.pendingPlan = nil } }),
            titleVisibility: .visible,
            presenting: self.flow.pendingPlan
        ) { plan in
            if !plan.items.isEmpty, plan.hasEnoughSpace {
                Button("Move models (\(ModelStorageChoiceFlow.bytes(plan.totalBytes)))") { self.monitor.start(plan, choice: .moveExisting) }
            }
            Button(plan.destinationHasModels ? "Use models already there" : "Don't move models") {
                self.monitor.start(plan, choice: .useExisting)
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(ModelStorageChoiceFlow.dialogMessage(for: plan))
        }
    }
}

extension View {
    func modelStorageChoiceDialog(_ flow: ModelStorageChoiceFlow, monitor: ModelStorageMonitor = .shared) -> some View {
        self.modifier(ModelStorageChoiceDialog(flow: flow, monitor: monitor))
    }
}

extension ModelStorageAvailability {
    /// A short sentence for the user, or nil when the location is usable.
    var problemDescription: String? {
        switch self {
        case .defaultLocations, .available:
            return nil
        case let .driveNotConnected(volumeName, _):
            return volumeName.map { "Model drive \"\($0)\" is not connected. Models become available again when you connect it." }
                ?? "Model drive is not connected. Models become available again when you connect it."
        case .folderMissing:
            return "The drive is connected, but the model folder was moved or deleted."
        case .accessDenied:
            return "FluidVoice cannot read or write the model folder. Check Files & Folders in Privacy & Security settings."
        }
    }
}
