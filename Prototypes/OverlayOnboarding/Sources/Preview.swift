import AppKit
import SwiftUI

// Extracted product colors; no SettingsStore, audio, models, or production callbacks.
enum FluidBrandColors { static let blue = Color(red: 0.10, green: 0.46, blue: 1) }
enum AppTheme { enum Metrics { enum Showcase { static let cardRadius: CGFloat = 24 } } }

/// One bounded clock makes pause/scrub deterministic. No clock remains at rest.
@MainActor final class SequencePlayer: ObservableObject {
    static let duration = 25.0
    @Published var time = 0.0
    @Published private(set) var playing = false
    @Published var slow = false
    @Published private(set) var demoActive = false
    var canActivate: Bool { time >= 13.4 }
    func toggleDemo() {
        guard canActivate else { return }
        pause()
        demoActive.toggle()
    }
    private var timer: Timer?
    private var lastTick = 0.0
    private var intervals: [Double] = []
    private(set) var tickCount = 0
    var stage: String {
        switch time {
        case ..<3.4: return "Overlay arrives"
        case ..<4.3: return "Mode chip"
        case ..<7.3: return "Basic and Smart"
        case ..<10.0: return "Smart selected"
        case ..<13.4: return "Shortcut"
        case ..<19.5: return "Correction example"
        default: return "Numbered list example"
        }
    }
    func play() {
        guard timer == nil else { return }
        if time >= Self.duration { time = 0 }
        playing = true
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastTick
        lastTick = now
        if intervals.count < 5000 { intervals.append(delta) }
        tickCount += 1
        time = min(Self.duration, time + delta * (slow ? 0.5 : 1))
        if time >= Self.duration { pause() }
    }
    func pause() { timer?.invalidate(); timer = nil; playing = false }
    func seek(_ value: Double) { pause(); demoActive = false; time = min(Self.duration, max(0, value)) }
    func replay() { seek(0); intervals.removeAll(keepingCapacity: true); tickCount = 0; play() }
    func report() -> String {
        let sorted = intervals.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
        return "ticks=\(tickCount) activeTimer=\(timer != nil) time=\(time) callback_p95_ms=\(p95) callback_over_33ms=\(intervals.filter { $0 > 0.0333 }.count)\nCallback timing is not presented-frame or GPU timing.\n"
    }
}

struct PreviewScene: View {
    @ObservedObject var player: SequencePlayer
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @State private var previewReduceMotion = false
    @State private var previewOpaque = false
    var reduced: Bool { systemReduceMotion || previewReduceMotion }
    private let paleBlue = Color(red: 0.48, green: 0.72, blue: 1)
    private func progress(_ start: Double, _ length: Double) -> Double {
        let x = min(1, max(0, (player.time - start) / length))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    private var arrival: Double { progress(0.15, 1.1) }
    private var overlayOpacity: Double { player.demoActive ? 1 : arrival * (1 - progress(12.0, 0.6)) }
    private var press: Double { progress(4.10, 0.16) * (1 - progress(4.30, 0.25)) }
    private var menu: Double { progress(4.40, 0.5) * (1 - progress(9.3, 0.5)) }
    private var menuSpring: Double {
        let t = min(1.2, max(0, player.time - 4.40))
        return 1 - exp(-8 * t) * (cos(11 * t) + (8.0 / 11) * sin(11 * t))
    }
    private var secondPress: Double { progress(7.0, 0.12) * (1 - progress(7.18, 0.18)) }
    private var selection: Double { player.time >= 7.18 ? 1 : 0 }
    private var pointerApproach: Double { progress(5.05, 0.55) }
    private var pointerToSmart: Double { progress(6.15, 0.65) }
    private var highlight: Double { progress(3.55, 0.4) * (1 - progress(10.0, 0.4)) }

    var body: some View {
        VStack(spacing: 0) {
            stage
            controls
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 880, idealWidth: 1040, minHeight: 730, idealHeight: 810)
    }
    // A continuous camera move, with still reading holds. All transforms stop at 11.8s.
    private var reveal: Double { progress(0.5, 2.7) }
    private var dock: Double { progress(10.0, 1.8) }
    private var cameraScale: Double { reduced ? 1 : 2.8 - 0.85 * reveal - 0.95 * dock }
    private var pitch: Double { reduced ? 0 : 60 * (1 - reveal) + 12 * reveal * (1 - dock) }
    private var yaw: Double { reduced ? 0 : 28 * (1 - reveal) - 10 * reveal * (1 - dock) }
    private var roll: Double { reduced ? 0 : -14 * (1 - reveal) + 2 * reveal * (1 - dock) }
    fileprivate var stage: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.018, green: 0.026, blue: 0.05)
                RadialGradient(colors: [FluidBrandColors.blue.opacity(0.19), .clear], center: .init(x: 0.64, y: 0.65), startRadius: 0, endRadius: 510)
                // A second fixed light gives the moving glass a spatial reference.
                Ellipse().fill(RadialGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.47).opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 400))
                    .frame(width: 820, height: 240).rotationEffect(.degrees(-25))
                    .position(x: geo.size.width * 0.68, y: geo.size.height * 0.7)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Meet your overlay")
                        .font(.fluidSystem(size: 42, design: .serif))
                    Text("Change modes with one click.")
                        .font(.fluidSystem(size: 15)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 70)
                .opacity(progress(1.15, 1.0) * (1 - progress(3.4, 0.55)))
                .offset(y: reduced ? 0 : 15 * (1 - progress(1.15, 1.0)))
                .position(x: geo.size.width / 2, y: 100)

                Text("Change modes\nwith one click.")
                    .font(.fluidSystem(size: 32, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 70)
                    .opacity(progress(4.0, 0.6) * (1 - progress(9.5, 0.5)))
                    .position(x: geo.size.width / 2, y: 122)

                // Overlay and menu share one camera, so their attachment never drifts.
                ZStack {
                    overlay
                }
                .frame(width: 340, height: 90.25)
                .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
                .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .rotationEffect(.degrees(roll))
                .scaleEffect(cameraScale)
                .opacity(overlayOpacity)
                .offset(y: player.demoActive || reduced ? 0 : 8 * progress(12.0, 0.6))
                .animation(reduced ? .easeOut(duration: 0.15) : .easeOut(duration: 0.25), value: player.demoActive)
                .position(x: geo.size.width / 2 + (reduced ? 0 : 90 * (1 - reveal)),
                          y: geo.size.height * 0.57 + dock * (geo.size.height * 0.43 - 123))
                .accessibilityHidden(overlayOpacity < 0.1)

                VStack(spacing: 12) {
                    if player.demoActive {
                        Text("Overlay preview · microphone off")
                            .font(.fluidSystem(size: 12)).foregroundStyle(.white.opacity(0.55))
                        Button("Hide overlay") { player.toggleDemo() }
                            .buttonStyle(.plain).foregroundStyle(paleBlue)
                    } else {
                        Text("Let’s try Smart mode")
                            .font(.fluidSystem(size: 22, design: .serif))
                            .foregroundStyle(.white.opacity(0.92))
                        HStack(spacing: 10) {
                            Text("Press").foregroundStyle(.white.opacity(0.8))
                            Text("⌥ Space")
                                .font(.fluidSystem(size: 22, weight: .medium))
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            Text("to start dictating").foregroundStyle(.white.opacity(0.8))
                        }
                        .font(.fluidSystem(size: 18))
                        Button("Try dictation") { player.toggleDemo() }
                            .buttonStyle(.plain).font(.fluidSystem(size: 13, weight: .medium))
                            .foregroundStyle(paleBlue)
                        Text("Preview shortcut · no audio recorded")
                            .font(.fluidSystem(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .opacity(progress(12.8, 0.6))
                .disabled(!player.canActivate)
                .allowsHitTesting(player.canActivate)
                .position(x: geo.size.width / 2, y: geo.size.height - (player.demoActive ? 37 : 110))
                .accessibilityHidden(!player.canActivate)

                example
                    .opacity(progress(13.4, 0.8))
                    .offset(y: reduced ? 0 : 18 * (1 - progress(13.4, 0.8)))
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.32)
                    .accessibilityHidden(player.time < 13.4)
            }
            .clipped()
        }
    }
    private var overlay: some View {
        BottomOverlayView(smart: selection > 0.5,
                          chipScale: reduced ? 1 : 1 - 0.075 * press,
                          chipHighlighted: highlight > 0.1,
                          demonstrationMenu: AnyView(
                            modeMenu
                                .scaleEffect(reduced ? 1 : (player.time < 9.3 ? 0.86 + 0.14 * menuSpring : 0.86 + 0.14 * menu), anchor: .bottomTrailing)
                                .rotation3DEffect(.degrees(reduced ? 0 : -16 * (1 - menu)), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.35)
                                .opacity(menu)
                                .offset(y: reduced ? 0 : 9 * (1 - menuSpring))
                                .accessibilityHidden(menu < 0.5)
                          ),
                          demonstrationPointer: AnyView(
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 15)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                                .scaleEffect(reduced ? 1 : 1 - 0.12 * max(press, secondPress))
                                .offset(x: 7 + 34 * (1 - progress(3.4, 0.65)) - 65 * pointerApproach,
                                        y: 7 + 31 * (1 - progress(3.4, 0.65)) - 54 * pointerApproach + 25 * pointerToSmart)
                                .opacity((reduced ? 0 : 1) * progress(3.3, 0.2) * (1 - progress(8.05, 0.3)))
                                .accessibilityHidden(true)
                          ))
    }
    private var modeMenu: some View {
        ProductionPromptMenu(smart: selection > 0.5,
                             smartPress: reduced ? 0 : secondPress,
                             hoveredRowID: player.time >= 6.75 && player.time < 7.18 ? "privateAI" : nil,
                             basicOpacity: progress(4.65, 0.24),
                             smartOpacity: progress(4.73, 0.28),
                             basicOffset: reduced ? 0 : 5 * (1 - progress(4.65, 0.30)),
                             smartOffset: reduced ? 0 : 7 * (1 - progress(4.73, 0.34)))
    }
    private var example: some View {
        let index = player.time >= 19.5 ? 1 : 0
        let item = PracticeExamples.items[index]
        let switchOpacity = player.time < 19.5 ? 1 - progress(19.15, 0.35) : progress(19.5, 0.4)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                ForEach(0..<2) { option in
                    Button(PracticeExamples.items[option].label) { player.seek(option == 0 ? 16 : 23) }
                        .buttonStyle(.plain)
                        .font(.fluidSystem(size: 12, weight: .medium))
                        .foregroundStyle(option == index ? paleBlue : .white.opacity(0.45))
                        .accessibilityAddTraits(option == index ? [.isSelected] : [])
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Text(item.title)
                    .font(.fluidSystem(size: 26, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You say").foregroundStyle(.white.opacity(0.5))
                        Text(item.spoken).foregroundStyle(.white.opacity(0.8))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 132)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Smart").foregroundStyle(paleBlue)
                        Text(item.cleaned).foregroundStyle(.white.opacity(0.93))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.fluidSystem(size: 14)).lineSpacing(3)
            }
            .frame(height: 198, alignment: .topLeading)
            .opacity(switchOpacity)
        }
        .padding(26).frame(width: 650, alignment: .leading)
        .modifier(OnboardingGlassSurface(selected: true, forceOpaque: previewOpaque))
    }
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button(action: { player.replay() }) { Image(systemName: "arrow.counterclockwise") }.help("Replay")
                Button(action: { player.playing ? player.pause() : player.play() }) {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 14)
                }.help(player.playing ? "Pause" : "Play").keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...SequencePlayer.duration)
                    .accessibilityLabel("Sequence position")
                Text(String(format: "%04.1f / 25s", player.time)).monospacedDigit().frame(width: 85)
            }
            HStack(spacing: 18) {
                Text(player.stage).foregroundStyle(.white.opacity(0.7)).frame(width: 130, alignment: .leading)
                Spacer()
                Toggle("Half speed", isOn: $player.slow)
                Toggle("Reduce motion", isOn: $previewReduceMotion)
                Toggle("Opaque surfaces", isOn: $previewOpaque)
                Text("VISUAL PREVIEW").font(.fluidSystem(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.35))
            }
        }
        .font(.fluidSystem(size: 11)).toggleStyle(.checkbox).buttonStyle(.plain)
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(Color(red: 0.04, green: 0.045, blue: 0.065))
    }
}

@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let player = SequencePlayer()
    var window: NSWindow!
    var observers: [NSObjectProtocol] = []
    var previewKeyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 810), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FluidVoice · Overlay Film"
        window.minSize = NSSize(width: 880, height: 758)
        window.delegate = self
        let args = ProcessInfo.processInfo.arguments
        let rendering = args.contains("--render-frames")
        if rendering {
            window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        } else {
            window.contentView = NSHostingView(rootView: PreviewScene(player: player))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Foreground preview only. Never install a global shortcut or connect to recording.
            previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window.isKeyWindow, self.player.canActivate,
                      event.keyCode == 49,
                      event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option else { return event }
                if !event.isARepeat { self.player.toggleDemo() }
                return nil
            }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSApplication.didHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.window.occlusionState.contains(.visible) || self.window.isMiniaturized || NSApp.isHidden { self.player.pause() }
                }
            })
        }
        if let i = args.firstIndex(of: "--seek"), args.count > i + 1, let value = Double(args[i + 1]) { player.seek(value) }
        else if !rendering { player.play() }
        if let i = args.firstIndex(of: "--render-frames"), args.count > i + 1 {
            renderFrames(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
        if let i = args.firstIndex(of: "--metrics"), args.count > i + 1 {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
                try? self?.player.report().write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
    func renderFrames(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let landmarks: [(String, Double)] = [("01-angle", 0.9), ("02-reveal", 2.0), ("03-settle", 3.3), ("04-press", 4.25), ("05-unfold", 4.7), ("05-basic", 6), ("06-pointer-basic", 5.8), ("06-pointer-smart", 6.85), ("06-smart-click", 7.1), ("06-smart-selected", 7.4), ("07-dock", 11), ("08-vanishing", 12.3), ("08-shortcut", 13.4), ("09-correction", 16), ("10-numbered-list", 23)]
        let film = ProcessInfo.processInfo.arguments.contains("--film")
        let reference = ProcessInfo.processInfo.arguments.contains("--reference")
        let filmDuration = ProcessInfo.processInfo.arguments.contains("--intro-only") ? 12.8 : SequencePlayer.duration
        let frames = reference ? [("production-medium-smart", 16.0)] : (film ? (0...Int(filmDuration * 60)).map { (String(format: "%04d", $0), Double($0) / 60) } : landmarks)
        for (index, frame) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * (film ? 0.04 : 0.55)) { [weak self] in
                self?.player.seek(frame.1)
                DispatchQueue.main.asyncAfter(deadline: .now() + (film ? 0 : 0.25)) { [weak self] in
                    guard let self else { return }
                    self.player.seek(frame.1)
                    if ProcessInfo.processInfo.arguments.contains("--activated") { self.player.toggleDemo() }
                    let content = reference
                        ? AnyView(BottomOverlayView(smart: true).fixedSize().padding(20).environment(\.colorScheme, .dark))
                        : AnyView(PreviewScene(player: self.player).stage.frame(width: 1040, height: 730).environment(\.colorScheme, .dark))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = reference ? 3 : 1.5
                    if let data = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(frame.0 + ".png"))
                    }
                    if index == frames.count - 1 { NSApp.terminate(nil) }
                }
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let previewKeyMonitor { NSEvent.removeMonitor(previewKeyMonitor) }
        previewKeyMonitor = nil
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct OverlayPreviewMain {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--check-interaction") {
            let player = SequencePlayer()
            player.seek(12.7)
            player.toggleDemo()
            precondition(!player.demoActive, "Activation must wait for the introduction")
            player.seek(13.4)
            player.play()
            player.toggleDemo()
            precondition(player.demoActive && !player.playing, "Activation should reveal overlay and stop autoplay")
            player.toggleDemo()
            precondition(!player.demoActive, "Second activation should hide the demo")
            player.toggleDemo()
            player.seek(0)
            precondition(!player.demoActive, "Scrubbing or replay must reset activation")
            print("PASS: early input ignored; ready input toggles overlay; autoplay pauses; seek resets activation")
            return
        }
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.setActivationPolicy(ProcessInfo.processInfo.arguments.contains("--render-frames") ? .accessory : .regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
