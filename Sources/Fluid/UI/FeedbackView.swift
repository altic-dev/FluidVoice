import SwiftUI

/// One calm surface: what kind of note, the note, how to reach you, send. Extras live in a
/// single quiet footer line so nothing competes with the message itself.
struct FeedbackView: View {
    @Environment(\.theme) private var theme
    @State private var category: FeedbackCategory = .issue
    @State private var message = ""
    @State private var email = ""
    @State private var includeDetails = false
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private static let starURL = URL(string: "https://github.com/altic-dev/Fluid-oss")
    private static let sponsorURL = URL(string: "https://github.com/sponsors/altic-dev")

    private var draft: FeedbackSubmission {
        FeedbackSubmission(
            email: self.email,
            message: self.message,
            category: self.category,
            appDetails: self.includeDetails ? FeedbackSubmission.appDetails : nil
        )
    }

    private var messageCount: Int { self.message.utf16.count }
    private var nearLimit: Bool { self.messageCount > FeedbackSubmission.messageLimit * 8 / 10 }
    private var overLimit: Bool { self.messageCount > FeedbackSubmission.messageLimit }
    private var emailLooksWrong: Bool { !self.email.isEmpty && !FeedbackSubmission.isValidEmail(self.email) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text("Make FluidVoice better.")
                        .font(self.theme.typography.displayTitle)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("Something in your way? Have an idea? Tell us.")
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.sent {
                    self.confirmation
                } else {
                    self.categories
                    self.form
                }

                self.footer
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(self.theme.metrics.spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(self.theme.palette.windowBackground)
    }

    // MARK: - Category

    private var categories: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: self.theme.metrics.spacing.sm) { self.categoryChips }
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.categoryChips }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Feedback type")
    }

    private var categoryChips: some View {
        ForEach(FeedbackCategory.allCases, id: \.self) { category in
            let selected = self.category == category
            Button {
                self.category = category
                self.messageFocused = true
            } label: {
                Label(category.rawValue, systemImage: category.icon)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(selected ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
                    .padding(.horizontal, self.theme.metrics.spacing.lg)
                    .frame(height: 34)
                    .background(self.theme.palette.primaryText.opacity(selected ? 0.10 : 0.04), in: Capsule())
                    .overlay(Capsule().strokeBorder(self.theme.palette.separator.opacity(selected ? 0.9 : 0.5), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .meetingHoverFeedback()
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                self.messageField

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    self.emailRow
                    self.detailsRow
                }
            }
            .padding(self.theme.metrics.spacing.xl)

            Rectangle()
                .fill(self.theme.palette.separator)
                .frame(height: 1)

            self.sendRow
                .padding(.horizontal, self.theme.metrics.spacing.xl)
                .padding(.vertical, self.theme.metrics.spacing.lg)
        }
        .background(self.surface)
        .disabled(self.sending)
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text(self.category.prompt)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)

            ZStack(alignment: .topLeading) {
                TextEditor(text: self.$message)
                    .font(self.theme.typography.body)
                    .scrollContentBackground(.hidden)
                    .focused(self.$messageFocused)
                    .padding(self.theme.metrics.spacing.sm)
                    .frame(minHeight: 168, maxHeight: 240)
                    .accessibilityLabel(self.category.prompt)
                if self.message.isEmpty {
                    Text(self.category.hint)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .padding(.horizontal, self.theme.metrics.spacing.md + 1)
                        .padding(.vertical, self.theme.metrics.spacing.lg)
                        .allowsHitTesting(false)
                }
            }
            .background(self.fieldSurface(focused: self.messageFocused))

            HStack(alignment: .firstTextBaseline) {
                Text(self.overLimit ? "Please shorten your message before sending." : "Leave out passwords and private information.")
                    .foregroundStyle(self.overLimit ? self.theme.palette.warning : self.theme.palette.tertiaryText)
                Spacer(minLength: self.theme.metrics.spacing.sm)
                if self.nearLimit {
                    Text("\(self.messageCount) / \(FeedbackSubmission.messageLimit)")
                        .monospacedDigit()
                        .foregroundStyle(self.overLimit ? self.theme.palette.warning : self.theme.palette.tertiaryText)
                }
            }
            .font(self.theme.typography.caption)
        }
    }

    private var emailRow: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Email")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("optional")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            TextField("", text: self.$email, prompt: Text("you@example.com").foregroundColor(self.theme.palette.tertiaryText))
                .textFieldStyle(.plain)
                .font(self.theme.typography.body)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .frame(height: 38)
                .background(self.fieldSurface(focused: false))
                .accessibilityLabel("Your email, optional")
            if self.emailLooksWrong {
                Text("That doesn’t look like an email address.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private var detailsRow: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Toggle(isOn: self.$includeDetails) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Text("Include app and macOS versions")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("No recordings or logs.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if self.includeDetails {
                Text(FeedbackSubmission.appDetails)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private var sendRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: self.theme.metrics.spacing.lg) {
                self.deliveryNote
                Spacer(minLength: 0)
                self.sendButton
            }
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                self.deliveryNote
                self.sendButton
            }
        }
    }

    @ViewBuilder private var deliveryNote: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(self.sending ? "Sending…" : "Goes straight to the FluidVoice team.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)
        }
    }

    private var sendButton: some View {
        Button { Task { await self.submit() } } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.sending { ProgressView().controlSize(.small) }
                Text(self.error == nil ? "Send feedback" : "Try again")
            }
        }
        .fluidGlassAction(prominent: true)
        .disabled(!self.draft.isValid || self.sending)
        .keyboardShortcut(.return, modifiers: .command)
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(self.theme.palette.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Thank you. It’s in.")
                    .font(self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("If we need more detail, we’ll reach you by email.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Button("Send another") { self.sent = false }
                .fluidGlassAction()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.theme.metrics.spacing.xxl)
        .background(self.surface)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text("Enjoying FluidVoice?")
            if let url = Self.starURL {
                Link("Star it on GitHub", destination: url)
            }
            if let url = Self.sponsorURL {
                Text("·").accessibilityHidden(true)
                Link("Support development", destination: url)
            }
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.tertiaryText)
        .tint(self.theme.palette.secondaryText)
        .padding(.top, self.theme.metrics.spacing.sm)
    }

    // MARK: - Surfaces

    /// Flat: a hairline, no shadow, no material. The page stays quiet around the message.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
        return shape
            .fill(self.theme.palette.cardBackground)
            .overlay(shape.strokeBorder(self.theme.palette.separator, lineWidth: 1))
    }

    private func fieldSurface(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
        return shape
            .fill(self.theme.palette.contentBackground)
            .overlay(shape.strokeBorder(focused ? self.theme.palette.secondaryText.opacity(0.5) : self.theme.palette.separator, lineWidth: 1))
    }

    // MARK: - Submit

    @MainActor private func submit() async {
        guard !self.sending, self.draft.isValid else { return }
        let submission = self.draft
        self.sending = true
        self.error = nil
        defer { self.sending = false }
        do {
            try await FeedbackClient().send(submission)
            self.sent = true
            self.message = ""
            self.email = ""
            self.includeDetails = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
