//
//  FeedbackView.swift
//  fluid
//
//  Extracted from ContentView.swift to reduce monolithic architecture.
//  Created: 2025-12-14
//

import AppKit
import SwiftUI

struct FeedbackView: View {
    @Environment(\.theme) private var theme

    // MARK: - State Variables (moved from ContentView)

    @State private var feedbackText: String = ""
    @State private var feedbackEmail: String = ""
    @State private var includeDebugLogs: Bool = false
    @State private var isSendingFeedback: Bool = false
    @State private var showFeedbackConfirmation: Bool = false
    @State private var showFeedbackError: Bool = false
    @State private var feedbackErrorMessage: String = ""
    @State private var appear: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(self.theme.palette.accent)
                        VStack(alignment: .leading) {
                            Text("Send Feedback")
                                .font(.system(size: 28, weight: .bold))
                            Text("Help us improve FluidVoice")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.bottom, 8)

                // Friendly Message & GitHub CTA
                ThemedCard(style: .prominent, hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.pink)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("We'd love to hear from you!")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(self.theme.palette.primaryText)

                                Text("Your feedback helps us make FluidVoice even better")
                                    .font(.system(size: 14))
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        HStack(spacing: 12) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.yellow)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Loving FluidVoice?")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(self.theme.palette.primaryText)

                                Text("Give us a star on GitHub! It helps others discover the project and motivates us to keep improving.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if let url = URL(string: "https://github.com/altic-dev/Fluid-oss") {
                                Link(destination: url) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "star.fill")
                                        Text("Star on GitHub")
                                            .fontWeight(.semibold)
                                    }
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(LinearGradient(
                                        colors: [.purple, .blue],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverEffect()
                            }
                        }
                    }
                    .padding(20)
                }

                // Feedback Form
                ThemedCard(style: .standard, hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Email")
                                .font(.headline)
                                .fontWeight(.semibold)

                            TextField("your.email@example.com", text: self.$feedbackEmail)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))

                            Text("Feedback")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .padding(.top, 8)

                            TextEditor(text: self.$feedbackText)
                                .font(.system(size: 14))
                                .frame(height: 120)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: NSColor.textBackgroundColor))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color(nsColor: NSColor.separatorColor), lineWidth: 1.5)))
                                .scrollContentBackground(.hidden)
                                .overlay(VStack {
                                    if self.feedbackText.isEmpty {
                                        Text("Share your thoughts, report bugs, or suggest features...")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .allowsHitTesting(false))

                            // Debug logs option
                            Toggle("Include debug logs", isOn: self.$includeDebugLogs)
                                .toggleStyle(GlassToggleStyle())

                            // Send Button
                            HStack {
                                Spacer()

                                Button(action: {
                                    Task {
                                        await self.sendFeedback()
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        if self.isSendingFeedback {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                        }
                                        Text(self.isSendingFeedback ? "Sending..." : "Send Feedback")
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(GlassButtonStyle())
                                .disabled(self.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    self.feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    self.isSendingFeedback)
                                .buttonHoverEffect()
                            }
                        }
                    }
                    .padding(20)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: self.$appear))
            }
            .padding(24)
        }
        .onAppear {
            self.appear = true
        }
        .alert("Feedback Sent", isPresented: self.$showFeedbackConfirmation) {
            Button("OK") {}
        } message: {
            Text("Thank you for helping us improve FluidVoice.")
        }
        .alert("Feedback Failed", isPresented: self.$showFeedbackError) {
            Button("Try Again") {
                Task {
                    await self.sendFeedback()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(self.feedbackErrorMessage)
        }
    }

    // MARK: - Feedback Functions

    private func sendFeedback() async {
        guard !self.feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        await MainActor.run {
            self.isSendingFeedback = true
        }

        let feedbackData = self.createFeedbackData()
        let success = await submitFeedback(data: feedbackData)

        await MainActor.run {
            self.isSendingFeedback = false
            if success {
                // Show confirmation and clear form
                self.showFeedbackConfirmation = true
                self.feedbackText = ""
                self.feedbackEmail = ""
                self.includeDebugLogs = false
            } else {
                // Show error to user - inputs are preserved for retry
                self.feedbackErrorMessage = "We couldn't send your feedback. Please check your internet connection and try again."
                self.showFeedbackError = true
            }
        }
    }

    private func createFeedbackData() -> [String: Any] {
        var feedbackContent = self.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)

        if self.includeDebugLogs {
            feedbackContent += "\n\n--- Debug Information ---\n"
            feedbackContent += "App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")\n"
            feedbackContent += "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")\n"
            feedbackContent += "macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            feedbackContent += "Date: \(Date().formatted())\n\n"

            // Add recent log entries
            let logFileURL = FileLogger.shared.currentLogFileURL()
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                do {
                    let logContent = try String(contentsOf: logFileURL)
                    let lines = logContent.components(separatedBy: .newlines)
                    let recentLines = Array(lines.suffix(30)) // Last 30 lines
                    feedbackContent += "Recent Log Entries:\n"
                    feedbackContent += recentLines.joined(separator: "\n")
                } catch {
                    feedbackContent += "Could not read log file: \(error.localizedDescription)\n"
                }
            }
        }

        return [
            "email_id": self.feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            "feedback": feedbackContent,
        ]
    }

    private func submitFeedback(data: [String: Any]) async -> Bool {
        guard let url = URL(string: "https://altic.dev/api/fluid/feedback") else {
            DebugLogger.shared.error("Invalid feedback API URL", source: "FeedbackView")
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: data)

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let success = (200...299).contains(httpResponse.statusCode)
                if success {
                    DebugLogger.shared.info("Feedback submitted successfully", source: "FeedbackView")
                } else {
                    DebugLogger.shared.error(
                        "Feedback submission failed with status: \(httpResponse.statusCode)",
                        source: "FeedbackView"
                    )
                }
                return success
            }
            return false
        } catch {
            DebugLogger.shared.error(
                "Network error submitting feedback: \(error.localizedDescription)",
                source: "FeedbackView"
            )
            return false
        }
    }
}

#Preview {
    FeedbackView()
}
