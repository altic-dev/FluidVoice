import SwiftUI
struct ProductionPromptMenu: View {
    let smart: Bool
    var smartPress = 0.0
    var hoveredRowID: String? = nil
    var basicOpacity = 1.0
    var smartOpacity = 1.0
    var basicOffset = 0.0
    var smartOffset = 0.0
    private func shortcutBadge(for selection: PreviewSelection) -> some View { EmptyView() }
    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }
    @ViewBuilder private var offRow: some View {
        let isSelected = !smart
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Basic")
                Spacer(minLength: 12)
                Text("No cleanup")
                    .font(.fluidSystem(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .off)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: "off"))
    }
    @ViewBuilder private var privateAIRow: some View {
        let isSelected = smart
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Smart")
                Spacer(minLength: 12)
                Text("Fluid-1")
                    .font(.fluidSystem(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .privateAI)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: PrivateAIProviderFeature.shared.providerID))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ON-DEVICE")
                .font(.fluidSystem(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 3)
            offRow.opacity(basicOpacity).offset(y: basicOffset)
            privateAIRow.opacity(smartOpacity).offset(y: smartOffset).scaleEffect(1 - 0.035 * smartPress)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 227.5, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}
enum PreviewSelection { case off, privateAI }
enum PrivateAIProviderFeature { struct Value { let providerID = "privateAI" }; static let shared = Value() }
