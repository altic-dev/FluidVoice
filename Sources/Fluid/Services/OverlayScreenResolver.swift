//
//  OverlayScreenResolver.swift
//  Fluid
//

import AppKit

enum OverlayScreenResolver {
    static func screenForCurrentPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(location)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
