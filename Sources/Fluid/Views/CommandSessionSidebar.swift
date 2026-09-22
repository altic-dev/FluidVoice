import AppKit
import SwiftUI

struct CommandSessionSidebar: View {
    @ObservedObject var history = ChatHistoryStore.shared
    let canChangeSession: Bool
    let blockingReason: String?
    let onNewSession: () -> Void
    let onSelect: (String) -> Void
    let onArchive: (String) -> Void
    let onRestore: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var rows: [SessionRow] = []
    @State private var scope = SessionScope.active
    @State private var keyboardSessionID: String?
    @State private var newSessionHovered = false
    @FocusState private var listFocused: Bool

    private struct SessionRow: Identifiable, Equatable {
        let id: String
        let title: String
        let preview: String
        let relativeTime: String
        let group: SessionGroup
        let isArchived: Bool
    }

    private enum SessionGroup: String, CaseIterable {
        case today = "Today"
        case yesterday = "Yesterday"
        case older = "Older"
    }

    private enum SessionScope: String, CaseIterable {
        case active = "Active"
        case archived = "Archived"

        var isArchived: Bool { self == .archived }
    }

    private struct SessionPresentation: Equatable {
        let row: SessionRow
        let selected: Bool
        let keyboardSelected: Bool
        let enabled: Bool
        let blockingReason: String?
    }

    /// A session keeps one identity across date groups. Every rendered value is part of the item.
    private enum SessionListItem: Identifiable, Equatable {
        case heading(SessionGroup)
        case session(SessionPresentation)

        var id: String {
            switch self {
            case let .heading(group): "heading:\(group.rawValue)"
            case let .session(presentation): presentation.row.id
            }
        }
    }

    private var filteredRows: [SessionRow] {
        let scopedRows = self.rows.filter { $0.isArchived == self.scope.isArchived }
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedRows }
        return scopedRows.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            if self.filteredRows.isEmpty {
                self.emptyState
            } else {
                self.sessionList
            }
            if !self.canChangeSession, let blockingReason {
                Text(blockingReason)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(self.theme.metrics.spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.contentBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command sessions")
        .onChange(of: self.scope) { _, _ in self.keyboardSessionID = nil }
        .onChange(of: self.searchText) { _, _ in self.keyboardSessionID = nil }
        .onReceive(self.history.$sessions) { self.refreshRows(from: $0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.refreshRows(from: self.history.sessions)
        }
    }

    /// Every control shares one text column: container inset `md` plus content inset `md`.
    private static let controlHeight: CGFloat = 34
    private static let iconWidth: CGFloat = 16

    private var header: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            self.newSessionButton
            Menu {
                Picker("Session history view", selection: self.$scope) {
                    ForEach(SessionScope.allCases, id: \.self) { scope in
                        Text(self.scopeTitle(scope)).tag(scope)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(self.scopeTitle(self.scope))
            }
            .fluidDropdownStyle(fillsWidth: true)
            .accessibilityLabel("Session history view")
            .accessibilityValue(self.scopeTitle(self.scope))
            self.searchField
        }
        .padding([.horizontal, .top], self.theme.metrics.spacing.md)
        .padding(.bottom, self.theme.metrics.spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scopeTitle(_ scope: SessionScope) -> String {
        "\(scope.rawValue) (\(self.rows.filter { $0.isArchived == scope.isArchived }.count))"
    }

    private var newSessionButton: some View {
        Button {
            guard self.canChangeSession else { return }
            self.scope = .active
            self.searchText = ""
            self.onNewSession()
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "square.and.pencil")
                    .fontWeight(.light)
                    .frame(width: Self.iconWidth)
                    .accessibilityHidden(true)
                Text("New chat")
            }
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.newSessionHovered ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, minHeight: Self.controlHeight, alignment: .leading)
            .background(
                self.newSessionHovered && self.canChangeSession ? self.theme.palette.cardBorder.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.newSessionHovered = $0 }
        .disabled(!self.canChangeSession)
        .help(self.blockingReason ?? "Start a new chat")
    }

    private var searchField: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            TextField("Search sessions", text: self.$searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search session titles and previews")
            if !self.searchText.isEmpty {
                Button { self.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear session search")
            }
        }
        .font(self.theme.typography.bodySmall)
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, minHeight: Self.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.elevatedCardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .strokeBorder(self.theme.palette.cardBorder)
                }
        }
    }

    private var sessionList: some View {
        let filtered = self.filteredRows
        let currentID = self.history.currentChatID
        let enabled = self.canChangeSession
        let blockingReason = self.blockingReason
        let items = SessionGroup.allCases.flatMap { group -> [SessionListItem] in
            let groupedRows = filtered.filter { $0.group == group }
            guard !groupedRows.isEmpty else { return [] }
            return [.heading(group)] + groupedRows.map {
                .session(SessionPresentation(
                    row: $0,
                    selected: $0.id == currentID,
                    keyboardSelected: $0.id == self.keyboardSessionID,
                    enabled: enabled,
                    blockingReason: blockingReason
                ))
            }
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        switch item {
                        case let .heading(group):
                            Text(group.rawValue)
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .padding(.horizontal, self.theme.metrics.spacing.md)
                                .padding(.top, self.theme.metrics.spacing.lg)
                                .padding(.bottom, self.theme.metrics.spacing.xs)
                        case let .session(presentation):
                            SessionRowView(
                                row: presentation.row,
                                selected: presentation.selected,
                                keyboardSelected: presentation.keyboardSelected,
                                canChangeSession: presentation.enabled,
                                blockingReason: presentation.blockingReason,
                                onSelect: self.openSession,
                                onArchive: self.onArchive,
                                onRestore: self.onRestore
                            )
                        }
                    }
                }
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.bottom, self.theme.metrics.spacing.md)
            }
            .focusable()
            .focused(self.$listFocused)
            .onMoveCommand { direction in
                guard self.canChangeSession, direction == .up || direction == .down,
                      !filtered.isEmpty else { return }
                self.listFocused = true
                let focusedID = self.keyboardSessionID ?? self.history.currentChatID
                let currentIndex = filtered.firstIndex { $0.id == focusedID }
                let index: Int
                if let currentIndex {
                    index = min(filtered.count - 1, max(0, currentIndex + (direction == .down ? 1 : -1)))
                } else {
                    index = direction == .down ? 0 : filtered.count - 1
                }
                let row = filtered[index]
                self.keyboardSessionID = row.id
                // Browsing archived rows must not restore them. Return explicitly opens one.
                if !row.isArchived, row.id != self.history.currentChatID { self.onSelect(row.id) }
                proxy.scrollTo(row.id, anchor: .center)
            }
            .onKeyPress(.return) {
                guard self.listFocused, self.canChangeSession, let id = self.keyboardSessionID,
                      self.filteredRows.contains(where: { $0.id == id }) else { return .ignored }
                self.openSession(id)
                return .handled
            }
            .onChange(of: self.history.currentChatID) { _, id in
                guard let id, filtered.contains(where: { $0.id == id }) else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func openSession(_ id: String) {
        guard self.canChangeSession,
              let session = self.history.sessions.first(where: { $0.id == id }) else { return }
        self.keyboardSessionID = nil
        if session.isArchived {
            self.onRestore(id)
            guard self.history.sessions.first(where: { $0.id == id })?.isArchived == false else { return }
            self.scope = .active
        }
        self.onSelect(id)
    }

    private struct SessionRowView: View {
        let row: SessionRow
        let selected: Bool
        let keyboardSelected: Bool
        let canChangeSession: Bool
        let blockingReason: String?
        let onSelect: (String) -> Void
        let onArchive: (String) -> Void
        let onRestore: (String) -> Void

        @Environment(\.theme) private var theme
        @State private var hovered = false
        @FocusState private var focusedControl: RowControl?

        private enum RowControl: Hashable {
            case open
            case archive
        }

        private var showsActions: Bool { self.keyboardSelected || self.hovered || self.focusedControl != nil }
        private var actionTitle: String { self.row.isArchived ? "Restore session" : "Archive session" }
        private var openHint: String { self.row.isArchived ? "Restore and open this session" : "Open this session" }

        var body: some View {
            Button {
                guard self.canChangeSession else { return }
                self.onSelect(self.row.id)
            } label: {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    HStack(spacing: 6) {
                        Text(self.row.title)
                            .font(self.selected ? self.theme.typography.bodySmallStrong : self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(self.row.relativeTime)
                            .font(self.theme.typography.captionSmall)
                            .foregroundStyle(self.theme.palette.tertiaryText)
                            .fixedSize()
                            .opacity(self.showsActions ? 0 : 1)
                    }
                    Text(self.row.preview)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .padding(.vertical, self.theme.metrics.spacing.sm)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused(self.$focusedControl, equals: .open)
            .accessibilityAddTraits(self.selected ? .isSelected : [])
            .accessibilityHint(self.openHint)
            .help(self.blockingReason ?? self.openHint)
            .accessibilityAction(named: Text(self.actionTitle)) { self.performArchiveAction() }
            .editableTitle(self.row.title, id: self.row.id, enabled: self.canChangeSession) {
                ChatHistoryStore.shared.renameChat(id: self.row.id, to: $0)
            }
            .overlay(alignment: .trailing) {
                Button(action: self.performArchiveAction) {
                    Image(systemName: self.row.isArchived ? "arrow.uturn.backward" : "archivebox")
                        .font(self.theme.typography.body)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused(self.$focusedControl, equals: .archive)
                .foregroundStyle(self.theme.palette.secondaryText)
                .opacity(self.showsActions ? 1 : 0)
                .allowsHitTesting(self.showsActions)
                .disabled(!self.showsActions)
                .accessibilityHidden(!self.showsActions)
                .accessibilityLabel("\(self.actionTitle): \(self.row.title)")
                .help(self.blockingReason ?? self.actionTitle)
                .padding(.trailing, self.theme.metrics.spacing.xs)
            }
            .background(
                self.selected ? self.theme.palette.cardBorder.opacity(0.55) : (self.showsActions ? self.theme.palette.cardBorder.opacity(0.25) : .clear),
                in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm)
            )
            .contentShape(Rectangle())
            .onHover { self.hovered = $0 }
            .disabled(!self.canChangeSession)
        }

        private func performArchiveAction() {
            guard self.canChangeSession else { return }
            if self.row.isArchived { self.onRestore(self.row.id) } else { self.onArchive(self.row.id) }
        }
    }

    private var emptyState: some View {
        let isSearching = !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = isSearching ? "No matching \(self.scope.rawValue.lowercased()) sessions" : "No \(self.scope.rawValue.lowercased()) sessions"
        return VStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: isSearching ? "magnifyingglass" : (self.scope.isArchived ? "archivebox" : "bubble.left.and.bubble.right"))
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.tertiaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(self.theme.typography.bodySmallStrong)
            Text(isSearching ? "Try another title or phrase from the preview." : (self.scope.isArchived ? "Archived sessions stay here until you restore them." : "Start a new session to work with your Mac."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .multilineTextAlignment(.center)
        .padding(self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Refresh a bounded presentation snapshot only when sessions change or the app becomes active.
    private func refreshRows(from sessions: [ChatSession]) {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        self.rows = sessions.sorted { $0.updatedAt > $1.updatedAt }.map { session in
            let message = session.messages.last {
                ($0.role == .user || $0.role == .assistant) && $0.content.contains { !$0.isWhitespace }
            }
            let preview = message.map { String($0.content.prefix(180)).split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
            let group: SessionGroup
            if calendar.isDate(session.updatedAt, inSameDayAs: now) {
                group = .today
            } else if let yesterday, calendar.isDate(session.updatedAt, inSameDayAs: yesterday) {
                group = .yesterday
            } else {
                group = .older
            }
            return SessionRow(
                id: session.id,
                title: session.title,
                preview: preview.isEmpty ? "No messages yet" : preview,
                relativeTime: formatter.localizedString(for: session.updatedAt, relativeTo: now),
                group: group,
                isArchived: session.isArchived
            )
        }
    }
}
