import AppKit
import SwiftUI

/// Floating "drag the app into the list" guide shown next to System Settings, generalized from
/// the Accessibility onboarding flow so any TCC pane (Screen Recording, etc.) can reuse it.
@MainActor
final class PermissionDragGuideController {
    static let shared = PermissionDragGuideController()

    private var panel: NSPanel?
    private var monitorTask: Task<Void, Never>?
    private var requestID: UUID?

    private init() {}

    func present(
        instruction: String,
        settingsPaneURL: URL,
        isGranted: @escaping @Sendable () -> Bool,
        onGranted: @escaping @MainActor () -> Void = {}
    ) {
        let requestID = UUID()
        self.requestID = requestID
        NSWorkspace.shared.open(settingsPaneURL)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.requestID == requestID else { return }
            self.showPanel(instruction: instruction)
            self.startMonitor(requestID: requestID, isGranted: isGranted, onGranted: onGranted)
            self.activateSystemSettingsSoon(requestID: requestID)
        }
    }

    func dismiss() {
        self.requestID = nil
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.panel?.close()
        self.panel = nil
    }

    private func showPanel(instruction: String) {
        let panelWidth: CGFloat = 560
        let panelHeight: CGFloat = 150
        let gap: CGFloat = 14
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let panelX: CGFloat
        let panelY: CGFloat
        if let settingsFrame = Self.systemSettingsWindowFrame() {
            panelX = min(
                visibleFrame.maxX - panelWidth - 16,
                max(visibleFrame.minX + 16, settingsFrame.midX - (panelWidth / 2))
            )
            panelY = max(visibleFrame.minY + 16, settingsFrame.minY - panelHeight - gap)
        } else {
            panelX = visibleFrame.midX - (panelWidth / 2)
            panelY = visibleFrame.minY + 120
        }

        let frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        let panel = self.panel ?? NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(
            rootView: PermissionDragGuideView(
                appURL: Self.draggableAppURL,
                appName: Bundle.main.fluidAppDisplayName,
                instruction: instruction,
                onReturnToApp: { [weak self] in self?.returnToApp() },
                onClose: { [weak self] in self?.dismiss() }
            )
        )
        panel.setFrame(frame, display: true, animate: self.panel != nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func startMonitor(
        requestID: UUID,
        isGranted: @escaping @Sendable () -> Bool,
        onGranted: @escaping @MainActor () -> Void
    ) {
        self.monitorTask?.cancel()
        self.monitorTask = Task { [weak self] in
            var missingSettingsCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, await self.requestID == requestID else { return }

                if isGranted() {
                    await MainActor.run {
                        self.dismiss()
                        onGranted()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return
                }

                let settingsFrame = await MainActor.run { Self.systemSettingsWindowFrame() }
                missingSettingsCount = settingsFrame == nil ? missingSettingsCount + 1 : 0
                if missingSettingsCount >= 3 {
                    await MainActor.run { self.returnToApp() }
                    return
                }
            }
        }
    }

    private func returnToApp() {
        self.dismiss()
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.isVisible && $0.title == "FluidVoice" } ?? NSApp.keyWindow)?
            .makeKeyAndOrderFront(nil)
    }

    private func activateSystemSettingsSoon(requestID: UUID) {
        for delay in [0.25, 0.85, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.requestID == requestID else { return }
                if let app = NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == "com.apple.SystemSettings" }) ??
                    NSWorkspace.shared.runningApplications
                    .first(where: { $0.localizedName == "System Settings" })
                {
                    app.activate(options: [])
                }
            }
        }
    }

    private static var draggableAppURL: URL {
        let runningAppURL = Bundle.main.bundleURL
        if runningAppURL.pathExtension == "app",
           FileManager.default.fileExists(atPath: runningAppURL.path)
        {
            return runningAppURL
        }
        let installedURL = URL(fileURLWithPath: "/Applications/FluidVoice.app")
        if FileManager.default.fileExists(atPath: installedURL.path) {
            return installedURL
        }
        return Bundle.main.bundleURL
    }

    private static func systemSettingsWindowFrame() -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0,
                  height > 0
            else { continue }

            for screen in NSScreen.screens {
                let convertedFrame = NSRect(
                    x: x,
                    y: screen.frame.maxY - y - height,
                    width: width,
                    height: height
                )
                if screen.frame.intersects(convertedFrame) {
                    return convertedFrame
                }
            }
            let convertedY = (NSScreen.main?.frame.maxY ?? 0) - y - height
            return NSRect(x: x, y: convertedY, width: width, height: height)
        }
        return nil
    }
}

private struct PermissionDragGuideView: View {
    let appURL: URL
    let appName: String
    let instruction: String
    let onReturnToApp: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArrowRaised = false
    @State private var isTokenHovered = false

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: self.appURL.path)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                    .offset(y: self.reduceMotion ? 0 : (self.isArrowRaised ? -8 : 4))
                    .animation(
                        self.reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: self.isArrowRaised
                    )

                Text(self.instruction)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Spacer()

                Button {
                    self.onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close guide")
            }

            HStack(spacing: 12) {
                Button {
                    self.onReturnToApp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Return to \(self.appName)")

                Image(nsImage: self.appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(self.appName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(self.isTokenHovered ? 0.095 : 0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(self.isTokenHovered ? 0.16 : 0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovered in
                if self.reduceMotion {
                    self.isTokenHovered = isHovered
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isTokenHovered = isHovered
                    }
                }
            }
            .onDrag {
                NSItemProvider(object: self.appURL as NSURL)
            }
            .accessibilityLabel("Drag \(self.appName) into the list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .onAppear {
            guard !self.reduceMotion else { return }
            self.isArrowRaised = true
        }
    }
}
