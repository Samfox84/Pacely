import SwiftUI
import UserNotifications
import BackgroundTasks
import WebKit
import UIKit

@main
struct PacelyApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    private let notificationDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        SoundPlayer.shared.prepare()
        // Lock Screen buttons (Done, Running late) talk to the on-phone engine in "Just this phone" mode
        PacelyServer.localHandler = { path, method, body in
            guard Store.localOnly else { return nil }
            return try? await LocalEngine.shared.request(path, method: method, body: body)
        }
        Task.detached(priority: .userInitiated) { ReadingFont.register() }   // off the main thread, so opening never stutters
        // Watch and Calendar set-up can take a few seconds the first time: do it in the background,
        // a moment after opening, so the first screen and the keyboard are never held up
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            WatchLink.shared.activate()
            CalendarSync.startWatchingChanges()
        }
        PacelyHooks.refresh = { await Scheduler.refresh() }
        NotificationDelegate.registerActions()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Let your day appear first; reminders, widgets and the watch catch up a moment later
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await Scheduler.refresh() }
            } else if phase == .background {
                Scheduler.scheduleAppRefresh()
            }
        }
        .backgroundTask(.appRefresh(Store.refreshID)) {
            await Scheduler.refresh()
            Scheduler.scheduleAppRefresh()
        }
    }
}

/// Shows reminders as banners even while Pacely is open, and handles the buttons on them
/// (press and hold a reminder, or swipe it down): Done, Running late, Remind me in 10 min.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let category = "pacely-activity"

    static func registerActions() {
        let done = UNNotificationAction(identifier: "done", title: "Done", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let late = UNNotificationAction(identifier: "late", title: "Running late (10 min)", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        let snooze = UNNotificationAction(identifier: "snooze", title: "Remind me in 10 min", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "bell"))
        let cat = UNNotificationCategory(identifier: category, actions: [done, late, snooze], intentIdentifiers: [],
                                         options: [.hiddenPreviewsShowTitle])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let req = response.notification.request
        let id = req.identifier
        // pacely-a12-start -> 12
        let parts = id.replacingOccurrences(of: "pacely-a", with: "").split(separator: "-")
        let itemId = parts.count >= 2 ? Int(parts.dropLast().joined(separator: "-")) ?? 0 : 0
        let action = response.actionIdentifier
        Task {
            switch action {
            case "done" where itemId > 0:
                await PacelyServer.send("/api/activities/\(itemId)", method: "PUT", body: ["done": true, "scope": "this"])
                await MainActor.run { clearNotifications(forItem: itemId) }
            case "late":
                await PacelyServer.send("/api/shift", method: "POST", body: ["minutes": 10])
            case "snooze":
                let c = (req.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
                c.title = "Reminder: " + req.content.title.replacingOccurrences(of: "Reminder: ", with: "")
                try? await center.add(UNNotificationRequest(identifier: id + "-snooze", content: c,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)))
            default:
                break
            }
            await MainActor.run { center.removeDeliveredNotifications(withIdentifiers: [id]) }
            await PacelyHooks.afterChange()
            if action == "done" || action == "late" {
                await MainActor.run { Planner.shared.say(action == "done" ? "Done" : "Moved the rest of today back 10 min"); Task { await Planner.shared.load() } }
            }
            completionHandler()
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isSetUp = Store.isSetUp || Store.isPartner
    @Published var showSettings = false
    @Published var showDictation = false
    @Published var joinMessage: String?
    @Published var webReload = UUID()
    private var refreshTask: Task<Void, Never>?

    func didSetUp() {
        isSetUp = true
        webReload = UUID()
        Task {
            await Scheduler.requestPermission()
            await Scheduler.refresh()
        }
    }

    func signOut() {
        Store.localOnly = false          // the plan file stays on the phone, so choosing "Just this phone" again brings it back
        Store.token = ""
        Store.partnerToken = ""
        Store.widgetCode = ""
        LocalCopy.clear()
        isSetUp = false
        showSettings = false
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        Task { await LiveActivityManager.shared.endAll() }
    }

    /// Messages sent by the web app inside the Pacely app.
    func handle(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        switch type {
        case "changed":
            refreshTask?.cancel()
            refreshTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await Scheduler.refresh()
            }
        case "focus":
            let endMs = (msg["end"] as? NSNumber)?.doubleValue ?? 0
            let startMs = (msg["start"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            let end = Date(timeIntervalSince1970: endMs / 1000)
            let start = Date(timeIntervalSince1970: startMs / 1000)
            let title = msg["title"] as? String ?? "Focus"
            let emoji = msg["emoji"] as? String ?? "⏳"
            let color = msg["color"] as? String ?? "#73CBA8"
            let itemId = (msg["itemId"] as? NSNumber)?.intValue ?? 0
            Task {
                await LiveActivityManager.shared.startFocus(title: title, emoji: emoji, colorHex: color, start: start, end: end, itemId: itemId)
                await Scheduler.scheduleFocusEnd(at: end, title: "\(emoji) \(title)")
            }
        case "focusStop":
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pacely-focus"])
            Task {
                await LiveActivityManager.shared.endFocus()
                await Scheduler.refresh()
            }
        case "settings":
            showSettings = true
        case "haptic":
            switch msg["style"] as? String ?? "medium" {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            default: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case "share":
            let text = msg["text"] as? String ?? ""
            if !text.isEmpty { presentShare([text]) }
        case "dictate":
            showDictation = true
        case "calm":
            PacelyPrefs.calm = msg["on"] as? Bool ?? false
            Task { await Scheduler.refresh() }
        case "copy":
            UIPasteboard.general.string = msg["text"] as? String ?? ""
        case "open":
            if let s = msg["url"] as? String, let u = URL(string: s) {
                UIApplication.shared.open(u)
            }
        case "logout":
            signOut()
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.isSetUp {
                MainView()
            } else {
                SetupView()
            }
        }
        .onOpenURL { url in
            // pacely://join?server=…&code=…  from a partner invite
            guard url.host == "join" else { return }
            Task { await PartnerAPI.join(url.absoluteString, state: state) }
        }
        .alert(state.joinMessage ?? "", isPresented: Binding(get: { state.joinMessage != nil }, set: { if !$0 { state.joinMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $state.showSettings) {
            NativeSettingsView()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showDictation) {
            DictationView { text in
                let js = "window.pacelyDictated && window.pacelyDictated(\(jsString(text)))"
                NotificationCenter.default.post(name: .pacelyRunJS, object: js)
            }
            .presentationDetents([.medium])
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if Store.isPartner { PartnerRootView().id(state.webReload) } else { RootTabView().id(state.webReload) }
    }
}


/// Shows the iPhone share sheet (Messages, WhatsApp, Gemini, Copy…).
@MainActor
func presentShare(_ items: [Any]) {
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    if let pop = vc.popoverPresentationController, let view = top?.view {
        pop.sourceView = view
        pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }
    top?.present(vc, animated: true)
}

/// Safely puts text inside a JavaScript call.
func jsString(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(arr.dropFirst().dropLast())
}
