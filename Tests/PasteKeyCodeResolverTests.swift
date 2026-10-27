import Carbon.HIToolbox
import Foundation

@main
enum PasteKeyCodeResolverTests {
    static func main() {
        // Read installed layout data without enabling or switching any user input source.
        guard let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource] else {
            fatalError("Unable to read installed keyboard layouts")
        }
        for (identifier, expected): (String, CGKeyCode) in [
            ("com.apple.keylayout.US", 9),
            ("com.apple.keylayout.Dvorak", 47),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
            ("com.apple.keylayout.French", 9),
            ("com.apple.keylayout.Russian", 9),
        ] {
            guard let source = sources.first(where: { source in
                guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
                return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == identifier
            }), let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                fatalError("Missing test layout: \(identifier)")
            }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let actual = PasteKeyCodeResolver.resolve(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
            precondition(actual == expected, "\(identifier): expected \(expected), got \(actual)")
            print("PASS \(identifier) Cmd+V=\(actual)")
        }
        precondition(PasteKeyCodeResolver.resolve(layoutData: nil, keyboardType: 0) == 9)
        precondition(PasteKeyCodeResolver.resolve(layoutData: Data(), keyboardType: 0) == 9)
        print("PASS unavailable layout fallback")
    }
}
