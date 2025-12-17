import Combine
import SwiftUI

// MARK: - Custom Animation Configurations

struct PulseAnimationConfig: AudioVisualizationConfig {
    let noiseThreshold: CGFloat = 0.3
    let maxAnimationScale: CGFloat = 2.5
    let animationSpring: Animation = .easeInOut(duration: 0.15) // Faster for 60 FPS
}

struct WaveAnimationConfig: AudioVisualizationConfig {
    let noiseThreshold: CGFloat = 0.2
    let maxAnimationScale: CGFloat = 4.0
    let animationSpring: Animation = .spring(
        response: 0.3,
        dampingFraction: 0.6,
        blendDuration: 0
    ) // Optimized for 60 FPS
}

// MARK: - Custom Animation Views

struct PulseAudioVisualizationView: View {
    @StateObject private var data: AudioVisualizationData
    let config: AudioVisualizationConfig
    @State private var animationId = UUID()

    init(audioLevelPublisher: AnyPublisher<CGFloat, Never>, config: AudioVisualizationConfig = PulseAnimationConfig()) {
        _data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioLevelPublisher))
        self.config = config
    }

    var body: some View {
        ZStack {
            // Multiple pulsing rings
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.green.opacity(0.6 - Double(index) * 0.2), lineWidth: 2)
                    .frame(width: 40 + CGFloat(index) * 20, height: 40 + CGFloat(index) * 20)
                    .scaleEffect(
                        self.data.audioLevel > self.config.noiseThreshold ?
                            1.0 + (self.data.audioLevel - self.config.noiseThreshold) * self.config
                            .maxAnimationScale : 1.0,
                        anchor: .center
                    )
                    .opacity(self.data.audioLevel > self.config.noiseThreshold ?
                        1.0 - (self.data.audioLevel - self.config.noiseThreshold) : 0.3)
                    .animation(self.config.animationSpring.delay(Double(index) * 0.1), value: self.animationId)
            }

            // Center dot
            Circle()
                .fill(Color.green)
                .frame(width: 12, height: 12)
        }
        .frame(width: 100, height: 100)
        .onChange(of: self.data.audioLevel) { _, newLevel in
            // Only trigger animation update for significant changes to prevent cycles
            if abs(newLevel - (self.data.audioLevel)) > 0.1 {
                self.animationId = UUID()
            }
        }
    }
}

struct WaveAudioVisualizationView: View {
    @StateObject private var data: AudioVisualizationData
    let config: AudioVisualizationConfig
    @State private var animationId = UUID()

    init(audioLevelPublisher: AnyPublisher<CGFloat, Never>, config: AudioVisualizationConfig = WaveAnimationConfig()) {
        _data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioLevelPublisher))
        self.config = config
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 4, height: 20)
                    .scaleEffect(
                        y: self.data.audioLevel > self.config.noiseThreshold ?
                            1.0 + (self.data.audioLevel - self.config.noiseThreshold) * self.config
                            .maxAnimationScale * (1.0 - Double(index) * 0.1) : 0.2,
                        anchor: .bottom
                    )
                    .animation(self.config.animationSpring.delay(Double(index) * 0.05), value: self.animationId)
            }
        }
        .frame(width: 60, height: 40)
        .onChange(of: self.data.audioLevel) { _, newLevel in
            // Only trigger animation update for significant changes to prevent cycles
            if abs(newLevel - (self.data.audioLevel)) > 0.1 {
                self.animationId = UUID()
            }
        }
    }
}

// MARK: - Usage Examples

/*
 // Example 1: Using Pulse Animation
 struct PulseListeningOverlayView: View {
     let audioLevelPublisher: AnyPublisher<CGFloat, Never>

     var body: some View {
         PulseAudioVisualizationView(
             audioLevelPublisher: audioLevelPublisher,
             config: PulseAnimationConfig()
         )
     }
 }

 // Example 2: Using Wave Animation
 struct WaveListeningOverlayView: View {
     let audioLevelPublisher: AnyPublisher<CGFloat, Never>

     var body: some View {
         WaveAudioVisualizationView(
             audioLevelPublisher: audioLevelPublisher,
             config: WaveAnimationConfig()
         )
     }
 }

 // Example 3: Custom Configuration
 struct CustomConfigAnimationConfig: AudioVisualizationConfig {
     let noiseThreshold: CGFloat = 0.1 // Very sensitive
     let maxAnimationScale: CGFloat = 5.0 // Very dramatic
     let animationSpring: Animation = .interpolatingSpring(stiffness: 300, damping: 30)
 }

 struct CustomListeningOverlayView: View {
     let audioLevelPublisher: AnyPublisher<CGFloat, Never>

     var body: some View {
         DefaultAudioVisualizationView(
             audioLevelPublisher: audioLevelPublisher,
             config: CustomConfigAnimationConfig()
         )
     }
 }
 */
