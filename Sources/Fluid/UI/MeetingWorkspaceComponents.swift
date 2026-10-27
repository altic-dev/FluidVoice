import SwiftUI

/// Pointer-only feedback; overlays never change geometry or intercept the native control.
struct MeetingHoverHighlight: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let isHovered: Bool
    let cornerRadius: CGFloat
    let reduceMotion: Bool

    var body: some View {
        let highlighted = self.isHovered && self.isEnabled
        RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
            .fill(self.theme.palette.primaryText.opacity(0.08))
            .opacity(highlighted ? 1 : 0)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: highlighted)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct MeetingHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                MeetingHoverHighlight(isHovered: self.isHovered, cornerRadius: self.cornerRadius, reduceMotion: self.reduceMotion)
            }
            .onHover { self.isHovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.isHovered = false }
            }
            .onDisappear { self.isHovered = false }
    }
}

extension View {
    func meetingHoverFeedback(cornerRadius: CGFloat = 1000) -> some View {
        self.modifier(MeetingHoverFeedback(cornerRadius: cornerRadius))
    }

    func meetingGlassAction(prominent: Bool = false, circular: Bool = false, tone: Color? = nil, spacious: Bool = false) -> some View {
        self.fluidGlassAction(prominent: prominent, circular: circular, tone: tone, spacious: spacious)
            .meetingHoverFeedback()
    }
}

enum MeetingDocumentSection: Hashable {
    case transcript
    case summary
}

/// Meeting titles use the system's editorial face; controls retain the app's native type.
struct MeetingDocumentTitle: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(self.title)
            .font(.system(.largeTitle, design: .serif).weight(.medium))
            .foregroundStyle(self.theme.palette.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Document navigation, deliberately quieter than the primary recording action.
struct MeetingDocumentTabs: View {
    @Binding var selection: MeetingDocumentSection
    var primaryTitle = "Transcript"
    var primaryIcon = "text.alignleft"
    var isEnabled = true
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            self.tab(self.primaryTitle, section: .transcript, icon: self.primaryIcon)
            self.tab("Meet Summary", section: .summary, icon: "sparkles")
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            // Divider inherits its axis from the surrounding layout, including the toolbar's HStack.
            Rectangle()
                .fill(self.theme.palette.separator)
                .frame(height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .disabled(!self.isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting document views")
    }

    private func tab(_ title: String, section: MeetingDocumentSection, icon: String) -> some View {
        Button { self.selection = section } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: icon)
                Text(title)
            }
            .font(self.theme.typography.bodySmallStrong)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(MeetingDocumentTabButtonStyle(isSelected: self.selection == section))
        .accessibilityLabel(title)
        .accessibilityAddTraits(self.selection == section ? .isSelected : [])
    }
}

/// A quiet document tab: rounded pointer feedback above a stable selection underline.
private struct MeetingDocumentTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, isSelected: self.isSelected)
    }

    private struct TabBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            let highlighted = self.isEnabled && (self.isHovered || self.configuration.isPressed)
            self.configuration.label
                .foregroundStyle(self.isSelected || highlighted ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .frame(height: FluidButtonSize.medium.controlHeight)
                .background {
                    Capsule()
                        .fill(self.theme.palette.elevatedCardBackground)
                        .overlay { Capsule().strokeBorder(self.theme.palette.separator.opacity(0.5), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .opacity(highlighted ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .contentShape(Capsule())
                .padding(.bottom, self.theme.metrics.spacing.sm)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(self.theme.palette.primaryText)
                        .frame(height: 2)
                        .opacity(self.isSelected ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .opacity(self.isEnabled ? 1 : 0.45)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: highlighted)
                .onHover { self.isHovered = $0 && self.isEnabled }
                .onChange(of: self.isEnabled) { _, enabled in
                    if !enabled { self.isHovered = false }
                }
                .onDisappear { self.isHovered = false }
        }
    }
}
