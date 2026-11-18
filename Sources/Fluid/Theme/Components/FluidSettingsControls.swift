import SwiftUI

// Settings pages in the refined look (`AppTheme.Look`): titled groups of rows on one flat card,
// after the Shortcuts page. Pages pass words and controls only; sizes, colors and lines come from here.

enum FluidSettingsLayout {
    /// Space between a group's card edge and its rows, and where row hairlines start.
    static let rowInset: CGFloat = 16
    /// Space above and below a row's words.
    static let rowVerticalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    /// Space between groups on a page.
    static let groupSpacing: CGFloat = 24
}

/// A titled group of settings rows on one flat card. A hint can sit at the right of the title and a
/// footnote under the card. With `separated`, rows get a hairline between them; groups that draw
/// their own lines (like the Shortcuts table) pass `false`.
struct FluidSettingsGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    var title: String?
    var hint: String?
    var footnote: String?
    var separated = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        let look = self.theme.look
        VStack(alignment: .leading, spacing: 0) {
            if self.title != nil || self.hint != nil {
                FluidGroupHeader(title: self.title, hint: self.hint)
            }

            VStack(spacing: 0) {
                if self.separated {
                    Group(subviews: self.content()) { rows in
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                FluidHairline().padding(.leading, FluidSettingsLayout.rowInset)
                            }
                            row
                        }
                    }
                } else {
                    self.content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.isInsideFluidSettingsGroup, true)
            // Row hover fills stay inside the card's rounded corners.
            .clipShape(RoundedRectangle(cornerRadius: FluidSettingsLayout.cornerRadius, style: .continuous))
            .fluidLit(look.card, in: RoundedRectangle(cornerRadius: FluidSettingsLayout.cornerRadius, style: .continuous))

            if let footnote {
                Text(footnote)
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, self.theme.metrics.spacing.sm)
            }
        }
    }
}

/// The title over a group, with a quiet hint or an action at the right. Settings groups and page
/// sections both use it, so every group title sits at the same size and spacing.
struct FluidGroupHeader<Accessory: View>: View {
    @Environment(\.theme) private var theme
    let title: String?
    let hint: String?
    let accessory: () -> Accessory

    init(title: String?, hint: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.hint = hint
        self.accessory = accessory
    }

    var body: some View {
        let look = self.theme.look
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.md) {
            if let title {
                Text(title)
                    .fluidText(.groupTitle)
                    .foregroundStyle(look.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if let hint {
                Text(hint)
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
            }
            self.accessory()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, self.theme.metrics.spacing.sm)
    }
}

extension FluidGroupHeader where Accessory == EmptyView {
    init(title: String?, hint: String? = nil) {
        self.init(title: title, hint: hint) { EmptyView() }
    }
}

/// One settings row: what it is on the left, its control on the right. `footnote` is a quiet line
/// under the description; `error` is a problem the user should act on.
struct FluidSettingsRow<Control: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var description: String?
    var footnote: String?
    var error: String?
    /// Extra leading space for a row that belongs to the one above it.
    var indent: CGFloat = 0
    @ViewBuilder let control: () -> Control

    var body: some View {
        let look = self.theme.look
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md + 2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.title)
                    .fluidText(.rowTitle)
                    .foregroundStyle(look.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let description {
                    Text(description)
                        .fluidText(.body)
                        .foregroundStyle(look.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let footnote {
                    Text(footnote)
                        .fluidText(.label)
                        .foregroundStyle(look.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fluidText(.label)
                        .foregroundStyle(look.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            self.control()
        }
        .padding(.leading, FluidSettingsLayout.rowInset + self.indent)
        .padding(.trailing, FluidSettingsLayout.rowInset)
        .padding(.vertical, FluidSettingsLayout.rowVerticalPadding)
    }
}

extension FluidSettingsRow where Control == EmptyView {
    init(title: String, description: String? = nil, footnote: String? = nil, error: String? = nil, indent: CGFloat = 0) {
        self.init(title: title, description: description, footnote: footnote, error: error, indent: indent) { EmptyView() }
    }
}

/// A full-width row inside a group that holds anything other than a titled setting, such as a
/// preview or a list, with the same insets as the rows around it.
struct FluidSettingsBlock<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        self.content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FluidSettingsLayout.rowInset)
            .padding(.vertical, FluidSettingsLayout.rowVerticalPadding)
    }
}

private struct FluidSettingsGroupMemberKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for views on a settings group's card, so marks like a search highlight fill their row
    /// instead of reaching past the card's clipped edge.
    var isInsideFluidSettingsGroup: Bool {
        get { self[FluidSettingsGroupMemberKey.self] }
        set { self[FluidSettingsGroupMemberKey.self] = newValue }
    }
}

extension View {
    /// The look's switch: small, labels hidden (the row says what it is), monochrome when on.
    func fluidSwitch() -> some View {
        self.modifier(FluidSwitchStyle())
    }
}

private struct FluidSwitchStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(self.theme.look.switchOn)
    }
}
