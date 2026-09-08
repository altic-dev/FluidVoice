import SwiftUI

/// Shared presentation only: callers retain dismissal guards and all settings ownership.
struct FluidManagementSheet<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String
    let symbol: String
    var dismissDisabled = false
    var height: CGFloat = 650
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: self.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(FluidBrandColors.blue)
                    .frame(width: 52, height: 52)
                    .background(FluidBrandColors.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.title).font(self.theme.typography.title)
                    Text(self.subtitle).font(self.theme.typography.body).foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Button("Done", action: self.close)
                    .fluidGlassAction()
                    .keyboardShortcut(.cancelAction)
                    .disabled(self.dismissDisabled)
            }
            .padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20, content: self.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
        }
        .frame(width: 720, height: self.height)
        .background(self.theme.palette.windowBackground)
        .tint(FluidBrandColors.blue)
        .appTheme(self.theme)
    }
}

/// Opaque content surfaces keep form text legible; glass is reserved for actions.
struct FluidManagementGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.title).font(self.theme.typography.bodyStrong).foregroundStyle(self.theme.palette.secondaryText)
            VStack(alignment: .leading, spacing: 16, content: self.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct FluidManagementRow<Control: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var detail: String = ""
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.title).font(self.theme.typography.bodyStrong)
                if !self.detail.isEmpty {
                    Text(self.detail).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            self.control()
        }
    }
}
