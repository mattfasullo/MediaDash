//
//  MediaDashApp.swift
//  MediaDash
//
//  Created by Matt Fasullo on 2025-11-18.
//

import SwiftUI

@main
struct MediaDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            GatekeeperView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView()
            }
        }
    }
}

struct CheckForUpdatesView: View {
    var body: some View {
        Button("Check for Updates...") {
            // After adding Sparkle SPM package, this will work
            NSApplication.shared.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("u", modifiers: [.command])
    }
}
