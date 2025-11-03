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
        
        print("📝 Parsing release notes:")
        print(notes)
        print("---")
        
        // Parse markdown format:
        // Expected structure:
        // ## What's New in vX.X.X
        // ### Section (e.g., "New", "Improvements")
        // - Feature item
        // - Another feature
        
        let lines = notes.components(separatedBy: .newlines)
        var currentTitle: String?
        var currentDescription = ""
        var currentSection = "" // Track section headers like "New", "Improvements"
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines
            if trimmed.isEmpty {
                // Empty line might signal end of current feature
                if let title = currentTitle, !title.isEmpty {
                    let desc = currentDescription.isEmpty ? "New feature or improvement" : currentDescription
                    features.append(createFeature(title: title, description: desc))
                    print("✅ Added feature: \(title)")
                    currentTitle = nil
                    currentDescription = ""
                }
                continue
            }
            
            // Skip main heading (## What's New...)
            if trimmed.hasPrefix("##") && !trimmed.hasPrefix("###") {
                // This is the main title, skip it
                continue
            }
            
            // Section headers (### New, ### Improvements, etc.)
            if trimmed.hasPrefix("###") {
                // Save previous feature if exists
                if let title = currentTitle, !title.isEmpty {
                    let desc = currentDescription.isEmpty ? "New feature or improvement" : currentDescription
                    features.append(createFeature(title: title, description: desc))
                    print("✅ Added feature: \(title)")
                    currentTitle = nil
                    currentDescription = ""
                }
                
                // This is a section header, not a feature
                currentSection = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                print("📂 Section: \(currentSection)")
                continue
            }
            
            // Check for bullet points or list items (supporting nested with spaces/tabs)
            let bulletPrefixes = ["- ", "* ", "+ ", "  - ", "  * ", "  + ", "\t- ", "\t* ", "\t+ "]
            var isBullet = false
            var bulletContent = ""
            
            for prefix in bulletPrefixes {
                if trimmed.hasPrefix(prefix) {
                    isBullet = true
                    bulletContent = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            
            if isBullet {
                // Save previous feature if exists
                if let title = currentTitle, !title.isEmpty {
                    let desc = currentDescription.isEmpty ? "New feature or improvement" : currentDescription
                    features.append(createFeature(title: title, description: desc))
                    print("✅ Added feature: \(title)")
                }
                
                // Check if it has a colon (title: description format)
                if let colonIndex = bulletContent.firstIndex(of: ":") {
                    currentTitle = String(bulletContent[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    currentDescription = String(bulletContent[bulletContent.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    // Entire content is the title, use section as context for description
                    currentTitle = bulletContent
                    // If we have a section context and no description, use it
                    if !currentSection.isEmpty {
                        currentDescription = currentSection
                    } else {
                    currentDescription = ""
                }
            }
            }
            // Continuation of description (only if we have a current item and not starting a new section)
            else if let title = currentTitle, !title.isEmpty, !trimmed.hasPrefix("#") {
                // Add to description if it's a continuation
                if currentDescription == currentSection {
                    // Replace section placeholder with actual description
                    currentDescription = trimmed
                } else {
                    if !currentDescription.isEmpty && currentDescription != currentSection {
                    currentDescription += " "
                }
                currentDescription += trimmed
            }
            }
        }
        
        // Add last feature if exists
        if let title = currentTitle, !title.isEmpty {
            let desc = currentDescription.isEmpty || currentDescription == currentSection ? "New feature or improvement" : currentDescription
            features.append(createFeature(title: title, description: desc))
            print("✅ Added feature: \(title)")
        }
        
        print("📊 Total features parsed: \(features.count)")
        
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

