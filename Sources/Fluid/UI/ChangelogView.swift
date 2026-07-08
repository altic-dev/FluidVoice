import SwiftUI

struct ChangelogView: View {
    @Environment(\.theme) private var theme

    @State private var releases: [SimpleUpdater.ReleaseNote] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    private let owner = "altic-dev"
    private let repo = "Fluid-oss"
    private let releaseLimit = 3

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                self.header

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
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .task {
            self.loadCachedReleases()
            await self.refreshReleases()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(self.theme.palette.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Change logs")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(self.theme.palette.primaryText)
                }

                Spacer()

                if self.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await self.refreshReleases(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh changelog")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "wifi.exclamationmark")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private var loadingCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading release notes...")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var emptyCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Text("No changelog available")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("FluidVoice could not load GitHub release notes right now.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let url = URL(string: "https://github.com/\(self.owner)/\(self.repo)/releases") {
                Link(destination: url) {
                    Label("View older release notes on GitHub", systemImage: "arrow.up.right.square")
                        .font(self.theme.typography.bodySmallStrong)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .fluidButton(.glass, size: .medium)
                .buttonHoverEffect()
            }

            Spacer()
        }
    }

    private func loadCachedReleases() {
        let cacheKey = self.cacheKey
        guard
            let data = UserDefaults.standard.data(forKey: cacheKey),
            let cache = try? JSONDecoder().decode(ChangelogCache.self, from: data)
        else { return }

        self.releases = Array(cache.releases.prefix(self.releaseLimit))
    }

    private func refreshReleases(force _: Bool = false) async {
        guard !self.isRefreshing else { return }

        self.isRefreshing = true
        self.errorMessage = nil

        do {
            let includePrerelease = SettingsStore.shared.betaReleasesEnabled
            let fetched = try await SimpleUpdater.shared.fetchRecentReleaseNotes(
                owner: self.owner,
                repo: self.repo,
                limit: self.releaseLimit,
                includePrerelease: includePrerelease
            )
            let limitedReleases = Array(fetched.prefix(self.releaseLimit))
            self.releases = limitedReleases
            self.saveCachedReleases(limitedReleases)
        } catch {
            if self.releases.isEmpty {
                self.errorMessage = "Unable to load release notes."
            } else {
                self.errorMessage = "Showing saved release notes. Refresh failed."
            }
        }

        self.isRefreshing = false
    }

    private func saveCachedReleases(_ releases: [SimpleUpdater.ReleaseNote]) {
        let cache = ChangelogCache(releases: releases, savedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: self.cacheKey)
    }

    private var cacheKey: String {
        let channel = SettingsStore.shared.betaReleasesEnabled ? "beta" : "stable"
        return "FluidVoiceChangelogCache.\(channel)"
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
        ThemedCard(style: self.isLatest ? .prominent : .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Text(self.release.title)
                                .font(self.theme.typography.sectionTitle)
                                .foregroundStyle(self.theme.palette.primaryText)
                                .lineLimit(2)

                            if self.isLatest {
                                Text("Latest")
                                    .font(self.theme.typography.badge)
                                    .foregroundStyle(self.theme.palette.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(self.theme.palette.accent.opacity(0.12))
                                    )
                            }

                            if self.release.isPrerelease {
                                Text("Beta")
                                    .font(self.theme.typography.badge)
                                    .foregroundStyle(self.theme.palette.warning)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(self.theme.palette.warning.opacity(0.12))
                                    )
                            }
                        }

                        Text(self.metadataText)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.tertiaryText)
                    }

                    Spacer()

                    if let url = self.release.url {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .font(self.theme.typography.captionStrong)
                                .padding(7)
                        }
                        .buttonStyle(.borderless)
                        .help("Open this release on GitHub")
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
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .padding(.top, 2)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.75))
                    .frame(width: 4, height: 4)
                Text(self.markdownAttributedString(from: self.block.text))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(self.markdownAttributedString(from: self.block.text))
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
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
