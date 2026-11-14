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
        check(Set(destinations.map(\.title)).count == destinations.count, "Each page needs a distinct title")
        for destination in destinations {
            for section in SettingsSection.allCases {
                // Settings open over the page, so opening and switching sections must keep the page to return to.
                settings.present(section, returningTo: destination)
                check(settings.isPresented && settings.selectedSection == section, "Settings must show the requested section")
                settings.present(.general, returningTo: .welcome)
                check(settings.dismiss() == destination, "Closing must return to the original page")
                check(!settings.isPresented, "Closing must hide Settings")
            }
        }

        // The settings popup keeps a fixed minimum, grows with the window up to a cap,
        // and fits inside any window at or above the size the app enforces while it is open.
        let popupMinimum = SettingsPopupLayout.minimumSize
        let popupMaximum = SettingsPopupLayout.maximumSize
        let openWindowMinimum = SettingsPopupLayout.minimumWindowContentSize
        for width in stride(from: 300, through: 3000, by: 7) {
            for height in stride(from: 200, through: 2000, by: 11) {
                let popup = SettingsPopupLayout(windowContentSize: CGSize(width: width, height: height))
                check(popup.width >= popupMinimum.width && popup.height >= popupMinimum.height, "Popup must never shrink below its minimum")
                check(popup.width <= popupMaximum.width && popup.height <= popupMaximum.height, "Popup must stop growing at its cap")
                if CGFloat(width) >= openWindowMinimum.width, CGFloat(height) >= openWindowMinimum.height {
                    check(popup.width <= CGFloat(width) && popup.height <= CGFloat(height), "Popup must stay inside the window")
                }
            }
        }
        check(SettingsPopupLayout(windowContentSize: openWindowMinimum).width == popupMinimum.width, "Smallest allowed window shows the minimum popup")
        let openWindow = SettingsPopupLayout.minimumWindowSize
        check(openWindow.width <= 1280 && openWindow.height <= 700, "The window size needed for Settings must fit the smallest supported screen")
        check(SettingsPopupLayout(windowContentSize: CGSize(width: 1400, height: 900)).width > popupMinimum.width, "Bigger windows get a bigger popup")
        check(SettingsPopupLayout(windowContentSize: CGSize(width: 4000, height: 3000)).width == popupMaximum.width, "Huge windows stop at the cap")

        // Clicking the page behind the popup closes it; the title bar and window edges do not.
        let behindPopup = CGRect(x: 0, y: 0, width: 980, height: 600)
        check(SettingsPopupLayout.isDismissingClick(at: CGPoint(x: 20, y: 300), windowContent: behindPopup), "A click on the page behind the popup closes it")
        check(!SettingsPopupLayout.isDismissingClick(at: CGPoint(x: 400, y: 630), windowContent: behindPopup), "A title bar click must still move the window")
        for edge in [CGPoint(x: 2, y: 300), CGPoint(x: 978, y: 300), CGPoint(x: 400, y: 3), CGPoint(x: 977, y: 4)] {
            check(!SettingsPopupLayout.isDismissingClick(at: edge, windowContent: behindPopup), "An edge click must still resize the window")
        }

        // The top bar counts as outside the popup, except the window buttons and the resize edge.
        let frame = CGRect(x: 0, y: 0, width: 980, height: 652)
        let content = CGRect(x: 0, y: 0, width: 980, height: 600)
        check(SettingsPopupLayout.isTopBarPress(at: CGPoint(x: 500, y: 626), windowFrame: frame, windowContent: content), "A press on the top bar is recognised")
        check(!SettingsPopupLayout.isTopBarPress(at: CGPoint(x: 30, y: 626), windowFrame: frame, windowContent: content), "The window buttons are left alone")
        check(!SettingsPopupLayout.isTopBarPress(at: CGPoint(x: 500, y: 650), windowFrame: frame, windowContent: content), "The top resize edge is left alone")
        check(!SettingsPopupLayout.isTopBarPress(at: CGPoint(x: 500, y: 300), windowFrame: frame, windowContent: content), "The page area is not the top bar")

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
        print("Page presentation: \(checks) checks passed (navigation non-effects, Settings open and close, adaptive layout)")
    }
}
