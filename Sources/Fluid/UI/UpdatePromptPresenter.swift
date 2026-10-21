import AppKit

/// Adapted from PR #837. Prompt presentation never takes focus or enters a modal loop.
@MainActor
final class UpdatePromptPresenter {
    static let shared = UpdatePromptPresenter()
    private var floatingPromptWindow: FloatingPromptPanel?
    private var floatingPromptQueue: [FloatingPrompt] = []
    private static let maxQueuedFloatingPrompts = 4

    func presentFloatingPrompt(
        title: String,
        message: String,
        actions: [FloatingPromptAction],
        isAutomaticUpdateOffer: Bool = false
    ) {
        guard !actions.isEmpty else { return }
        if let index = self.floatingPromptQueue.firstIndex(where: { $0.title == title }) {
            let existing = self.floatingPromptQueue[index]
            let promotesToManual = existing.isAutomaticUpdateOffer && !isAutomaticUpdateOffer
            guard existing.message != message || promotesToManual else { return }
            self.floatingPromptQueue[index] = FloatingPrompt(
                title: title,
                message: message,
                actions: actions,
                isAutomaticUpdateOffer: existing.isAutomaticUpdateOffer && isAutomaticUpdateOffer
            )
            if index == 0 {
                let wasKey = self.floatingPromptWindow?.isKeyWindow == true
                self.floatingPromptWindow?.close()
                self.floatingPromptWindow = nil
                self.showNextFloatingPromptIfIdle()
                if wasKey { self.floatingPromptWindow?.makeKey() }
            }
            return
        }
        guard self.floatingPromptQueue.count < Self.maxQueuedFloatingPrompts else {
            return
        }

        self.floatingPromptQueue.append(FloatingPrompt(
            title: title,
            message: message,
            actions: actions,
            isAutomaticUpdateOffer: isAutomaticUpdateOffer
        ))
        self.showNextFloatingPromptIfIdle()
    }

    private func showNextFloatingPromptIfIdle() {
        guard self.floatingPromptWindow == nil, let prompt = self.floatingPromptQueue.first else { return }

        let title = prompt.title
        let message = prompt.message
        let actions = prompt.actions
        let margin: CGFloat = 22
        let textLeading: CGFloat = 92
        let buttonHeight: CGFloat = 30
        let buttonSpacing: CGFloat = 10

        let buttons = actions.enumerated().map { index, action in
            let button = FloatingPromptButton(title: action.title) { [weak self] in
                guard let self, self.floatingPromptQueue.first?.id == prompt.id else { return }
                self.finishVisibleFloatingPrompt()
                action.handler()
                self.showNextFloatingPromptIfIdle()
            }
            if index == 0 {
                button.keyEquivalent = "\r"
            }
            return button
        }
        let buttonWidths = buttons.enumerated().map { index, button in
            max(ceil(button.fittingSize.width), index == 0 ? 96 : 80)
        }
        let buttonsWidth = buttonWidths.reduce(0, +) + buttonSpacing * CGFloat(max(buttons.count - 1, 0))
        let panelWidth = max(420, margin * 2 + buttonsWidth)
        let textWidth = panelWidth - textLeading - margin

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .fluidSystemFont(ofSize: 16, weight: .semibold)
        let titleHeight = ceil(titleLabel.fittingSize.height)

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .fluidSystemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = textWidth
        let detailHeight = ceil(detail.fittingSize.height)

        let buttonsY = margin - 2
        let detailY = buttonsY + buttonHeight + 16
        let titleY = detailY + detailHeight + 8
        let panelHeight = titleY + titleHeight + margin

        titleLabel.frame = NSRect(x: textLeading, y: titleY, width: textWidth, height: titleHeight)
        detail.frame = NSRect(x: textLeading, y: detailY, width: textWidth, height: detailHeight)

        var buttonTrailing = panelWidth - margin
        for (button, width) in zip(buttons, buttonWidths) {
            button.frame = NSRect(x: buttonTrailing - width, y: buttonsY, width: width, height: buttonHeight)
            buttonTrailing -= width + buttonSpacing
        }

        let panel = FloatingPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        if let cancelButton = buttons.last {
            panel.onCancel = { [weak cancelButton] in cancelButton?.performClick(nil) }
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.maskImage = .roundedRectMask(cornerRadius: 16)
        content.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: margin, y: panelHeight - margin - 52, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)
        content.addSubview(titleLabel)
        content.addSubview(detail)
        for button in buttons {
            content.addSubview(button)
        }

        panel.contentView = content
        panel.initialFirstResponder = buttons.first
        panel.center()
        // Even our own search/editor field may be receiving dictation. Never make this key here.
        panel.orderFrontRegardless()
        self.floatingPromptWindow = panel
    }

    private func finishVisibleFloatingPrompt() {
        self.floatingPromptWindow?.close()
        self.floatingPromptWindow = nil
        if !self.floatingPromptQueue.isEmpty {
            self.floatingPromptQueue.removeFirst()
        }
    }

    func dismissAutomaticUpdateOffers() {
        self.dismissPrompts { $0.isAutomaticUpdateOffer }
    }

    func dismissUpdateOffers() {
        self.dismissPrompts { $0.title == "Update Available" }
    }

    func dismissUpdateCheckResults() {
        self.dismissPrompts {
            $0.title == "No Updates" || $0.title == "No Beta Updates" || $0.title == "Update Check Failed"
        }
    }

    private func dismissPrompts(where shouldDismiss: (FloatingPrompt) -> Bool) {
        let removesVisiblePrompt = self.floatingPromptQueue.first.map(shouldDismiss) == true
        self.floatingPromptQueue.removeAll(where: shouldDismiss)
        if removesVisiblePrompt {
            self.floatingPromptWindow?.close()
            self.floatingPromptWindow = nil
            self.showNextFloatingPromptIfIdle()
        }
    }

    func dismissAll() {
        self.floatingPromptWindow?.close()
        self.floatingPromptWindow = nil
        self.floatingPromptQueue.removeAll()
    }
}

struct FloatingPromptAction {
    let title: String
    let handler: @MainActor () -> Void
}

private struct FloatingPrompt {
    let id = UUID()
    let title: String
    let message: String
    let actions: [FloatingPromptAction]
    let isAutomaticUpdateOffer: Bool
}

private final class FloatingPromptPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool {
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        let onCancel = self.onCancel
        onCancel?()
    }
}

private final class FloatingPromptButton: NSButton {
    private let onClick: @MainActor () -> Void

    init(title: String, onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(self.handleClick)
        self.sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FloatingPromptButton is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    @objc private func handleClick() {
        let onClick = self.onClick
        onClick()
    }
}

extension NSImage {
    static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        return image
    }
}
