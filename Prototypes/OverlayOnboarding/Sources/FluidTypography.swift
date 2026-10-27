import AppKit
import SwiftUI

/// Edit these four choices to experiment across the app, then rebuild.
/// `.system` keeps Apple's native font. `.named("AvenirNext-Regular")` uses an installed
/// PostScript font name. `.newYork` uses Apple’s native serif at every size and weight.
/// Invalid names fall back to the original system design.
enum FluidTypography {
    enum Family {
        case system
        case newYork
        case named(String)
    }

    static let standard: Family = .system
    static let serif: Family = .system
    static let rounded: Family = .system
    static let monospace: Family = .system

    // Resolve each choice once, rather than looking up installed fonts during rendering.
    private static let standardName = resolvedName(for: standard)
    private static let serifName = resolvedName(for: serif)
    private static let roundedName = resolvedName(for: rounded)
    private static let monospaceName = resolvedName(for: monospace)

    static func resolvedName(for family: Family) -> String? {
        guard case let .named(name) = family, NSFont(name: name, size: 12) != nil else { return nil }
        return name
    }

    static func name(for design: Font.Design) -> String? {
        switch design {
        case .serif: self.serifName
        case .rounded: self.roundedName
        case .monospaced: self.monospaceName
        default: self.standardName
        }
    }

    static var overridesStandard: Bool {
        if case .system = self.standard { return false }
        return true
    }

    static func systemDesign(for design: Font.Design) -> Font.Design {
        let family: Family = switch design {
        case .serif: self.serif
        case .rounded: self.rounded
        case .monospaced: self.monospace
        default: self.standard
        }
        if case .newYork = family { return .serif }
        return design
    }

    static func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
        case .title: NSFont.preferredFont(forTextStyle: .title1).pointSize
        case .title2: NSFont.preferredFont(forTextStyle: .title2).pointSize
        case .title3: NSFont.preferredFont(forTextStyle: .title3).pointSize
        case .headline: NSFont.preferredFont(forTextStyle: .headline).pointSize
        case .subheadline: NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        case .callout: NSFont.preferredFont(forTextStyle: .callout).pointSize
        case .footnote: NSFont.preferredFont(forTextStyle: .footnote).pointSize
        case .caption: NSFont.preferredFont(forTextStyle: .caption1).pointSize
        case .caption2: NSFont.preferredFont(forTextStyle: .caption2).pointSize
        default: NSFont.preferredFont(forTextStyle: .body).pointSize
        }
    }
}

extension Font {
    /// Family indirection only: default size, weight, and design remain native.
    static func fluidSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard let name = FluidTypography.name(for: design) else {
            return .system(size: size, weight: weight, design: FluidTypography.systemDesign(for: design))
        }
        return .custom(name, fixedSize: size).weight(weight)
    }

    static func fluidSystem(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
        guard let name = FluidTypography.name(for: design) else {
            return .system(style, design: FluidTypography.systemDesign(for: design))
        }
        let font = Font.custom(name, size: FluidTypography.pointSize(for: style), relativeTo: style)
        return style == .headline ? font.weight(.semibold) : font
    }
}

extension NSFont {
    static func fluidSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        self.fluidFont(ofSize: size, weight: weight, design: .default)
    }

    static func fluidMonospacedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        self.fluidFont(ofSize: size, weight: weight, design: .monospaced)
    }

    private static func fluidFont(ofSize size: CGFloat, weight: NSFont.Weight, design: Font.Design) -> NSFont {
        if let name = FluidTypography.name(for: design), let font = NSFont(name: name, size: size) {
            let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
            return NSFont(descriptor: descriptor, size: size) ?? font
        }
        if FluidTypography.systemDesign(for: design) == .serif,
           let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size)
        {
            return font
        }
        return design == .monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }
}
