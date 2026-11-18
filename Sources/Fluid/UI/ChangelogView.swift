import SwiftUI

struct ChangelogView: View {
    @Environment(\.theme) private var theme

    @State private var releases: [SimpleUpdater.ReleaseNote] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var lastRefresh: Date?
    @State private var releasesChannel: String?
    @State private var refreshTask: Task<Void, Never>?

    private let owner = "altic-dev"
    private let repo = "Fluid-oss"
    private let releaseLimit = 3

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.text)
                }

                if self.releases.isEmpty, self.isRefreshing {
                    self.loadingCard
                } else if self.releases.isEmpty {
                    self.emptyCard
                } else {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        ForEach(Array(self.releases.enumerated()), id: \.element) { index, release in
                            ChangelogReleaseCard(
                                release: release,
                                isLatest: index == 0,
                                theme: self.theme
                            )
                        }
                    }
                }

                self.footer
            }
            .fluidPageContent(width: .reading)
        }
        .fluidCanvas()
        .fluidPageActions {
            Button {
                Task { await self.refreshReleases(force: true) }
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .fluidToolbarIcon()
                        .opacity(self.isRefreshing ? 0 : 1)
                    if self.isRefreshing { ProgressView().controlSize(.small) }
                }
                .frame(width: 22, height: 22)
            }
            .disabled(self.isRefreshing)
            .help("Refresh changelog")
            .accessibilityLabel("Refresh changelog")
        }
        .onAppear { self.loadCachedReleasesIfChannelChanged() }
        .onFluidPagePresented {
            self.loadCachedReleasesIfChannelChanged()
            self.refreshTask?.cancel()
            self.refreshTask = Task {
                if !self.releases.isEmpty {
                    // Saved notes are on screen, so the network result can wait for the page to settle.
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                }
                await self.refreshReleases()
            }
        }
        .onDisappear { self.refreshTask?.cancel() }
    }

    private var loadingCard: some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading release notes...")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyCard: some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No changelog available")
                    .fluidText(.groupTitle)
                    .foregroundStyle(self.theme.look.text)
                Text("FluidVoice could not load GitHub release notes right now.")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            if let url = URL(string: "https://github.com/\(self.owner)/\(self.repo)/releases") {
                Link("View older release notes on GitHub", destination: url)
                    .fluidAction()
            }

            Spacer()
        }
    }

    /// The page stays built across visits, so a beta setting change must replace the notes on screen.
    private func loadCachedReleasesIfChannelChanged() {
        let channel = Self.currentChannel
        guard self.releasesChannel != channel else { return }
        self.releasesChannel = channel
        self.lastRefresh = nil
        self.errorMessage = nil
        let cache = UserDefaults.standard.data(forKey: Self.cacheKey(for: channel))
            .flatMap { try? JSONDecoder().decode(ChangelogCache.self, from: $0) }
        self.releases = Array((cache?.releases ?? []).prefix(self.releaseLimit))
    }

    private func refreshReleases(force: Bool = false) async {
        guard !self.isRefreshing else { return }
        // Cached pages reappear often, and each refresh can re-render every release note.
        if !force, let lastRefresh = self.lastRefresh, Date().timeIntervalSince(lastRefresh) < 600 { return }

        self.loadCachedReleasesIfChannelChanged()
        let channel = Self.currentChannel
        self.isRefreshing = true
        self.errorMessage = nil

        do {
            let fetched = try await SimpleUpdater.shared.fetchRecentReleaseNotes(
                owner: self.owner,
                repo: self.repo,
                limit: self.releaseLimit,
                includePrerelease: channel == "beta"
            )
            let limitedReleases = Array(fetched.prefix(self.releaseLimit))
            self.saveCachedReleases(limitedReleases, channel: channel)
            if self.releasesChannel == channel {
                if limitedReleases != self.releases { self.releases = limitedReleases }
                self.lastRefresh = Date()
            }
        } catch {
            if self.releases.isEmpty {
                self.errorMessage = "Unable to load release notes."
            } else {
                self.errorMessage = "Showing saved release notes. Refresh failed."
            }
        }

        self.isRefreshing = false
    }

    private func saveCachedReleases(_ releases: [SimpleUpdater.ReleaseNote], channel: String) {
        let cache = ChangelogCache(releases: releases, savedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey(for: channel))
    }

    private static var currentChannel: String {
        SettingsStore.shared.betaReleasesEnabled ? "beta" : "stable"
    }

    private static func cacheKey(for channel: String) -> String {
        "FluidVoiceChangelogCache.\(channel)"
    }
}

private struct ChangelogCache: Codable {
    let releases: [SimpleUpdater.ReleaseNote]
    let savedAt: Date
}

private struct ChangelogReleaseCard: View {
    let release: SimpleUpdater.ReleaseNote
    let isLatest: Bool
    let theme: AppTheme

    var body: some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Text(self.release.title)
                                .fluidText(.groupTitle)
                                .foregroundStyle(self.theme.look.text)
                                .lineLimit(2)

                            if self.isLatest {
                                FluidChip(text: "Latest")
                            }

                            if self.release.isPrerelease {
                                FluidChip(text: "Beta", style: .outlined)
                            }
                        }

                        Text(self.metadataText)
                            .fluidText(.label)
                            .foregroundStyle(self.theme.look.tertiaryText)
                    }

                    Spacer()

                    if let url = self.release.url {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .font(.fluidSystem(size: 12, weight: .semibold))
                        }
                        .fluidGlassAction(circular: true, quiet: true)
                        .help("Open this release on GitHub")
                        .accessibilityLabel("Open this release on GitHub")
                    }
                }

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    ForEach(self.noteBlocks, id: \.self) { block in
                        ChangelogNoteBlock(block: block, theme: self.theme)
                    }
                }
            }
        }
    }

    private var metadataText: String {
        if let publishedAt = self.release.publishedAt {
            return "\(self.release.version) - \(publishedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return self.release.version
    }

    private var noteBlocks: [ChangelogNoteBlock.Model] {
        ChangelogNoteBlock.Model.make(
            from: self.release.notes,
            releaseTitle: self.release.title,
            version: self.release.version
        )
    }
}

private struct ChangelogNoteBlock: View {
    enum Kind: Hashable {
        case heading
        case bullet
        case paragraph
    }

    struct Model: Hashable {
        let kind: Kind
        let text: String

        static func make(from notes: String, releaseTitle: String, version: String) -> [Model] {
            var blocks: [Model] = []

            for rawLine in notes.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }

                if line.hasPrefix("#") {
                    let heading = String(line.drop { $0 == "#" })
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !self.shouldStop(atHeading: heading) else { break }
                    guard heading != releaseTitle, heading != version else { continue }

                    blocks.append(Model(kind: .heading, text: heading))
                    continue
                }

                guard !self.isBoilerplateLine(line) else { continue }

                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    blocks.append(Model(kind: .bullet, text: String(line.dropFirst(2))))
                    continue
                }

                blocks.append(Model(kind: .paragraph, text: line))
            }

            return blocks
        }

        private static func shouldStop(atHeading heading: String) -> Bool {
            heading.localizedCaseInsensitiveContains("contributors") ||
                heading.localizedCaseInsensitiveContains("need help")
        }

        private static func isBoilerplateLine(_ line: String) -> Bool {
            let lowercased = line.lowercased()
            return lowercased.contains("report issues:") ||
                lowercased.contains("github.com/altic-dev/fluidvoice/issues") ||
                lowercased.contains("github.com/altic-dev/fluid-oss/issues")
        }
    }

    let block: Model
    let theme: AppTheme

    var body: some View {
        switch self.block.kind {
        case .heading:
            Text(self.block.text)
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.text)
                .padding(.top, 2)
        case .bullet, .paragraph:
            // Each note is its own line; the look has no decorative bullets.
            Text(self.markdownAttributedString(from: self.block.text))
                .fluidText(.body)
                .foregroundStyle(self.theme.look.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(text)
        }
    }
}

#Preview {
    ChangelogView()
        .environment(\.theme, AppTheme.dark)
}
