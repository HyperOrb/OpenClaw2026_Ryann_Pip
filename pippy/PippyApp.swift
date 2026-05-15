//
//  PippyApp.swift
//  pippy
//
//  Notch/overlay-first companion app. Pip surfaces live above apps and are
//  driven by NSPanel overlays instead of a dock window.
//

import ServiceManagement
import SwiftUI

@main
struct PippyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Manages companion lifecycle and startup behavior for the dock app shell.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    let companionManager = CompanionManager()
    private var hasStartedCompanion = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🐶 Pip: Starting...")
        print("🐶 Pip: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        PipAnalytics.configure()
        PipAnalytics.trackAppOpened()

        NSApp.setActivationPolicy(.accessory)
        activateCompanionIfNeeded()
        registerAsLoginItemIfNeeded()
    }

    func activateCompanionIfNeeded() {
        guard !hasStartedCompanion else { return }
        companionManager.start()
        hasStartedCompanion = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🐶 Pip: Registered as login item")
            } catch {
                print("⚠️ Pip: Failed to register as login item: \(error)")
            }
        }
    }

}
