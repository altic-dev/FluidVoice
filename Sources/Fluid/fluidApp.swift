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
    @ObservedObject private var settings = SettingsStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
                if MeetingExternalReferenceTrialAGate.autorunEnabled(environment: ProcessInfo.processInfo.environment)
                    || MeetingSCKPairedDiagnosticGate.autorunEnabled()
                    || ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"] != nil
                    || ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1"
                {
                    Color.clear
                } else {
                    self.applicationContent
                }
            #else
                self.applicationContent
            #endif
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    self.menuBarManager.openPreferencesFromUI()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var applicationContent: some View {
        AdaptiveAppTheme(accent: self.settings.accentColor) {
            ContentView()
                .environmentObject(self.menuBarManager)
                // Resolve the singleton only when the normal application content branch is built.
                // The DEBUG C2 autorun branch returns Color.clear before this view is evaluated.
                .environmentObject(AppServices.shared)
        }
    }
}
