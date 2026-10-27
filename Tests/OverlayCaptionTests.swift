import AppKit
import QuartzCore
import SwiftUI

@main
struct OverlayCaptionTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        self.testBoundedUnicodePreview()
        self.testStableWrapping()
        self.testCorrectionsAndReset()
        self.testHiddenBufferIsBounded()
        self.testRecoveryAfterRevisionsAndLargeChunks()
        self.testRetainedContextCorrectionWithUnchangedPreview()
        self.testWordRevealDeadlinesAndUnicode()
        try await self.testDisplayBufferDeadlinesAndCancellation()
        try await self.testStoppedCaptionCannotRestartFromLayoutOrDetachment()
        try await self.testReopenedCaptionStartsAnewWithoutAnIntermediateEmptyUpdate()
        self.testScrollingAndReducedMotion()
        self.testPreviewLimitKeepsAFullViewport()
        self.testTrimmingDoesNotRestartTheSameLineScroll()
        try self.testSizingAndRendering()
        print("PASS: paced word reveal, deadlines, revisions, Unicode, cancellation, fixed viewport, bounded context, wrapping, scrolling and Reduce Motion")
    }

    static func testBoundedUnicodePreview() {
        let source = String(repeating: "字幕 👩🏽‍💻 cafe\u{301} ", count: 100)
        let preview = OverlayCaptionText.tail(source, limit: 50)
        precondition(preview.text.count == 50)
        precondition(preview.sourceOffset + preview.text.utf16.count == source.utf16.count)
        let stored = OverlayCaptionText.tail(source, limit: 800)
        precondition(OverlayCaptionText.tail(stored.text, limit: 50, sourceOffset: stored.sourceOffset) == preview)
        precondition(OverlayCaptionText.tail(source, limit: 0) == .empty)
    }

    static func testStableWrapping() {
        var buffer = OverlayCaptionBuffer()
        var text = ""
        let words = "These captions keep their wrapped lines still while more words arrive at the end of the sentence. "
        for character in String(repeating: words, count: 8) {
            text.append(character)
            _ = buffer.update(.tail(text, limit: 100))
            let layout = OverlayCaptionLayout(text: buffer.text, width: 180, fontSize: 13, opacity: 1)
            let full = OverlayCaptionLayout(text: text, width: 180, fontSize: 13, opacity: 1)
            let actual = layout.lines.map { $0.characters.location + buffer.sourceOffset }
            let expected = full.lines.map(\.characters.location).filter { $0 >= buffer.sourceOffset }
            precondition(actual == expected, "Trimming the character limit changed the wrapped line starts")
            let visibleOffset = buffer.preview.sourceOffset - buffer.sourceOffset
            if let line = layout.lines.first(where: { $0.characters.upperBound > visibleOffset }) {
                buffer.removeHiddenPrefix(utf16Count: line.characters.location)
            }
            precondition(buffer.text.count <= 150)
        }
    }

    static func testCorrectionsAndReset() {
        var buffer = OverlayCaptionBuffer()
        _ = buffer.update(.tail("Keep the beginning and correct the last world", limit: 100))
        precondition(buffer.update(.tail("Keep the beginning and correct the last word", limit: 100)))
        precondition(buffer.text.hasSuffix("last word"))
        precondition(!buffer.update(.tail("A completely different result", limit: 100)))
        precondition(buffer.text == "A completely different result")
        precondition(!buffer.update(.empty))
        precondition(buffer.text.isEmpty && buffer.sourceOffset == 0)
        _ = buffer.update(.tail("New recording", limit: 100))
        precondition(buffer.text == "New recording")
    }

    static func testHiddenBufferIsBounded() {
        var buffer = OverlayCaptionBuffer()
        for count in stride(from: 100, through: 20_000, by: 20) {
            _ = buffer.update(.tail(String(repeating: "a", count: count), limit: 100))
            precondition(buffer.text.utf16.count <= 4196)
        }
    }

    static func testRecoveryAfterRevisionsAndLargeChunks() {
        var buffer = OverlayCaptionBuffer()
        let first = "The first complete sentence stays in place. We can still correct the latest word."
        let next = first + " A large result arrives all at once and contains more than fifty new characters."
        _ = buffer.update(.tail(first, limit: 50), context: .tail(first, limit: 800))
        precondition(buffer.update(.tail(next, limit: 50), context: .tail(next, limit: 800)))
        precondition(buffer.text == next, "A large chunk must keep earlier visible lines")
        let revision = next.replacingOccurrences(of: "result arrives", with: "revision arrived")
        precondition(buffer.update(.tail(revision, limit: 50), context: .tail(revision, limit: 800)))
        precondition(buffer.text == revision, "Revisions need the source context, not a freshly wrapped short tail")
        precondition(OverlayCaptionLayout(text: buffer.text, width: 304, fontSize: 13, opacity: 1).lines.count >= 3)
        let unrelated = String(repeating: "An entirely different revised sentence with enough context to fill the preview. ", count: 20)
        precondition(!buffer.update(.tail(unrelated, limit: 50), context: .tail(unrelated, limit: 800)))
        precondition(buffer.text.count <= 800)
        _ = buffer.update(.empty, context: .empty)
        precondition(buffer.text.isEmpty && buffer.sourceOffset == 0)
    }

    static func testRetainedContextCorrectionWithUnchangedPreview() {
        var buffer = OverlayCaptionBuffer()
        let hidden = String(repeating: "Earlier hidden context. ", count: 40)
        let visible = "The old word sits on line one.\nThe second line is unchanged.\nThe last line is unchanged."
        let original = hidden + visible
        let corrected = hidden + visible.replacingOccurrences(of: "old", with: "new")
        let preview = OverlayCaptionText.tail(original, limit: 50)
        precondition(preview == .tail(corrected, limit: 50))
        _ = buffer.update(preview, context: .tail(original, limit: 800))
        buffer.removeHiddenPrefix(utf16Count: hidden.utf16.count - buffer.sourceOffset)
        let retainedOffset = buffer.sourceOffset
        precondition(buffer.update(preview, context: .tail(corrected, limit: 800)))
        precondition(buffer.text == visible.replacingOccurrences(of: "old", with: "new"), "A correction before an unchanged preview must update retained visible lines")
        precondition(buffer.sourceOffset == retainedOffset && buffer.preview == preview)
        let hiddenCorrection = corrected.replacingOccurrences(of: "Earlier", with: "Another")
        precondition(buffer.update(preview, context: .tail(hiddenCorrection, limit: 800)))
        precondition(buffer.text == visible.replacingOccurrences(of: "old", with: "new"))
        precondition(buffer.sourceOffset == retainedOffset && buffer.preview == preview)
    }

    static func testWordRevealDeadlinesAndUnicode() {
        var reveal = OverlayCaptionReveal()
        let text = "These words arrive gradually instead of appearing together as one pasted chunk."
        reveal.update(.tail(text, limit: 800), now: 0)
        reveal.advance(now: 0)
        precondition(!reveal.displayed.text.isEmpty && reveal.displayed.text != text)
        var previous = reveal.displayed.text
        for tick in 1...6 {
            reveal.advance(now: Double(tick) * OverlayCaptionReveal.interval)
            precondition(reveal.displayed.text.hasPrefix(previous))
            previous = reveal.displayed.text
        }
        precondition(reveal.displayed.text == text && !reveal.hasPendingWords)
        for source in ["字幕会慢慢出现。接下来是更多文字。", "👩🏽‍💻 café e\u{301} مرحبا more words", String(repeating: "word ", count: 150)] {
            reveal = OverlayCaptionReveal()
            reveal.update(.tail(source, limit: 800), now: 0)
            for tick in 0...6 {
                reveal.advance(now: Double(tick) * OverlayCaptionReveal.interval)
                precondition(source.hasPrefix(reveal.displayed.text), "Never split a Unicode grapheme")
            }
            precondition(reveal.displayed.text == source)
        }
        // Replacing the target must not push an existing deadline into the future.
        reveal = OverlayCaptionReveal()
        for tick in 0...6 {
            let latest = text + String(repeating: " latest", count: tick)
            reveal.update(.tail(latest, limit: 800), now: Double(tick) * 0.06)
            reveal.advance(now: Double(tick) * 0.06)
        }
        reveal.advance(now: 0.42)
        precondition(!reveal.hasPendingWords)
        reveal.update(.empty, now: 0.43)
        precondition(reveal.displayed == .empty && !reveal.hasPendingWords)
    }

    @MainActor
    static func testDisplayBufferDeadlinesAndCancellation() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        func update(_ text: String, reduceMotion: Bool = false, isActive: Bool = true) {
            view.update(caption: .tail(text, limit: 100), context: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: reduceMotion, isActive: isActive)
            view.layoutSubtreeIfNeeded()
        }
        let first = "Words should flow into the preview instead of being pasted in a whole chunk."
        update(first)
        let initial = view.accessibilityValue() as? String ?? ""
        precondition(!initial.isEmpty && first.hasPrefix(initial) && initial != first)
        try await Task.sleep(for: .milliseconds(85))
        let next = view.accessibilityValue() as? String ?? ""
        precondition(next.count > initial.count && next != first, "Words must appear in intermediate steps")
        for index in 0..<100 {
            update(first + " latest revision \(index)")
        }
        update(first + " final corrected words")
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == first + " final corrected words", "Finish the latest revision within the display deadline")
        update(first + " stale pending words must never survive a new recording")
        update("")
        update("New recording")
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == "New recording")
        update("Before teardown with many pending words that should not appear later")
        let beforeTeardown = view.accessibilityValue() as? String
        view.stopScrolling()
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == beforeTeardown)
        let hiddenText = "A retained hidden view must stop revealing words until it is presented again."
        update(hiddenText)
        let beforeHide = view.accessibilityValue() as? String
        update(hiddenText, isActive: false)
        update(hiddenText + " An update while hidden must not restart it.", isActive: false)
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == beforeHide)
        update(hiddenText)
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == hiddenText)
        update("Reduce Motion presents the complete result immediately", reduceMotion: true)
        precondition(view.accessibilityValue() as? String == "Reduce Motion presents the complete result immediately")
        precondition(view.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
    }

    @MainActor
    static func testStoppedCaptionCannotRestartFromLayoutOrDetachment() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        func update() {
            view.update(caption: .tail("Words still waiting to appear must not animate after the preview has been removed.", limit: 100), fontSize: 13, opacity: 1, reduceMotion: false)
        }
        update()
        view.stopScrolling()
        view.layoutSubtreeIfNeeded()
        precondition(view.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true, "A pending layout must not restart a stopped fade")
        update()
        window.contentView = nil
        let removedValue = view.accessibilityValue() as? String
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == removedValue, "Detached captions must cancel their pending word queue")
        precondition(view.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
    }

    @MainActor
    static func testReopenedCaptionStartsAnewWithoutAnIntermediateEmptyUpdate() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        func update(_ text: String, active: Bool = true) {
            view.update(caption: .tail(text, limit: 100), context: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: false, isActive: active)
        }
        update(String(repeating: "Older words fill this preview. ", count: 10))
        view.flushPendingCaption()
        view.stopScrolling()
        let hiddenValue = view.accessibilityValue() as? String
        update("", active: false)
        precondition(view.accessibilityValue() as? String == hiddenValue, "A hidden reset must not repaint the parked caption")
        let next = "New recording words should begin gradually instead of appearing together in one block."
        update(next)
        let initial = view.accessibilityValue() as? String ?? ""
        precondition(!initial.isEmpty && next.hasPrefix(initial) && initial != next, "A previous recording must not skip the new recording's word reveal")
        try await Task.sleep(for: .milliseconds(500))
        precondition(view.accessibilityValue() as? String == next)
        view.stopScrolling()
    }

    @MainActor
    static func testScrollingAndReducedMotion() {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 180, height: 32))
        func update(_ text: String, reduceMotion: Bool = false) {
            view.update(caption: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: reduceMotion)
            view.flushPendingCaption()
            view.layoutSubtreeIfNeeded()
        }
        update("First line\nSecond line")
        precondition(view.layer?.animationKeys()?.isEmpty != false, "First presentation must not scroll from the start")
        update("First line\nSecond line\nThird")
        let scroll = view.layer?.animation(forKey: "captionScroll") as? CABasicAnimation
        precondition(scroll != nil && scroll?.duration == OverlayCaptionNSView.scrollDuration)
        let target = view.layer?.sublayerTransform.m42
        update("First line\nSecond line\nThird word")
        precondition(view.layer?.sublayerTransform.m42 == target, "Words on the same line must not move the viewport")
        precondition(view.layer?.animation(forKey: "captionScroll") != nil)
        update("First line\nSecond line\nThird word\nFourth", reduceMotion: true)
        precondition(view.layer?.animationKeys()?.isEmpty != false)
        update("")
        precondition(view.layer?.sublayerTransform.m42 == 0)
        precondition(view.layer?.animationKeys()?.isEmpty != false, "Clearing must cancel stale scrolling")
        update("New recording")
        precondition(view.layer?.sublayerTransform.m42 == 0)
        precondition(view.hitTest(.zero) == nil)
        precondition(view.accessibilityValue() as? String == "New recording")
        update("A long caption that fills more than one line while the user keeps speaking and thinking out loud.")
        let expandedHeight = view.fittingHeight(width: 180, maxHeight: 60, maxLines: nil)
        update("A shorter correction")
        precondition(view.fittingHeight(width: 180, maxHeight: 60, maxLines: nil) == expandedHeight)
        update("")
        precondition(view.fittingHeight(width: 180, maxHeight: 60, maxLines: nil) == expandedHeight, "Clearing text must keep the reserved line slots")
    }

    @MainActor
    static func testPreviewLimitKeepsAFullViewport() {
        // A 50-character preview is shorter than three visible lines. Once the
        // window fills, its older lines must survive until they actually scroll out.
        let view = OverlayCaptionNSView()
        precondition(view.fittingHeight(width: 304, maxHeight: 54.6, maxLines: 3) == 54)
        var text = ""
        var filled = false
        var sourceHasThreeLines = false
        var previousTarget: CGFloat = 0
        let words = String(repeating: "These captions stay readable while more words arrive at the end of the sentence. ", count: 30)
        for word in words.split(separator: " ") {
            text += "\(word) "
            view.update(caption: .tail(text, limit: 50), fontSize: 13, opacity: 1, reduceMotion: true)
            view.flushPendingCaption()
            let height = view.fittingHeight(width: 304, maxHeight: 54.6, maxLines: 3)
            view.frame = CGRect(x: 0, y: 0, width: 304, height: height)
            view.layoutSubtreeIfNeeded()
            guard let layer = view.layer, let drawing = layer.sublayers?.first else {
                preconditionFailure("Caption layers must exist")
            }
            sourceHasThreeLines = sourceHasThreeLines || OverlayCaptionLayout(text: text, width: 304, fontSize: 13, opacity: 1).lines.count >= 3
            filled = filled || sourceHasThreeLines
            if filled {
                precondition(height == 54, "A full caption window must not lose a visible line")
                precondition(
                    abs(drawing.frame.maxY + layer.sublayerTransform.m42 - height) < 0.5,
                    "Trimming must not leave an empty line at the bottom"
                )
                precondition(
                    layer.sublayerTransform.m42 <= previousTarget,
                    "Appending words must not pull previous lines back down"
                )
            }
            previousTarget = layer.sublayerTransform.m42
            precondition(drawing.frame.height <= 180, "Retained context must remain bounded")
        }
        precondition(filled, "The preview limit must not prevent the window from filling")
    }

    @MainActor
    static func testTrimmingDoesNotRestartTheSameLineScroll() {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 180, height: 36))
        func update(_ text: String) {
            view.update(caption: .tail(text, limit: 50), fontSize: 13, opacity: 1, reduceMotion: false)
            view.flushPendingCaption()
            view.layoutSubtreeIfNeeded()
        }
        let prefix = "First sentence.\nSecond sentence.\nThird sentence."
        update(prefix)
        update(prefix + "\nNext")
        guard let layer = view.layer, let before = layer.animation(forKey: "captionScroll") else {
            preconditionFailure("A new line must start scrolling")
        }
        let target = layer.sublayerTransform.m42
        update(prefix + "\nNext word at a time")
        guard let after = layer.animation(forKey: "captionScroll") else {
            preconditionFailure("The original scroll must continue")
        }
        precondition(layer.sublayerTransform.m42 == target)
        precondition(before.beginTime == after.beginTime, "Trimming must not restart an unfinished scroll")
        update("")
        precondition(layer.sublayers?.first?.frame.minY == 0, "A new recording must reset the retained line origin")
    }

    @MainActor
    static func testSizingAndRendering() throws {
        for (width, fontSize, maximumHeight, maximumLines) in [(180.0, 10.0, 60.0, 5), (198.0, 11.0, 46.2, 1), (304.0, 13.0, 54.6, 3), (396.0, 15.0, 80.0, 4)] {
            let view = OverlayCaptionNSView()
            for text in ["Short caption", String(repeating: "A stable caption with readable words. ", count: 30), "字幕 مرحبا 👩🏽‍💻 café", String(repeating: "x", count: 800)] {
                view.update(caption: .tail(text, limit: 100), fontSize: fontSize, opacity: 1, reduceMotion: true)
                view.flushPendingCaption()
                let height = view.fittingHeight(width: width, maxHeight: maximumHeight, maxLines: maximumLines)
                precondition(height > 0 && height <= maximumHeight)
                view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                view.layoutSubtreeIfNeeded()
                precondition(view.frame.height == height)
                if let output = ProcessInfo.processInfo.environment["CAPTION_TEST_OUTPUT"], text.hasPrefix("A stable") {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        preconditionFailure("Caption must produce a bitmap")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        preconditionFailure("Caption must produce a PNG")
                    }
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("caption-\(Int(fontSize)).png"))
                }
            }
        }
    }
}
