import SwiftUI

/// Grouped search results shown in place of the sidebar sections while the search
/// box has text. Each category independently toggles between a preview and all hits.
struct AppSearchResultsView: View {
    static let rowsPerGroup = 5

    @ObservedObject var service: AppSearchService
    @Binding var cursor: AppSearchHit.Target?
    @Binding var expanded: Set<AppSearchKind>
    let open: (AppSearchHit) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The rows on screen, in order, for keyboard movement.
    static func visibleHits(_ groups: [AppSearchGroup], expanded: Set<AppSearchKind>) -> [AppSearchHit] {
        groups.flatMap { group in
            expanded.contains(group.kind) ? group.hits : Array(group.hits.prefix(self.rowsPerGroup))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if self.service.groups.isEmpty {
                    Text("No results")
                        .font(self.theme.typography.sidebarItem)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, self.theme.metrics.spacing.md)
                }
                ForEach(self.service.groups) { group in
                    Section {
                        let shown = self.expanded.contains(group.kind) ? group.hits : Array(group.hits.prefix(Self.rowsPerGroup))
                        ForEach(shown) { hit in
                            self.row(hit)
                        }
                        if group.hits.count > Self.rowsPerGroup {
                            Button {
                                let wasExpanded = self.expanded.contains(group.kind)
                                self.toggle(group)
                                if wasExpanded { proxy.scrollTo(group.kind, anchor: .top) }
                            } label: {
                                Text(self.expanded.contains(group.kind) ? "Show less" : "Show more (\(group.hits.count - Self.rowsPerGroup))")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.vertical, self.theme.metrics.spacing.xs / 2)
                            }
                            .buttonStyle(.plain)
                            .font(self.theme.typography.sidebarItem)
                            .foregroundStyle(self.theme.palette.accent)
                            .sidebarOptionHover(isSelected: false, reduceMotion: self.reduceMotion)
                            .accessibilityLabel("\(self.expanded.contains(group.kind) ? "Show fewer" : "Show all") \(group.kind.title) results")
                        }
                    } header: {
                        self.groupHeader(group)
                            .id(group.kind)
                    }
                }
            }
            .listStyle(.sidebar)
            .accentColor(self.theme.palette.accent)
            .onChange(of: self.cursor) { _, target in
                target.map { proxy.scrollTo($0) }
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: AppSearchGroup) -> some View {
        if group.hits.count > Self.rowsPerGroup {
            Button { self.toggle(group) } label: {
                HStack(spacing: self.theme.metrics.spacing.xs) {
                    Text(group.kind.title)
                    Image(systemName: self.expanded.contains(group.kind) ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Spacer(minLength: 0)
                }
                .font(self.theme.typography.sidebarSection)
                .foregroundStyle(.secondary)
                .padding(.vertical, self.theme.metrics.spacing.xs / 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sidebarOptionHover(isSelected: false, reduceMotion: self.reduceMotion)
            .accessibilityLabel("\(group.kind.title) results")
            .accessibilityValue(self.expanded.contains(group.kind) ? "Expanded, \(group.hits.count) results" : "Showing \(Self.rowsPerGroup) of \(group.hits.count) results")
            .accessibilityHint(self.expanded.contains(group.kind) ? "Show fewer results" : "Show all results")
        } else {
            Text(group.kind.title)
                .font(self.theme.typography.sidebarSection)
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ group: AppSearchGroup) {
        guard group.hits.count > Self.rowsPerGroup else { return }
        if self.expanded.remove(group.kind) == nil {
            self.expanded.insert(group.kind)
        } else if let cursor = self.cursor,
                  group.hits.dropFirst(Self.rowsPerGroup).contains(where: { $0.target == cursor })
        {
            self.cursor = nil
        }
    }

    private func row(_ hit: AppSearchHit) -> some View {
        let isSelected = self.cursor == hit.target
        return Button {
            self.open(hit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(self.theme.typography.sidebarItem)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, self.theme.metrics.spacing.xs / 2)
        }
        .buttonStyle(.plain)
        .onHover {
            if $0 {
                self.cursor = hit.target
            }
        }
        .sidebarOptionHover(isSelected: isSelected, reduceMotion: self.reduceMotion)
        .id(hit.id)
    }
}
