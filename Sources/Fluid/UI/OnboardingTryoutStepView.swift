import SwiftUI

struct OnboardingTryoutStepView: View {
    @Binding var finalText: String

    let language: VoiceEngineLanguage
    let shortcutDisplay: String
    let isReady: Bool
    let isRunning: Bool
    let isRecordingShortcut: Bool
    let shortcutRecordingMessage: String?
    let footerHint: String?
    let onToggleShortcut: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var isChangeHovered = false
    @FocusState private var isEditorFocused: Bool
    @State private var isShortcutKeyPressed = false
    @State private var isShortcutGlowActive = false
    @State private var shortcutAnimationRevision = 0

    init(
        finalText: Binding<String>,
        language: VoiceEngineLanguage,
        shortcutDisplay: String,
        isReady: Bool,
        isRunning: Bool,
        isRecordingShortcut: Bool,
        shortcutRecordingMessage: String?,
        footerHint: String? = nil,
        onToggleShortcut: @escaping () -> Void
    ) {
        self._finalText = finalText
        self.language = language
        self.shortcutDisplay = shortcutDisplay
        self.isReady = isReady
        self.isRunning = isRunning
        self.isRecordingShortcut = isRecordingShortcut
        self.shortcutRecordingMessage = shortcutRecordingMessage
        self.footerHint = footerHint
        self.onToggleShortcut = onToggleShortcut
    }

    private static let languageExamples: [String: [String]] = [
        "ar": [
            "ذكرني أن أرسل الملاحظات قبل الخامسة.",
            "اكتب رسالة قصيرة عن اجتماع اليوم.",
        ],
        "de": [
            "Erinnere mich daran, die Notizen vor fünf zu senden.",
            "Schreib eine kurze Nachricht über das heutige Treffen.",
        ],
        "en": [
            "Remind me to send the notes before five.",
            "Write a short update about today's meeting.",
        ],
        "es": [
            "Recuérdame enviar las notas antes de las cinco.",
            "Escribe una breve actualización sobre la reunión de hoy.",
        ],
        "fr": [
            "Rappelle-moi d'envoyer les notes avant cinq heures.",
            "Écris un court message sur la réunion d'aujourd'hui.",
        ],
        "hi": [
            "मुझे पाँच बजे से पहले नोट्स भेजने की याद दिलाना।",
            "आज की मीटिंग के बारे में एक छोटा अपडेट लिखो।",
        ],
        "it": [
            "Ricordami di inviare gli appunti prima delle cinque.",
            "Scrivi un breve aggiornamento sulla riunione di oggi.",
        ],
        "ja": [
            "5時前にメモを送るようにリマインドして。",
            "今日の会議について短い更新を書いて。",
        ],
        "ko": [
            "다섯 시 전에 메모를 보내라고 알려줘.",
            "오늘 회의에 대한 짧은 업데이트를 써줘.",
        ],
        "nl": [
            "Herinner me eraan om de notities voor vijf uur te sturen.",
            "Schrijf een korte update over de vergadering van vandaag.",
        ],
        "pl": [
            "Przypomnij mi, żeby wysłać notatki przed piątą.",
            "Napisz krótką aktualizację o dzisiejszym spotkaniu.",
        ],
        "pt": [
            "Lembre-me de enviar as notas antes das cinco.",
            "Escreva uma breve atualização sobre a reunião de hoje.",
        ],
        "ru": [
            "Напомни мне отправить заметки до пяти.",
            "Напиши короткое обновление о сегодняшней встрече.",
        ],
        "ta": [
            "ஐந்து மணிக்கு முன் குறிப்புகளை அனுப்ப நினைவூட்டு.",
            "இன்றைய கூட்டத்தைப் பற்றி ஒரு குறுகிய புதுப்பிப்பு எழுது.",
        ],
        "uk": [
            "Нагадай мені надіслати нотатки до п'ятої.",
            "Напиши коротке оновлення про сьогоднішню зустріч.",
        ],
        "vi": [
            "Nhắc tôi gửi ghi chú trước năm giờ.",
            "Viết một cập nhật ngắn về cuộc họp hôm nay.",
        ],
        "zh": [
            "提醒我五点前发送笔记。",
            "写一段关于今天会议的简短更新。",
        ],
    ]

    private var exampleTexts: [String] {
        Self.languageExamples[self.language.id] ?? []
    }

    private var promptText: String {
        if self.exampleTexts.isEmpty {
            return "Say anything you'd want to dictate in \(self.language.displayName)."
        }
        return "Try this, or say anything you'd want to dictate."
    }

    private var hasText: Bool {
        !self.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowPlaceholder: Bool {
        !self.hasText && !self.isEditorFocused
    }

    private var placeholderText: String {
        if self.isReady {
            return "Click here to test FluidVoice"
        }
        return self.isRunning ? "Listening..." : "Your dictation will appear here..."
    }

    var body: some View {
        VStack(spacing: 12) {
            self.keyboardCard

            Text(self.footerHint ?? "Feels slow or inaccurate? Go back and try another model for \(self.language.displayName).")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(Color.white.opacity(0.44))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 560)
        .onAppear {
            self.isShortcutGlowActive = self.isRunning
        }
        .onChange(of: self.isRunning) { _, newValue in
            self.animateShortcutKeyToggle(to: newValue)
        }
    }

    private var keyboardCard: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return VStack(spacing: 14) {
            HStack {
                Spacer()
                self.changeShortcutButton
            }
            .frame(height: 0)
            .offset(y: 8)

            self.shortcutVisual
                .padding(.top, 10)

            self.actionHintRow

            if let shortcutRecordingMessage,
               self.isRecordingShortcut,
               !shortcutRecordingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Label(shortcutRecordingMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(Color.orange.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            self.editorPanel
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .background(
            shape
                .fill(Color.white.opacity(0.040))
                .overlay(shape.stroke(Color.white.opacity(0.11), lineWidth: 1))
                .overlay(
                    shape.stroke(
                        FluidOnboardingLandingColors.blue.opacity(self.isShortcutGlowActive ? 0.30 : 0.12),
                        lineWidth: self.isShortcutGlowActive ? 1.3 : 1
                    )
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation shortcut \(self.shortcutDisplay). Press once to start. Press again to stop.")
    }

    private var changeShortcutButton: some View {
        let shape = Capsule()
        let isEnabled = !self.isRunning
        let title = self.isRecordingShortcut ? "Cancel" : "Change"
        let fillOpacity = isEnabled ? (self.isChangeHovered ? 0.11 : 0.07) : 0.045
        let foregroundOpacity = isEnabled ? (self.isChangeHovered ? 0.94 : 0.78) : 0.42
        let ringOpacity = self.isChangeHovered && isEnabled ? 0.50 : 0

        return Button {
            self.onToggleShortcut()
        } label: {
            Text(title)
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(.white.opacity(foregroundOpacity))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 72, height: 32)
                .background(
                    shape
                        .fill(Color.white.opacity(fillOpacity))
                        .overlay(shape.stroke(self.isChangeHovered && isEnabled ? FluidOnboardingLandingColors.blue.opacity(0.30) : Color.white.opacity(0.07), lineWidth: 1))
                        .overlay(
                            shape
                                .stroke(FluidOnboardingLandingColors.blue.opacity(ringOpacity), lineWidth: self.isChangeHovered && isEnabled ? 1.4 : 1)
                                .padding(-2)
                        )
                        .shadow(color: FluidOnboardingLandingColors.blue.opacity(self.isChangeHovered && isEnabled ? 0.08 : 0), radius: 16, x: 0, y: 6)
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(!isEnabled)
        .onHover { isHovered in
            self.setChangeHovered(isHovered && isEnabled)
        }
    }

    private var shortcutVisual: some View {
        HStack(spacing: 14) {
            self.sideKeyBox()
            self.shortcutKeycap(self.shortcutDisplay)
            self.sideKeyBox()
        }
    }

    private var actionHintRow: some View {
        Text("Press once to start. Press again to stop.")
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(Color.white.opacity(0.62))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }

    private var editorPanel: some View {
        let examples = Array(self.exampleTexts.prefix(1))

        return VStack(alignment: .leading, spacing: 10) {
            if !examples.isEmpty {
                Text(self.promptText)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.58))

                ForEach(examples, id: \.self) { example in
                    self.examplePill(example)
                }
            } else {
                self.examplePill("Say anything in \(self.language.displayName).")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: self.$finalText)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(.white)
                    .frame(height: 108)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(self.isRunning ? 0.075 : 0.045))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        self.isRunning ? FluidOnboardingLandingColors.blue.opacity(0.46) : Color.white.opacity(0.08),
                                        lineWidth: self.isRunning ? 1.4 : 1
                                    )
                            )
                    )
                    .scrollContentBackground(.hidden)
                    .focused(self.$isEditorFocused)

                if self.shouldShowPlaceholder {
                    Text(self.placeholderText)
                        .font(self.theme.typography.bodySmallStrong)
                        .foregroundStyle(Color.white.opacity(0.38))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func sideKeyBox() -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.055),
                        Color.white.opacity(0.020),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .frame(width: 88, height: 66)
    }

    private func shortcutKeycap(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let isPressed = self.isShortcutKeyPressed
        let isListening = self.isShortcutGlowActive

        return Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .padding(.horizontal, 14)
            .frame(width: 112, height: 74)
            .background(
                shape
                    .fill(Color.white.opacity(isListening ? 0.115 : 0.075))
                    .overlay(
                        shape.stroke(
                            FluidOnboardingLandingColors.blue.opacity(isListening ? 0.86 : 0.48),
                            lineWidth: isListening ? 1.6 : 1.2
                        )
                    )
                    .shadow(
                        color: FluidOnboardingLandingColors.blue.opacity(isListening ? 0.34 : 0.20),
                        radius: isListening ? 18 : 12,
                        x: 0,
                        y: isPressed ? 2 : 0
                    )
            )
            .scaleEffect(isPressed ? 0.965 : 1)
            .offset(y: isPressed ? 4 : 0)
            .accessibilityLabel("Current shortcut \(text)")
    }

    private func examplePill(_ text: String) -> some View {
        Text(text)
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(2)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(FluidOnboardingLandingColors.blue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(FluidOnboardingLandingColors.blue.opacity(0.16), lineWidth: 1)
                    )
            )
    }

    private func setChangeHovered(_ isHovered: Bool) {
        guard self.isChangeHovered != isHovered else { return }
        if self.reduceMotion {
            self.isChangeHovered = isHovered
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.isChangeHovered = isHovered
            }
        }
    }

    private func animateShortcutKeyToggle(to isListening: Bool) {
        self.shortcutAnimationRevision += 1
        let revision = self.shortcutAnimationRevision

        if self.reduceMotion {
            self.isShortcutKeyPressed = false
            self.isShortcutGlowActive = isListening
            return
        }

        withAnimation(.easeOut(duration: 0.055)) {
            self.isShortcutKeyPressed = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            guard self.shortcutAnimationRevision == revision else {
                return
            }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.72, blendDuration: 0.02)) {
                self.isShortcutKeyPressed = false
                self.isShortcutGlowActive = isListening
            }
        }
    }
}
