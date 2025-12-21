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
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var theme = AppTheme.dark

    init() {
        // Use the shared singleton instance
        _appServices = StateObject(wrappedValue: AppServices.shared)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(self.menuBarManager)
                .environmentObject(self.appServices)
                .appTheme(self.theme)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentSize)
    }
}
