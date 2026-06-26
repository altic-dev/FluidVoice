//
//  AISettingsComponents.swift
//  fluid
//
//  Extracted from AISettingsView.swift to keep view body under lint limit.
//

import SwiftUI

/// A gentle wave surface that bobs up and down
struct LiquidLayer: Shape {
    var phase: Double // Phase offset for this layer
    var time: Double // Animation time

    var animatableData: Double {
        get { self.time }
        set { self.time = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = Double(rect.width)
        let height = Double(rect.height)
        let step = max(2.0, width / 160.0)

        // Wave surface very close to the top (only 3% offset for wave amplitude)
        let baseY = height * 0.03

        path.move(to: CGPoint(x: 0, y: CGFloat(baseY)))

        // Create a gentle, organic wave surface
        for x in stride(from: 0.0, through: width, by: step) {
            let normalizedX = x / width

            // Slow, gentle wave like water sloshing in a jar
            let waveAmplitude = 2.0
            let waveFrequency = 1.5 // Lower frequency = broader, more ocean-like waves
            let y = baseY + sin((normalizedX * waveFrequency + self.time * 0.25 + self.phase) * .pi) * waveAmplitude

            path.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }

        // Fill down to bottom
        path.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(height)))
        path.addLine(to: CGPoint(x: 0, y: CGFloat(height)))
        path.closeSubpath()

        return path
    }
}

/// A vertical liquid-filled bar with animated fill level
struct LiquidBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    let fillPercent: Double
    let color: Color
    let secondaryColor: Color
    let icon: String
    let label: String

    // Animated fill level (smoothly transitions between values)
    @State private var animatedFill: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            // Label
            HStack(spacing: 4) {
                Image(systemName: self.icon)
                    .font(self.theme.typography.tiny)
                    .foregroundStyle(self.color)
                Text(self.label)
                    .font(self.theme.typography.tinyStrong)
                    .foregroundStyle(.secondary)
            }

            // Liquid Container (Capsule Glass)
            ZStack(alignment: .bottom) {
                // Background (Empty glass interior)
                Capsule()
                    .fill(self.theme.palette.cardBackground.opacity(0.9))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        self.theme.palette.cardBorder.opacity(0.55),
                                        self.theme.palette.cardBorder.opacity(0.25),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )

                // Single clean liquid layer with animated height
                GeometryReader { geo in
                    let displayHeight = geo.size.height * CGFloat(self.animatedFill)

                    Group {
                        if self.reduceMotion {
                            LiquidLayer(phase: 0.0, time: 0)
                                .fill(
                                    LinearGradient(
                                        colors: [self.color, self.secondaryColor],
                                        startPoint: .bottom,
                                        endPoint: .top
                                    )
                                )
                                .frame(height: displayHeight)
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                                let time = timeline.date.timeIntervalSinceReferenceDate

                                // Single organic liquid surface
                                LiquidLayer(phase: 0.0, time: time)
                                    .fill(
                                        LinearGradient(
                                            colors: [self.color, self.secondaryColor],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(height: displayHeight)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(Capsule())
                .padding(3)

                // Glass highlight (3D glossy effect)
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.25), location: 0),
                                .init(color: .white.opacity(0.08), location: 0.25),
                                .init(color: .clear, location: 0.5),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(2)
                    .allowsHitTesting(false)
            }
            .frame(width: 48, height: 90)

            // Percentage (shows target, not animated)
            Text("\(Int(self.fillPercent * 100))%")
                .font(self.theme.typography.metricTiny)
                .foregroundStyle(self.fillPercent > 0 ? self.color : .secondary)
                .contentTransition(.numericText())
        }
        .onAppear {
            // Initialize to target on first appear
            self.animatedFill = self.fillPercent
        }
        .onChange(of: self.fillPercent) { _, newValue in
            guard !self.reduceMotion else {
                self.animatedFill = newValue
                return
            }

            // Animate liquid level change with a gentle "sloshing" feel
            withAnimation(.interpolatingSpring(stiffness: 140, damping: 18)) {
                self.animatedFill = newValue
            }
        }
    }
}
