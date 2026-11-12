import Foundation
import EventKit

/// Two-way sync with the Calendar app on the iPhone.
/// - Pacely activities appear in a calendar called "Pacely" (and so on your Watch, Mac, iCloud...).
/// - Move or delete one in the Calendar app and Pacely follows.
/// - Events from your other calendars (iCloud, Google, Outlook accounts on the phone) show in Pacely.
enum CalendarSync {
    static let store = EKEventStore()
    private static let d = UserDefaults.standard
    private static var running = false

    static var enabled: Bool {
        get { d.bool(forKey: "calSync") }
        set { d.set(newValue, forKey: "calSync") }
    }

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToEvents() } catch { return false }
    }

    /// When something changes in the Calendar app, sync again shortly after.
    static func startWatchingChanges() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            guard enabled, !running else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await syncIfEnabled()
            }
        }
    }

    // MARK: - helpers

    private struct SyncItem: Codable {
        let id: Int
        let date: String
        let start: String
        let duration: Int
        let title: String
        let emoji: String
        let notes: String
        let done: Int
        let repeating: Bool
    }

    private struct SyncPayload: Codable {
        let items: [SyncItem]
        let tz: String?
    }

    private static func formatter(_ tz: TimeZone, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format
        return f
    }

    private static func signature(date: String, start: String, duration: Int, title: String) -> String {
        "\(date) \(start) \(duration) \(title)"
    }

    private static func pacelyCalendar() -> EKCalendar? {
        if let id = d.string(forKey: "calId"), let cal = store.calendar(withIdentifier: id) { return cal }
        if let existing = store.calendars(for: .event).first(where: { $0.title == "Pacely" && $0.allowsContentModifications }) {
            d.set(existing.calendarIdentifier, forKey: "calId")
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = "Pacely"
        cal.cgColor = CGColor(red: 0.18, green: 0.49, blue: 0.47, alpha: 1)
        let sources = store.sources
        cal.source = store.defaultCalendarForNewEvents?.source
            ?? sources.first(where: { $0.sourceType == .calDAV })
            ?? sources.first(where: { $0.sourceType == .local })
        do {
            try store.saveCalendar(cal, commit: true)
            d.set(cal.calendarIdentifier, forKey: "calId")
            d.set([String: [String: String]](), forKey: "calMap")
            return cal
        } catch {
            print("Could not create Pacely calendar:", error)
            return nil
        }
    }

    // MARK: - sync

    static func syncIfEnabled() async {
        guard enabled, hasAccess, Store.isSetUp, !running else { return }
        running = true
        defer { running = false }
        do {
            try await pushAndPull()
            try await importOtherCalendars()
        } catch {
            print("Calendar sync failed:", error)
        }
    }

    private static func pushAndPull() async throws {
        let data = try await API.request("/api/sync?days=14")
        let p = try JSONDecoder().decode(SyncPayload.self, from: data)
        let tz = TimeZone(identifier: p.tz ?? TimeZone.current.identifier) ?? .current
        let full = formatter(tz, "yyyy-MM-dd HH:mm")
        let dayF = formatter(tz, "yyyy-MM-dd")
        let timeF = formatter(tz, "HH:mm")
        guard let cal = pacelyCalendar() else { return }

        var map = (d.dictionary(forKey: "calMap") as? [String: [String: String]]) ?? [:]
        let serverIds = Set(p.items.map { String($0.id) })
        let windowStart = p.items.map { $0.date }.min() ?? dayF.string(from: Date())

        for item in p.items {
            let key = String(item.id)
            let serverSig = signature(date: item.date, start: item.start, duration: item.duration, title: item.title)
            guard let start = full.date(from: "\(item.date) \(item.start)") else { continue }
            let end = start.addingTimeInterval(TimeInterval(item.duration * 60))
            let shownTitle = item.emoji.isEmpty ? item.title : "\(item.emoji) \(item.title)"

            if let m = map[key], let evId = m["ev"], let ev = store.event(withIdentifier: evId) {
                var evTitle = ev.title ?? item.title
                if !item.emoji.isEmpty, evTitle.hasPrefix(item.emoji + " ") { evTitle = String(evTitle.dropFirst(item.emoji.count + 1)) }
                let evMins = max(1, Int(ev.endDate.timeIntervalSince(ev.startDate) / 60))
                let evSig = signature(date: dayF.string(from: ev.startDate), start: timeF.string(from: ev.startDate), duration: evMins, title: evTitle)
                let lastSig = m["sig"] ?? ""
                if lastSig == serverSig && evSig != lastSig {
                    // Changed in the Calendar app: send it back to Pacely
                    var body: [String: Any] = ["date": dayF.string(from: ev.startDate), "start": timeF.string(from: ev.startDate),
                                               "duration": evMins, "title": evTitle]
                    if item.repeating { body["scope"] = "this" }
                    _ = try? await API.request("/api/activities/\(item.id)", method: "PUT", body: body)
                    map[key] = ["ev": evId, "sig": evSig, "date": dayF.string(from: ev.startDate)]
                } else if lastSig != serverSig {
                    // Changed in Pacely: update the calendar
                    ev.title = shownTitle
                    ev.startDate = start
                    ev.endDate = end
                    ev.notes = item.notes
                    try? store.save(ev, span: .thisEvent, commit: false)
                    map[key] = ["ev": evId, "sig": serverSig, "date": item.date]
                }
            } else if map[key] != nil {
                // It was in the Pacely calendar and someone deleted it there: remove it from Pacely too
                _ = try? await API.request("/api/activities/\(item.id)?scope=this", method: "DELETE")
                map.removeValue(forKey: key)
            } else {
                let ev = EKEvent(eventStore: store)
                ev.calendar = cal
                ev.title = shownTitle
                ev.startDate = start
                ev.endDate = end
                ev.notes = item.notes
                do {
                    try store.save(ev, span: .thisEvent, commit: false)
                    map[key] = ["ev": ev.eventIdentifier ?? "", "sig": serverSig, "date": item.date]
                } catch {
                    print("Could not add event:", error)
                }
            }
        }

        // Deleted in Pacely: remove from the calendar (only inside the synced window)
        for (key, m) in map where !serverIds.contains(key) {
            if (m["date"] ?? "") >= windowStart {
                if let evId = m["ev"], let ev = store.event(withIdentifier: evId) {
                    try? store.remove(ev, span: .thisEvent, commit: false)
                }
                map.removeValue(forKey: key)
            }
        }
        try? store.commit()
        d.set(map, forKey: "calMap")
    }

    /// Your other calendars, shown read-only in Pacely.
    private static func importOtherCalendars() async throws {
        let pacelyId = d.string(forKey: "calId")
        let cals = store.calendars(for: .event).filter {
            $0.calendarIdentifier != pacelyId && !$0.title.localizedCaseInsensitiveContains("pacely") && $0.type != .birthday
        }
        guard !cals.isEmpty else { return }
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400)
        let end = start.addingTimeInterval(16 * 86400)
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        let tz = TimeZone.current
        let dayF = formatter(tz, "yyyy-MM-dd")
        let timeF = formatter(tz, "HH:mm")
        var events: [[String: Any]] = []
        for ev in store.events(matching: pred) {
            if ev.isAllDay {
                events.append(["uid": ev.eventIdentifier ?? "", "title": ev.title ?? "Busy", "date": dayF.string(from: ev.startDate),
                               "all_day": true, "duration": 1440, "location": ev.location ?? ""])
            } else {
                let mins = max(5, Int(ev.endDate.timeIntervalSince(ev.startDate) / 60))
                events.append(["uid": ev.eventIdentifier ?? "", "title": ev.title ?? "Busy", "date": dayF.string(from: ev.startDate),
                               "start": timeF.string(from: ev.startDate), "duration": min(mins, 1440), "location": ev.location ?? "",
                               "repeats": ev.hasRecurrenceRules])
            }
        }
        _ = try await API.request("/api/phonecal", method: "POST", body: ["events": events])
    }
}
