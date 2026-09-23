import AppKit
import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    @Environment(\.theme) private var theme
    @StateObject private var controller = MeetingSummaryController()
    @State private var confirmDeletion = false
    @State private var kind = MeetingSummaryKind.executive

    private var refreshID: String {
        "\(self.session?.id.uuidString ?? "home")-\(self.session?.updatedAt.timeIntervalSince1970 ?? 0)-\(self.kind.rawValue)"
    }

    private var hint: String {
        if self.session == nil, self.controller.installed {
            return "Open a completed meeting to summarize its transcript."
        }
        return "Summaries, decisions, and action items, generated on your Mac."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Your meeting, summed up.")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(self.controller.model == nil ? "Meeting summaries require a build with Fluid Intelligence." : self.hint)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            if self.controller.model != nil {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if self.controller.installed {
                        Picker("Summary type", selection: self.$kind) {
                            ForEach(MeetingSummaryKind.allCases) { kind in Text(kind.title).tag(kind) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fluidDropdownStyle()
                        .fixedSize()
                        .disabled(self.controller.busy)
                    }
                    self.actions
                }
                if self.controller.downloading {
                    Text(PrivateAIModelDownloadProgressText.detailText(for: self.controller.progress))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                if let error = self.controller.error {
                    Text(error).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.warning)
                        .textSelection(.enabled)
                }
                if !self.controller.output.isEmpty {
                    CommandMarkdownContent(text: self.controller.output)
                }
            }
            Label("On-device · English · Frees its memory when done", systemImage: "lock")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
        .task(id: self.refreshID) { await self.controller.refresh(session: self.session, kind: self.kind) }
        .onDisappear { self.controller.cancel() }
        .alert("Delete summary model?", isPresented: self.$confirmDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let asrService { self.controller.deleteModel(asr: asrService) }
            }
        } message: {
            Text("Remove the 1.45 GB download from this Mac. Your meetings and saved summaries stay. You can download it again anytime.")
        }
    }

    private var actions: some View {
        FluidGlassControlGroup {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.controller.checking {
                    ProgressView().controlSize(.small)
                } else if self.controller.downloading {
                    Button {} label: {
                        VStack(spacing: 4) {
                            Text(PrivateAIModelDownloadProgressText.buttonTitle(for: self.controller.progress))
                            ProgressView(value: self.controller.progress?.fractionCompleted)
                                .progressViewStyle(.linear)
                                .frame(width: 160)
                                .controlSize(.mini)
                        }
                    }
                    .fluidGlassAction()
                    .disabled(true)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else if self.controller.deleting {
                    ProgressView().controlSize(.small)
                    Text("Deleting download…").font(self.theme.typography.bodySmall)
                } else if !self.controller.installed {
                    Button("Download · 1.45 GB", systemImage: "arrow.down.circle") { self.controller.download() }
                        .fluidGlassAction(prominent: true)
                        .disabled(!self.isQuiescent)
                } else if self.controller.generating {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(self.theme.typography.bodySmall)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else {
                    Button("Summarize", systemImage: "sparkles") {
                        if let session, let asrService {
                            self.controller.summarize(session: session, kind: self.kind, asr: asrService)
                        }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(self.session?.transcriptSegments.isEmpty != false || self.asrService == nil || !self.isQuiescent)
                }
                Menu {
                    Button("Delete model", systemImage: "trash", role: .destructive) {
                        self.confirmDeletion = true
                    }
                    .disabled(!self.controller.installed || self.controller.busy || self.controller.checking || !self.isQuiescent || self.asrService == nil)
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden)
                    .fluidGlassAction(circular: true)
                    .accessibilityLabel("Meeting summary actions")
                    .disabled(self.controller.busy)
                if !self.controller.output.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.controller.output, forType: .string)
                    }
                    .fluidGlassAction()
                }
            }
        }
    }
}
