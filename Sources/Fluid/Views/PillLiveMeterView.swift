import AppKit
import Combine
import QuartzCore
import SwiftUI

/// State advances once per timer tick on MainActor, never in a SwiftUI body or Canvas.
/// The isolated child is the only view invalidated by these 60 Hz publications.
@MainActor
final class PillMeterPresentation: ObservableObject {
    @Published private(set) var levels = [Double](repeating: 0, count: 6)
    private let pipeline: PillSpectrumPipeline
    private var timer: Timer?
    private var dynamics = PillMeterDynamics()
    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0
    private var count = 6
    private var sensitivity = 0.4
    #if DEBUG
    private(set) var presentationLatencies: [Double] = []
    var timerForTesting: Timer? {
        self.timer
    }
    #endif

    init(pipeline: PillSpectrumPipeline = .shared) {
        self.pipeline = pipeline
    }

    /// A new attempt can become ready before the next presentation tick.
    /// Never draw heights belonging to the previous epoch during that interval.
    var levelsAreCurrent: Bool {
        self.epoch == self.pipeline.epoch
    }

    func start(count: Int, sensitivity: Double) {
        self.count = count
        self.sensitivity = sensitivity
        guard self.timer == nil else { return }
        self.dynamics.reset()
        self.tick()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.dynamics.reset()
        self.epoch = 0
        self.sequence = 0
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let pipeline = self.pipeline
        guard pipeline.isVisible else {
            // A view may appear before the controller's visibility notification.
            // Keep its driver armed; onDisappear/stop owns timer teardown.
            self.dynamics.reset()
            self.epoch = 0
            self.sequence = 0
            if self.levels.contains(where: { $0 != 0 }) {
                self.levels = .init(repeating: 0, count: self.count)
            }
            return
        }
        if pipeline.epoch != self.epoch {
            self.epoch = pipeline.epoch
            self.sequence = 0
            self.dynamics.reset()
        }
        var target = [Double](repeating: 0, count: self.count)
        if let frame = pipeline.latest(), now - frame.publishedAt < 0.15 {
            if frame.sequence != self.sequence {
                // The analyzer resets PCM history on gaps. Keep the visible envelope
                // continuous within an attempt; only a new epoch resets its heights.
                self.sequence = frame.sequence
                #if DEBUG
                if self.presentationLatencies.count < 4096 {
                    self.presentationLatencies.append((now - frame.publishedAt) * 1000)
                }
                #endif
            }
            target = PillMeterMapping.levels(frame.amplitudes, count: self.count, sensitivity: self.sensitivity, rms: frame.rms)
        }
        let next = self.dynamics.advance(target: target, at: now)
        // Silence has no redraws. Polling remains alive so speech can wake immediately.
        if next != self.levels {
            self.levels = next
        }
    }
}

struct PillLiveMeterView: View {
    let count: Int
    let sensitivity: Double
    let ready: Bool
    @StateObject private var presentation = PillMeterPresentation()

    var body: some View {
        GeometryReader { proxy in
            let geometry = PillMeterGeometry(count: self.count, availableWidth: proxy.size.width, availableHeight: proxy.size.height)
            Canvas { context, size in
                let showsLevels = self.ready && self.presentation.levelsAreCurrent
                var x = (size.width - geometry.groupWidth) / 2
                for index in 0..<geometry.count {
                    let level = showsLevels && index < self.presentation.levels.count ? self.presentation.levels[index] : 0
                    let height = geometry.width + (geometry.maximumHeight - geometry.width) * level
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: geometry.width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: geometry.width / 2), with: .color(.white.opacity(0.88)))
                    x += geometry.width + geometry.gap
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { self.presentation.start(count: self.count, sensitivity: self.sensitivity) }
        .onChange(of: self.count) { _, _ in self.presentation.start(count: self.count, sensitivity: self.sensitivity) }
        .onChange(of: self.sensitivity) { _, _ in self.presentation.start(count: self.count, sensitivity: self.sensitivity) }
        .onDisappear { self.presentation.stop() }
        .transaction { $0.animation = nil }
    }
}
