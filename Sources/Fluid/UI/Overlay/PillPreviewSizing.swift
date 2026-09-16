//
//  PillPreviewSizing.swift
//  Fluid
//
//  Pure width math for the live preview that grows the pill while dictating.
//

import Foundation

/// Estimates how wide the compact pill must become to show a live preview.
///
/// The pill has to grow smoothly rather than jump, and it must stay small, so the
/// width is derived from the text with a pure function instead of a layout
/// measurement pass. That keeps the value testable and avoids a feedback loop
/// between SwiftUI layout and the window resize path.
enum PillPreviewSizing {
    /// Hard cap so the preview never turns the pill into a text box.
    static let maxWidth: CGFloat = 150
    /// Below this the preview is not worth the extra width.
    static let minUsefulWidth: CGFloat = 34
    /// Horizontal breathing room added around the text.
    static let horizontalPadding: CGFloat = 14

    /// Estimated width of a single character for the system font size in use.
    static func characterWidth(forFontSize fontSize: CGFloat) -> CGFloat {
        max(fontSize * 0.54, 1)
    }

    /// Width to reserve for the preview, or 0 when it should stay hidden.
    static func width(for text: String, fontSize: CGFloat, characterLimit: Int) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, characterLimit > 0 else { return 0 }

        let visibleCount = min(trimmed.count, characterLimit)
        let estimated = CGFloat(visibleCount) * self.characterWidth(forFontSize: fontSize) + self.horizontalPadding
        guard estimated >= self.minUsefulWidth else { return 0 }
        return min(estimated, self.maxWidth)
    }
}
