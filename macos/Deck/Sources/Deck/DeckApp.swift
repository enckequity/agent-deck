import AppKit
import SwiftUI
import UserNotifications

@main
struct DeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("Deck", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { store.newTask() }
                    .keyboardShortcut("n")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in Store.shared.start() }
    }

    /// Keep running with the window closed so notifications still arrive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(NSApp.isActive ? [] : [.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String
        Task { @MainActor in
            if let id { Store.shared.selection = id }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            completionHandler()
        }
    }
}
