import Foundation
import UserNotifications
import BackgroundTasks
import ActivityKit
import WidgetKit

/// Schedules reminders on the phone itself, so they arrive even with no signal.
enum Scheduler {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func scheduleAppRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Store.refreshID)
        r.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func refresh() async {
        if Store.isPartner { await PartnerAPI.refresh(); return }
        guard Store.isSetUp else { return }
        do {
            let data = try await API.request("/api/upcoming")
            let p = try JSONDecoder().decode(UpcomingPayload.self, from: data)
            await schedule(p, extra: try? JSONDecoder().decode(NudgePayload.self, from: data))
            await tidyDelivered(p)
            if let a = try? JSONDecoder().decode(AddedPayload.self, from: data) { await announceAdded(a.added ?? []) }
            if let chain = try? JSONDecoder().decode(ChainPayload.self, from: data) {
                await LiveActivityChain.update(with: chain)
            }
            WidgetCenter.shared.reloadAllTimelines()
            await CalendarSync.syncIfEnabled()
            await WatchLink.shared.send()
        } catch {
            print("Pacely refresh failed:", error)
        }
    }

    private struct Planned {
        let id: String
        let date: Date
        let title: String
        let body: String
    }

    static func schedule(_ p: UpcomingPayload, extra: NudgePayload? = nil) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let old = pending.map { $0.identifier }.filter { $0.hasPrefix("pacely-a") || $0.hasPrefix("pacely-n") || $0.hasPrefix("pacely-commute") }
        center.removePendingNotificationRequests(withIdentifiers: old)

        let now = Date()
        var plans: [Planned] = []
        let countdown = extra?.leave_style == "countdown"     // otherwise gentle: one heads-up, no countdown
        for item in p.items where (item.done ?? 0) == 0 {
            guard let start = p.startDate(item) else { continue }
            let end = start.addingTimeInterval(TimeInterval(item.duration * 60))
            let label = "\(item.emoji ?? "") \(item.title)".trimmingCharacters(in: .whitespaces)
            let remind = item.remind ?? 0
            if remind > 0 {
                plans.append(Planned(id: "pacely-a\(item.id)-before", date: start.addingTimeInterval(TimeInterval(-remind * 60)),
                                     title: label, body: "In \(remind) minutes, at \(item.start)."))
            }
            if remind >= 0 {
                plans.append(Planned(id: "pacely-a\(item.id)-start", date: start, title: label, body: "Starting about now."))
            }
            if (item.end_alert ?? 0) == 1 && item.duration >= 10 {
                plans.append(Planned(id: "pacely-a\(item.id)-end", date: end.addingTimeInterval(-300),
                                     title: label, body: "About 5 minutes left."))
            }
            if let lv = item.leave, !lv.isEmpty, let leave = p.at(item.date, lv) {
                // Time to leave: 10 minutes' warning, then the moment
                let how = item.travel_by == "transit" ? " by public transport" : item.travel_by == "car" ? " drive" : ""
                let trip = (item.travel_min ?? 0) > 0 ? " · \(item.travel_min!) min\(how)" : ""
                if countdown {
                    // Countdown: 20, 10 and 5 minutes before, then the moment
                    for m in [20, 10, 5] {
                        plans.append(Planned(id: "pacely-a\(item.id)-leave\(m)", date: leave.addingTimeInterval(TimeInterval(-m * 60)),
                                             title: "Leave in \(m) minutes", body: label + trip))
                    }
                    plans.append(Planned(id: "pacely-a\(item.id)-leave", date: leave, title: "Time to leave", body: label + trip))
                } else {
                    // Gentle: one heads-up, 15 minutes before. No countdown, no "now!"
                    plans.append(Planned(id: "pacely-a\(item.id)-leave15", date: leave.addingTimeInterval(-15 * 60),
                                         title: "Heads up: leave around \(lv)", body: label + trip + ". No rush."))
                }
            }
            if (item.nag ?? 0) == 1 {
                // Important things: keep gently nudging until they're ticked off
                for k in 1...3 {
                    plans.append(Planned(id: "pacely-a\(item.id)-nag\(k)", date: start.addingTimeInterval(TimeInterval(k * 10 * 60)),
                                         title: label, body: "Still here whenever you're ready."))
                }
            }
        }
        for n in extra?.nudges ?? [] {
            if let d = p.at(n.date, n.time) { plans.append(Planned(id: "pacely-n\(n.date)-\(n.key)-\(n.time)", date: d, title: n.title, body: n.body)) }
        }
        if let c = extra?.commute, let lv = c.leave, let day = c.date, let d = p.at(day, lv) {
            plans.append(Planned(id: "pacely-commute10", date: d.addingTimeInterval(-600), title: "🚇 Leave for work in 10 minutes", body: c.summary ?? ""))
            plans.append(Planned(id: "pacely-commute", date: d, title: "🚇 Time to leave for work", body: c.summary ?? ""))
        }
        // Quiet hours: nothing is scheduled inside them
        let qf = extra?.quiet_from ?? "", qt = extra?.quiet_to ?? ""
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        func quiet(_ d: Date) -> Bool {
            guard !qf.isEmpty, !qt.isEmpty else { return false }
            let t = hm.string(from: d)
            return qf < qt ? (qf <= t && t < qt) : (t >= qf || t < qt)
        }
        let upcoming = plans.filter { $0.date > now && !quiet($0.date) }.sorted { $0.date < $1.date }.prefix(60)
        for plan in upcoming {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = Sounds.notification(plan.id.hasSuffix("-end") ? "pacely-ending" : "pacely-reminder")
            // One stack per activity, so alerts don't pile up separately
            content.threadIdentifier = plan.id.components(separatedBy: "-").prefix(2).joined(separator: "-")
            content.relevanceScore = plan.id.hasSuffix("-start") ? 1 : 0.5
            content.categoryIdentifier = plan.id.hasPrefix("pacely-a") && !plan.id.contains("-leave") ? NotificationDelegate.category : ""
            content.interruptionLevel = .active
            content.targetContentIdentifier = "today"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: plan.id, content: content, trigger: trigger))
        }

        if let f = p.focus {
            let end = Date(timeIntervalSince1970: f.end / 1000)
            if end > now { await scheduleFocusEnd(at: end, title: f.title ?? "") }
        }
    }

    /// Clears alerts that are out of date: reminders for things that have started or finished,
    /// anything you've ticked off, and anything that's no longer in your plan.
    static func tidyDelivered(_ p: UpcomingPayload) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let now = Date()
        var byId: [Int: (start: Date, end: Date, done: Bool)] = [:]
        for item in p.items {
            guard let s = p.startDate(item) else { continue }
            byId[item.id] = (s, s.addingTimeInterval(TimeInterval(item.duration * 60)), (item.done ?? 0) == 1)
        }
        var gone: [String] = []
        for n in delivered {
            let id = n.request.identifier
            if id == "pacely-focus" {
                if now.timeIntervalSince(n.date) > 30 * 60 { gone.append(id) }
                continue
            }
            if id.hasPrefix("pacely-n") || id.hasPrefix("pacely-commute") {
                if now.timeIntervalSince(n.date) > 60 * 60 { gone.append(id) }   // body nudges fade after an hour
                continue
            }
            if id.hasPrefix("pacely-added-") {
                if now.timeIntervalSince(n.date) > 12 * 3600 { gone.append(id) }
                continue
            }
            guard id.hasPrefix("pacely-a") else { continue }
            let rest = id.dropFirst("pacely-a".count)            // "12-start", or "-900001-leave20" for journeys and calendar events
            let parts = rest.split(separator: "-")
            guard parts.count >= 2, let n0 = Int(parts.dropLast().joined(separator: "-")) else { gone.append(id); continue }
            let num = rest.hasPrefix("-") ? -n0 : n0
            guard let w = byId[num] else { gone.append(id); continue }   // no longer planned (or from another day)
            let kind = parts.last ?? ""
            if w.done { gone.append(id); continue }
            switch kind {
            case "before": if now >= w.start { gone.append(id) }
            case "start": if now >= w.end { gone.append(id) }
            case "end": if now >= w.end.addingTimeInterval(5 * 60) { gone.append(id) }
            case "nag1", "nag2", "nag3": if now >= w.start.addingTimeInterval(90 * 60) { gone.append(id) }
            case "leave20", "leave15", "leave10", "leave5", "leave": if now >= w.start.addingTimeInterval(5 * 60) || now >= w.end { gone.append(id) }
            default: break
            }
        }
        if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: gone) }
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// "💌 Alex added something": tells you once when someone adds to your plan with their link.
    static func announceAdded(_ items: [AddedItem]) async {
        let key = "pacely.seenAdded"
        var seen = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        let center = UNUserNotificationCenter.current()
        for it in items where !seen.contains(it.id) {
            seen.insert(it.id)
            guard let ts = it.createdTs, Date().timeIntervalSince1970 - ts < 6 * 3600 else { continue }
            let c = UNMutableNotificationContent()
            c.title = "💌 \(it.by) added something"
            c.body = "\(it.emoji ?? "") \(it.title) · \(it.when)".trimmingCharacters(in: .whitespaces)
            c.sound = Sounds.notification("pacely-added")
            c.threadIdentifier = "pacely-added"
            try? await center.add(UNNotificationRequest(identifier: "pacely-added-\(it.id)", content: c, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen.suffix(300)), forKey: key)
    }

    static func scheduleFocusEnd(at end: Date, title: String) async {
        guard end > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Focus time is up"
        content.body = title.isEmpty ? "Nice work. Take a breath." : title
        content.sound = Sounds.notification("pacely-timer")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pacely-focus", content: content, trigger: trigger))
    }
}

/// Starts and stops the Lock Screen / Dynamic Island countdowns.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activities: [Activity<PacelyActivityAttributes>] {
        Activity<PacelyActivityAttributes>.activities
    }

    func startFocus(title: String, emoji: String, colorHex: String, start: Date, end: Date, itemId: Int = 0) async {
        await endAll()
        request(PacelyActivityAttributes.ContentState(title: title, emoji: emoji, colorHex: colorHex, start: start, end: end, kind: "focus",
                                                     itemId: itemId, shown: Date()))
    }

    func endFocus() async {
        for a in activities where a.content.state.kind == "focus" {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    func endAll() async {
        for a in activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func request(_ state: PacelyActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: PacelyActivityAttributes(name: "Pacely"),
                                     content: ActivityContent(state: state, staleDate: state.end),
                                     pushType: nil)
        } catch {
            print("Live Activity failed:", error)
        }
    }
}


/// Things added by someone with your share link (from /api/upcoming).
struct AddedItem: Codable {
    let id: Int
    let title: String
    let emoji: String?
    let by: String
    let when: String
    let createdTs: Double?
}
struct AddedPayload: Codable {
    let added: [AddedItem]?
}

/// Your own sounds. Put .caf, .wav or .aiff files (30 seconds or less) in the Pacely/Sounds folder
/// with these names. Any that are missing use the normal iPhone sound.
///   pacely-reminder  reminders     pacely-ending  "5 minutes left"
///   pacely-timer     focus is up   pacely-added   someone added something for you
enum Sounds {
    static func notification(_ name: String) -> UNNotificationSound {
        for ext in ["caf", "wav", "aiff"] {
            if Bundle.main.url(forResource: name, withExtension: ext) != nil {
                return UNNotificationSound(named: UNNotificationSoundName("\(name).\(ext)"))
            }
        }
        return .default
    }
}
