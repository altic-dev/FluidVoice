import AppKit
import SwiftUI

/// The one place that shows where every downloaded model lives and lets the user move them.
struct ModelStorageSettingsSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var monitor = ModelStorageMonitor.shared
    @StateObject private var flow = ModelStorageChoiceFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.fluidSystem(.headline))
                    .foregroundStyle(.primary)
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Storage Location")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("Speech, helper and meeting models are downloaded to this folder. You can choose a folder on an external drive.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(self.monitor.configuration.usesCustomRoot ? self.monitor.displayPath : "Default (inside your Library folder)")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(self.monitor.displayPath)
                self.statusLine
            }

            if let progress = self.monitor.moveProgress {
                self.moveProgressView(progress)
            } else {
                self.actions
            }

            ForEach(self.messages, id: \.self) { message in
                Text(message)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !self.monitor.leftoverLinks.isEmpty, self.monitor.moveProgress == nil {
                HStack(spacing: 8) {
                    Text("Links to the old folders are still in place.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button("Remove leftover links") { self.monitor.removeLeftoverLinks() }
                        .controlSize(.small)
                }
            }

            Divider()

            self.overview
        }
        .task { await self.monitor.refresh() }
        .modelStorageChoiceDialog(self.flow)
    }

    // MARK: - Pieces

    @ViewBuilder private var statusLine: some View {
        if let problem = self.monitor.availability.problemDescription {
            Label(problem, systemImage: "externaldrive.badge.exclamationmark")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
        } else if let free = self.monitor.freeBytes {
            let volume = self.monitor.volumeName.map { " on \($0)" } ?? ""
            Text("\(ModelStorageChoiceFlow.bytes(free)) available\(volume)")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Choose…") { self.flow.chooseFolder() }
            Button("Reveal in Finder") { self.reveal(self.monitor.configuration.resolvedRootURL ?? ModelStorageLocation.fluidAudioModelsDirectory()) }
                .disabled(!self.monitor.availability.isUsable)
            Button("Reset to default") { self.flow.prepare(.defaultLocations) }
                .disabled(!self.monitor.configuration.usesCustomRoot)
            if self.monitor.configuration.usesCustomRoot, self.monitor.availability.isUsable {
                Button("Release models for eject") { self.monitor.releaseModels() }
                    .help("Unloads the dictation model so the drive can be ejected. It loads again when you next dictate. Close other apps that use files on the drive as well.")
            }
            if self.flow.isPlanning {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.small)
        .disabled(self.flow.isPlanning)
    }

    /// Lists every kind of model, including the ones this setting does not move, so nothing is a surprise.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where models are stored")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)
            self.overviewRow(
                title: "Speech and helper models",
                detail: "Fluid Speech, Parakeet, Whisper, Qwen3 ASR, Cohere and Nemotron, plus voice detection and vocabulary boosting.",
                location: self.chosenLocationText
            )
            self.overviewRow(
                title: "Meeting models",
                detail: "The FluidMeet speaker label model.",
                location: self.chosenLocationText
            )
            if PrivateAIProviderFeature.shared.isAvailable {
                self.overviewRow(
                    title: "Fluid Intelligence models",
                    detail: "Cleanup and Edit models are managed by Fluid Intelligence and are not moved by this setting.",
                    location: PrivateAIIntegrationService.modelDirectoryURL.path,
                    revealURL: PrivateAIIntegrationService.modelDirectoryURL
                )
            }
            self.overviewRow(
                title: "Optimized copies",
                detail: "macOS and FluidVoice keep prepared copies of some models in your Library's Caches folder. They are rebuilt automatically if removed.",
                location: ModelStorageLocation.defaultCachesDirectory.path
            )
        }
    }

    private func overviewRow(title: String, detail: String, location: String, revealURL: URL? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text((location as NSString).abbreviatingWithTildeInPath)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(location)
            }
            Spacer(minLength: 12)
            if let revealURL {
                Button("Reveal") { self.reveal(revealURL) }
                    .controlSize(.small)
            }
        }
    }

    private var chosenLocationText: String {
        self.monitor.configuration.usesCustomRoot ? self.monitor.displayPath : "Default location in your Library folder"
    }

    private func moveProgressView(_ progress: ModelStorageMoveProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if progress.totalBytes > 0 {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Model move progress")
                    .accessibilityValue(Self.phaseText(progress))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Self.phaseText(progress))
            }
            HStack(spacing: 8) {
                Text(Self.phaseText(progress))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                if self.monitor.canCancelMove {
                    Button("Cancel") { self.monitor.cancelMove() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var messages: [String] {
        [self.flow.errorMessage, self.monitor.lastMoveMessage, self.monitor.interruptedMoveNotice].compactMap { $0 }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func phaseText(_ progress: ModelStorageMoveProgress) -> String {
        let amount = progress.totalBytes > 0
            ? " · \(ModelStorageChoiceFlow.bytes(progress.completedBytes)) of \(ModelStorageChoiceFlow.bytes(progress.totalBytes))"
            : ""
        switch progress.phase {
        case .copying: return "Copying models\(amount)"
        case .verifying: return "Verifying the copy\(amount)"
        case .waitingForIdle: return "Waiting for dictation to finish"
        case .switching: return "Switching folders"
        case .cleaningUp: return "Removing the originals"
        }
    }
}
