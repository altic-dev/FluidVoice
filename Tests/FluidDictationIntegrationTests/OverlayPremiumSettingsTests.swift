import CoreGraphics
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Pure-logic coverage for the premium overlay: persisted-value compatibility,
/// anchor math, glow modulation, envelope damping and preview sizing.
///
/// Everything here is side-effect free on purpose. These tests never write to
/// UserDefaults, the Keychain or the audio cache, so they are safe to run on a
/// machine that is actively using FluidVoice.
@MainActor
final class OverlayPremiumSettingsTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 950)
    /// 108 pt pill + 2 x 26 pt canvas padding, 38 pt tall.
    private let pillWindowSize = CGSize(width: 160, height: 90)
    private let canvasPadding = SettingsStore.OverlayPosition.pillCanvasPadding

    // MARK: - OverlayPosition compatibility

    func testLegacyOverlayPositionRawValuesStillDecode() {
        XCTAssertEqual(SettingsStore.OverlayPosition(rawValue: "top"), .topCenter)
        XCTAssertEqual(SettingsStore.OverlayPosition(rawValue: "bottom"), .bottomCenter)
    }

    func testPremiumAnchorRawValuesDecode() {
        XCTAssertEqual(SettingsStore.OverlayPosition(rawValue: "topLeft"), .topLeft)
        XCTAssertEqual(SettingsStore.OverlayPosition(rawValue: "topRight"), .topRight)
        XCTAssertEqual(SettingsStore.OverlayPosition(rawValue: "bottomLeft"), .bottomLeft)
        XCTAssertEqual(SettingsStore.OverlayPosition(rawValue: "bottomRight"), .bottomRight)
    }

    func testUnknownPersistedPositionDoesNotDecode() {
        XCTAssertNil(SettingsStore.OverlayPosition(rawValue: "middleLeft"))
    }

    func testLegacyTopPreferenceKeepsTheNotchPresentation() {
        let legacyTop = SettingsStore.OverlayPosition(rawValue: "top")
        XCTAssertEqual(legacyTop?.usesNotchPresentation, true)
        XCTAssertEqual(legacyTop?.usesFloatingOverlay, false)
    }

    func testEveryOtherAnchorUsesTheFloatingPill() {
        let floating: [SettingsStore.OverlayPosition] = [
            .bottomCenter, .topLeft, .topRight, .bottomLeft, .bottomRight,
        ]
        for anchor in floating {
            XCTAssertTrue(anchor.usesFloatingOverlay, "\(anchor.rawValue) should use the floating pill")
            XCTAssertFalse(anchor.usesNotchPresentation, "\(anchor.rawValue) should not use the notch")
        }
    }

    func testVerticalAndSidePredicates() {
        XCTAssertTrue(SettingsStore.OverlayPosition.bottomLeft.isBottomAnchored)
        XCTAssertTrue(SettingsStore.OverlayPosition.bottomCenter.isBottomAnchored)
        XCTAssertTrue(SettingsStore.OverlayPosition.bottomRight.isBottomAnchored)
        XCTAssertFalse(SettingsStore.OverlayPosition.topCenter.isBottomAnchored)
        XCTAssertFalse(SettingsStore.OverlayPosition.topLeft.isBottomAnchored)

        XCTAssertTrue(SettingsStore.OverlayPosition.topRight.isSideAnchored)
        XCTAssertTrue(SettingsStore.OverlayPosition.bottomLeft.isSideAnchored)
        XCTAssertFalse(SettingsStore.OverlayPosition.topCenter.isSideAnchored)
        XCTAssertFalse(SettingsStore.OverlayPosition.bottomCenter.isSideAnchored)
    }

    func testOverlayPositionSurvivesCodableRoundTrip() throws {
        for anchor in SettingsStore.OverlayPosition.allCases {
            let data = try JSONEncoder().encode(anchor)
            XCTAssertEqual(try JSONDecoder().decode(SettingsStore.OverlayPosition.self, from: data), anchor)
        }
    }

    // MARK: - Anchor geometry

    private func origin(for anchor: SettingsStore.OverlayPosition, bottomOffset: CGFloat = 50) -> CGPoint {
        anchor.windowOrigin(
            windowSize: self.pillWindowSize,
            screenFrame: self.screenFrame,
            visibleFrame: self.visibleFrame,
            bottomOffset: bottomOffset,
            canvasPadding: self.canvasPadding
        )
    }

    /// The bottom offset positions the *visible* pill, not the transparent shadow
    /// canvas around it. Anchoring the window instead made the pill float upwards
    /// as the scale grew - the diagonal glide the polish pass reported.
    func testBottomCenterPinsTheVisiblePillToTheBottomOffset() {
        let origin = self.origin(for: .bottomCenter)
        XCTAssertEqual(origin.x, self.screenFrame.midX - self.pillWindowSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y + self.canvasPadding, self.visibleFrame.minY + 50, accuracy: 0.001)
    }

    func testBottomOffsetStillMovesTheBottomCenterAnchor() {
        XCTAssertEqual(
            self.origin(for: .bottomCenter, bottomOffset: 120).y + self.canvasPadding,
            self.visibleFrame.minY + 120,
            accuracy: 0.001
        )
    }

    /// P4: the anchored edge is invariant across the whole 50 - 200 % band, for
    /// every anchor. This is the "no diagonal glide" guarantee, measured.
    func testChangingTheScaleNeverMovesTheAnchoredEdge() {
        let scales: [CGFloat] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        for anchor in SettingsStore.OverlayPosition.allCases {
            var bottomEdge: [CGFloat] = []
            var topEdge: [CGFloat] = []
            var centreX: [CGFloat] = []
            var leftEdge: [CGFloat] = []
            var rightEdge: [CGFloat] = []
            for scale in scales {
                let padding = self.canvasPadding * scale
                // The pill is 108 x 38 with 26 pt of canvas padding on all sides,
                // so a scale multiplies both the content and that padding.
                let windowSize = CGSize(
                    width: (108 + self.canvasPadding * 2) * scale,
                    height: (38 + self.canvasPadding * 2) * scale
                )
                let origin = anchor.windowOrigin(
                    windowSize: windowSize,
                    screenFrame: self.screenFrame,
                    visibleFrame: self.visibleFrame,
                    bottomOffset: 160,
                    canvasPadding: padding
                )
                bottomEdge.append(origin.y + padding)
                topEdge.append(origin.y + windowSize.height - padding)
                centreX.append(origin.x + windowSize.width / 2)
                leftEdge.append(origin.x + padding)
                rightEdge.append(origin.x + windowSize.width - padding)
            }
            let spread = { (values: [CGFloat]) in (values.max() ?? 0) - (values.min() ?? 0) }

            switch anchor {
            case .bottomCenter, .bottomLeft, .bottomRight:
                XCTAssertLessThanOrEqual(spread(bottomEdge), 0.01, "\(anchor.rawValue) bottom edge drifted")
            case .topCenter, .topLeft, .topRight:
                XCTAssertLessThanOrEqual(spread(topEdge), 0.01, "\(anchor.rawValue) top edge drifted")
            }

            switch anchor {
            case .topCenter, .bottomCenter:
                XCTAssertLessThanOrEqual(spread(centreX), 0.01, "\(anchor.rawValue) centre drifted")
            case .topLeft, .bottomLeft:
                XCTAssertLessThanOrEqual(spread(leftEdge), 0.01, "\(anchor.rawValue) left edge drifted")
            case .topRight, .bottomRight:
                XCTAssertLessThanOrEqual(spread(rightEdge), 0.01, "\(anchor.rawValue) right edge drifted")
            }
        }
    }

    func testTopAnchorsSitJustBelowTheMenuBar() {
        let anchors: [SettingsStore.OverlayPosition] = [.topCenter, .topLeft, .topRight]
        for anchor in anchors {
            let origin = self.origin(for: anchor)
            let visibleTop = origin.y + self.pillWindowSize.height - self.canvasPadding
            XCTAssertEqual(
                visibleTop,
                self.visibleFrame.maxY - SettingsStore.OverlayPosition.verticalEdgeInset,
                accuracy: 0.001,
                "\(anchor.rawValue) should clear the menu bar"
            )
        }
    }

    func testSideAnchorsRespectTheHorizontalEdgeInset() {
        let left = self.origin(for: .topLeft)
        XCTAssertEqual(
            left.x + self.canvasPadding,
            self.visibleFrame.minX + SettingsStore.OverlayPosition.horizontalEdgeInset,
            accuracy: 0.001
        )
        let leftBottom = self.origin(for: .bottomLeft)
        XCTAssertEqual(leftBottom.x, left.x, accuracy: 0.001)

        let right = self.origin(for: .topRight)
        XCTAssertEqual(
            right.x + self.pillWindowSize.width - self.canvasPadding,
            self.visibleFrame.maxX - SettingsStore.OverlayPosition.horizontalEdgeInset,
            accuracy: 0.001
        )
        let rightBottom = self.origin(for: .bottomRight)
        XCTAssertEqual(rightBottom.x, right.x, accuracy: 0.001)
    }

    func testVisiblePillNeverLeavesTheVisibleFrame() {
        for anchor in SettingsStore.OverlayPosition.allCases {
            let origin = self.origin(for: anchor)
            let visibleMinX = origin.x + self.canvasPadding
            let visibleMaxX = origin.x + self.pillWindowSize.width - self.canvasPadding
            let visibleMinY = origin.y + self.canvasPadding
            let visibleMaxY = origin.y + self.pillWindowSize.height - self.canvasPadding

            XCTAssertGreaterThanOrEqual(visibleMinX, self.visibleFrame.minX - 0.001, anchor.rawValue)
            XCTAssertLessThanOrEqual(visibleMaxX, self.visibleFrame.maxX + 0.001, anchor.rawValue)
            XCTAssertGreaterThanOrEqual(visibleMinY, self.visibleFrame.minY - 0.001, anchor.rawValue)
            XCTAssertLessThanOrEqual(visibleMaxY, self.visibleFrame.maxY + 0.001, anchor.rawValue)
        }
    }

    func testOffsetsAreClampedIntoTheVisibleFrame() {
        let huge = self.origin(for: .bottomCenter, bottomOffset: 100_000)
        XCTAssertLessThanOrEqual(
            huge.y + self.pillWindowSize.height,
            self.visibleFrame.maxY + 0.001
        )
    }

    // MARK: - Glow intensity

    func testAuraOpacityMatchesTheDesignTargets() {
        let normal = OverlayGlowIntensity.normal
        XCTAssertEqual(normal.auraOpacity(forLevel: 0), 0.136, accuracy: 0.005)
        XCTAssertEqual(normal.auraOpacity(forLevel: 0.5), 0.204, accuracy: 0.005)
        XCTAssertEqual(normal.auraOpacity(forLevel: 1), 0.272, accuracy: 0.005)
    }

    func testAuraOpacityIsMonotonicAndBounded() {
        for intensity in OverlayGlowIntensity.allCases {
            var previous = -1.0
            for step in 0...20 {
                let value = intensity.auraOpacity(forLevel: CGFloat(step) / 20)
                XCTAssertGreaterThanOrEqual(value, previous)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 0.42)
                previous = value
            }
            XCTAssertEqual(intensity.auraOpacity(forLevel: -5), intensity.auraOpacity(forLevel: 0))
            XCTAssertEqual(intensity.auraOpacity(forLevel: 9), intensity.auraOpacity(forLevel: 1))
        }
    }

    func testSubtleStaysCalmerThanVivid() {
        for step in 0...10 {
            let level = CGFloat(step) / 10
            XCTAssertLessThan(
                OverlayGlowIntensity.subtle.auraOpacity(forLevel: level),
                OverlayGlowIntensity.vivid.auraOpacity(forLevel: level)
            )
        }
    }

    // MARK: - Envelope follower

    func testFollowerRisesFasterThanItFalls() {
        var follower = AudioEnvelopeFollower()
        follower.update(with: 1)
        let afterAttack = follower.smoothed
        follower.update(with: 0)
        let afterRelease = follower.smoothed

        XCTAssertGreaterThan(afterAttack, 0.5)
        XCTAssertGreaterThan(afterRelease, 1 - afterAttack)
        XCTAssertLessThan(afterRelease, afterAttack)
    }

    func testDelayedSamplesAreOrderedNewestFirst() {
        var follower = AudioEnvelopeFollower()
        follower.update(with: 1)

        XCTAssertEqual(follower.delayedSample(at: 0), follower.smoothed, accuracy: 0.0001)
        XCTAssertEqual(follower.delayedSample(at: AudioEnvelopeFollower.historyLength - 1), 0, accuracy: 0.0001)
        XCTAssertEqual(follower.delayedSample(at: 999), 0, accuracy: 0.0001)
        XCTAssertEqual(follower.delayedSample(at: -1), 0, accuracy: 0.0001)
    }

    func testHistoryLengthIsStableAcrossManyUpdates() {
        var follower = AudioEnvelopeFollower()
        for step in 0..<200 {
            follower.update(with: CGFloat(step % 10) / 10)
        }
        XCTAssertEqual(follower.history.count, AudioEnvelopeFollower.historyLength)
    }

    func testResetReturnsTheFollowerToSilence() {
        var follower = AudioEnvelopeFollower()
        follower.update(with: 1)
        follower.reset()
        XCTAssertEqual(follower.smoothed, 0, accuracy: 0.0001)
        XCTAssertEqual(follower.history.max() ?? -1, 0, accuracy: 0.0001)
    }

    func testNormalizationGatesBackgroundNoiseAndClamps() {
        XCTAssertEqual(AudioEnvelopeFollower.normalized(0.2, noiseThreshold: 0.4), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioEnvelopeFollower.normalized(1, noiseThreshold: 0.4), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioEnvelopeFollower.normalized(-3, noiseThreshold: 0.4), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioEnvelopeFollower.normalized(9, noiseThreshold: 0.4), 1, accuracy: 0.0001)
        XCTAssertLessThan(
            AudioEnvelopeFollower.normalized(0.6, noiseThreshold: 0.4),
            AudioEnvelopeFollower.normalized(0.8, noiseThreshold: 0.4)
        )
    }

    // MARK: - Pill preview sizing

    func testPreviewWidthIsZeroWithoutUsableText() {
        XCTAssertEqual(PillPreviewSizing.width(for: "", fontSize: 10, characterLimit: 150), 0)
        XCTAssertEqual(PillPreviewSizing.width(for: "   \n ", fontSize: 10, characterLimit: 150), 0)
        XCTAssertEqual(PillPreviewSizing.width(for: "hello", fontSize: 10, characterLimit: 0), 0)
    }

    func testPreviewWidthIsCappedAndGrowsWithText() {
        let longText = String(repeating: "a", count: 500)
        XCTAssertEqual(
            PillPreviewSizing.width(for: longText, fontSize: 10, characterLimit: 500),
            PillPreviewSizing.maxWidth
        )

        let short = PillPreviewSizing.width(for: "bonjour", fontSize: 10, characterLimit: 150)
        let longer = PillPreviewSizing.width(for: String(repeating: "a", count: 20), fontSize: 10, characterLimit: 150)
        XCTAssertGreaterThan(longer, short)
        XCTAssertLessThanOrEqual(longer, PillPreviewSizing.maxWidth)
    }

    func testPreviewWidthHonoursTheCharacterLimit() {
        let limit = 10
        let capped = PillPreviewSizing.width(for: String(repeating: "a", count: 400), fontSize: 10, characterLimit: limit)
        let equivalent = PillPreviewSizing.width(for: String(repeating: "a", count: limit), fontSize: 10, characterLimit: 150)
        XCTAssertEqual(capped, equivalent, accuracy: 0.001)
    }

    func testVeryShortPreviewIsNotWorthTheExtraWidth() {
        XCTAssertEqual(PillPreviewSizing.width(for: "a", fontSize: 2, characterLimit: 150), 0)
    }

    // MARK: - Lifecycle

    func testLifecycleResolvesFromPublishedSignalsOnly() {
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: false,
                isReleaseTransitioning: true,
                isProcessing: true,
                hasProcessingFailure: true
            ),
            .hidden
        )
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: true,
                isReleaseTransitioning: false,
                isProcessing: false,
                hasProcessingFailure: false
            ),
            .recording
        )
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: true,
                isReleaseTransitioning: true,
                isProcessing: false,
                hasProcessingFailure: false
            ),
            .processing
        )
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: true,
                isReleaseTransitioning: false,
                isProcessing: true,
                hasProcessingFailure: false
            ),
            .processing
        )
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: true,
                isReleaseTransitioning: false,
                isProcessing: false,
                hasProcessingFailure: true
            ),
            .error
        )
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: true,
                isReleaseTransitioning: false,
                isProcessing: true,
                hasProcessingFailure: true
            ),
            .processing
        )
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: true,
                isReleaseTransitioning: false,
                isProcessing: false,
                hasProcessingFailure: false,
                isDeliveryCompleted: true
            ),
            .completed
        )
        // A parked panel never reports completion.
        XCTAssertEqual(
            OverlayLifecycleState.resolve(
                isPresented: false,
                isReleaseTransitioning: false,
                isProcessing: false,
                hasProcessingFailure: false,
                isDeliveryCompleted: true
            ),
            .hidden
        )
    }

    func testOnlyRecordingShowsTheAudioVisualizer() {
        XCTAssertTrue(OverlayLifecycleState.recording.showsVisualizer)
        XCTAssertTrue(OverlayLifecycleState.hidden.showsVisualizer)
        XCTAssertFalse(OverlayLifecycleState.processing.showsVisualizer)
        XCTAssertFalse(OverlayLifecycleState.error.showsVisualizer)
        XCTAssertFalse(OverlayLifecycleState.completed.showsVisualizer)
    }

    // MARK: - Styles and themes

    func testFallbacksAreTheDocumentedDefaults() {
        XCTAssertEqual(OverlayVisualStyle.fallback, .aurora)
        XCTAssertEqual(OverlayColorTheme.fallback, .aurora)
        XCTAssertEqual(OverlayGlowIntensity.fallback, .normal)
        XCTAssertTrue(OverlayAppearance.fallback.showsTargetAppIcon)
    }

    func testUnknownPersistedAppearanceValuesAreRejected() {
        XCTAssertNil(OverlayVisualStyle(rawValue: "hologram"))
        XCTAssertNil(OverlayColorTheme(rawValue: "neon"))
        XCTAssertNil(OverlayGlowIntensity(rawValue: "blinding"))
    }

    func testEveryStyleAndThemeIsPresentable() {
        XCTAssertEqual(
            Set(OverlayVisualStyle.allCases.map(\.rawValue)).count,
            OverlayVisualStyle.allCases.count
        )
        XCTAssertEqual(
            Set(OverlayColorTheme.allCases.map(\.rawValue)).count,
            OverlayColorTheme.allCases.count
        )
        for style in OverlayVisualStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.summary.isEmpty)
        }
        for theme in OverlayColorTheme.allCases {
            XCTAssertGreaterThanOrEqual(theme.palette.gradientColors.count, 3)
            XCTAssertGreaterThanOrEqual(theme.swatchColors.count, 3)
        }
        for intensity in OverlayGlowIntensity.allCases {
            XCTAssertFalse(intensity.displayName.isEmpty)
            XCTAssertGreaterThan(intensity.auraStrokeWidth, intensity.borderWidth)
            XCTAssertGreaterThan(intensity.visualizerGlowScale, 0)
        }
    }

    func testAppearanceEnumsSurviveCodableRoundTrip() throws {
        for style in OverlayVisualStyle.allCases {
            let data = try JSONEncoder().encode(style)
            XCTAssertEqual(try JSONDecoder().decode(OverlayVisualStyle.self, from: data), style)
        }
        for theme in OverlayColorTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            XCTAssertEqual(try JSONDecoder().decode(OverlayColorTheme.self, from: data), theme)
        }
        for intensity in OverlayGlowIntensity.allCases {
            let data = try JSONEncoder().encode(intensity)
            XCTAssertEqual(try JSONDecoder().decode(OverlayGlowIntensity.self, from: data), intensity)
        }
    }

    // MARK: - Orbit timing

    func testOrbitCompletesOneTurnPerRevolution() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(OrbitalGlow.angle(for: start), 0, accuracy: 0.001)
        XCTAssertEqual(
            OrbitalGlow.angle(for: start.addingTimeInterval(OrbitalGlow.revolutionSeconds / 4)),
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OrbitalGlow.angle(for: start.addingTimeInterval(OrbitalGlow.revolutionSeconds * 0.75)),
            270,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(
            OrbitalGlow.angle(for: start.addingTimeInterval(123_456)),
            360
        )
    }

    func testOrbitSpeedStaysInTheAmbientRange() {
        XCTAssertGreaterThanOrEqual(OrbitalGlow.revolutionSeconds, 4)
        XCTAssertLessThanOrEqual(OrbitalGlow.revolutionSeconds, 7)
    }

    // MARK: - Minimal dot geometry

    /// Regression guard: the Minimal style is a row of dots, and the Settings
    /// miniature must be drawn from this same geometry instead of its own copy
    /// of the numbers (it used to render bars, which no longer matched).
    func testMinimalStyleIsANineDotRow() {
        XCTAssertEqual(MinimalDotGeometry.dotCount, 9)
        XCTAssertEqual(MinimalDotGeometry.previewRadii.count, MinimalDotGeometry.dotCount)
    }

    func testMinimalDotRadiiStayWithinTheirBounds() {
        for (index, radius) in MinimalDotGeometry.previewRadii.enumerated() {
            XCTAssertGreaterThanOrEqual(radius, MinimalDotGeometry.minimumRadius, "dot \(index)")
            XCTAssertLessThanOrEqual(radius, MinimalDotGeometry.maximumRadius, "dot \(index)")
        }
    }

    func testMinimalDotRowIsSymmetricAndBrightestInTheMiddle() {
        let radii = MinimalDotGeometry.previewRadii
        let lastIndex = radii.count - 1
        for index in 0...(lastIndex / 2) {
            XCTAssertEqual(radii[index], radii[lastIndex - index], accuracy: 0.0001, "dot \(index)")
        }
        XCTAssertGreaterThan(radii[lastIndex / 2], radii[0])
    }

    func testMinimalTaperDampsTheEndsOfTheRow() {
        let first = MinimalDotGeometry.taper(at: 0)
        let middle = MinimalDotGeometry.taper(at: MinimalDotGeometry.dotCount / 2)
        XCTAssertLessThan(first, middle)
        XCTAssertEqual(middle, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(first, MinimalDotGeometry.minimumTaper)
    }

    func testMinimalPreviewRadiiUseTheLiveRadiusFormula() {
        for (index, energy) in MinimalDotGeometry.previewEnergies.enumerated() {
            XCTAssertEqual(
                MinimalDotGeometry.previewRadii[index],
                MinimalDotGeometry.radius(energy: energy, at: index),
                accuracy: 0.0001
            )
        }
    }

    func testMinimalRadiusFormulaIsMonotonicInEnergy() {
        for index in 0..<MinimalDotGeometry.dotCount {
            let quiet = MinimalDotGeometry.radius(energy: 0, at: index)
            let loud = MinimalDotGeometry.radius(energy: 1, at: index)
            XCTAssertEqual(quiet, MinimalDotGeometry.minimumRadius, accuracy: 0.0001)
            XCTAssertLessThan(quiet, loud)
        }
    }

    // MARK: - Overlay formats and user scale

    func testSelectableFormatsArePillSmallMediumRoundSVG() {
        XCTAssertEqual(SettingsStore.OverlaySize.selectable, [.pill, .small, .medium, .round, .svg])
        XCTAssertEqual(SettingsStore.OverlaySize.round.displayName, "Round")
        XCTAssertEqual(SettingsStore.OverlaySize.svg.displayName, "SVG")
        XCTAssertFalse(SettingsStore.OverlaySize.round.isLegacy)
        XCTAssertFalse(SettingsStore.OverlaySize.svg.isLegacy)
        // The Companion is an overlay *style*, not a format.
        XCTAssertTrue(OverlayVisualStyle.allCases.contains(.companion))
        XCTAssertEqual(OverlayVisualStyle.companion.displayName, "Companion")
    }

    /// The chromeless format reserves nothing for chrome: the canvas is the
    /// graphic, and no padding is added around the window.
    func testSVGFormatReservesNothingForChrome() {
        let layout = BottomOverlayView.LayoutConstants.get(for: .svg)
        XCTAssertEqual(layout.hPadding, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.vPadding, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.cornerRadius, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.containerWidth, layout.waveformWidth, accuracy: 0.0001)
        XCTAssertEqual(layout.overlayHeight, layout.waveformHeight, accuracy: 0.0001)
        XCTAssertFalse(layout.showsPreview)
        XCTAssertFalse(layout.showsModeLabel)
        XCTAssertFalse(layout.showsTopControls)
    }

    /// The animation must still get a real, usable canvas at every scale.
    func testSVGFormatScalesLikeEveryOtherFormat() {
        let base = BottomOverlayView.LayoutConstants.get(for: .svg)
        let scaled = base.scaled(by: 1.5)
        XCTAssertEqual(scaled.waveformWidth, base.waveformWidth * 1.5, accuracy: 0.0001)
        XCTAssertEqual(scaled.waveformHeight, base.waveformHeight * 1.5, accuracy: 0.0001)
        XCTAssertEqual(scaled.hPadding, 0, accuracy: 0.0001)
        XCTAssertEqual(scaled.cornerRadius, 0, accuracy: 0.0001)
    }

    /// The orb reuses the shared rounded-rectangle surface, so it is only truly
    /// circular if the canvas is square and the radius is half the side.
    func testRoundFormatIsASquareWithACircleRadius() {
        let layout = BottomOverlayView.LayoutConstants.get(for: .round)
        XCTAssertEqual(layout.containerWidth, layout.overlayHeight, accuracy: 0.0001)
        XCTAssertEqual(layout.containerWidth, layout.overlayWidth, accuracy: 0.0001)
        XCTAssertEqual(layout.cornerRadius, layout.containerWidth / 2, accuracy: 0.0001)
        XCTAssertEqual(layout.waveformWidth, layout.waveformHeight, accuracy: 0.0001)
    }

    /// The orb carries the visualizer only: no preview, no mode label, no controls.
    func testRoundFormatStaysMinimal() {
        let layout = BottomOverlayView.LayoutConstants.get(for: .round)
        XCTAssertFalse(layout.showsPreview)
        XCTAssertFalse(layout.showsModeLabel)
        XCTAssertFalse(layout.showsTopControls)
        XCTAssertFalse(layout.usesFixedCanvas)
        XCTAssertGreaterThan(layout.barCount, 0)
    }

    func testMinimalDotCountAdaptsToTheCanvasWidth() {
        // The pill canvas keeps the full row, the orb gets a few calm dots.
        XCTAssertEqual(MinimalDotGeometry.dotCount(forWidth: 52), 9)
        XCTAssertEqual(MinimalDotGeometry.dotCount(forWidth: 34), 6)
        // Never below the floor, never above the ceiling.
        XCTAssertEqual(MinimalDotGeometry.dotCount(forWidth: 8), MinimalDotGeometry.minimumDotCount)
        XCTAssertEqual(MinimalDotGeometry.dotCount(forWidth: 400), MinimalDotGeometry.dotCount)
        // Unknown width falls back to the full row rather than crashing.
        XCTAssertEqual(MinimalDotGeometry.dotCount(forWidth: 0), MinimalDotGeometry.dotCount)
    }

    func testMinimalGeometryForFewerDotsStaysSymmetricAndBounded() {
        for count in MinimalDotGeometry.minimumDotCount...MinimalDotGeometry.dotCount {
            let middle = count / 2
            for index in 0...middle {
                let left = MinimalDotGeometry.radius(energy: 0.8, at: index, count: count)
                let right = MinimalDotGeometry.radius(energy: 0.8, at: count - 1 - index, count: count)
                XCTAssertEqual(left, right, accuracy: 0.0001, "count \(count) index \(index)")
            }
            let centre = MinimalDotGeometry.radius(energy: 0.8, at: middle, count: count)
            XCTAssertGreaterThanOrEqual(centre, MinimalDotGeometry.radius(energy: 0.8, at: 0, count: count))
            XCTAssertLessThanOrEqual(centre, MinimalDotGeometry.maximumRadius)
            XCTAssertGreaterThanOrEqual(centre, MinimalDotGeometry.minimumRadius)
        }
    }

    /// `.large` left the picker but must keep decoding, so an install that had
    /// selected it does not silently fall back to another format.
    func testLegacyLargeFormatStillDecodesAndIsFlagged() throws {
        let legacy = try XCTUnwrap(SettingsStore.OverlaySize(rawValue: "large"))
        XCTAssertEqual(legacy, .large)
        XCTAssertTrue(legacy.isLegacy)
        XCTAssertFalse(SettingsStore.OverlaySize.selectable.contains(.large))
        for size in SettingsStore.OverlaySize.selectable {
            XCTAssertFalse(size.isLegacy, size.rawValue)
        }
    }

    func testOverlayScaleBandIsTwentyFiveToThreeHundredPercent() {
        XCTAssertEqual(SettingsStore.overlayScaleRange.lowerBound, 0.25, accuracy: 0.0001)
        XCTAssertEqual(SettingsStore.overlayScaleRange.upperBound, 3.0, accuracy: 0.0001)
        XCTAssertEqual(SettingsStore.overlayScaleDefault, 1.0, accuracy: 0.0001)
        XCTAssertTrue(SettingsStore.overlayScaleRange.contains(SettingsStore.overlayScaleDefault))
    }

    /// The scale has to move every visual dimension, otherwise a "larger" pill
    /// would just be a bigger transparent frame around the same tiny graphics.
    func testLayoutScalingMultipliesEveryVisualDimension() {
        let base = BottomOverlayView.LayoutConstants.get(for: .pill)
        let scaled = base.scaled(by: 1.25)

        XCTAssertEqual(scaled.hPadding, base.hPadding * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.vPadding, base.vPadding * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.waveformWidth, base.waveformWidth * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.waveformHeight, base.waveformHeight * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.iconSize, base.iconSize * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.transFontSize, base.transFontSize * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.cornerRadius, base.cornerRadius * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.barWidth, base.barWidth * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.barSpacing, base.barSpacing * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.minBarHeight, base.minBarHeight * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.maxBarHeight, base.maxBarHeight * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.containerWidth, base.containerWidth * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.overlayWidth, base.overlayWidth * 1.25, accuracy: 0.0001)
        XCTAssertEqual(scaled.overlayHeight, base.overlayHeight * 1.25, accuracy: 0.0001)
    }

    /// Scaling changes how large the overlay is, never what it draws.
    func testLayoutScalingLeavesCountsAndFlagsAlone() {
        let base = BottomOverlayView.LayoutConstants.get(for: .small)
        let scaled = base.scaled(by: 0.5)

        XCTAssertEqual(scaled.barCount, base.barCount)
        XCTAssertEqual(scaled.usesFixedCanvas, base.usesFixedCanvas)
        XCTAssertEqual(scaled.showsTopControls, base.showsTopControls)
        XCTAssertEqual(scaled.showsPreview, base.showsPreview)
        XCTAssertEqual(scaled.showsModeLabel, base.showsModeLabel)
    }

    func testLayoutScalingAtOneIsTheIdentity() {
        let base = BottomOverlayView.LayoutConstants.get(for: .medium)
        let scaled = base.scaled(by: 1)
        XCTAssertEqual(scaled.containerWidth, base.containerWidth, accuracy: 0.0001)
        XCTAssertEqual(scaled.overlayHeight, base.overlayHeight, accuracy: 0.0001)
        XCTAssertEqual(scaled.barCount, base.barCount)
    }

    // MARK: - Notch presentation

    /// The notch body is much tighter than the pill: the Wave row must fit or the
    /// style would clip inside the cutout.
    func testNotchWaveRowFitsInsideTheNotchCanvas() {
        XCTAssertLessThanOrEqual(
            NotchStyleVisualizer.waveRowWidth,
            NotchStyleVisualizer.canvasWidth,
            "Wave must not overflow the notch body"
        )
        XCTAssertGreaterThan(NotchStyleVisualizer.waveRowWidth, 0)
    }

    /// The rim has to stay faint enough to read as light rather than a ring.
    func testNotchHaloStaysBoundedAcrossPresetsAndLevels() {
        for glow in OverlayGlowIntensity.allCases {
            for level in [CGFloat(0), 0.5, 1, 4] {
                let opacity = NotchHaloRim.rimOpacity(glow: glow, level: level)
                XCTAssertGreaterThan(opacity, 0, "\(glow.rawValue) at \(level)")
                XCTAssertLessThanOrEqual(opacity, 0.85, "\(glow.rawValue) at \(level)")
            }
        }
    }

    func testNotchHaloFollowsTheVoiceAndThePreset() {
        XCTAssertGreaterThan(
            NotchHaloRim.rimOpacity(glow: .normal, level: 1),
            NotchHaloRim.rimOpacity(glow: .normal, level: 0)
        )
        XCTAssertGreaterThan(
            NotchHaloRim.rimOpacity(glow: .vivid, level: 0.5),
            NotchHaloRim.rimOpacity(glow: .subtle, level: 0.5)
        )
    }

    func testNotchCanvasIsTheCompactBodySize() {
        XCTAssertEqual(NotchStyleVisualizer.canvasWidth, 48, accuracy: 0.0001)
        XCTAssertEqual(NotchStyleVisualizer.canvasHeight, 18, accuracy: 0.0001)
        // A few dots still fit, so Minimal stays a row rather than a single dot.
        XCTAssertGreaterThanOrEqual(MinimalDotGeometry.dotCount(forWidth: NotchStyleVisualizer.canvasWidth), 5)
    }

    // MARK: - Advanced glow tuning

    /// `OverlayGlowTuning.strength` is process-wide, so every case restores it.
    private func withGlowStrength(_ value: Double, _ body: () -> Void) {
        let previous = OverlayGlowTuning.strength
        OverlayGlowTuning.strength = value
        body()
        OverlayGlowTuning.strength = previous
    }

    func testGlowStrengthBandIsHalfToHundredFiftyPercent() {
        XCTAssertEqual(OverlayGlowTuning.range.lowerBound, 0.5, accuracy: 0.0001)
        XCTAssertEqual(OverlayGlowTuning.range.upperBound, 1.5, accuracy: 0.0001)
        XCTAssertEqual(OverlayGlowTuning.neutral, 1.0, accuracy: 0.0001)
        XCTAssertTrue(OverlayGlowTuning.range.contains(OverlayGlowTuning.neutral))
    }

    func testAdvancedStrengthScalesTheAuraAndTheVisualizerGlow() {
        let preset = OverlayGlowIntensity.vivid
        withGlowStrength(1.0) {
            let base = preset.auraBaseOpacity
            withGlowStrength(1.5) {
                XCTAssertGreaterThan(preset.auraBaseOpacity, base)
                XCTAssertGreaterThan(preset.auraBlurRadius, 6.5)
            }
            withGlowStrength(0.5) {
                XCTAssertLessThan(preset.auraBaseOpacity, base)
            }
        }
    }

    /// A hairline that grows linearly stops reading as a hairline, so the
    /// advanced control deliberately moves it far less than the aura.
    func testAdvancedStrengthBarelyMovesTheHairline() {
        let preset = OverlayGlowIntensity.normal
        withGlowStrength(1.0) {
            let baseBorder = preset.borderWidth
            let baseAura = preset.auraStrokeWidth
            withGlowStrength(1.5) {
                let borderRatio = preset.borderWidth / baseBorder
                let auraRatio = preset.auraStrokeWidth / baseAura
                XCTAssertLessThan(borderRatio, auraRatio)
                XCTAssertLessThan(borderRatio, 1.2)
            }
        }
    }

    func testExtremeStoredStrengthIsClampedWhenRead() {
        withGlowStrength(12) {
            XCTAssertEqual(OverlayGlowTuning.clampedStrength, 1.5, accuracy: 0.0001)
            // Even at the ceiling the aura stays a gentle light.
            XCTAssertLessThanOrEqual(OverlayGlowIntensity.vivid.auraBaseOpacity, 0.30)
        }
        withGlowStrength(-3) {
            XCTAssertEqual(OverlayGlowTuning.clampedStrength, 0.5, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(OverlayGlowIntensity.subtle.borderWidth, 0.5)
        }
    }

    func testPresetOrderSurvivesTheAdvancedStrength() {
        withGlowStrength(1.4) {
            XCTAssertLessThan(OverlayGlowIntensity.subtle.visualizerGlowScale, OverlayGlowIntensity.normal.visualizerGlowScale)
            XCTAssertLessThan(OverlayGlowIntensity.normal.visualizerGlowScale, OverlayGlowIntensity.vivid.visualizerGlowScale)
        }
    }

    // MARK: - Surface and custom theme

    func testSurfaceAppearanceResolvesAgainstTheSystemAppearance() {
        XCTAssertFalse(OverlaySurfaceAppearance.dark.resolvesToLight(systemIsDark: false))
        XCTAssertFalse(OverlaySurfaceAppearance.dark.resolvesToLight(systemIsDark: true))
        XCTAssertTrue(OverlaySurfaceAppearance.light.resolvesToLight(systemIsDark: false))
        XCTAssertTrue(OverlaySurfaceAppearance.light.resolvesToLight(systemIsDark: true))
        // Automatic simply follows the system.
        XCTAssertTrue(OverlaySurfaceAppearance.automatic.resolvesToLight(systemIsDark: false))
        XCTAssertFalse(OverlaySurfaceAppearance.automatic.resolvesToLight(systemIsDark: true))
    }

    func testLightSurfaceSwapsTheForegroundInsteadOfTheLight() {
        let dark = OverlaySurfaceStyle.dark
        let light = OverlaySurfaceStyle.light
        XCTAssertFalse(dark.isLight)
        XCTAssertTrue(light.isLight)
        XCTAssertNotEqual(dark.primaryText, light.primaryText)
        XCTAssertNotEqual(dark.fill, light.fill)
        // A light surface needs stronger hairlines to stay visible.
        XCTAssertGreaterThan(light.borderScale, dark.borderScale)
    }

    func testCustomThemeDerivesAFullPaletteFromOneColor() {
        for hex in ["#2FA8F0", "#E0533D", "#37C46B"] {
            guard let palette = OverlayPalette.derive(fromHex: hex) else {
                XCTFail("derivation failed for \(hex)")
                continue
            }
            XCTAssertEqual(palette.gradientColors.count, 3)
            XCTAssertNotEqual(palette.primary, palette.accent, hex)
            XCTAssertNotEqual(palette.primary, palette.tertiary, hex)
        }
    }

    func testCustomThemeRejectsUnusableInput() {
        XCTAssertNil(OverlayPalette.derive(fromHex: "nope"))
        XCTAssertNil(OverlayPalette.derive(fromHex: "#12345"))
    }

    func testCustomThemeIsARealThemeCase() {
        XCTAssertTrue(OverlayColorTheme.allCases.contains(.custom))
        XCTAssertEqual(OverlayColorTheme.custom.rawValue, "custom")
        XCTAssertEqual(OverlayColorTheme.custom.displayName, "Custom")
    }

    /// Every modern format has to be buildable, so no size can end up without a
    /// layout while the picker still offers it.
    func testEverySelectableFormatHasAPositiveLayout() {
        for size in SettingsStore.OverlaySize.selectable {
            let layout = BottomOverlayView.LayoutConstants.get(for: size)
            XCTAssertGreaterThan(layout.overlayWidth, 0, size.rawValue)
            XCTAssertGreaterThan(layout.waveformWidth, 0, size.rawValue)
            // Chromeless formats deliberately draw no surface, so they carry no
            // corner radius; every format that draws one must round it.
            if size == .svg {
                XCTAssertEqual(layout.cornerRadius, 0, "the animation alone has no surface")
                XCTAssertEqual(layout.iconSize, 0, "the animation alone has no icon")
                XCTAssertFalse(layout.showsPreview, size.rawValue)
                XCTAssertFalse(layout.showsModeLabel, size.rawValue)
            } else {
                XCTAssertGreaterThan(layout.cornerRadius, 0, size.rawValue)
            }
            // The orb is deliberately icon-less: it carries the visualizer only.
            if size == .round {
                XCTAssertEqual(layout.iconSize, 0, "the orb has no icon")
            } else if size != .svg {
                XCTAssertGreaterThan(layout.iconSize, 0, size.rawValue)
                XCTAssertGreaterThanOrEqual(layout.iconSize, layout.cornerRadius, size.rawValue)
            }
        }
    }

    func testNotchPresentationOffersAnAmbientGlowMode() {
        XCTAssertTrue(SettingsStore.NotchPresentationMode.allCases.contains(.ambient))
        XCTAssertTrue(SettingsStore.NotchPresentationMode.ambient.displayName.contains("Ambient Glow"))
        XCTAssertTrue(SettingsStore.NotchPresentationMode.ambient.displayName.contains("Beta"))
    }

    /// Ambient Glow is the reference look: no icon, no text, a wider canvas
    /// for the premium style. It must not depend on the hardware compact areas.
    func testAmbientNotchPolicyDropsTheChromeAndEnlargesTheAnimation() {
        let policy = NotchOverlayManager.NotchPresentationPolicy.forMode(
            .ambient,
            supportsCompactPresentation: false
        )
        XCTAssertFalse(policy.showsAppIcon)
        XCTAssertFalse(policy.showsPromptSelector)
        XCTAssertFalse(policy.showsStreamingPreview)
        XCTAssertFalse(policy.showsModeLabel)
        XCTAssertFalse(policy.allowsCommandExpansion)
        XCTAssertGreaterThan(policy.visualizerWidth, NotchStyleVisualizer.canvasWidth)
        XCTAssertGreaterThanOrEqual(policy.visualizerHeight, NotchStyleVisualizer.canvasHeight)
        // The compact and standard rows keep their own geometry.
        let compact = NotchOverlayManager.NotchPresentationPolicy.forMode(
            .minimal,
            supportsCompactPresentation: true
        )
        XCTAssertTrue(compact.showsAppIcon)
        XCTAssertEqual(compact.visualizerWidth, NotchStyleVisualizer.canvasWidth, accuracy: 0.0001)
    }

    func testNotchBarCountAdaptsToTheCanvasWidth() {
        XCTAssertEqual(NotchStyleVisualizer.barCount(forWidth: NotchStyleVisualizer.canvasWidth), 10)
        XCTAssertEqual(NotchStyleVisualizer.barCount(forWidth: 104), 16)
        XCTAssertEqual(NotchStyleVisualizer.barCount(forWidth: 20), 6)
        // The ambient row still fits inside its canvas.
        let ambientBars = NotchStyleVisualizer.barCount(forWidth: 104)
        let row = CGFloat(ambientBars) * NotchStyleVisualizer.barWidth
            + CGFloat(ambientBars - 1) * NotchStyleVisualizer.barSpacing
        XCTAssertLessThanOrEqual(row, 104)
    }

    func testCompanionScaleStartsAtTheReferenceSizeAndCanGrow() {
        XCTAssertEqual(SettingsStore.companionScaleRange.lowerBound, 0.5, accuracy: 0.0001)
        XCTAssertEqual(SettingsStore.companionScaleRange.upperBound, 3.0, accuracy: 0.0001)
        XCTAssertEqual(SettingsStore.companionScaleDefault, 1.0, accuracy: 0.0001)
        XCTAssertTrue(SettingsStore.companionScaleRange.contains(SettingsStore.companionScaleDefault))
        XCTAssertGreaterThan(CompanionMetrics.baseSide, 0)
    }

    /// The Companion is a style, so its expression must come from the phases the
    /// pipeline already publishes - never from a state of its own.
    func testCompanionStyleMapsTheLifecycleToAnExpression() {
        XCTAssertEqual(OverlayVisualizerView.companionState(for: .hidden, hasTranscription: false), .idle)
        XCTAssertEqual(OverlayVisualizerView.companionState(for: .recording, hasTranscription: false), .listening)
        XCTAssertEqual(OverlayVisualizerView.companionState(for: .recording, hasTranscription: true), .typing)
        XCTAssertEqual(OverlayVisualizerView.companionState(for: .processing, hasTranscription: false), .thinking)
        XCTAssertEqual(OverlayVisualizerView.companionState(for: .completed, hasTranscription: false), .completed)
        XCTAssertEqual(OverlayVisualizerView.companionState(for: .error, hasTranscription: false), .error)
    }

    // MARK: - Aurora multilayer geometry (P1)

    /// `__/\____`, not `/`. The centreline may weave, but it must stay centred on
    /// its own axis, otherwise the whole composition reads as a tilted object.
    func testAuroraLayerCentrelinesStayOnTheirAxis() {
        let rect = CGRect(x: 0, y: 0, width: 104, height: 44)
        for spec in [AuroraLayerSpec.atmosphere, .mass, .accent] {
            for phase in [CGFloat(0), 1.3, 2.7, 4.1] {
                let geometry = AuroraLayerGeometry(
                    rect: rect,
                    spec: spec,
                    samples: [],
                    level: 0.7,
                    phase: phase
                )
                var sum: CGFloat = 0
                for step in 0..<AuroraLayerSpec.steps {
                    let axis = (geometry.upperPoint(at: step).y + geometry.lowerPoint(at: step).y) / 2
                    sum += axis
                }
                let mean = sum / CGFloat(AuroraLayerSpec.steps)
                let expected = rect.midY + rect.height * spec.verticalOffset
                XCTAssertEqual(
                    mean,
                    expected,
                    accuracy: rect.height * 0.15,
                    "layer axis drifted at phase \(phase)"
                )
            }
        }
    }

    /// Three layers, three motions. Identical outlines nudged a few points apart
    /// would be the artificial look the brief calls out.
    func testAuroraLayersDoNotMoveInLockstep() {
        XCTAssertNotEqual(AuroraLayerSpec.atmosphere.speed, AuroraLayerSpec.mass.speed)
        XCTAssertNotEqual(AuroraLayerSpec.mass.speed, AuroraLayerSpec.accent.speed)
        XCTAssertNotEqual(AuroraLayerSpec.atmosphere.weaveFrequency, AuroraLayerSpec.mass.weaveFrequency)
        XCTAssertNotEqual(AuroraLayerSpec.mass.weaveFrequency, AuroraLayerSpec.accent.weaveFrequency)
        XCTAssertNotEqual(AuroraLayerSpec.mass.verticalOffset, AuroraLayerSpec.accent.verticalOffset)
        // The accent crosses the body in the opposite direction on purpose.
        XCTAssertLessThan(AuroraLayerSpec.accent.driftDirection, 0)
        XCTAssertGreaterThan(AuroraLayerSpec.mass.driftDirection, 0)
    }

    /// The mass must keep visible energy zones; a single convex blob means the
    /// lobes have collapsed.
    func testAuroraMassKeepsVisibleLobes() {
        let rect = CGRect(x: 0, y: 0, width: 104, height: 44)
        let geometry = AuroraLayerGeometry(rect: rect, spec: .mass, samples: [], level: 1, phase: 1.1)
        var peak: CGFloat = 0
        var valley: CGFloat = .greatestFiniteMagnitude
        for step in 0..<AuroraLayerSpec.steps {
            let thickness = geometry.lowerPoint(at: step).y - geometry.upperPoint(at: step).y
            peak = max(peak, thickness)
            valley = min(valley, thickness)
        }
        XCTAssertGreaterThan(peak, valley * 1.35, "the lobes have flattened into one blob")
    }

    /// More voice must mean more mass: the visualizer has to react clearly.
    func testAuroraThicknessGrowsWithLevel() {
        let rect = CGRect(x: 0, y: 0, width: 104, height: 44)
        func peakThickness(level: CGFloat) -> CGFloat {
            let geometry = AuroraLayerGeometry(rect: rect, spec: .mass, samples: [], level: level, phase: 1.1)
            var peak: CGFloat = 0
            for step in 0..<AuroraLayerSpec.steps {
                peak = max(peak, geometry.lowerPoint(at: step).y - geometry.upperPoint(at: step).y)
            }
            return peak
        }
        let quiet = peakThickness(level: 0)
        let normal = peakThickness(level: 0.5)
        let loud = peakThickness(level: 1)
        XCTAssertGreaterThan(quiet, 0, "idle must keep a silhouette")
        XCTAssertGreaterThan(normal, quiet * 1.4)
        XCTAssertGreaterThan(loud, normal * 1.25)
    }

    // MARK: - Palette spectrum (P3)

    /// Every theme carries a distinct highlight, which is what keeps Aurora from
    /// collapsing into "Blue".
    func testEveryThemeHasADistinctHighlightHue() {
        for theme in OverlayColorTheme.allCases {
            let palette = theme.palette
            XCTAssertNotEqual(palette.highlight, palette.primary, theme.rawValue)
            XCTAssertNotEqual(palette.highlight, palette.secondary, theme.rawValue)
            XCTAssertNotEqual(palette.highlight, palette.tertiary, theme.rawValue)
            XCTAssertNotEqual(palette.highlight, palette.accent, theme.rawValue)
        }
    }

    /// The Wave row walks the whole theme spectrum and closes back on cyan.
    func testWaveSpectrumWalksTheWholeTheme() {
        let palette = OverlayColorTheme.aurora.palette
        XCTAssertEqual(palette.spectrumColors.count, 6)
        XCTAssertEqual(palette.spectrumColor(at: 0), palette.tertiary)
        XCTAssertEqual(palette.spectrumColor(at: 1), palette.tertiary)
        XCTAssertTrue(palette.spectrumColors.contains(palette.highlight))
        XCTAssertTrue(palette.spectrumColors.contains(palette.accent))
        // Positions outside the unit interval are clamped, never crash.
        XCTAssertEqual(palette.spectrumColor(at: -3), palette.tertiary)
        XCTAssertEqual(palette.spectrumColor(at: 4), palette.tertiary)
    }

    func testCustomThemeAlsoDerivesAHighlight() {
        for hex in ["#2FA8F0", "#E0533D", "#37C46B"] {
            guard let palette = OverlayPalette.derive(fromHex: hex) else {
                XCTFail("derivation failed for \(hex)")
                continue
            }
            XCTAssertNotEqual(palette.highlight, palette.primary, hex)
            XCTAssertNotEqual(palette.highlight, palette.accent, hex)
        }
    }

    // MARK: - Small format (P2)

    /// Small is the app icon plus the animation. The word "Dictate" spent exactly
    /// the width the animation should own, and the old capsule left most of itself
    /// empty around a tiny graphic.
    func testSmallFormatGivesTheAnimationMostOfTheCapsule() {
        let layout = BottomOverlayView.LayoutConstants.get(for: .small)
        let rowWidth = layout.hPadding * 2
            + layout.iconSize
            + layout.waveformWidth
            + layout.hPadding / 1.5
        XCTAssertLessThanOrEqual(rowWidth, layout.containerWidth + 0.5, "the row must fit the capsule")
        XCTAssertGreaterThan(
            layout.waveformWidth / layout.containerWidth,
            0.6,
            "the animation must own most of the capsule"
        )
        XCTAssertEqual(layout.iconSize, 16, accuracy: 0.001)
        XCTAssertGreaterThan(layout.waveformHeight, 20)
    }

    // MARK: - Preview seed

    /// The seeded follower is what lets the audio-reactive styles be inspected
    /// offscreen; it must not change the live defaults.
    func testPreviewFollowerMakesAPeakInTheMiddle() {
        let follower = AudioEnvelopeFollower.preview(level: 0.8)
        XCTAssertGreaterThan(follower.smoothed, 0.3)
        let middle = follower.delayedSample(at: AudioEnvelopeFollower.historyLength / 2)
        let edge = follower.delayedSample(at: 0)
        XCTAssertGreaterThanOrEqual(middle, edge)
        XCTAssertEqual(AudioEnvelopeFollower().smoothed, 0, accuracy: 0.0001)
    }

    // MARK: - Companion (P6 / P7)

    func testCompanionVariantRawValuesAreStable() throws {
        XCTAssertEqual(CompanionVariant(rawValue: "default"), .standard)
        XCTAssertEqual(CompanionVariant(rawValue: "gothic"), .gothic)
        XCTAssertNil(CompanionVariant(rawValue: "vampire"))
        for variant in CompanionVariant.allCases {
            let data = try JSONEncoder().encode(variant)
            XCTAssertEqual(try JSONDecoder().decode(CompanionVariant.self, from: data), variant)
        }
    }

    func testCompanionSettingsEnumsSurviveCodableRoundTrip() throws {
        for accessory in CompanionAccessory.allCases {
            XCTAssertEqual(try JSONDecoder().decode(CompanionAccessory.self, from: try JSONEncoder().encode(accessory)), accessory)
        }
        for intensity in MotionIntensity.allCases {
            XCTAssertEqual(try JSONDecoder().decode(MotionIntensity.self, from: try JSONEncoder().encode(intensity)), intensity)
        }
    }

    /// The companion expresses the session, never a new source of truth.
    func testCompanionStateResolvesFromPublishedSignalsOnly() {
        XCTAssertEqual(
            CompanionState.resolve(isPresented: false, isProcessing: false, didComplete: false, hasFailure: false, hasTranscription: false),
            .idle
        )
        XCTAssertEqual(
            CompanionState.resolve(isPresented: true, isProcessing: false, didComplete: false, hasFailure: false, hasTranscription: false),
            .listening
        )
        XCTAssertEqual(
            CompanionState.resolve(isPresented: true, isProcessing: false, didComplete: false, hasFailure: false, hasTranscription: true),
            .typing
        )
        XCTAssertEqual(
            CompanionState.resolve(isPresented: true, isProcessing: true, didComplete: false, hasFailure: false, hasTranscription: false),
            .thinking
        )
        XCTAssertEqual(
            CompanionState.resolve(isPresented: false, isProcessing: false, didComplete: true, hasFailure: false, hasTranscription: false),
            .completed
        )
        // A failure outranks everything else: it is the state the user must see.
        XCTAssertEqual(
            CompanionState.resolve(isPresented: true, isProcessing: true, didComplete: false, hasFailure: true, hasTranscription: true),
            .error
        )
    }

    /// The dark body must not be a plain circle and must not grow the single
    /// pointed lobe of a teardrop.
    func testCompanionCoreIsNeitherACircleNorATeardrop() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        let geometry = CompanionGeometry(
            rect: rect,
            phase: 1.7,
            level: 0.6,
            tuning: CompanionVariant.standard.tuning,
            motion: 1
        )
        let path = geometry.corePath()
        let box = path.boundingRect
        XCTAssertGreaterThan(box.width, geometry.coreRadius * 1.4, "the body is not a point")
        XCTAssertLessThan(box.width, geometry.coreRadius * 2.6, "the body stays compact")

        // A teardrop would be strongly taller than wide (or the reverse). The body
        // is a squashed but balanced blob.
        let aspect = box.height / box.width
        XCTAssertGreaterThan(aspect, 0.75)
        XCTAssertLessThan(aspect, 1.25)

        // A plain circle would have the un-modulated diameter exactly; the
        // silhouette is modulated, so the box is measurably different.
        XCTAssertNotEqual(box.width, geometry.coreRadius * 2, accuracy: 0.5)
    }

    /// Membranes must wrap, not close: every ribbon leaves an opening, and each
    /// one sits outside the dark body.
    func testCompanionMembranesAreTaperedRibbonsOutsideTheBody() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        for variant in CompanionVariant.allCases {
            let geometry = CompanionGeometry(
                rect: rect,
                phase: 2.3,
                level: 0.7,
                tuning: variant.tuning,
                motion: 1
            )
            for index in 0..<variant.tuning.membraneCount {
                let span = geometry.membraneSpan(index: index)
                XCTAssertGreaterThan(span, CGFloat.pi, "\(variant.rawValue) membrane too short")
                XCTAssertLessThan(span, 2 * CGFloat.pi, "\(variant.rawValue) membrane closed into a ring")
                XCTAssertGreaterThan(
                    geometry.membraneRadius(index: index),
                    geometry.coreRadius,
                    "\(variant.rawValue) membrane sits inside the body"
                )
                let box = geometry.membranePath(index: index).boundingRect
                XCTAssertFalse(box.isNull || box.isEmpty, "\(variant.rawValue) membrane has no geometry")
                // Nothing may escape the companion canvas.
                XCTAssertGreaterThanOrEqual(box.minX, -1)
                XCTAssertGreaterThanOrEqual(box.minY, -1)
                XCTAssertLessThanOrEqual(box.maxX, rect.width + 1)
                XCTAssertLessThanOrEqual(box.maxY, rect.height + 1)
            }
        }
    }

    func testCompanionAccessoriesOccupyDistinctSlots() {
        XCTAssertEqual(Set(CompanionAccessory.allCases.map(\.slot)), Set([.head, .face, .body, .aura]))
        XCTAssertEqual(CompanionAccessory.hat.slot, .head)
        XCTAssertEqual(CompanionAccessory.glasses.slot, .face)
        XCTAssertEqual(CompanionAccessory.scarf.slot, .body)
        XCTAssertEqual(CompanionAccessory.halo.slot, .aura)
        XCTAssertTrue(CompanionAccessory.fallback.isEmpty)
    }

    /// Seven variants share one engine, but each one has to feel different.
    func testCompanionVariantsUseDifferentTuning() {
        let tunings = CompanionVariant.allCases.map(\.tuning)
        XCTAssertGreaterThan(Set(tunings.map(\.speed)).count, 2)
        XCTAssertGreaterThan(Set(tunings.map(\.sharpness)).count, 2)
        XCTAssertTrue(CompanionVariant.fire.tuning.rise > CompanionVariant.water.tuning.rise)
        XCTAssertTrue(CompanionVariant.wind.tuning.membraneCount > CompanionVariant.earth.tuning.membraneCount)
        XCTAssertGreaterThan(CompanionVariant.earth.tuning.membraneCount, 0)
    }

    /// Default and Aurora follow the user's overlay theme (including Custom);
    /// the elemental variants carry their own identity.
    func testCompanionPaletteFollowsTheThemeUnlessTheVariantIsElemental() {
        let themePalette = OverlayColorTheme.blue.palette
        XCTAssertEqual(CompanionVariant.standard.palette(themePalette: themePalette), themePalette)
        XCTAssertEqual(CompanionVariant.aurora.palette(themePalette: themePalette), themePalette)
        XCTAssertNotEqual(CompanionVariant.fire.palette(themePalette: themePalette), themePalette)
        XCTAssertNotEqual(CompanionVariant.gothic.palette(themePalette: themePalette), themePalette)
    }

    func testMotionIntensityIsOrderedAndHasASafeFallback() {
        XCTAssertLessThan(MotionIntensity.subtle.scale, MotionIntensity.normal.scale)
        XCTAssertLessThan(MotionIntensity.normal.scale, MotionIntensity.expressive.scale)
        XCTAssertEqual(MotionIntensity.fallback, .normal)
        XCTAssertEqual(CompanionVariant.fallback, .standard)
    }

}


