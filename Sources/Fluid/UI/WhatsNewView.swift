import SwiftUI

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var showContent = false
    @State private var features: [WhatsNewFeature] = []
    @State private var isLoading = true
    @State private var version: String = ""
    
    init() {
        // Set default version
        _version = State(initialValue: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
        
        // Set fallback features (used if GitHub fetch fails)
        // Update these to match your current version's features
        _features = State(initialValue: [
            WhatsNewFeature(
                icon: "network",
                title: "Release Notes Unavailable",
                description: "Unable to fetch latest release notes. Please check your internet connection."
            )
        ])
    }
    
    var body: some View {
        ZStack {
            theme.palette.windowBackground
                .ignoresSafeArea()

            Rectangle()
                .fill(theme.materials.window)
                .ignoresSafeArea()

            ThemedCard(style: .prominent, padding: 0, hoverEffect: false) {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: theme.metrics.spacing.md) {
                        // App Icon or Logo
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.corners.lg))
                            .shadow(color: theme.palette.accent.opacity(0.3), radius: 18, x: 0, y: 8)
                            .scaleEffect(showContent ? 1 : 0.5)
                            .opacity(showContent ? 1 : 0)
                        
                        Text("What's New in v\(version)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.primaryText)
                            .opacity(showContent ? 1 : 0)
                            .offset(y: showContent ? 0 : -20)
                        
                        Text("FluidVoice keeps getting better")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.palette.secondaryText)
                            .opacity(showContent ? 1 : 0)
                            .offset(y: showContent ? 0 : -20)
                    }
                    .padding(.top, theme.metrics.spacing.xl)
                    .padding(.bottom, theme.metrics.spacing.lg)
                    
                    // Features List
                    ScrollView {
                        VStack(spacing: theme.metrics.spacing.lg) {
                            ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                                FeatureRow(feature: feature)
                                    .opacity(showContent ? 1 : 0)
                                    .offset(y: showContent ? 0 : 24)
                                    .animation(
                                        .spring(response: 0.6, dampingFraction: 0.8)
                                            .delay(Double(index) * 0.1),
                                        value: showContent
                                    )
                            }
                        }
                        .padding(.horizontal, theme.metrics.spacing.xl)
                        .padding(.vertical, theme.metrics.spacing.md)
                    }
                    
                    // Continue Button
                    Button("Continue") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            SettingsStore.shared.markWhatsNewAsSeen()
                            dismiss()
                        }
                    }
                    .buttonStyle(PremiumButtonStyle(height: 48))
                    .buttonHoverEffect()
                    .padding(.horizontal, theme.metrics.spacing.xl)
                    .padding(.vertical, theme.metrics.spacing.lg)
                    .opacity(showContent ? 1 : 0)
                }
            }
            .frame(width: 520, height: 620)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                showContent = true
            }
            
            // Fetch release notes from GitHub
            Task {
                await fetchReleaseNotes()
            }
        }
    }
    
    // MARK: - GitHub Release Notes Fetching
    
    private func fetchReleaseNotes() async {
        do {
            let (fetchedVersion, notes) = try await SimpleUpdater.shared.fetchLatestReleaseNotes(
                owner: "altic-dev",
                repo: "Fluid-oss"
            )
            
            // Parse release notes into features
            let parsedFeatures = parseReleaseNotes(notes)
            
            await MainActor.run {
                if !parsedFeatures.isEmpty {
                    self.features = parsedFeatures
                }
                // Update version to match GitHub release
                if fetchedVersion.hasPrefix("v") {
                    self.version = String(fetchedVersion.dropFirst())
                } else {
                    self.version = fetchedVersion
                }
                self.isLoading = false
            }
        } catch {
            // If GitHub fetch fails, keep the fallback features
            print("Failed to fetch release notes: \(error)")
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
    
    private func parseReleaseNotes(_ notes: String) -> [WhatsNewFeature] {
        var features: [WhatsNewFeature] = []
        
        // Parse markdown format:
        // - Look for bullet points (-, *, +)
        // - Look for headings (##, ###)
        // - Extract feature descriptions
        
        let lines = notes.components(separatedBy: .newlines)
        var currentTitle: String?
        var currentDescription = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines
            if trimmed.isEmpty {
                continue
            }
            
            // Check for bullet points or list items
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                // Save previous feature if exists
                if let title = currentTitle, !currentDescription.isEmpty {
                    features.append(createFeature(title: title, description: currentDescription))
                }
                
                // Extract new feature
                let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                
                // Check if it has a colon (title: description format)
                if let colonIndex = content.firstIndex(of: ":") {
                    currentTitle = String(content[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    currentDescription = String(content[content.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    // Entire content is the title/description
                    currentTitle = content
                    currentDescription = ""
                }
            }
            // Check for headings (secondary features)
            else if trimmed.hasPrefix("###") {
                if let title = currentTitle, !currentDescription.isEmpty {
                    features.append(createFeature(title: title, description: currentDescription))
                }
                currentTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentDescription = ""
            }
            // Continuation of description
            else if currentTitle != nil && !trimmed.hasPrefix("#") {
                if !currentDescription.isEmpty {
                    currentDescription += " "
                }
                currentDescription += trimmed
            }
        }
        
        // Add last feature
        if let title = currentTitle, !currentDescription.isEmpty {
            features.append(createFeature(title: title, description: currentDescription))
        } else if let title = currentTitle {
            features.append(createFeature(title: title, description: title))
        }
        
        return features
    }
    
    private func createFeature(title: String, description: String) -> WhatsNewFeature {
        // Determine icon based on keywords in title
        let lowerTitle = title.lowercased()
        let icon: String
        
        if lowerTitle.contains("fix") || lowerTitle.contains("bug") {
            icon = "checkmark.circle"
        } else if lowerTitle.contains("performance") || lowerTitle.contains("faster") || lowerTitle.contains("speed") {
            icon = "bolt.fill"
        } else if lowerTitle.contains("new") || lowerTitle.contains("add") || lowerTitle.contains("feature") {
            icon = "sparkles"
        } else if lowerTitle.contains("audio") || lowerTitle.contains("sound") || lowerTitle.contains("microphone") {
            icon = "waveform"
        } else if lowerTitle.contains("ui") || lowerTitle.contains("design") || lowerTitle.contains("interface") {
            icon = "paintbrush.fill"
        } else if lowerTitle.contains("setting") || lowerTitle.contains("option") || lowerTitle.contains("config") {
            icon = "gearshape.2"
        } else if lowerTitle.contains("update") || lowerTitle.contains("improve") {
            icon = "arrow.up.circle"
        } else {
            icon = "star.fill"
        }
        
        return WhatsNewFeature(icon: icon, title: title, description: description.isEmpty ? title : description)
    }
}

struct FeatureRow: View {
    let feature: WhatsNewFeature
    @Environment(\.theme) private var theme
    
    var body: some View {
        ThemedCard(style: .subtle, hoverEffect: false) {
            HStack(alignment: .top, spacing: theme.metrics.spacing.md) {
                ZStack {
                    Circle()
                        .fill(theme.palette.accent.opacity(0.12))
                        .frame(width: 46, height: 46)
                        .overlay(
                            Circle()
                                .stroke(theme.palette.accent.opacity(0.2), lineWidth: 1)
                        )
                    
                    Image(systemName: feature.icon)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(theme.palette.accent)
                }
                
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                    Text(feature.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.primaryText)
                    
                    Text(feature.description)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
            }
        }
    }
}

struct WhatsNewFeature {
    let icon: String
    let title: String
    let description: String
}

#Preview {
    WhatsNewView()
}

