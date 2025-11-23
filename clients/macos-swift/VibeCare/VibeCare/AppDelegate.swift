//
//  AppDelegate.swift
//  VibeCare
//
//  Handles application lifecycle events and ensures proper window focus on launch.
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to regular app (shows in Dock and can be focused)
        NSApp.setActivationPolicy(.regular)

        // Activate the app to bring it to the foreground and accept keyboard input
        NSApp.activate(ignoringOtherApps: true)

        // Make sure the main window is key and front
        // Small delay to ensure SwiftUI has finished creating the window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When clicking app icon in Dock, bring window to front if it exists
        if !flag {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
