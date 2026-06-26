import AppKit

class MenuBarIconGenerator {
    static func createMenuBarIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()

        // Clear background (transparent)
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()

        // Draw white "F" shape
        NSColor.white.set()

        let path = NSBezierPath()

        // F shape proportions for 18x18 icon
        let x: CGFloat = 4
        let y: CGFloat = 2
        let width: CGFloat = 10
        let height: CGFloat = 14
        let strokeWidth: CGFloat = 2

        // Vertical line of F
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x, y: y + height))
        path.line(to: NSPoint(x: x + strokeWidth, y: y + height))
        path.line(to: NSPoint(x: x + strokeWidth, y: y + height * 0.6))

        // Top horizontal line
        path.line(to: NSPoint(x: x + width * 0.7, y: y + height * 0.6))
        path.line(to: NSPoint(x: x + width * 0.7, y: y + height * 0.6 + strokeWidth))
        path.line(to: NSPoint(x: x + strokeWidth, y: y + height * 0.6 + strokeWidth))

        // Middle horizontal line
        path.line(to: NSPoint(x: x + strokeWidth, y: y + height * 0.8))
        path.line(to: NSPoint(x: x + width * 0.6, y: y + height * 0.8))
        path.line(to: NSPoint(x: x + width * 0.6, y: y + height * 0.8 + strokeWidth))
        path.line(to: NSPoint(x: x + strokeWidth, y: y + height * 0.8 + strokeWidth))

        // Complete the F
        path.line(to: NSPoint(x: x + strokeWidth, y: y + height))
        path.line(to: NSPoint(x: x + width, y: y + height))
        path.line(to: NSPoint(x: x + width, y: y + height - strokeWidth))
        path.line(to: NSPoint(x: x, y: y + height - strokeWidth))
        path.close()

        path.fill()

        image.unlockFocus()

        // Set as template image
        image.isTemplate = true

        return image
    }
}
