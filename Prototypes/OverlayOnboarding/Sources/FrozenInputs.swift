import AppKit
import SwiftUI

// No UserDefaults, recording services, observers or production controllers.
// Source defaults and the read-only installed preference snapshot both select medium/streaming.
struct SettingsStore {
    enum OverlaySize { case pill, small, medium, large }
    let overlaySize = OverlaySize.medium
}
struct FrozenAppServices { struct ASR { let isAsrReady = true; let isLoadingModel = false; let isDownloadingModel = false }; let asr = ASR() }
struct FrozenOverlayState {
    let isProcessing = false
    let isBottomOverlayPresented = false
    let isBottomOverlayReleaseTransitioning = false
    let isBottomOverlayDismissing = false
    let spokenSendIndicatorState = false
    let spokenSendCountdownID = 0
}
struct SpokenSendIndicatorView: View {
    let state: Bool; let color: Color; let size: CGFloat
    var body: some View { EmptyView() }
}
struct CompositorShimmerSweep: View {
    let duration: Double; let peakOpacity: Double
    var body: some View { EmptyView() }
}
enum FluidOnboardingLandingColors { static let blue = FluidBrandColors.blue }
private struct EmptyThemeKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues { var theme: Int { get { self[EmptyThemeKey.self] } set { self[EmptyThemeKey.self] = newValue } } }
enum PillShadowMetrics { static let radius: CGFloat = 10; static let yOffset: CGFloat = 4 }
struct DynamicPreviewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
// Frozen transcription branches never change; this keeps their copied two-value callback
// syntax compilable on macOS 13 without attaching any production event behavior.
extension View {
    func onChange<V: Equatable>(of value: V, _ action: @escaping (V, V) -> Void) -> some View { self }
}
