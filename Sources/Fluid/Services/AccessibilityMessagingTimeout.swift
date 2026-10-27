import ApplicationServices

/// Bounds every Accessibility round-trip this process makes. The system
/// default is about six seconds; a busy target app would otherwise block the
/// main thread, and with it the keyboard event tap, for that long.
enum AccessibilityMessagingTimeout {
    static let seconds: Float = 2

    static func configure() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), self.seconds)
    }
}
