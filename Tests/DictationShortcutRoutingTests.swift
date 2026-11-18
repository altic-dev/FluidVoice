@main
enum DictationShortcutRoutingTests {
    typealias Routing = DictationShortcutRouting<String, String>

    static func routing(main: [String], mainStyle: String = "smart", styles: [(String, String)] = []) -> Routing {
        Routing(
            mainKeys: main,
            mainStyle: mainStyle,
            styleKeys: styles.map { (style: $0.0, key: $0.1) },
            keyCanMoveToStyle: { !$0.hasPrefix("mouse") }
        )
    }

    static func styles(_ routing: Routing) -> [String] {
        routing.styleKeys.map { "\($0.style)=\($0.key)" }
    }

    static func main() {
        // A single main key changes the shared style and stays a main key.
        var single = self.routing(main: ["ralt"], styles: [("smart", "fn")])
        precondition(single.move(single.packages[0], to: "off"))
        precondition(single.mainKeys == ["ralt"] && single.mainStyle == "off")
        precondition(self.styles(single) == ["smart=fn"], "Other keys must keep their style")

        // An extra main key moves out to a free style and leaves the other main keys alone.
        var extra = self.routing(main: ["ralt", "f5"])
        precondition(extra.move(extra.packages[1], to: "email"))
        precondition(extra.mainKeys == ["ralt"] && extra.mainStyle == "smart")
        precondition(self.styles(extra) == ["email=f5"])

        // A style key joins the main keys when it picks the main style.
        var back = self.routing(main: ["ralt"], styles: [("email", "f5")])
        precondition(back.move(back.packages[1], to: "smart"))
        precondition(back.mainKeys == ["ralt", "f5"] && back.styleKeys.isEmpty)

        // A style key switches to another free style in place.
        var swap = self.routing(main: ["ralt"], styles: [("email", "f5"), ("notes", "f6")])
        precondition(swap.move(swap.packages[1], to: "slack"))
        precondition(self.styles(swap) == ["slack=f5", "notes=f6"])

        // No cleanup is a style like any other, so an extra key can use it.
        var plain = self.routing(main: ["ralt", "f5"], styles: [("smart", "fn")])
        precondition(plain.move(plain.packages[2], to: "off"))
        precondition(self.styles(plain) == ["off=fn"] && plain.mainKeys == ["ralt", "f5"])

        // Blocked moves explain why and change nothing.
        let busy = self.routing(main: ["ralt", "f5", "mouse4"], styles: [("email", "fn")])
        precondition(busy.blocker(moving: busy.packages[1], to: "email") == .taken(by: "fn"))
        precondition(busy.blocker(moving: busy.packages[1], to: "off") == nil)
        precondition(busy.blocker(moving: busy.packages[2], to: "notes") == .mainKeysOnly)
        precondition(busy.blocker(moving: busy.packages[2], to: "smart") == nil)
        precondition(busy.blocker(moving: busy.packages[3], to: "off") == nil)
        precondition(busy.blocker(moving: busy.packages[3], to: "smart") == nil)
        var unchanged = busy
        precondition(!unchanged.move(busy.packages[1], to: "email"))
        precondition(unchanged.mainKeys == busy.mainKeys && self.styles(unchanged) == self.styles(busy))

        // Picking the current style, or acting on a stale package, is a no-op.
        var same = self.routing(main: ["ralt", "f5"])
        precondition(!same.move(same.packages[0], to: "smart"))
        let stale = same.packages[1]
        same.mainKeys = ["ralt"]
        precondition(!same.move(stale, to: "email") && same.styleKeys.isEmpty)

        print("Dictation shortcut routing tests passed")
    }
}
