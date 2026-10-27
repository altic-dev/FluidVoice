import AppKit
import SwiftUI

@main
struct FluidTypographyTests {
    static func main() {
        precondition(FluidTypography.resolvedName(for: .named("FluidVoice-Missing-Font")) == nil)
        precondition(FluidTypography.resolvedName(for: .system) == nil)
        let custom = ProcessInfo.processInfo.environment["TEST_CUSTOM_FONTS"] == "1"
        for design: Font.Design in [.default, .serif, .rounded, .monospaced] {
            if custom {
                precondition(FluidTypography.name(for: design) == "AvenirNext-Regular")
                precondition(Font.fluidSystem(size: 23, weight: .semibold, design: design) == Font.custom("AvenirNext-Regular", fixedSize: 23).weight(.semibold))
            } else {
                precondition(FluidTypography.name(for: design) == nil)
                precondition(Font.fluidSystem(size: 23, weight: .semibold, design: design) == Font.system(
                    size: 23,
                    weight: .semibold,
                    design: FluidTypography.systemDesign(for: design)
                ))
                precondition(Font.fluidSystem(.caption, design: design) == Font.system(.caption, design: FluidTypography.systemDesign(for: design)))
            }
        }
        let native = NSFont.fluidSystemFont(ofSize: 18, weight: .semibold)
        let mono = NSFont.fluidMonospacedSystemFont(ofSize: 13, weight: .regular)
        precondition(native.pointSize == 18 && mono.pointSize == 13)
        if custom {
            precondition(native.familyName == "Avenir Next" && mono.familyName == "Avenir Next")
        } else {
            if FluidTypography.systemDesign(for: .default) == .serif {
                guard let descriptor = NSFont.systemFont(ofSize: 18, weight: .semibold).fontDescriptor.withDesign(.serif) else {
                    preconditionFailure("The system serif font must be available")
                }
                precondition(native == NSFont(descriptor: descriptor, size: 18))
            } else {
                precondition(native == NSFont.systemFont(ofSize: 18, weight: .semibold))
            }
            if FluidTypography.systemDesign(for: .monospaced) == .serif {
                guard let descriptor = NSFont.systemFont(ofSize: 13, weight: .regular).fontDescriptor.withDesign(.serif) else {
                    preconditionFailure("The system serif font must be available")
                }
                precondition(mono == NSFont(descriptor: descriptor, size: 13))
            } else {
                precondition(mono == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            }
        }
        print(custom ? "All four custom family routes and native editors passed" : "Configured system designs, sizes, weights, semantic styles, and missing-font fallback passed")
    }
}
