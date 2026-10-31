import AppKit
import QuartzCore
import SwiftUI

/// The bounded preview and its position in the recognizer's complete transcript.
/// Keeping that position lets the renderer retain a wrapped line as the preview limit advances.
struct OverlayCaptionText: Equatable {
    let text: String
    let sourceOffset: Int

    static let empty = Self(text: "", sourceOffset: 0)

    static func tail(_ text: String, limit: Int, sourceOffset: Int = 0) -> Self {
        guard limit > 0, !text.isEmpty else { return .empty }
        let start = text.index(text.endIndex, offsetBy: -limit, limitedBy: text.startIndex) ?? text.startIndex
        let suffix = String(text[start...])
        return Self(text: suffix, sourceOffset: sourceOffset + text.utf16.count - suffix.utf16.count)
    }
}

/// Paces only the preview. Keep one bounded target, not a queue of recognizer results.
struct OverlayCaptionReveal {
    static let interval: CFTimeInterval = 0.07
    static let maximumDelay: CFTimeInterval = 0.42
    private(set) var target = OverlayCaptionText.empty
    private(set) var displayed = OverlayCaptionText.empty
    private var boundaries: [Int] = []
    private var deadline: CFTimeInterval = 0

    var hasPendingWords: Bool { self.displayed != self.target }

    mutating func update(_ target: OverlayCaptionText, now: CFTimeInterval) {
        guard target != self.target else { return }
        let wasPending = self.hasPendingWords
        let visibleEnd = self.displayed.sourceOffset + self.displayed.text.utf16.count
        let wasEmpty = self.displayed.text.isEmpty
        self.target = target
        var boundaries: [Int] = []
        target.text.enumerateSubstrings(in: target.text.startIndex..<target.text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            let start = range.lowerBound.utf16Offset(in: target.text)
            if start > 0 { boundaries.append(start) }
        }
        if !target.text.isEmpty { boundaries.append(target.text.utf16.count) }
        self.boundaries = boundaries
        // Revisions replace already visible words without replaying the whole caption.
        // Round forward to a word boundary so a correction never leaves half a word.
        let retained = wasEmpty ? 0 : max(0, visibleEnd - target.sourceOffset)
        let end = retained == 0 ? 0 : self.boundaries.first(where: { $0 >= retained }) ?? target.text.utf16.count
        self.show(through: end)
        if !wasPending { self.deadline = now + Self.maximumDelay }
    }

    mutating func advance(now: CFTimeInterval) {
        let remaining = self.boundaries.filter { $0 > self.displayed.text.utf16.count }
        guard !remaining.isEmpty else { return }
        let steps = max(1, Int(ceil((self.deadline - now) / Self.interval)))
        let count = max(1, Int(ceil(Double(remaining.count) / Double(steps))))
        self.show(through: remaining[min(count, remaining.count) - 1])
    }

    mutating func finish() { self.displayed = self.target }

    private mutating func show(through end: Int) {
        guard let range = Range(NSRange(location: 0, length: end), in: self.target.text) else { return }
        self.displayed = OverlayCaptionText(text: String(self.target.text[range]), sourceOffset: self.target.sourceOffset)
    }
}

struct OverlayCaptionBuffer {
    private(set) var text = ""
    private(set) var sourceOffset = 0
    private(set) var preview = OverlayCaptionText.empty

    /// Retain enough recent context to fill the viewport, never an entire recording.
    /// Returns false for a reset, replacement, or a gap in the incoming transcript.
    mutating func update(_ preview: OverlayCaptionText, context: OverlayCaptionText? = nil) -> Bool {
        let previousText = self.text
        let relativeOffset = preview.sourceOffset - self.sourceOffset
        let prefixRange = NSRange(location: 0, length: max(0, relativeOffset))
        // A hidden view may receive many updates before its next layout pass.
        let prefix = relativeOffset >= 0 && relativeOffset <= 4096 ? Range(prefixRange, in: previousText) : nil
        let overlap = prefix.map { String(previousText[$0.upperBound...]) } ?? ""
        let commonPrefix = zip(overlap, preview.text).prefix { $0 == $1 }.count
        var continuous = !overlap.isEmpty && commonPrefix >= min(12, overlap.count)

        if !preview.text.isEmpty, let context,
           context.sourceOffset <= preview.sourceOffset,
           context.sourceOffset + context.text.utf16.count == preview.sourceOffset + preview.text.utf16.count,
           context.text.hasSuffix(preview.text)
        {
            // Context also corrects retained visible lines before an unchanged short tail.
            // Prefer its current words over the prefix saved from the previous update.
            let retainedStart = self.sourceOffset - context.sourceOffset
            let retainedRange = NSRange(location: max(0, retainedStart), length: max(0, context.text.utf16.count - retainedStart))
            if continuous, retainedStart < 0,
               let prefix = Range(NSRange(location: 0, length: -retainedStart), in: previousText)
            {
                // A caller may supply only the short preview. Keep visible text
                // preceding its context, and replace everything it does cover.
                self.text = String(previousText[prefix]) + context.text
            } else if retainedStart >= 0, !previousText.isEmpty,
                      let range = Range(retainedRange, in: context.text),
                      continuous || context.text[range].hasPrefix(previousText.prefix(12))
            {
                self.text = String(context.text[range])
                continuous = true
            } else {
                self.text = context.text
                self.sourceOffset = context.sourceOffset
                continuous = false
            }
        } else if continuous, let prefix {
            self.text = String(previousText[prefix]) + preview.text
        } else {
            self.text = preview.text
            self.sourceOffset = preview.sourceOffset
        }
        self.preview = preview
        return continuous
    }

    mutating func removeHiddenPrefix(utf16Count: Int) {
        guard utf16Count > 0,
              utf16Count <= self.preview.sourceOffset - self.sourceOffset,
              let range = Range(NSRange(location: 0, length: utf16Count), in: self.text)
        else { return }
        self.text.removeSubrange(range)
        self.sourceOffset += utf16Count
    }
}

/// TextKit supplies both line breaks and drawing, so measurement and the displayed glyphs agree.
final class OverlayCaptionLayout {
    struct Line {
        let characters: NSRange
        let rect: CGRect
    }

    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer
    private(set) var lines: [Line] = []
    let lineHeight: CGFloat
    // All production caption sizes, measured once; waveform refreshes need no text layout.
    private static let lineHeights: [CGFloat: CGFloat] = {
        let manager = NSLayoutManager()
        return Dictionary(uniqueKeysWithValues: [9.0, 10, 11, 13, 15].map { size in
            let font = NSFont.fluidSystemFont(ofSize: size, weight: .medium)
            return (size, ceil(manager.defaultLineHeight(for: font)) + 2)
        })
    }()

    init(text: String, width: CGFloat, fontSize: CGFloat, opacity: CGFloat) {
        let font = NSFont.fluidSystemFont(ofSize: fontSize, weight: .medium)
        self.lineHeight = ceil(self.manager.defaultLineHeight(for: font)) + 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = self.lineHeight
        paragraph.maximumLineHeight = self.lineHeight
        self.storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            .paragraphStyle: paragraph,
        ])
        self.container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        self.container.lineFragmentPadding = 0
        self.storage.addLayoutManager(self.manager)
        self.manager.addTextContainer(self.container)
        self.manager.ensureLayout(for: self.container)
        self.manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: self.manager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            self.lines.append(Line(characters: self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect: rect))
        }
    }

    var height: CGFloat { ceil(self.lines.last?.rect.maxY ?? self.lineHeight) }

    func viewportHeight(maxHeight: CGFloat, maxLines: Int?) -> CGFloat {
        Self.viewportHeight(lineHeight: self.lineHeight, maxHeight: maxHeight, maxLines: maxLines)
    }

    static func viewportHeight(fontSize: CGFloat, maxHeight: CGFloat, maxLines: Int? = nil) -> CGFloat {
        let lineHeight = Self.lineHeights[fontSize] ?? ceil(NSLayoutManager().defaultLineHeight(
            for: NSFont.fluidSystemFont(ofSize: fontSize, weight: .medium)
        )) + 2
        return Self.viewportHeight(lineHeight: lineHeight, maxHeight: maxHeight, maxLines: maxLines)
    }

    private static func viewportHeight(lineHeight: CGFloat, maxHeight: CGFloat, maxLines: Int?) -> CGFloat {
        let capacity = max(1, Int((maxHeight / lineHeight).rounded(.down)))
        return min(maxHeight, CGFloat(min(capacity, maxLines ?? capacity)) * lineHeight)
    }
}

/// Shared by the top notch, expanded command recording, and every bottom preview size.
struct OverlayCaptionView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let caption: OverlayCaptionText
    var context: OverlayCaptionText?
    let fontSize: CGFloat
    let maxHeight: CGFloat
    var opacity: CGFloat = 0.96
    var maxLines: Int?
    var isActive = true

    func makeNSView(context: Context) -> OverlayCaptionNSView {
        OverlayCaptionNSView()
    }

    func updateNSView(_ nsView: OverlayCaptionNSView, context: Context) {
        nsView.update(caption: self.caption, context: self.context, fontSize: self.fontSize, opacity: self.opacity, reduceMotion: self.reduceMotion, isActive: self.isActive)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OverlayCaptionNSView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // Reserve complete line slots from the first word. Text updates must not resize
        // the window or move the controls underneath the preview.
        return CGSize(width: width, height: nsView.fittingHeight(width: width, maxHeight: self.maxHeight, maxLines: self.maxLines))
    }

    static func dismantleNSView(_ nsView: OverlayCaptionNSView, coordinator: ()) {
        nsView.stopScrolling()
    }
}

final class OverlayCaptionNSView: NSView {
    private let drawingLayer = OverlayCaptionDrawingLayer()
    private let revealLayer = OverlayCaptionDrawingLayer()
    private var buffer = OverlayCaptionBuffer()
    private var reveal = OverlayCaptionReveal()
    private var revealFromOffset: Int?
    private var fontSize: CGFloat = 13
    private var opacity: CGFloat = 0.96
    private var reduceMotion = false
    private var cachedLayout: OverlayCaptionLayout?
    private var cachedWidth: CGFloat = 0
    private var renderedWidth: CGFloat = 0
    private var renderedHeight: CGFloat = 0
    private var targetY: CGFloat = 0
    private var contentOriginY: CGFloat = 0
    private var canAnimate = false
    private var hasRendered = false
    private var pendingUpdate = true
    private struct Update: Equatable {
        let caption: OverlayCaptionText
        let context: OverlayCaptionText?
    }

    private var latestUpdate: Update?
    private var scheduledUpdate: DispatchWorkItem?
    static let scrollDuration: CFTimeInterval = 0.18
    static let revealDuration: CFTimeInterval = 0.125
    private static let scrollAnimationKey = "captionScroll"

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        self.drawingLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        self.revealLayer.actions = self.drawingLayer.actions
        self.layer?.addSublayer(self.drawingLayer)
        self.layer?.addSublayer(self.revealLayer)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel("Live transcription")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil { self.stopScrolling() }
        self.updateBackingScale()
    }

    override func viewDidHide() {
        super.viewDidHide()
        self.stopScrolling()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.updateBackingScale()
    }

    private func updateBackingScale() {
        self.drawingLayer.contentsScale = self.window?.backingScaleFactor ?? 1
        self.revealLayer.contentsScale = self.drawingLayer.contentsScale
        self.drawingLayer.setNeedsDisplay()
        self.revealLayer.setNeedsDisplay()
    }

    // The caption must never take clicks or focus away from overlay controls or the target app.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(caption: OverlayCaptionText, context: OverlayCaptionText? = nil, fontSize: CGFloat, opacity: CGFloat, reduceMotion: Bool, isActive: Bool = true) {
        guard isActive, !self.isHiddenOrHasHiddenAncestor else {
            if self.latestUpdate != nil { self.stopScrolling() }
            return
        }
        let update = Update(caption: caption, context: context)
        let styleChanged = self.fontSize != fontSize || self.opacity != opacity
        let motionChanged = self.reduceMotion != reduceMotion
        guard update != self.latestUpdate || styleChanged || motionChanged else { return }
        self.latestUpdate = update
        self.fontSize = fontSize
        self.opacity = opacity
        self.reduceMotion = reduceMotion

        let source: OverlayCaptionText
        if !caption.text.isEmpty, let context, context.sourceOffset <= caption.sourceOffset,
           context.sourceOffset + context.text.utf16.count == caption.sourceOffset + caption.text.utf16.count,
           context.text.hasSuffix(caption.text)
        { source = context } else { source = caption }
        self.reveal.update(source, now: CACurrentMediaTime())
        if caption.text.isEmpty || reduceMotion {
            self.cancelPendingCaption()
            self.reveal.finish()
        } else if self.scheduledUpdate == nil {
            self.reveal.advance(now: CACurrentMediaTime())
        }
        self.presentRevealedCaption(resetLayout: styleChanged, resetMotion: motionChanged)
        self.scheduleNextWord()
    }

    /// Also used by layout tests to inspect the final, fully revealed snapshot.
    func flushPendingCaption() {
        self.cancelPendingCaption()
        self.reveal.finish()
        self.presentRevealedCaption()
    }

    private func scheduleNextWord() {
        guard self.reveal.hasPendingWords, self.scheduledUpdate == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledUpdate = nil
            self.reveal.advance(now: CACurrentMediaTime())
            self.presentRevealedCaption()
            self.scheduleNextWord()
        }
        self.scheduledUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayCaptionReveal.interval, execute: work)
    }

    private func cancelPendingCaption() {
        self.scheduledUpdate?.cancel()
        self.scheduledUpdate = nil
    }

    private func presentRevealedCaption(resetLayout: Bool = false, resetMotion: Bool = false) {
        guard let latestUpdate else { return }
        let context = self.reveal.displayed
        let caption = OverlayCaptionText.tail(context.text, limit: latestUpdate.caption.text.count, sourceOffset: context.sourceOffset)
        let previousBuffer = self.buffer
        let previousEnd = previousBuffer.sourceOffset + previousBuffer.text.utf16.count
        let continuous = self.buffer.update(caption, context: context)
        if caption != previousBuffer.preview || self.buffer.text != previousBuffer.text || self.buffer.sourceOffset != previousBuffer.sourceOffset {
            if !continuous { self.contentOriginY = 0 }
            self.canAnimate = (self.pendingUpdate ? self.canAnimate : true) && continuous
            self.revealFromOffset = self.reduceMotion ? nil : continuous ? previousEnd : self.buffer.sourceOffset
            if caption != previousBuffer.preview { self.setAccessibilityValue(caption.text) }
        } else if !resetLayout, !resetMotion {
            return
        }
        if resetLayout { self.contentOriginY = 0 }
        if resetLayout || resetMotion { self.canAnimate = false }
        self.cachedLayout = nil
        self.pendingUpdate = true
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    func fittingHeight(width: CGFloat, maxHeight: CGFloat, maxLines: Int?) -> CGFloat {
        self.textLayout(width: width).viewportHeight(maxHeight: maxHeight, maxLines: maxLines)
    }

    private func textLayout(width: CGFloat) -> OverlayCaptionLayout {
        if let cachedLayout, self.cachedWidth == width { return cachedLayout }
        let layout = OverlayCaptionLayout(text: self.buffer.text, width: width, fontSize: self.fontSize, opacity: self.opacity)
        self.cachedWidth = width
        self.cachedLayout = layout
        return layout
    }

    override func layout() {
        super.layout()
        guard self.bounds.width > 0, self.bounds.height > 0, let layer else { return }
        let resized = self.renderedWidth != self.bounds.width || self.renderedHeight != self.bounds.height
        guard self.pendingUpdate || resized else { return }
        if self.renderedWidth != self.bounds.width { self.contentOriginY = 0 }

        var layout = self.textLayout(width: self.bounds.width)
        let currentY = layer.presentation()?.sublayerTransform.m42 ?? self.targetY
        let visibleOffset = self.buffer.preview.sourceOffset - self.buffer.sourceOffset
        let currentTop = max(0, -currentY - self.contentOriginY)
        let nextTop = max(0, layout.height - self.bounds.height)
        let retainFromY = min(currentTop, nextTop) - layout.lineHeight
        // The character limit must never erase a line the user is still reading. Keep
        // the full viewport plus an entering line, and discard only complete hidden lines.
        if let first = layout.lines.first(where: {
            $0.characters.upperBound > visibleOffset || $0.rect.maxY > retainFromY
        }), first.characters.location > 0 {
            self.contentOriginY += first.rect.minY
            self.buffer.removeHiddenPrefix(utf16Count: first.characters.location)
            self.cachedLayout = nil
            layout = self.textLayout(width: self.bounds.width)
        }

        let nextY = self.buffer.preview.text.isEmpty ? 0 : -max(0, self.contentOriginY + layout.height - self.bounds.height)
        let shouldAnimate = self.hasRendered && self.canAnimate && !resized && !self.reduceMotion && !self.buffer.preview.text.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.drawingLayer.captionLayout = layout
        let textLength = self.buffer.text.utf16.count
        let revealStart = self.revealFromOffset.map { max(0, min(textLength, $0 - self.buffer.sourceOffset)) } ?? textLength
        let fadeWords = self.pendingUpdate && !self.reduceMotion && (!resized || !self.hasRendered) && revealStart < textLength
        self.drawingLayer.visibleRange = NSRange(location: 0, length: fadeWords ? revealStart : textLength)
        // Keep absolute line positions when freeing old text. Rebasing the scroll
        // transform here would restart its easing on each trim and make it crawl.
        self.drawingLayer.frame = CGRect(x: 0, y: self.contentOriginY, width: self.bounds.width, height: layout.height)
        self.drawingLayer.setNeedsDisplay()
        self.revealLayer.removeAnimation(forKey: "captionReveal")
        self.revealLayer.captionLayout = layout
        self.revealLayer.visibleRange = NSRange(location: revealStart, length: fadeWords ? textLength - revealStart : 0)
        if fadeWords {
            let glyphs = layout.manager.glyphRange(forCharacterRange: self.revealLayer.visibleRange, actualCharacterRange: nil)
            let rect = layout.manager.boundingRect(forGlyphRange: glyphs, in: layout.container).insetBy(dx: -1, dy: -1).integral
            self.revealLayer.drawingOrigin = CGPoint(x: -rect.minX, y: -rect.minY)
            self.revealLayer.frame = rect.offsetBy(dx: 0, dy: self.contentOriginY)
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = Self.revealDuration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            self.revealLayer.add(animation, forKey: "captionReveal")
        }
        self.revealLayer.setNeedsDisplay()
        layer.sublayerTransform = CATransform3DMakeTranslation(0, nextY, 0)
        // New words on the same line must not restart an in-flight scroll.
        if !shouldAnimate || abs(nextY - self.targetY) > 0.5 {
            layer.removeAnimation(forKey: Self.scrollAnimationKey)
            if shouldAnimate, abs(nextY - currentY) > 0.5 {
                let animation = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
                animation.fromValue = currentY
                animation.toValue = nextY
                animation.duration = Self.scrollDuration
                animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                layer.add(animation, forKey: Self.scrollAnimationKey)
            }
        }
        CATransaction.commit()
        self.targetY = nextY
        self.renderedWidth = self.bounds.width
        self.renderedHeight = self.bounds.height
        self.hasRendered = true
        self.pendingUpdate = false
        self.canAnimate = true
    }

    func stopScrolling() {
        self.cancelPendingCaption()
        self.latestUpdate = nil
        self.reveal = OverlayCaptionReveal()
        self.canAnimate = false
        self.revealFromOffset = nil
        self.layer?.removeAnimation(forKey: Self.scrollAnimationKey)
        self.revealLayer.removeAllAnimations()
    }
}

/// An owned layer renders the complete bounded text, including lines outside the viewport.
/// An NSView subview would cull that offscreen drawing before the compositor scrolls it in.
private final class OverlayCaptionDrawingLayer: CALayer {
    var captionLayout: OverlayCaptionLayout?
    var visibleRange = NSRange(location: 0, length: 0)
    var drawingOrigin = CGPoint.zero

    override func draw(in context: CGContext) {
        guard let captionLayout, self.visibleRange.length > 0 else { return }
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let glyphs = captionLayout.manager.glyphRange(forCharacterRange: self.visibleRange, actualCharacterRange: nil)
        captionLayout.manager.drawGlyphs(forGlyphRange: glyphs, at: self.drawingOrigin)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}
