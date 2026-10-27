import Foundation

@main
enum ForegroundAppOverrideTests {
    static func main() {
        var state = ForegroundAppOverride<String>()
        precondition(state.activate("editor"))
        precondition(state.choice(slot: "primary", appID: "editor") == nil)
        state.select("smart-mini", slot: "primary", appID: "editor")
        precondition(!state.activate("editor"))
        precondition(!state.activate(nil))
        precondition(!state.activate(""))
        precondition(state.choice(slot: "primary", appID: "editor") == "smart-mini")
        precondition(state.choice(slot: "secondary", appID: "editor") == nil)
        state.select("basic", slot: "secondary", appID: "editor")
        precondition(state.choice(slot: "primary", appID: "editor") == "smart-mini")
        state.select("wrong-app", slot: "primary", appID: "browser")
        precondition(state.choice(slot: "primary", appID: "editor") == "smart-mini")
        precondition(state.choice(slot: "primary", appID: "browser") == nil)
        precondition(state.activate("browser"))
        precondition(state.choice(slot: "primary", appID: "editor") == nil)
        precondition(state.activate("editor"))
        precondition(state.choice(slot: "primary", appID: "editor") == nil)
        precondition(state.choice(slot: "secondary", appID: "editor") == nil)
        for _ in 0..<1000 {
            state.select("basic", slot: "primary", appID: "editor")
            state.activate("browser")
            state.activate("editor")
            precondition(state.choice(slot: "primary", appID: "editor") == nil)
        }
        print("PASS: same-app persistence, app re-entry reset, slot isolation, stale targets, nil events, 1000 rapid switches")
    }
}
