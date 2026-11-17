import SwiftUI

/// The model pop-ups fill the shared pop-up size (`FluidPopupLayout`); only the list column is theirs.
enum ModelPickerLayout {
    static let listWidth: CGFloat = 360
    static let rowLogoSize: CGFloat = 28
    static let detailLogoSize: CGFloat = 36
}

enum ModelPickerFormat {
    /// "128 GB", kept together on one line.
    static func memory(_ bytes: UInt64?) -> String? {
        bytes.map { "\($0 / (1024 * 1024 * 1024))\u{00A0}GB" }
    }
}

enum ModelPickerTag: Equatable {
    case recommended
    case tryFirst

    var title: String {
        switch self {
        case .recommended: "Recommended"
        case .tryFirst: "Try first"
        }
    }
}

/// One list row: the name, the two numbers, and only the marks that tell rows apart (in use,
/// languages not listed, the model's own label, a tag). Everything else about a model belongs in the detail panel.
struct ModelPickerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let logo: FluidModelLogo.Mark
    let firstValue: Int?
    let secondValue: Int?
    /// The model lists no languages, so its support for the user's language is unknown.
    var notListedNote = false
    /// The model's own label, such as "New", shown after its name.
    var badge: String?
    let isInUse: Bool
    let tag: ModelPickerTag?
}

/// How the list is ordered, chosen from the "Sort by" menu. `suggested` is the order the pop-up
/// builds, recommended first.
enum ModelPickerSort: Hashable {
    case suggested
    case name
    case first
    case second

    /// Menu order: the default, then the numbers people compare most, then names.
    static let menuOrder: [ModelPickerSort] = [.suggested, .second, .first, .name]

    func title(_ columns: ModelPickerColumns) -> String {
        switch self {
        case .suggested: "Recommended"
        case .name: "Name"
        case .first: columns.first
        case .second: columns.second
        }
    }

    /// Names A to Z; numbers best first with unrated rows last. Ties keep the suggested order.
    func apply(_ rows: [ModelPickerRow]) -> [ModelPickerRow] {
        let indexed = Array(rows.enumerated())
        let ordered: [(offset: Int, element: ModelPickerRow)] = switch self {
        case .suggested:
            indexed
        case .name:
            indexed.sorted { lhs, rhs in
                let order = lhs.element.name.localizedStandardCompare(rhs.element.name)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }
        case .first:
            indexed.sorted { Self.isBefore($0.element.firstValue, $0.offset, $1.element.firstValue, $1.offset) }
        case .second:
            indexed.sorted { Self.isBefore($0.element.secondValue, $0.offset, $1.element.secondValue, $1.offset) }
        }
        return ordered.map(\.element)
    }

    private static func isBefore(_ lhs: Int?, _ lhsOffset: Int, _ rhs: Int?, _ rhsOffset: Int) -> Bool {
        let left = lhs ?? Int.min, right = rhs ?? Int.min
        return left == right ? lhsOffset < rhsOffset : left > right
    }
}

/// Numbers shown in the list columns. `scale` is appended for 1–5 levels, e.g. "4/5".
struct ModelPickerColumns: Equatable {
    let first: String
    let second: String
    var scale: Int?

    /// The highest value in each column; ties are all highlighted.
    static func bestValues(_ rows: [ModelPickerRow]) -> (first: Int?, second: Int?) {
        (rows.compactMap(\.firstValue).max(), rows.compactMap(\.secondValue).max())
    }
}

// MARK: - Frame

struct ModelPickerSheet<Header: View, Notice: View, List: View, Detail: View, Footer: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    /// Escape closes the pop-up whichever control has keyboard focus.
    let close: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let list: () -> List
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(self.title).fluidText(.sheetTitle).foregroundStyle(self.theme.look.text)
                Spacer(minLength: self.theme.metrics.spacing.md)
                // Room for the focus ring around a selector in this line.
                HStack(spacing: self.theme.metrics.spacing.xs, content: self.header)
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, self.theme.metrics.spacing.xl)
            .padding(.vertical, self.theme.metrics.spacing.md)
            FluidHairline()
            self.notice()
            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0, content: self.list)
                }
                .frame(width: ModelPickerLayout.listWidth)
                FluidHairline(axis: .vertical)
                VStack(spacing: 0) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0, content: self.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, self.theme.metrics.spacing.xl)
                            .padding(.top, self.theme.metrics.spacing.lg)
                            .padding(.bottom, self.theme.metrics.spacing.xxl)
                    }
                    .mask(ModelPickerBottomFade())
                    FluidHairline()
                    HStack(spacing: self.theme.metrics.spacing.sm, content: self.footer)
                        .padding(.horizontal, self.theme.metrics.spacing.xl)
                        .padding(.top, self.theme.metrics.spacing.md)
                        .padding(.bottom, self.theme.metrics.spacing.lg)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.look.sheet)
        .onExitCommand(perform: self.close)
        .tint(self.theme.look.text)
        .appTheme(self.theme)
    }
}

/// Fades the last lines so scrollable content reads as "more below" instead of cut off.
private struct ModelPickerBottomFade: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
        }
    }
}

// MARK: - List

/// The "Sort by" menu for the pop-up header, in the same in-text style as the language menu.
struct ModelPickerSortMenu: View {
    @Environment(\.theme) private var theme
    let columns: ModelPickerColumns
    @Binding var sort: ModelPickerSort

    var body: some View {
        FluidDropdownPicker("Sort by", selectedTitle: self.sort.title(self.columns), selection: self.$sort) {
            ForEach(ModelPickerSort.menuOrder, id: \.self) { Text($0.title(self.columns)).tag($0) }
        }
        .fluidDropdownStyle(appearance: .text, tone: self.theme.look.secondaryText)
        .fixedSize()
    }
}

struct ModelPickerListHeader: View {
    @Environment(\.theme) private var theme
    let columns: ModelPickerColumns

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
            Text("Model")
                // Lines up with the model names, past the row logos.
                .padding(.leading, ModelPickerLayout.rowLogoSize + self.theme.metrics.spacing.sm + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(self.columns.first).frame(width: ModelPickerRowView.firstColumnWidth, alignment: .trailing)
            Text(self.columns.second).frame(width: ModelPickerRowView.secondColumnWidth, alignment: .trailing)
        }
        .fluidText(.label)
        .foregroundStyle(self.theme.look.tertiaryText)
        .padding(.horizontal, self.theme.metrics.spacing.lg)
        .padding(.top, self.theme.metrics.spacing.md - 2)
        .padding(.bottom, self.theme.metrics.spacing.xs + 2)
        .overlay(alignment: .bottom) { FluidHairline() }
    }
}

struct ModelPickerRowView: View {
    static let firstColumnWidth: CGFloat = 44
    static let secondColumnWidth: CGFloat = 60

    @Environment(\.theme) private var theme
    let row: ModelPickerRow
    let columns: ModelPickerColumns
    let best: (first: Int?, second: Int?)
    let isSelected: Bool
    /// Rows after the first draw a line above themselves.
    var isFirst = false
    let select: () -> Void

    var body: some View {
        Button(action: self.select) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.sm + 2) {
                FluidModelLogo(mark: self.row.logo, size: ModelPickerLayout.rowLogoSize)
                self.content
            }
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.vertical, self.theme.metrics.spacing.sm + 1)
        }
        .fluidSelectableRow(isSelected: self.isSelected)
        .overlay(alignment: .top) { if !self.isFirst { FluidHairline() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.xs + 2) {
                    Text(self.row.name)
                        .fluidText(.rowTitle)
                        .foregroundStyle(self.theme.look.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge = self.row.badge {
                        FluidChip(text: badge).fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                self.value(self.row.firstValue, isBest: self.row.firstValue != nil && self.row.firstValue == self.best.first)
                    .frame(width: Self.firstColumnWidth, alignment: .trailing)
                self.value(self.row.secondValue, isBest: self.row.secondValue != nil && self.row.secondValue == self.best.second)
                    .frame(width: Self.secondColumnWidth, alignment: .trailing)
            }
            if self.row.notListedNote || self.row.isInUse || self.row.tag != nil {
                HStack(spacing: self.theme.metrics.spacing.xs + 2) {
                    if self.row.notListedNote {
                        FluidChip(text: "Languages not listed")
                    }
                    if self.row.isInUse {
                        FluidStatusLabel(text: "In use")
                    }
                    Spacer(minLength: 0)
                    if let tag = self.row.tag {
                        ModelPickerTagChip(tag: tag)
                    }
                }
            }
        }
    }

    private func value(_ value: Int?, isBest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(value.map(String.init) ?? "–")
                .fluidText(.value)
            if let scale = self.columns.scale, value != nil {
                Text("/\(scale)").fluidText(.label).foregroundStyle(self.theme.look.tertiaryText)
            }
        }
        .monospacedDigit()
        .foregroundStyle(isBest ? self.theme.look.text : self.theme.look.secondaryText)
    }
}

struct ModelPickerTagChip: View {
    let tag: ModelPickerTag

    var body: some View {
        FluidChip(text: self.tag.title, style: self.tag == .tryFirst ? .dashed : .outlined)
    }
}

struct ModelPickerListNote: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(self.text)
            .fluidText(.label)
            .foregroundStyle(self.theme.look.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.vertical, self.theme.metrics.spacing.md - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { FluidHairline() }
    }
}

// MARK: - Detail panel

struct ModelPickerDetailHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let logo: FluidModelLogo.Mark
    /// Why to pick it; for a recommended model, why it is recommended. The tag stays in the list.
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                FluidModelLogo(mark: self.logo, size: ModelPickerLayout.detailLogoSize)
                Text(self.title)
                    .fluidText(.detailTitle)
                    .foregroundStyle(self.theme.look.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(self.summary)
                .fluidText(.subtitle)
                .foregroundStyle(self.theme.look.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, self.theme.metrics.spacing.md + 2)
    }
}

/// "Supported languages" row: the user's language first, every other one on demand, in the app's
/// shared disclosure style. No ticks: a tick reads as "selected", not "supported".
struct ModelPickerLanguagesRow: View {
    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    let yourLanguage: String
    let supportsYourLanguage: Bool
    /// Display names, already sorted, without the user's language.
    let otherLanguages: [String]

    var body: some View {
        DisclosureGroup(isExpanded: self.$isExpanded) {
            FluidChipFlow {
                if self.supportsYourLanguage {
                    FluidChip(text: self.yourLanguage)
                }
                ForEach(self.otherLanguages, id: \.self) { FluidChip(text: $0) }
            }
            // Lines the chips up with the label, past the shared style's chevron column.
            .padding(.leading, 14 + self.theme.metrics.spacing.sm)
            .padding(.bottom, self.theme.metrics.spacing.sm)
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Supported languages").foregroundStyle(self.theme.look.secondaryText)
                Spacer(minLength: self.theme.metrics.spacing.sm)
                Text(self.summary).foregroundStyle(self.theme.look.text).lineLimit(1)
            }
            .fluidText(.body)
        }
        .disclosureGroupStyle(FluidDisclosureGroupStyle())
        .overlay(alignment: .top) { FluidHairline() }
    }

    private var summary: String {
        guard self.supportsYourLanguage else {
            let count = self.otherLanguages.count
            return "\(count) \(count == 1 ? "language" : "languages"), not \(self.yourLanguage)"
        }
        guard !self.otherLanguages.isEmpty else { return self.yourLanguage }
        return "\(self.yourLanguage) and \(self.otherLanguages.count) more"
    }
}
