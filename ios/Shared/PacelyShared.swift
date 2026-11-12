// Shared between the Pacely app and its widget extension.
import Foundation
import SwiftUI
import ActivityKit
import AppIntents
import UserNotifications
import WidgetKit

/// Live Activity data: shown on the Lock Screen and in the Dynamic Island.
struct PacelyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var emoji: String
        var colorHex: String
        var start: Date
        var end: Date
        /// "focus" for a focus timer, "now" for an activity
        var kind: String
        /// Pacely activity id, or 0 when there is nothing to tick off
        var itemId: Int = 0
        /// What comes after this one, e.g. "🥣 Breakfast" and "10:30"
        var nextTitle: String = ""
        var nextStart: String = ""
        /// When this Live Activity was put on screen (used for "starts in" countdowns)
        var shown: Date = Date()
        /// Calm countdown: show "until 9:15" instead of a ticking clock
        var calm: Bool? = nil
        var isCalm: Bool { calm ?? false }

        var range: ClosedRange<Date> {
            let safeEnd = end > start ? end : start.addingTimeInterval(1)
            return start...safeEnd
        }
        var untilStart: ClosedRange<Date> {
            let s = shown < start ? shown : start.addingTimeInterval(-1)
            return s...start
        }
        /// Same activity, ignoring when it was shown.
        func sameAs(_ o: ContentState) -> Bool {
            title == o.title && emoji == o.emoji && colorHex == o.colorHex && start == o.start && end == o.end &&
                kind == o.kind && itemId == o.itemId && nextTitle == o.nextTitle && nextStart == o.nextStart && isCalm == o.isCalm
        }
    }
    var name: String
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        if s.count == 6, Scanner(string: s).scanHexInt64(&v) {
            // parsed
        } else {
            v = 0x7CB8F0
        }
        self.init(red: Double((v >> 16) & 0xFF) / 255.0,
                  green: Double((v >> 8) & 0xFF) / 255.0,
                  blue: Double(v & 0xFF) / 255.0)
    }
}

/// What the server's /api/widget endpoint returns.
struct WidgetItem: Codable, Hashable {
    let id: Int?
    let title: String
    let emoji: String
    let color: String
    let start: String?
    let startTs: Double
    let endTs: Double
    let done: Bool
    let steps: Int
    let stepsDone: Int

    var startDate: Date { Date(timeIntervalSince1970: startTs) }
    var endDate: Date {
        let e = Date(timeIntervalSince1970: endTs)
        return e > startDate ? e : startDate.addingTimeInterval(60)
    }
    var range: ClosedRange<Date> { startDate...endDate }
}

struct WidgetFocus: Codable, Hashable {
    let title: String
    let startTs: Double
    let endTs: Double
    let color: String
    var startDate: Date { Date(timeIntervalSince1970: startTs) }
    var endDate: Date { Date(timeIntervalSince1970: max(endTs, startTs + 1)) }
    var range: ClosedRange<Date> { startDate...endDate }
}

struct WidgetPayload: Codable, Hashable {
    let now: WidgetItem?
    let next: [WidgetItem]
    let done: Int
    let total: Int
    let date: String
    var focus: WidgetFocus? = nil

    /// Recalculate "now" and "next" for a later moment, so the widget moves on by itself.
    func advanced(to t: Date) -> WidgetPayload {
        var all: [WidgetItem] = []
        if let n = now { all.append(n) }
        all.append(contentsOf: next)
        all.sort { $0.startTs < $1.startTs }
        let cur = all.first { $0.startDate <= t && t < $0.endDate && !$0.done }
        let upcoming = all.filter { $0.startDate > t && !$0.done }
        let f = (focus?.endDate ?? .distantPast) > t ? focus : nil
        return WidgetPayload(now: cur, next: upcoming, done: done, total: total, date: date, focus: f)
    }

    static var sample: WidgetPayload {
        let n = Date()
        return WidgetPayload(
            now: WidgetItem(id: 0, title: "Get dressed", emoji: "👕", color: "#B89AE8", start: "08:00",
                            startTs: n.addingTimeInterval(-300).timeIntervalSince1970,
                            endTs: n.addingTimeInterval(600).timeIntervalSince1970, done: false, steps: 3, stepsDone: 1),
            next: [
                WidgetItem(id: 0, title: "Breakfast", emoji: "🥣", color: "#F4A07A", start: "08:15",
                           startTs: n.addingTimeInterval(600).timeIntervalSince1970,
                           endTs: n.addingTimeInterval(1800).timeIntervalSince1970, done: false, steps: 0, stepsDone: 0),
                WidgetItem(id: 0, title: "Pack bag", emoji: "🎒", color: "#73CBA8", start: "08:35",
                           startTs: n.addingTimeInterval(1800).timeIntervalSince1970,
                           endTs: n.addingTimeInterval(2100).timeIntervalSince1970, done: false, steps: 4, stepsDone: 0)
            ],
            done: 2, total: 6, date: "")
    }
}

/// The link baked into the build (Config/widget-link.txt), used when a widget hasn't been given one.
enum BundledLink {
    static var value: String {
        guard let url = Bundle.main.url(forResource: "widget-link", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("http") } ?? ""
        return line
    }
}

// MARK: - Talking to the server from intents (these run inside the Pacely app)

enum PacelyServer {
    static var server: String { UserDefaults.standard.string(forKey: "server") ?? "" }
    static var token: String { UserDefaults.standard.string(forKey: "token") ?? "" }

    /// Set by the app in "Just this phone" mode, so intents use the on-phone engine instead of a server
    nonisolated(unsafe) static var localHandler: ((String, String, [String: Any]?) async -> Data?)?

    @discardableResult
    static func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Data? {
        if let h = localHandler, let d = await h(path, method, body) { return d }
        guard !server.isEmpty, !token.isEmpty, let url = URL(string: server + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { return nil }
        return data
    }
}

// MARK: - Live Activities that start themselves

struct ChainItem: Decodable {
    let id: Int
    let date: String
    let start: String
    let duration: Int
    let title: String
    let emoji: String?
    let color: String?
    let done: Int?
}

struct ChainPayload: Decodable {
    let items: [ChainItem]
    let tz: String?
}

/// Puts the activity happening now, or the next one coming up, on the Lock Screen.
/// A coming-up activity switches to its countdown by itself when it starts, even if Pacely isn't open.
enum LiveActivityChain {
    static func refresh() async {
        guard let data = await PacelyServer.send("/api/upcoming"),
              let p = try? JSONDecoder().decode(ChainPayload.self, from: data) else { return }
        await update(with: p)
    }

    @MainActor
    static func update(with p: ChainPayload) async {
        let now = Date()
        let all = Activity<PacelyActivityAttributes>.activities
        if all.contains(where: { $0.content.state.kind == "focus" && $0.content.state.end > now }) { return }
        for a in all where a.content.state.kind == "focus" {
            await a.end(nil, dismissalPolicy: .immediate)
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: p.tz ?? TimeZone.current.identifier) ?? .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let list: [(ChainItem, Date, Date)] = p.items.compactMap { i in
            guard (i.done ?? 0) == 0, let s = f.date(from: "\(i.date) \(i.start)") else { return nil }
            let e = s.addingTimeInterval(TimeInterval(max(1, i.duration) * 60))
            return e > now ? (i, s, e) : nil
        }.sorted { $0.1 < $1.1 }

        let existing = all.filter { $0.content.state.kind == "now" }
        guard let first = list.first(where: { $0.1 < now.addingTimeInterval(6 * 3600) }) else {
            for a in existing { await a.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let next = list.first { $0.0.id != first.0.id && $0.1 >= first.2.addingTimeInterval(-60) }
        let state = PacelyActivityAttributes.ContentState(
            title: first.0.title, emoji: first.0.emoji ?? "📝", colorHex: first.0.color ?? "#7CB8F0",
            start: first.1, end: first.2, kind: "now", itemId: max(0, first.0.id),
            nextTitle: next.map { "\($0.0.emoji ?? "") \($0.0.title)".trimmingCharacters(in: .whitespaces) } ?? "",
            nextStart: next?.0.start ?? "", shown: now, calm: PacelyPrefs.calm)

        if existing.contains(where: { $0.content.state.sameAs(state) }) { return }
        for a in existing { await a.end(nil, dismissalPolicy: .immediate) }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: PacelyActivityAttributes(name: "Pacely"),
                                     content: ActivityContent(state: state, staleDate: first.1 > now ? first.1 : first.2),
                                     pushType: nil)
        } catch {
            print("Live Activity failed:", error)
        }
    }
}

/// Small settings the app and its Lock Screen buttons share.
enum PacelyPrefs {
    static var calm: Bool {
        get { UserDefaults.standard.object(forKey: "pacely.calm") as? Bool ?? true }   // calm by default: "until 9:15", no ticking clock
        set { UserDefaults.standard.set(newValue, forKey: "pacely.calm") }
    }
}

/// The app sets this when it starts, so Lock Screen buttons can also tidy notifications and reminders.
@MainActor
enum PacelyHooks {
    static var refresh: (() async -> Void)?
    static func afterChange() async {
        if let r = refresh { await r() } else { await LiveActivityChain.refresh() }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Removes the alerts for one activity from Notification Centre (used when it's ticked off).
func clearNotifications(forItem id: Int) {
    let c = UNUserNotificationCenter.current()
    let ids = ["before", "start", "end", "nag1", "nag2", "nag3", "start-snooze"].map { "pacely-a\(id)-\($0)" }
    c.removeDeliveredNotifications(withIdentifiers: ids)
    c.removePendingNotificationRequests(withIdentifiers: ids)
}

// MARK: - Buttons on the Lock Screen, Dynamic Island and widgets

/// "I'm running late": pushes the rest of today back, from the Lock Screen, a widget or Siri.
struct RunningLateIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "I'm running late"
    static var description = IntentDescription("Pushes the rest of today's Pacely plan back a few minutes.")

    @Parameter(title: "Minutes", default: 10)
    var minutes: Int

    init() {}
    init(minutes: Int) { self.minutes = minutes }

    static var parameterSummary: some ParameterSummary {
        Summary("Push today back \(\.$minutes) minutes")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mins = max(5, min(120, minutes))
        guard await PacelyServer.send("/api/shift", method: "POST", body: ["minutes": mins]) != nil else {
            return .result(dialog: "I couldn't reach Pacely just now.")
        }
        await PacelyHooks.afterChange()
        return .result(dialog: "Okay. I've moved the rest of today back \(mins) minutes. No rush.")
    }
}

/// ✓ Done. Ticks off the activity, then shows the next one.
struct LiveActivityDoneIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark done"
    static var description = IntentDescription("Ticks off the activity that's happening now.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Activity")
    var itemId: Int

    init() {}
    init(itemId: Int) { self.itemId = itemId }

    func perform() async throws -> some IntentResult {
        if itemId > 0 {
            await PacelyServer.send("/api/activities/\(itemId)", method: "PUT", body: ["done": true, "scope": "this"])
            clearNotifications(forItem: itemId)
        }
        for a in Activity<PacelyActivityAttributes>.activities where a.content.state.itemId == itemId {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        await PacelyHooks.afterChange()
        return .result()
    }
}

/// Starts a focus timer from a widget without opening Pacely.
struct StartFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start focus"
    static var description = IntentDescription("Starts a Pacely focus timer.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Minutes")
    var minutes: Int

    init() {}
    init(minutes: Int) { self.minutes = minutes }

    func perform() async throws -> some IntentResult {
        let mins = max(1, min(240, minutes))
        let start = Date()
        let end = start.addingTimeInterval(TimeInterval(mins * 60))
        await PacelyServer.send("/api/focus", method: "POST",
                               body: ["end": Int(end.timeIntervalSince1970 * 1000), "total": mins * 60, "title": "⏳ Focus", "color": "#73CBA8"])
        for a in Activity<PacelyActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            let state = PacelyActivityAttributes.ContentState(title: "Focus", emoji: "⏳", colorHex: "#73CBA8",
                                                             start: start, end: end, kind: "focus", shown: start)
            _ = try? Activity.request(attributes: PacelyActivityAttributes(name: "Pacely"),
                                      content: ActivityContent(state: state, staleDate: end), pushType: nil)
        }
        let c = UNMutableNotificationContent()
        c.title = "Focus time is up"
        c.body = "Nice work. Take a breath."
        c.sound = .default
        let trig = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(mins * 60), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pacely-focus", content: c, trigger: trig))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct StopFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop focus"
    static var description = IntentDescription("Stops the Pacely focus timer.")
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PacelyServer.send("/api/focus", method: "POST", body: [:])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pacely-focus"])
        for a in Activity<PacelyActivityAttributes>.activities where a.content.state.kind == "focus" {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        await LiveActivityChain.refresh()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// "Update Pacely" in the Shortcuts app. Use it in an automation (for example "When my alarm is stopped")
/// so your Lock Screen countdown is ready each morning.
struct UpdatePacelyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Update Pacely"
    static var description = IntentDescription("Refreshes Pacely and puts what's now or next on your Lock Screen.")

    init() {}

    func perform() async throws -> some IntentResult {
        await LiveActivityChain.refresh()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
