import Foundation
import SwiftUI

@main
struct PagePresentationTests {
    @MainActor
    static func main() {
        let destinations: [SidebarItem] = [
            .welcome, .history, .stats, .voiceEngine, .aiEnhancements, .cleanupStyles,
            .customDictionary, .commandMode, .fileTranscription, .meetingTranscription,
            .feedback, .changelog, .rewriteMode,
        ]
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }

        var settings = SettingsNavigationState()
        check(AppPagePresentation(destination: nil, settings: settings).title == "Dashboard", "Missing destination must have a useful title")
        check(Set(destinations.map(\.title)).count == destinations.count, "Each page needs a distinct title")
        for destination in destinations {
            let initial = settings
            let page = AppPagePresentation(destination: destination, settings: settings)
            check(page.title == destination.title && page.showsPageActions, "Destination chrome must be current")
            check(settings == initial, "Reading chrome must not mutate navigation")
            for section in SettingsSection.allCases {
                settings.present(section, returningTo: destination)
                let snapshot = settings
                // Simulate a stale underlying destination while Settings is visible.
                for hiddenDestination in destinations {
                    let hidden = AppPagePresentation(destination: hiddenDestination, settings: settings)
                    check(hidden.title == section.title, "Hidden content must not change the Settings title")
                    check(!hidden.showsPageActions, "Hidden page actions must not leak into Settings")
                    check(settings == snapshot, "Presentation must not change the return destination")
                }
                check(settings.dismiss() == destination, "Back must retain its original destination")
                let restored = AppPagePresentation(destination: destination, settings: settings)
                check(restored == page, "Rapid Settings/Back changes must not retain stale chrome")
            }
        }

        // Geometry checks use production layout code, including the capped width.
        for width in stride(from: 320, through: 2000, by: 1) {
            let layout = DashboardLayout(width: CGFloat(width))
            if layout.hasActionColumn {
                check(layout.mainWidth >= 640, "Action column must not squeeze main content")
            }
            for count in 1...3 {
                let columns = layout.setupColumns(count: count)
                check(count % columns == 0, "Setup rows must remain complete")
                if columns > 1 {
                    check((layout.contentWidth - CGFloat(count - 1) * 10) / CGFloat(count) >= 280, "Setup cards must remain readable")
                }
            }
        }
        var environment = EnvironmentValues()
        check(environment.fluidPageToolbarVisible, "Standalone page actions should default to visible")
        environment.fluidPageToolbarVisible = false
        check(!environment.fluidPageToolbarVisible, "Mounted hidden pages must suppress toolbar contribution")
        check(EnvironmentValues().fluidPageToolbarVisible, "Toolbar visibility must not leak into another view environment")
        print("Page presentation: \(checks) checks passed (navigation non-effects, hidden actions, rapid Settings/Back, adaptive layout)")
    }
}
