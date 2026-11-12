import SwiftUI
import AppKit
import WebKit
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class MacModel: ObservableObject {
    static let shared = MacModel()

    @Published var isSetUp = Store.isSetUp
    /// "local" (plans in a file on this Mac), "server", or "" (not chosen yet)
    @Published var mode = Store.mode
    @Published var plans: [Planned] = []
    @Published var tick = Date()
    @Published var focusEnd: Date?
    @Published var focusTitle = ""
    @Published var offline = false

    let host = WebHost()
    var isLocal: Bool { mode == "local" }
    private var timer: Timer?
    private var lastRefresh = Date.distantPast
    private var shown = Set<String>()
    private var snoozed: [(PopupInfo, Date)] = []

    // MARK: what's happening

    var current: Planned? {
        let now = tick
        return plans.first { ($0.item.done ?? 0) == 0 && $0.start <= now && now < $0.end }
    }

    var upcoming: [Planned] {
        let now = tick
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return plans.filter { ($0.item.done ?? 0) == 0 && $0.start > now && $0.start < endOfDay }
    }

    /// Short text for the menu bar, e.g. "🧹 12m" or "⏳ 8m".
    var menuTitle: String? {
        let now = tick
        if let f = focusEnd, f > now {
            return "⏳ \(minutesText(f.timeIntervalSince(now)))"
        }
        if let c = current {
            return "\(c.item.emoji ?? "•") \(minutesText(c.end.timeIntervalSince(now)))"
        }
        if let n = upcoming.first, n.start.timeIntervalSince(now) <= 60 * 60 {
            return "Next \(n.item.start)"
        }
        return nil
    }

    func minutesText(_ seconds: TimeInterval) -> String {
        let m = Int(ceil(seconds / 60))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    // MARK: lifecycle

    func start() {
        guard timer == nil else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in MacModel.shared.onTick() }
        }
        if isSetUp { host.load(mode: mode) }
    }

    private func onTick() {
        tick = Date()
        if tick.timeIntervalSince(lastRefresh) > 180 {
            Task { await refresh() }
        }
        checkPopups()
    }

    func refresh() async {
        guard isSetUp else { return }
        lastRefresh = Date()
        do {
            let data = try await call("GET", "/api/upcoming")
            let p = try JSONDecoder().decode(UpcomingPayload.self, from: data)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: p.tz ?? TimeZone.current.identifier) ?? .current
            f.dateFormat = "yyyy-MM-dd HH:mm"
            plans = p.items.compactMap { item in
                guard let s = f.date(from: "\(item.date) \(item.start)") else { return nil }
                return Planned(item: item, start: s, end: s.addingTimeInterval(TimeInterval(item.duration * 60)))
            }.sorted { $0.start < $1.start }
            if let fi = p.focus {
                let end = Date(timeIntervalSince1970: fi.end / 1000)
                if end > Date() { focusEnd = end; focusTitle = fi.title ?? "" }
            }
            offline = false
            tick = Date()
            scheduleBanners()
            checkPopups()
        } catch {
            offline = true
        }
    }

    // MARK: pop-ups

    private func checkPopups() {
        guard isSetUp else { return }
        let now = Date()
        let window: TimeInterval = 10 * 60

        if let due = snoozed.first(where: { $0.1 <= now }) {
            snoozed.removeAll { $0.1 <= now }
            show(due.0)
            return
        }
        if let f = focusEnd, f <= now {
            focusEnd = nil
            if now.timeIntervalSince(f) < window {
                show(PopupInfo(kind: .focusEnd, heading: "Focus time is up", title: focusTitle.isEmpty ? "Nice work" : focusTitle,
                               detail: "Take a breath, stretch, have some water.", emoji: "🌿", color: "#73CBA8", plan: nil, next: upcoming.first))
            }
            return
        }
        for p in plans where (p.item.done ?? 0) == 0 {
            let remind = p.item.remind ?? 0
            var events: [(PopupKind, Date)] = []
            if remind > 0 { events.append((.before, p.start.addingTimeInterval(TimeInterval(-remind * 60)))) }
            if remind >= 0 { events.append((.start, p.start)) }
            if (p.item.end_alert ?? 0) == 1 && p.item.duration >= 10 { events.append((.end, p.end.addingTimeInterval(-300))) }
            for (kind, when) in events {
                let key = "\(p.item.id)-\(kind)-\(p.item.date)-\(p.item.start)"
                guard now >= when, now.timeIntervalSince(when) < window, !shown.contains(key) else { continue }
                shown.insert(key)
                let next = plans.first { $0.start >= p.end.addingTimeInterval(-60) && $0.id != p.id && ($0.item.done ?? 0) == 0 }
                switch kind {
                case .before:
                    show(PopupInfo(kind: .before, heading: "Coming up in \(remind) min", title: p.item.title,
                                   detail: "At \(p.item.start) · \(p.item.duration) min. A good moment to finish what you’re doing.",
                                   emoji: p.item.emoji ?? "📝", color: p.item.color ?? "#7CB8F0", plan: p, next: nil))
                case .start:
                    show(PopupInfo(kind: .start, heading: "Time to start", title: p.item.title,
                                   detail: "\(p.item.duration) min · until \(timeText(p.end))",
                                   emoji: p.item.emoji ?? "📝", color: p.item.color ?? "#7CB8F0", plan: p, next: next))
                case .end:
                    show(PopupInfo(kind: .end, heading: "5 minutes left", title: p.item.title,
                                   detail: next.map { "Start wrapping up. Next: \($0.label) at \($0.item.start)" } ?? "Start wrapping up.",
                                   emoji: p.item.emoji ?? "📝", color: p.item.color ?? "#7CB8F0", plan: p, next: next))
                default:
                    break
                }
                return
            }
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    func show(_ info: PopupInfo) {
        guard Store.popups || info.kind == .test else { return }
        PopupController.shared.show(info)
    }

    func snooze(_ info: PopupInfo, minutes: Int = 5) {
        snoozed.append((info, Date().addingTimeInterval(TimeInterval(minutes * 60))))
    }

    func testPopup() {
        show(PopupInfo(kind: .test, heading: "This is a Pacely pop-up", title: "Make a cup of tea",
                       detail: "Pop-ups appear at the start of activities, 5 minutes before the end, and when focus time is up.",
                       emoji: "☕", color: "#D9B99B", plan: nil, next: nil))
    }

    // MARK: actions

    /// Talks to wherever the plans are kept: the on-Mac engine, or the server.
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        if isLocal {
            let text = try await host.js("await LOCAL.ready; return JSON.stringify(await LOCAL.call(m, p, b));",
                                         ["m": method, "p": path, "b": body ?? NSNull()])
            return Data(text.utf8)
        }
        return try await API.request(path, method: method, body: body)
    }

    func markDone(_ p: Planned) async {
        guard p.canTick else { return }
        _ = try? await call("PUT", "/api/activities/\(p.item.id)", ["done": true, "scope": "this"])
        await refresh()
        reloadWeb()
    }

    func shift(minutes: Int) async {
        _ = try? await call("POST", "/api/shift", ["minutes": minutes])
        await refresh()
        reloadWeb()
    }

    func startFocus(_ p: Planned) {
        openMainWindow()
        let js = "(async()=>{try{S.date=S.today;S.view='today';await loadDay();const it=findItem(\(p.item.id));if(it)startFocusFor(it)}catch(e){}})()"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.host.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func reloadWeb() {
        host.webView?.evaluateJavaScript("try{refresh()}catch(e){}", completionHandler: nil)
    }

    /// Set by the menu bar label, which can open SwiftUI windows.
    var openMain: (() -> Void)?
    var openPrefs: (() -> Void)?

    func openMainWindow() {
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: where plans are kept

    /// Connected to a server (from the setup screen).
    func didSetUp() {
        Store.mode = "server"
        mode = "server"
        isSetUp = true
        host.load(mode: "server")
    }

    /// Keep plans on this Mac. Pass a backup file's text to start from it.
    func chooseLocal(from fileText: String? = nil) {
        if let t = fileText {
            LocalStore.safetyCopy("before-loading-a-file")
            LocalStore.write(t)
        }
        Store.mode = "local"
        mode = "local"
        isSetUp = true
        plans = []
        host.load(mode: "local")
    }

    /// Go back to the "where should Pacely keep your plans?" screen. Nothing is deleted.
    func changeStorage() {
        let a = NSAlert()
        a.messageText = "Change where your plans are kept?"
        a.informativeText = isLocal
            ? "Your plans on this Mac stay safe in their file. You can come back to them any time, or save a copy first with File › Export Database."
            : "You'll be logged out of your server on this Mac. Your plans stay on the server."
        a.addButton(withTitle: "Change")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if isLocal { flushLocal() } else { Store.token = "" }
        Store.mode = ""
        mode = ""
        isSetUp = false
        plans = []
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        openMainWindow()
    }

    func signOut() {
        Store.token = ""
        Store.mode = ""
        mode = ""
        isSetUp = false
        plans = []
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    // MARK: File menu: export and import

    private func say(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private var backupName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "pacely-backup-\(f.string(from: Date())).json"
    }

    func exportDatabase() {
        guard isSetUp else { say("Nothing to save yet", "Choose where Pacely keeps your plans first."); return }
        Task {
            do {
                let text: String
                if isLocal {
                    text = try await host.js("await LOCAL.ready; return LOCAL.exportText();")
                } else {
                    text = String(decoding: try await API.request("/api/export"), as: UTF8.self)
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = backupName
                panel.allowedContentTypes = [.json]
                panel.message = "Save a copy of all your plans. You can load it on another Mac or PC, or into a Pacely server."
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try text.write(to: url, atomically: true, encoding: .utf8)
                if isLocal { _ = try? await host.js("LOCAL.markBackedUp(); return '';") }
            } catch {
                say("Couldn't save a copy", error.localizedDescription)
            }
        }
    }

    /// Pick a backup file, then choose Merge or Replace.
    func importDatabase() {
        guard isSetUp else { say("Choose where to keep your plans first", "Then you can load a file."); return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Pacely backup file"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard let text = LocalStore.validBackup(data) else {
            say("That isn't a Pacely backup", "Choose a file made with Export Database or Pacely's Save a copy button.")
            return
        }
        let a = NSAlert()
        a.messageText = "Add this file to your plans, or replace them?"
        a.informativeText = "Merge keeps everything you have now and adds anything new from the file.\n\nReplace swaps your plans for the ones in the file. A copy of your current plans is kept first."
        a.addButton(withTitle: "Merge")
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        let choice = a.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let mode = choice == .alertFirstButtonReturn ? "merge" : "replace"
        if isLocal && mode == "replace" { flushLocal(); LocalStore.safetyCopy("before-replace") }
        Task {
            do {
                let obj: [String: Any]
                if isLocal {
                    let r = try await host.js("const r = await window.pacelyImport(t, m); return JSON.stringify(r);", ["t": text, "m": mode])
                    obj = (try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any]) ?? [:]
                } else {
                    obj = try await importToServer(text, mode: mode)
                    reloadWeb()
                }
                let n = (obj["activities"] as? Int) ?? 0
                say(mode == "merge" ? "Merged" : "Replaced",
                    mode == "merge" ? "\(n) new activit\(n == 1 ? "y was" : "ies were") added. Everything you had is still there." : "Your plans now match the file.")
                await refresh()
            } catch {
                say("That file didn't load", error.localizedDescription)
            }
        }
    }

    /// Sends a backup file to the server. Older servers can only replace, so merging is checked first.
    private func importToServer(_ text: String, mode: String) async throws -> [String: Any] {
        if mode == "merge" {
            let me = try await API.request("/api/me")
            let info = (try? JSONSerialization.jsonObject(with: me) as? [String: Any]) ?? [:]
            let feats = info["features"] as? [String] ?? []
            guard feats.contains("merge") else {
                throw APIError.message("Your server needs updating before it can merge files. Choose Replace, or update the server first (run the install line again on the server).")
            }
        }
        guard var body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw APIError.message("That file isn't a Pacely backup.")
        }
        body["mode"] = mode
        let r = try await API.request("/api/import", method: "POST", body: body)
        return (try? JSONSerialization.jsonObject(with: r) as? [String: Any]) ?? [:]
    }

    /// Writes any unsaved on-Mac changes straight away (used when quitting).
    func flushLocal() {
        guard isLocal, let wv = host.webView else { return }
        wv.evaluateJavaScript("LOCAL.flush()") { result, _ in
            if let t = result as? String, !t.isEmpty { LocalStore.write(t) }
        }
    }

    func quit(_ reply: @escaping () -> Void) {
        guard isLocal, let wv = host.webView else { reply(); return }
        var done = false
        let finish = { if !done { done = true; reply() } }
        wv.evaluateJavaScript("LOCAL.flush()") { result, _ in
            if let t = result as? String, !t.isEmpty { LocalStore.write(t) }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }
    }

    /// Messages from the web app inside this window.
    func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String ?? "" {
        case "changed":
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refresh()
            }
        case "focus":
            let endMs = (msg["end"] as? NSNumber)?.doubleValue ?? 0
            focusEnd = Date(timeIntervalSince1970: endMs / 1000)
            let emoji = msg["emoji"] as? String ?? "⏳"
            focusTitle = "\(emoji) \(msg["title"] as? String ?? "Focus")"
            tick = Date()
        case "focusStop":
            focusEnd = nil
            tick = Date()
        case "exportDb":
            exportDatabase()
        case "importDb":
            importDatabase()
        case "changeStorage":
            changeStorage()
        case "settings":
            openPrefs?()
            NSApp.activate(ignoringOtherApps: true)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(msg["text"] as? String ?? "", forType: .string)
        case "open":
            if let s = msg["url"] as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        case "logout":
            signOut()
        default:
            break
        }
    }

    // MARK: notification banners (used when pop-ups are switched off)

    private func scheduleBanners() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard Store.banners else { return }
        let now = Date()
        var n = 0
        for p in plans where (p.item.done ?? 0) == 0 {
            let remind = p.item.remind ?? 0
            var list: [(String, Date, String, String)] = []
            if remind > 0 { list.append(("before", p.start.addingTimeInterval(TimeInterval(-remind * 60)), "Coming up in \(remind) min", p.label)) }
            if remind >= 0 { list.append(("start", p.start, "Time to start", p.label)) }
            if (p.item.end_alert ?? 0) == 1 && p.item.duration >= 10 { list.append(("end", p.end.addingTimeInterval(-300), "5 minutes left", "\(p.label) – start wrapping up")) }
            for (kind, when, title, body) in list where when > now && n < 60 {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                c.sound = Store.sound ? .default : nil
                let trig = UNTimeIntervalNotificationTrigger(timeInterval: max(1, when.timeIntervalSinceNow), repeats: false)
                center.add(UNNotificationRequest(identifier: "pacely-\(p.item.id)-\(kind)", content: c, trigger: trig))
                n += 1
            }
        }
    }
}
