import SwiftUI

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: AppTheme = .dark
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies an app theme to the view hierarchy.
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.theme, theme)
    }
}






