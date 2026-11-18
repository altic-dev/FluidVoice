import SwiftUI

/// A note another screen fills in for the user. Everything in it stays visible and editable.
struct FeedbackDraft: Equatable {
    let category: FeedbackCategory
    let message: String
    let includeDetails: Bool
}

/// One calm surface: what kind of note, the note, how to reach you, send. Extras live in a
/// single quiet footer line so nothing competes with the message itself.
struct FeedbackView: View {
    @Environment(\.theme) private var theme
    /// Taken once when it arrives, then cleared, so later visits start empty.
    @Binding var pendingDraft: FeedbackDraft?
    @State private var category: FeedbackCategory = .issue
    @State private var message = ""
    @State private var email = ""
    @State private var includeDetails = false
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @State private var showsFilledInNote = false
    @FocusState private var messageFocused: Bool
    @FocusState private var emailFocused: Bool

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
                FluidPageHeader(title: "Make FluidVoice better.", subtitle: "Something in your way? Have an idea? Tell us.")

                if self.sent {
                    self.confirmation
                } else {
                    self.categories
                    self.form
                }

                self.footer
            }
            .fluidPageContent(width: .form, alignment: .center)
        }
        .fluidCanvas()
        .onAppear(perform: self.takePendingDraft)
        .onChange(of: self.pendingDraft) { _, _ in self.takePendingDraft() }
    }

    private func takePendingDraft() {
        guard let draft = self.pendingDraft else { return }
        self.pendingDraft = nil
        self.category = draft.category
        self.message = draft.message
        self.includeDetails = draft.includeDetails
        self.sent = false
        self.error = nil
        self.showsFilledInNote = true
    }

    private var filledInNote: some View {
        Text("We filled this in for you. Add anything you noticed, or just send it.")
            .fluidText(.label)
            .foregroundStyle(self.theme.look.highlightText)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .padding(.vertical, self.theme.metrics.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.theme.look.highlightFill, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
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
                    .fluidText(.rowTitle)
                    .foregroundStyle(selected ? self.theme.look.text : self.theme.look.secondaryText)
                    .padding(.horizontal, self.theme.metrics.spacing.lg)
                    .frame(height: 34)
                    .background(self.theme.look.quietFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .fluidSelectableRow(isSelected: selected, cornerRadius: 999, fillsWidth: false)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                if self.showsFilledInNote {
                    self.filledInNote
                }
                self.messageField

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    self.emailRow
                    self.detailsRow
                }
            }
            .padding(self.theme.metrics.spacing.xl)

            FluidHairline()

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
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.text)

            ZStack(alignment: .topLeading) {
                TextEditor(text: self.$message)
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.text)
                    .scrollContentBackground(.hidden)
                    .focused(self.$messageFocused)
                    .padding(self.theme.metrics.spacing.sm)
                    .frame(minHeight: 168, maxHeight: 240)
                    .accessibilityLabel(self.category.prompt)
                if self.message.isEmpty {
                    Text(self.category.hint)
                        .fluidText(.body)
                        .foregroundStyle(self.theme.look.tertiaryText)
                        .padding(.horizontal, self.theme.metrics.spacing.md + 1)
                        .padding(.vertical, self.theme.metrics.spacing.lg)
                        .allowsHitTesting(false)
                }
            }
            .fluidFieldChrome(isFocused: self.messageFocused, padding: 0)

            HStack(alignment: .firstTextBaseline) {
                Text(self.overLimit ? "Please shorten your message before sending." : "Leave out passwords and private information.")
                    .foregroundStyle(self.overLimit ? self.theme.look.text : self.theme.look.tertiaryText)
                Spacer(minLength: self.theme.metrics.spacing.sm)
                if self.nearLimit {
                    Text("\(self.messageCount) / \(FeedbackSubmission.messageLimit)")
                        .monospacedDigit()
                        .foregroundStyle(self.overLimit ? self.theme.look.text : self.theme.look.tertiaryText)
                }
            }
            .fluidText(.label)
        }
    }

    private var emailRow: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Email")
                    .fluidText(.rowTitle)
                    .foregroundStyle(self.theme.look.text)
                Text("optional")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
            }
            TextField("", text: self.$email, prompt: Text(verbatim: "you@example.com").foregroundColor(self.theme.look.tertiaryText))
                .textFieldStyle(.plain)
                .fluidText(.body)
                .foregroundStyle(self.theme.look.text)
                .focused(self.$emailFocused)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .frame(height: 38)
                .fluidFieldChrome(isFocused: self.emailFocused, padding: 0)
                .accessibilityLabel("Your email, optional")
            if self.emailLooksWrong {
                Label("That doesn’t look like an email address.", systemImage: "exclamationmark.triangle")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.text)
            }
        }
    }

    private var detailsRow: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Include app and macOS versions")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.text)
                Text("No recordings or logs.")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
                Spacer(minLength: self.theme.metrics.spacing.sm)
                Toggle("Include app and macOS versions", isOn: self.$includeDetails)
                    .fluidSwitch()
            }
            if self.includeDetails {
                Text(FeedbackSubmission.appDetails)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.look.secondaryText)
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
            Label(error, systemImage: "exclamationmark.triangle")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.text)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(self.sending ? "Sending…" : "Goes straight to the FluidVoice team.")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.tertiaryText)
        }
    }

    private var sendButton: some View {
        Button { Task { await self.submit() } } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.sending { ProgressView().controlSize(.small) }
                Text(self.error == nil ? "Send feedback" : "Try again")
            }
        }
        .fluidAction(.primary)
        .disabled(!self.draft.isValid || self.sending)
        .keyboardShortcut(.return, modifiers: .command)
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Thank you. It’s in.")
                    .fluidText(.detailTitle)
                    .foregroundStyle(self.theme.look.text)
                Text("If we need more detail, we’ll reach you by email.")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
            Button("Send another") { self.sent = false }
                .fluidAction()
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
                    .fluidGlassAction(quiet: true)
            }
            if let url = Self.sponsorURL {
                Link("Support development", destination: url)
                    .fluidGlassAction(quiet: true)
            }
        }
        .fluidText(.label)
        .foregroundStyle(self.theme.look.tertiaryText)
        .padding(.top, self.theme.metrics.spacing.sm)
    }

    // MARK: - Surfaces

    /// The shared card: flat, a hairline, no shadow. The page stays quiet around the message.
    private var surface: some View {
        RoundedRectangle(cornerRadius: FluidSurfaceCard<EmptyView>.cornerRadius, style: .continuous)
            .fill(self.theme.look.card.top)
            .overlay(
                RoundedRectangle(cornerRadius: FluidSurfaceCard<EmptyView>.cornerRadius, style: .continuous)
                    .strokeBorder(self.theme.look.card.edgeTop, lineWidth: 1)
            )
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
            self.showsFilledInNote = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
