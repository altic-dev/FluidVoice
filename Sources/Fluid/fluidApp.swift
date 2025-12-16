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
    @StateObject private var appServices = AppServices.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var theme = AppTheme.dark

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(menuBarManager)
                .environmentObject(appServices)
                .appTheme(theme)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentSize)
    }
}
