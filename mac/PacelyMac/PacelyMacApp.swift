import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

@main
struct PacelyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MacModel.shared

    var body: some Scene {
        Window("Pacely", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 420, minHeight: 560)
        }
        .defaultSize(width: 520, height: 820)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Export Database…") { model.exportDatabase() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Database…") { model.importDatabase() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Show Backups Folder") {
                    try? FileManager.default.createDirectory(at: LocalStore.backupsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(LocalStore.backupsFolder)
                }
                Button("Change Where Plans Are Kept…") { model.changeStorage() }
            }
        }

        Window("Pacely Settings", id: "prefs") {
            MacSettingsView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            MenuLabel()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await MacModel.shared.refresh() }
        }
        Task { @MainActor in MacModel.shared.start() }
    }

    /// Closing the window keeps Pacely running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Save anything not yet written before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            MacModel.shared.quit { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

struct RootView: View {
    @EnvironmentObject var model: MacModel
    @State private var connecting = false

    var body: some View {
        Group {
            if model.isSetUp {
                MacWebView(model: model)
            } else if connecting || (model.mode == "server") {
                MacSetupView(back: { connecting = false; Store.mode = ""; model.mode = "" })
            } else {
                MacWelcomeView(connect: { connecting = true })
            }
        }
        .onChange(of: model.isSetUp) { ok in if ok { connecting = false } }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            print("Login item change failed:", error)
        }
    }
}
