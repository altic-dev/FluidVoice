//
//  fluidApp.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import ApplicationServices
import SwiftUI

@main
struct FluidApp: App {
    @StateObject private var menuBarManager = MenuBarManager()
    @StateObject private var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Use the shared singleton instance
        _appServices = StateObject(wrappedValue: AppServices.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(self.menuBarManager)
                .environmentObject(self.appServices)
                .appTheme(AppTheme.dark(accent: self.settings.accentColor))
                .preferredColorScheme(.dark)
                .frame(minWidth: 800, idealWidth: 1000, minHeight: 500, idealHeight: 700)
        }
    }
}
