import SwiftUI

private enum AIProvidersPreviewPanel { case manage, add, compare, external }

/// Milestone 3: isolated sample data. This view intentionally has no settings/service/controller reference.
struct AIProvidersDesignPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLight = false
    @State private var isCompact = false
    @State private var showsExamples = true
    @State private var activePanel: AIProvidersPreviewPanel?

    private var theme: AppTheme { AppTheme.adaptive(accent: .blue, colorScheme: self.isLight ? .light : .dark) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Design preview · sample data")
                    .font(self.theme.typography.captionStrong)
                Spacer()
                Toggle("Light", isOn: self.$isLight)
                Toggle("Compact", isOn: self.$isCompact)
                Toggle("Example providers", isOn: self.$showsExamples)
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(self.activePanel == nil ? .cancelAction : nil)
                    .fluidButton(.secondary, size: .small)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .toggleStyle(.checkbox)
            .font(self.theme.typography.caption)
            .padding(self.theme.metrics.spacing.lg)
            Divider()
            AIProvidersPresentation(panel: self.$activePanel, showsExamples: self.showsExamples)
                .frame(width: self.isCompact ? 580 : 820)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 650)
        .background(self.theme.palette.windowBackground)
        .foregroundStyle(self.theme.palette.primaryText)
        .appTheme(self.theme)
        .environment(\.colorScheme, self.isLight ? .light : .dark)
    }
}

private struct AIProvidersPresentation: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview = Model.mini
    @State private var selected = Model.mini
    @Binding var panel: AIProvidersPreviewPanel?
    @FocusState private var panelCloseFocused: Bool
    let showsExamples: Bool

    private enum Model: String, CaseIterable, Identifiable {
        case pico = "Pico", mini = "Fluid-1 Mini", full = "Fluid-1"
        var id: String { self.rawValue }
        var detail: String {
            switch self {
            case .pico: "Fast and lightweight.\nGreat for everyday use."
            case .mini: "Better understanding.\nHandles more context."
            case .full: "Most capable.\nFor complex tasks."
            }
        }

        var tags: [String] {
            switch self {
            case .pico: ["Fast", "Lightweight"]
            case .mini: ["Balanced", "Smart cleanup"]
            case .full: ["Quality", "Long context"]
            }
        }
    }

    private var spacing: AppTheme.Metrics.Spacing { self.theme.metrics.spacing }
    private var isDark: Bool { self.colorScheme == .dark }
    private var supportingText: Color { self.isDark ? self.theme.palette.secondaryText : self.theme.palette.primaryText.opacity(0.75) }

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: self.spacing.xl) {
                    self.intelligence
                    self.externalProviders
                }
                .padding(self.spacing.xl)
            }
            .disabled(self.panel != nil)
            .accessibilityHidden(self.panel != nil)

            if let panel = self.panel {
                Button { self.panel = nil } label: {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close panel")
                self.inspector(panel)
            }
        }
    }

    private var intelligence: some View {
        VStack(alignment: .leading, spacing: self.spacing.lg) {
            HStack(spacing: self.spacing.lg) {
                Image("Provider_Fluid1")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: self.spacing.xs) {
                    Text("Fluid Intelligence")
                        .font(self.theme.typography.title)
                    Text("Private, on-device intelligence.")
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.supportingText)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.shield")
                    .font(self.theme.typography.titleIcon)
                    .foregroundStyle(Color.blue)
                    .help("Your words stay on your Mac")
            }

            Divider().overlay(Color.blue.opacity(0.12))

            HStack {
                Text("Choose your model")
                    .font(self.theme.typography.sectionTitle)
                Spacer()
                Text("On your Mac")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.supportingText)
            }

            self.carousel

            HStack(spacing: self.spacing.md) {
                Button("Compare models", systemImage: "square.split.2x1") { self.panel = .compare }
                    .fluidButton(.inline, size: .small)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if self.selected != self.preview {
                    Button("Use \(self.preview.rawValue)") { self.selected = self.preview }
                        .fluidButton(.accent, size: .small)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Changes sample selection only")
                }
                Button("Manage", systemImage: "slider.horizontal.3") { self.panel = .manage }
                    .fluidButton(.secondary, size: .small)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(self.spacing.xl)
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg)
                .fill(self.theme.palette.cardBackground)
                .overlay {
                    if !self.reduceTransparency {
                        RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg)
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(self.isDark ? 0.20 : 0.09), Color.blue.opacity(0.015)],
                                startPoint: .topTrailing,
                                endPoint: .bottomLeading
                            ))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg)
                        .strokeBorder(Color.blue.opacity(self.isDark ? 0.36 : 0.25), lineWidth: 1)
                }
        }
    }

    private var carousel: some View {
        VStack(spacing: self.spacing.sm) {
            GeometryReader { geometry in
                let cardWidth = min(300, geometry.size.width * 0.44)
                let sideWidth = (geometry.size.width - cardWidth - self.spacing.md * 2 - 80) / 2
                let stride = cardWidth / 2 + sideWidth / 2 + self.spacing.md
                ZStack {
                    ForEach(Model.allCases) { model in
                        let position = self.carouselPosition(model)
                        self.modelCard(model, compactSide: position != 0 && geometry.size.width < 640)
                            .frame(width: position == 0 ? cardWidth : sideWidth, height: 190)
                            .scaleEffect(position == 0 ? 1 : 0.86)
                            .opacity(position == 0 ? 1 : 0.85)
                            .offset(x: CGFloat(position) * stride)
                            .zIndex(position == 0 ? 1 : 0)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(alignment: .leading) { self.carouselArrow(forward: false) }
                .overlay(alignment: .trailing) { self.carouselArrow(forward: true) }
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    self.advanceCarousel(forward: value.translation.width < 0)
                })
            }
            .frame(height: 214)

            HStack(spacing: self.spacing.xs) {
                ForEach(Model.allCases) { model in
                    Button { self.browse(model) } label: {
                        Circle()
                            .fill(self.preview == model ? Color.cyan : Color.blue.opacity(0.4))
                            .frame(width: self.preview == model ? 10 : 7, height: self.preview == model ? 10 : 7)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(model.rawValue)")
                    .accessibilityValue(self.preview == model ? "Current page" : "")
                }
            }
        }
    }

    private func carouselPosition(_ model: Model) -> Int {
        let models = Model.allCases
        let index = models.firstIndex(of: model) ?? 0
        let current = models.firstIndex(of: self.preview) ?? 0
        let distance = (index - current + models.count) % models.count
        return distance > models.count / 2 ? distance - models.count : distance
    }

    private func browse(_ model: Model) {
        withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            self.preview = model
        }
    }

    private func advanceCarousel(forward: Bool) {
        let models = Model.allCases
        let index = models.firstIndex(of: self.preview) ?? 0
        self.browse(models[(index + (forward ? 1 : models.count - 1)) % models.count])
    }

    private func carouselArrow(forward: Bool) -> some View {
        Button { self.advanceCarousel(forward: forward) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
                .frame(width: 34, height: 34)
                .background(self.theme.palette.contentBackground, in: Circle())
                .overlay { Circle().strokeBorder(Color.blue.opacity(0.65), lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Next model" : "Previous model")
    }

    private func modelCard(_ model: Model, compactSide: Bool) -> some View {
        let isPreview = self.preview == model
        return Button { self.browse(model) } label: {
            VStack(alignment: .leading, spacing: self.spacing.md) {
                HStack {
                    Spacer()
                    if self.selected == model {
                        Text("Selected")
                            .font(self.theme.typography.badge)
                            .foregroundStyle(self.supportingText)
                    }
                }
                Text(model.rawValue)
                    .font(compactSide ? self.theme.typography.sectionTitle : self.theme.typography.title)
                if !compactSide {
                    Text(model.detail)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 36, alignment: .topLeading)
                    HStack(spacing: self.spacing.sm) {
                        ForEach(isPreview ? model.tags : Array(model.tags.prefix(1)), id: \.self) { tag in
                            Text(tag)
                                .font(self.theme.typography.badge)
                                .padding(.horizontal, self.spacing.sm)
                                .padding(.vertical, self.spacing.xs)
                                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                        }
                    }
                }
            }
            .padding(self.spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                self.theme.palette.contentBackground
                if isPreview && !self.reduceTransparency {
                    Color.blue.opacity(self.isDark ? 0.16 : 0.06)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
            .overlay {
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
                    .strokeBorder(isPreview ? Color.cyan : Color.blue.opacity(0.3), lineWidth: isPreview ? 2 : 1)
            }
            .shadow(color: isPreview && !self.reduceTransparency ? Color.blue.opacity(0.24) : .clear, radius: 8)
            .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(model.rawValue)")
        .accessibilityValue(isPreview ? "Previewed" : "")
        .accessibilityHint("Browse without changing the selected model")
    }

    private var externalProviders: some View {
        VStack(alignment: .leading, spacing: self.spacing.md) {
            HStack {
                Text("Other providers")
                    .font(self.theme.typography.sectionTitle)
                Spacer()
                Button("Add Provider", systemImage: "plus") { self.panel = .add }
                    .fluidButton(.secondary, size: .small)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(spacing: 0) {
                if self.showsExamples {
                    self.providerRow("OpenAI", subtitle: "Cloud provider", image: "Provider_OpenAI")
                    Divider().padding(.leading, 60)
                    self.providerRow("Ollama", subtitle: "Local provider", image: "Provider_Ollama")
                } else {
                    HStack(spacing: self.spacing.md) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(self.supportingText)
                        Text("No other providers added")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.supportingText)
                        Spacer()
                    }
                    .padding(self.spacing.xl)
                }
            }
            .background(self.theme.palette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
        }
    }

    private func providerRow(_ name: String, subtitle: String, image: String) -> some View {
        HStack(spacing: self.spacing.md) {
            Image(image).resizable().scaledToFit().frame(width: 26, height: 26)
                .padding(5)
                .background(Color.white, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: self.spacing.xs) {
                Text(name).font(self.theme.typography.bodySmallStrong)
                Text(subtitle).font(self.theme.typography.caption).foregroundStyle(self.supportingText)
            }
            Spacer()
            Button("Manage") { self.panel = .external }
                .fluidButton(.secondary, size: .small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Manage \(name)")
        }
        .padding(self.spacing.lg)
    }

    private func inspector(_ panel: AIProvidersPreviewPanel) -> some View {
        VStack(alignment: .leading, spacing: self.spacing.xl) {
            HStack {
                Text(panel == .add ? "Add Provider" : panel == .compare ? "Compare models" : "Manage")
                    .font(self.theme.typography.sectionTitle)
                Spacer()
                Button { self.panel = nil } label: { Image(systemName: "xmark") }
                    .fluidButton(.secondary, size: .small)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Close panel")
                    .focused(self.$panelCloseFocused)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            if panel == .add {
                ForEach(["OpenAI", "Anthropic", "Ollama", "Custom provider"], id: \.self) { provider in
                    Label(provider, systemImage: "plus.circle")
                        .font(self.theme.typography.body)
                }
            } else if panel == .compare {
                ForEach(Model.allCases) { model in
                    VStack(alignment: .leading, spacing: self.spacing.sm) {
                        Text(model.rawValue).font(self.theme.typography.sectionTitle)
                        Text(model.detail).font(self.theme.typography.bodySmall)
                    }
                }
            } else {
                Text(panel == .manage ? "Fluid Intelligence" : "Provider settings")
                    .font(self.theme.typography.title)
                Text(panel == .manage ? "\(self.selected.rawValue) · On-device" : "Connection · Models · Preferences")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.supportingText)
                Divider()
                ForEach(panel == .manage ? ["Model downloads", "Backend & context", "Startup preferences", "Storage & maintenance"] : ["Connection details", "Model selection", "Verification"], id: \.self) { label in
                    Text(label).font(self.theme.typography.body)
                }
            }
            Spacer()
            Text("Panel layout preview. Settings and connections are not wired yet.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.supportingText)
        }
        .padding(self.spacing.xl)
        .frame(width: 290)
        .frame(maxHeight: .infinity)
        .background(self.theme.palette.elevatedCardBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(self.theme.palette.separator).frame(width: 1)
        }
        .onAppear { self.panelCloseFocused = true }
    }
}
