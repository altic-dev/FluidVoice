import SwiftUI

/// Grouped search results shown in place of the sidebar sections while the search
/// box has text. Each group shows a few rows and a "more" row that expands it.
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
                        if group.hits.count > shown.count {
                            Button("\(group.hits.count - shown.count) more…") {
                                self.expanded.insert(group.kind)
                            }
                            .buttonStyle(.plain)
                            .font(self.theme.typography.sidebarItem)
                            .foregroundStyle(self.theme.palette.accent)
                            .padding(.vertical, self.theme.metrics.spacing.xs / 2)
                        }
                    } header: {
                        Text(group.kind.title)
                            .font(self.theme.typography.sidebarSection)
                            .foregroundStyle(.secondary)
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
