#if DEBUG
import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Opt-in local fixture. No microphone, recognition, history, or production defaults.
/// Launch with FLUIDVOICE_PILL_DEMO=1 so normal dictation services stay isolated.
@MainActor
final class PillMeterDebugDemo: ObservableObject {
    private static let shared = PillMeterDebugDemo()
    @Published var phase = "Ready"
    @Published var count = 6
    @Published private(set) var microphoneBusy = false
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var fixtureEpoch: UInt64?
    private var savedSettings: (SettingsStore.OverlaySize, Int)?

    static func startIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_PILL_DEMO"] == "1" else { return false }
        DispatchQueue.main.async { Self.shared.open() }
        return true
    }

    private func open() {
        if let window = self.window {
            window.makeKeyAndOrderFront(nil); return
        }
        let view = PillMeterLabView(demo: self)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 250, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pill Meter Lab — Debug PCM"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func run() {
        guard !self.microphoneBusy else { return }
        let meter = PillSpectrumPipeline.shared
        guard !meter.isCapturing || self.fixtureEpoch == meter.epoch else {
            self.phase = "PCM fixture unavailable during an actual recording"
            return
        }
        var replayPCM: [Float] = []
        if let path = ProcessInfo.processInfo.environment["FLUIDVOICE_PILL_PCM_FILE"] {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                      file.length > 0, file.length <= 16_000 * 120,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
                else {
                    self.phase = "Replay requires a mono 16 kHz fixture of at most two minutes"
                    return
                }
                try file.read(into: buffer)
                guard let channel = buffer.floatChannelData?[0] else { return }
                replayPCM = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            } catch {
                self.phase = "PCM replay unavailable: \(error.localizedDescription)"
                return
            }
        }
        self.cancel()
        self.generation &+= 1
        let generation = self.generation
        self.savedSettings = (SettingsStore.shared.overlaySize, SettingsStore.shared.pillBarCount)
        SettingsStore.shared.overlaySize = .pill
        SettingsStore.shared.pillBarCount = self.count
        self.task = Task { @MainActor in
            let controller = BottomOverlayWindowController.shared
            let pipeline = PillSpectrumPipeline.shared
            controller.show(audioPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
            pipeline.begin(session: Int(generation), attempt: generation)
            self.fixtureEpoch = pipeline.epoch
            let fixtureEpoch = pipeline.epoch
            self.phase = "Microphone readiness · stationary dots"
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, pipeline.epoch == fixtureEpoch else { return }
            OverlayAudioLevelState.shared.isLive = true
            // Optional slower fixtures make individual spectral shapes inspectable.
            let requestedSeconds = Int(ProcessInfo.processInfo.environment["FLUIDVOICE_PILL_FIXTURE_SECTION_SECONDS"] ?? "1") ?? 1
            let blocksPerSection = min(10, max(1, requestedSeconds)) * 100
            let blockCount = replayPCM.isEmpty ? (5 * blocksPerSection) : (replayPCM.count + 159) / 160
            for block in 0..<blockCount {
                guard !Task.isCancelled, self.generation == generation, pipeline.epoch == fixtureEpoch else { return }
                let section = min(4, block / blocksPerSection)
                let phase = replayPCM.isEmpty
                    ? ["Low vowel · O", "Mid vowel · A", "Sibilant · S", "Silence · stationary dots", "Frequency sweep"][section]
                    : String(format: "Recorded PCM replay · %.1f s", Double(block) / 100)
                if self.phase != phase {
                    self.phase = phase
                }
                let frequencies: [Double]
                switch section {
                case 0: frequencies = [220, 400, 700]
                case 1: frequencies = [700, 1200, 2000]
                case 2: frequencies = stride(from: 4100.0, through: 5900, by: 113).map { $0 }
                case 3: frequencies = []
                default: frequencies = [150 * pow(38, Double(block % blocksPerSection) / Double(blocksPerSection))]
                }
                let samples: [Float]
                if !replayPCM.isEmpty {
                    samples = Array(replayPCM[(block * 160)..<min(replayPCM.count, (block + 1) * 160)])
                } else {
                    samples = (0..<160).map { sample -> Float in
                        let time = Double(block * 160 + sample) / 16_000
                        return Float(frequencies.enumerated().reduce(0.0) { sum, item in
                            sum + (section == 2 ? 0.014 : 0.08 / Double(item.offset + 1)) * sin(2 * .pi * item.element * time)
                        })
                    }
                }
                pipeline.offer(samples, sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled, self.generation == generation, pipeline.epoch == fixtureEpoch else { return }
            controller.freezeForStop()
            pipeline.end()
            self.fixtureEpoch = nil
            let completionEpoch = pipeline.epoch
            self.phase = "Stop accepted · upstream release bridge"
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, pipeline.epoch == completionEpoch else { return }
            controller.setProcessing(true)
            for phase in ["Transcribing · upstream shimmer", "Enhancing · same shimmer layer", "Finalizing · same shimmer layer"] {
                self.phase = phase
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.generation == generation, pipeline.epoch == completionEpoch else { return }
            }
            controller.setProcessing(false)
            _ = await controller.hideAndWait()
            self.restoreSettings()
            self.phase = "Complete · original dismissal"
        }
    }

    func cancel() {
        if self.microphoneBusy {
            self.task?.cancel()
            self.phase = "Cancelling microphone check"
            return
        }
        self.task?.cancel()
        self.task = nil
        self.generation &+= 1
        let meter = PillSpectrumPipeline.shared
        if self.fixtureEpoch == meter.epoch {
            meter.end()
        }
        self.fixtureEpoch = nil
        if !meter.isCapturing {
            BottomOverlayWindowController.shared.hideImmediately()
        }
        self.restoreSettings()
        self.phase = "Cancelled · cleared"
    }

    func runMicrophoneCheck() {
        guard !self.microphoneBusy else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            self.phase = "Microphone check blocked: macOS permission is not already granted"
            return
        }
        let asr = AppServices.shared.asr
        guard !asr.isRunning, !asr.isStarting else {
            self.phase = "Microphone check blocked: another recording is active"
            return
        }
        self.cancel()
        self.microphoneBusy = true
        self.savedSettings = (SettingsStore.shared.overlaySize, SettingsStore.shared.pillBarCount)
        SettingsStore.shared.overlaySize = .pill
        SettingsStore.shared.pillBarCount = self.count
        self.task = Task { @MainActor in
            defer { self.microphoneBusy = false; self.restoreSettings() }
            self.phase = "Preparing existing recognition model"
            if asr.micStatus != .authorized {
                await asr.initialize()
            }
            do { try await asr.ensureAsrReady() } catch {
                self.phase = "Microphone check: model unavailable — \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled else { self.phase = "Microphone check cancelled"; return }
            let controller = BottomOverlayWindowController.shared
            controller.show(audioPublisher: asr.audioLevelPublisher, mode: .dictation)
            let outcome = await asr.start()
            guard outcome == .started, asr.isRunning else {
                controller.hideImmediately()
                self.phase = "Microphone check: capture start failed"
                return
            }
            OverlayAudioLevelState.shared.isLive = true
            self.phase = "Real microphone · recording for five seconds"
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled {
                await asr.stopWithoutTranscription()
                controller.hideImmediately()
                self.phase = "Microphone check cancelled"
                return
            }
            controller.freezeForStop()
            controller.setProcessing(true)
            self.phase = "Real microphone · transcribing with upstream shimmer"
            let result = await asr.stop()
            controller.setProcessing(false)
            _ = await controller.hideAndWait()
            self.phase = "Microphone complete · \(result.count) characters · no text inserted or history saved"
            print("PILL_MIC_CHECK completed=true characters=\(result.count) outcome=\(asr.lastStopOutcome)")
        }
    }

    private func restoreSettings() {
        if let savedSettings = self.savedSettings {
            SettingsStore.shared.overlaySize = savedSettings.0
            SettingsStore.shared.pillBarCount = savedSettings.1
            self.savedSettings = nil
        }
    }
}

private struct PillMeterLabView: View {
    @ObservedObject var demo: PillMeterDebugDemo
    @ObservedObject private var state = NotchContentState.shared
    var body: some View {
        VStack(spacing: 22) {
            Text("Pill microphone meter").font(.title2.bold())
            Text("Deterministic PCM • actual renderer and processing lifecycle")
                .foregroundStyle(.secondary)
            Group {
                if self.state.isBottomOverlayPresented {
                    BottomWaveformView(color: .white, layout: .get(for: .pill), visibleBarCount: nil)
                } else {
                    Color.clear
                }
            }
            .frame(width: 46, height: 30)
            .padding(.horizontal, 27).padding(.vertical, 8)
            .background(.black, in: Capsule())
            .scaleEffect(3).frame(height: 120)
            Text(self.demo.phase).monospacedDigit()
            HStack {
                Picker("Bars", selection: self.$demo.count) {
                    ForEach(3...8, id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 120)
                    .disabled(self.demo.microphoneBusy)
                Button("Run PCM → loading → completion") { self.demo.run() }
                    .disabled(self.demo.microphoneBusy)
                Button("Cancel") { self.demo.cancel() }
            }
            Button("Check existing microphone access (5 seconds)") { self.demo.runMicrophoneCheck() }
                .disabled(self.demo.microphoneBusy)
        }.padding(24).frame(width: 600, height: 400)
    }
}
#endif
