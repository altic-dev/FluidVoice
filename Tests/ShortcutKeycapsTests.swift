@main
enum ShortcutKeycapsTests {
    static func expect(_ display: String, _ caps: [String]) {
        let actual = ShortcutKeycaps.caps(for: display)
        precondition(actual == caps, "\(display) -> \(actual), expected \(caps)")
    }

    static func main() {
        // Modifiers come first in the usual Mac order, and "Left" is dropped from combinations.
        self.expect("Left ⌘ + Left ⌥ + Left ⌃ + M", ["⌃", "⌥", "⌘", "M"])
        self.expect("Left ⌘ + S", ["⌘", "S"])
        self.expect("⇧ + ⌘ + K", ["⇧", "⌘", "K"])
        // A side-specific modifier keeps its side so the user knows which key to press.
        self.expect("Right ⌥ + Left ⌘ + K", ["Right ⌥", "⌘", "K"])
        // A single key is shown as it is, except keys that are hard to read.
        self.expect("Right ⌥", ["Right ⌥"])
        self.expect("fn", ["fn"])
        self.expect("`", ["Backtick"])
        self.expect("Escape", ["esc"])
        self.expect("Left ⌘ + Space", ["⌘", "space"])
        // Mouse buttons and unknown keys pass through untouched.
        self.expect("Left ⌥ + Mouse 4", ["⌥", "Mouse 4"])
        self.expect("", [])
        print("Shortcut keycap tests passed")
    }
}
