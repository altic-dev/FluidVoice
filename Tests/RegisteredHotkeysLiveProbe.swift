import AppKit
import Carbon

@main
struct HotkeyDeliveryProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hotkeys = RegisteredHotkeys(driver: CarbonHotkeyDriver())
        var edges = 0
        hotkeys.onFailure = { _, status in
            print("REGISTRATION_FAILED status=\(status)")
            fflush(stdout)
        }
        hotkeys.onEvent = { _, down in
            edges += 1
            print("OPTION_SPACE \(down ? "DOWN" : "UP") secureInput=\(IsSecureEventInputEnabled())")
            fflush(stdout)
        }
        hotkeys.update(shortcuts: [HotkeyShortcut(keyCode: 49, modifierFlags: .option)])
        print("READY: Option+Space only; secureInput=\(IsSecureEventInputEnabled()); expires in 90 seconds")
        fflush(stdout)
        Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
            MainActor.assumeIsolated {
                hotkeys.update(shortcuts: [])
                print("DONE edges=\(edges); registration removed")
                fflush(stdout)
                app.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(event, atStart: true)
                }
            }
        }
        app.run()
    }
}
