//
//  fluidApp.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import SwiftUI
import AppKit
import ApplicationServices

@main
struct fluidApp: App {
    @StateObject private var menuBarManager = MenuBarManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showWhatsNew = false
    @State private var theme = AppTheme.dark

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(menuBarManager)
                .appTheme(theme)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $showWhatsNew) {
                    WhatsNewView()
                        .appTheme(theme)
                }
                .onAppear {
                    // Check if we should show what's new after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showWhatsNew = SettingsStore.shared.shouldShowWhatsNew()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowWhatsNew"))) { _ in
                    showWhatsNew = true
                }
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentSize)
    }
}
