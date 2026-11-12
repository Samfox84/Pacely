import Foundation

// What the Pacely server sends back. Decoding is forgiving: numbers may arrive as text or true/false, and missing
// fields get sensible defaults, so an older or newer server never stops the app from opening.

extension KeyedDecodingContainer {
    func int(_ k: Key, _ def: Int = 0) -> Int {
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v ? 1 : 0 }
        if let v = try? decodeIfPresent(String.self, forKey: k), let i = Int(v) { return i }
        return def
    }
    func optInt(_ k: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        return nil
    }
    func str(_ k: Key, _ def: String = "") -> String {
        if let v = try? decodeIfPresent(String.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return String(v) }
        return def
    }
    func optStr(_ k: Key) -> String? {
        guard let v = try? decodeIfPresent(String.self, forKey: k), !v.isEmpty else { return nil }
        return v
    }
    func bool(_ k: Key) -> Bool {
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v }
        return int(k) != 0
    }
}

struct Step: Codable, Hashable, Identifiable {
    var id = UUID()
    var t: String
    var d: Bool = false
    var m: Int? = nil

    enum CodingKeys: String, CodingKey { case t, d, m }
    init(t: String, d: Bool = false, m: Int? = nil) { self.t = t; self.d = d; self.m = m }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { t = s; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.str(.t); d = c.bool(.d); m = c.optInt(.m)
    }
    var dict: [String: Any] {
        var o: [String: Any] = ["t": t, "d": d]
        if let m, m > 0 { o["m"] = m }
        return o
    }
}

struct Repeat: Codable, Hashable {
    var type: String = "none"
    var days: [Int] = []
    enum CodingKeys: String, CodingKey { case type, days }
    init(type: String = "none", days: [Int] = []) { self.type = type; self.days = days }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.str(.type, "none"); days = (try? c.decodeIfPresent([Int].self, forKey: .days)) ?? []
    }
    var dict: [String: Any] { ["type": type, "days": days] }
    var label: String {
        switch type {
        case "daily": return "Every day"
        case "weekdays": return "Weekdays"
        case "days": return "Every " + days.sorted().map { Day.short[$0] }.joined(separator: ", ")
        default: return "Doesn't repeat"
        }
    }
}

/// An activity, a to-do, or an event from a linked calendar.
struct Item: Decodable, Identifiable, Hashable {
    var id: String            // "12" for Pacely items, "c34" for calendar events
    var kind: String          // event, todo, cal
    var title: String
    var emoji: String
    var color: String
    var date: String?
    var start: String?
    var duration: Int
    var notes: String
    var steps: [Step]
    var done: Bool
    var rep: Repeat
    var remind: Int
    var endAlert: Bool
    var masterId: Int?
    var priority: String
    var allday: String
    var addedBy: String
    var calendar: String
    var isAllDayCal: Bool
    var isPrivate: Bool
    var nag: Bool
    var location: String
    var link: String
    var leave: String?
    var travelMin: Int
    var travelBy: String

    enum K: String, CodingKey {
        case id, kind, title, emoji, color, date, start, duration, notes, steps, done, `repeat`, remind, end_alert, master_id
        case priority, allday, added_by, calendar, all_day, `private`, nag, location, link, leave, travel_min, travel_by
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.str(.id); kind = c.str(.kind, "event"); title = c.str(.title, "Untitled"); emoji = c.str(.emoji, "📝")
        color = c.str(.color, "#7CB8F0"); date = c.optStr(.date); start = c.optStr(.start); duration = max(1, c.int(.duration, 30))
        notes = c.str(.notes); steps = (try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? []
        done = c.bool(.done); rep = (try? c.decodeIfPresent(Repeat.self, forKey: .repeat)) ?? Repeat()
        remind = c.int(.remind); endAlert = c.int(.end_alert, 1) != 0; masterId = c.optInt(.master_id)
        priority = c.str(.priority, "soon"); allday = c.str(.allday); addedBy = c.str(.added_by)
        calendar = c.str(.calendar); isAllDayCal = c.bool(.all_day); isPrivate = c.bool(.private); nag = c.bool(.nag)
        location = c.str(.location); link = c.str(.link); leave = c.optStr(.leave).flatMap { $0.isEmpty ? nil : $0 }
        travelMin = c.int(.travel_min); travelBy = c.str(.travel_by)
    }
    init(title: String, kind: String = "event") {
        id = "0"; self.kind = kind; self.title = title; emoji = "📝"; color = "#7CB8F0"; date = nil; start = nil; duration = 30
        notes = ""; steps = []; done = false; rep = Repeat(); remind = 0; endAlert = true; masterId = nil; priority = "soon"
        allday = ""; addedBy = ""; calendar = ""; isAllDayCal = false; isPrivate = false; nag = false
        location = ""; link = ""; leave = nil; travelMin = 0; travelBy = ""
    }
    /// "Leave at 11:41 · 1h 9m drive"
    var tripText: String {
        var bits: [String] = []
        if let leave { bits.append("Leave at \(leave)") }
        if travelMin > 0 { bits.append(Clock.length(travelMin) + (travelBy == "transit" ? " by train or tube" : travelBy == "car" ? " drive" : "")) }
        return bits.joined(separator: " · ")
    }

    var num: Int { Int(id) ?? 0 }
    var isCal: Bool { kind == "cal" }
    var isTodo: Bool { kind == "todo" }
    var isAllDay: Bool { !allday.isEmpty || isAllDayCal }
    var startMin: Int? { start.flatMap(Clock.minutes) }
    var endMin: Int? { startMin.map { $0 + duration } }
    var stepsDone: Int { steps.filter(\.d).count }
    var label: String { "\(emoji) \(title)" }
    var timeText: String {
        if isAllDay { return "All day" }
        guard let s = startMin else { return "Any time · \(Clock.length(duration))" }
        return "\(Clock.hhmm(s))–\(Clock.hhmm(s + duration)) · \(Clock.length(duration))"
    }
}

struct DayData: Decodable {
    var date: String
    var items: [Item]
    var allday: [Item]
    var quiet: String
    var moods: [Mood]
    var commute: Commute?
    enum K: String, CodingKey { case date, items, allday, quiet, moods, commute }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = c.str(.date); items = (try? c.decode([Item].self, forKey: .items)) ?? []
        allday = (try? c.decode([Item].self, forKey: .allday)) ?? []; quiet = c.str(.quiet)
        moods = (try? c.decode([Mood].self, forKey: .moods)) ?? []
        commute = try? c.decodeIfPresent(Commute.self, forKey: .commute)
    }
    init() { date = ""; items = []; allday = []; quiet = ""; moods = [] }
}

struct WeekDay: Decodable {
    var n: Int
    var done: Int
    var items: [WeekItem]
    enum K: String, CodingKey { case n, done, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        n = c.int(.n); done = c.int(.done); items = (try? c.decode([WeekItem].self, forKey: .items)) ?? []
    }
}
struct WeekItem: Decodable, Hashable {
    var title: String, emoji: String, color: String, start: String?, duration: Int, done: Bool, cal: Bool, allday: String
    enum K: String, CodingKey { case title, emoji, color, start, duration, done, cal, allday }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = c.str(.title); emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); start = c.optStr(.start)
        duration = c.int(.duration, 30); done = c.bool(.done); cal = c.bool(.cal); allday = c.str(.allday)
    }
}

struct Mood: Decodable, Identifiable, Hashable {
    var id: Int, ts: String, date: String, mood: Int, energy: Int?, note: String
    enum K: String, CodingKey { case id, ts, date, mood, energy, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.int(.id); ts = c.str(.ts); date = c.str(.date); mood = c.int(.mood, 3); energy = c.optInt(.energy); note = c.str(.note)
    }
}

struct SavedNumber: Codable, Hashable { var label: String; var number: String; var words: String }

/// Today's journeys on an office day (to work, and home again), checked with TfL every few minutes.
struct Commute: Decodable, Hashable {
    var to: CommuteLeg?
    var back: CommuteLeg?
    enum K: String, CodingKey { case back }
    init(from decoder: Decoder) throws {
        let leg = try? CommuteLeg(from: decoder)
        to = (leg?.leave.isEmpty ?? true) ? nil : leg
        back = try? decoder.container(keyedBy: K.self).decodeIfPresent(CommuteLeg.self, forKey: .back)
    }
}

struct CommuteLeg: Decodable, Hashable {
    struct Line: Decodable, Hashable { var line: String; var status: String; var good: Bool; var reason: String? }
    var leave: String
    var arrive: String
    var minutes: Int
    var summary: String
    var status: [Line]
    var alerted: String?
    var alert: String?
    var checked: String
    enum K: String, CodingKey { case leave, arrive, minutes, summary, status, alerted, alert, checked }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        leave = c.str(.leave); arrive = c.str(.arrive); minutes = c.int(.minutes); summary = c.str(.summary)
        status = (try? c.decode([Line].self, forKey: .status)) ?? []; alerted = c.optStr(.alerted); alert = c.optStr(.alert); checked = c.str(.checked)
    }
}

struct TravelPrefs: Decodable {
    var home = "", work = "", workStart = "09:00", homeTime = "15:00", travelBy = "car", buffer = 10, commute = true, leaveStyle = "gentle"
    var modes: [String] = ["tube", "elizabeth-line", "overground", "dlr", "bus", "national-rail", "tram"]
    enum K: String, CodingKey { case home, work, work_start, home_time, travel_by, travel_buffer, commute, modes, leave_style }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        home = c.str(.home); work = c.str(.work); workStart = c.str(.work_start, "09:00"); homeTime = c.str(.home_time, "15:00"); travelBy = c.str(.travel_by, "car")
        buffer = c.int(.travel_buffer, 10); commute = c.bool(.commute)
        if let m = try? c.decode([String].self, forKey: .modes), !m.isEmpty { modes = m }
        leaveStyle = c.str(.leave_style, "gentle")
    }
}

struct Me: Decodable {
    struct Quiet: Decodable { var from = "", to = "" }
    var quiet = Quiet()
    var travel = TravelPrefs()
    var nudges: [String: Bool] = [:]
    var features: [String] = []
    var autoTick = true
    var myName = ""
    var numbers: [SavedNumber] = []
    var theme = "auto"
    var today = ""
    enum K: String, CodingKey { case features, auto_tick, my_name, numbers, theme, today, travel, nudges, quiet }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        features = (try? c.decode([String].self, forKey: .features)) ?? []; autoTick = c.bool(.auto_tick)
        myName = c.str(.my_name); numbers = (try? c.decode([SavedNumber].self, forKey: .numbers)) ?? []
        theme = c.str(.theme, "auto"); today = c.str(.today)
        travel = (try? c.decode(TravelPrefs.self, forKey: .travel)) ?? TravelPrefs()
        nudges = (try? c.decode([String: Bool].self, forKey: .nudges)) ?? [:]
        quiet = (try? c.decode(Quiet.self, forKey: .quiet)) ?? Quiet()
    }
    func has(_ f: String) -> Bool { features.contains(f) }
}

struct RecentItem: Decodable, Hashable {
    var title: String, emoji: String, color: String, duration: Int, start: String?, steps: [Step]
    enum K: String, CodingKey { case title, emoji, color, duration, start, steps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = c.str(.title); emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); duration = c.int(.duration, 30)
        start = c.optStr(.start); steps = (try? c.decode([Step].self, forKey: .steps)) ?? []
    }
}

struct RoutineItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var emoji: String = "📝"
    var color: String = "#7CB8F0"
    var duration: Int = 10
    var steps: [String] = []
    enum CodingKeys: String, CodingKey { case title, emoji, color, duration, steps }
    init(title: String) { self.title = title }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.str(.title); emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); duration = c.int(.duration, 10)
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
    }
    var dict: [String: Any] { ["title": title, "emoji": emoji, "color": color, "duration": duration, "steps": steps] }
}
struct Routine: Decodable, Identifiable, Hashable {
    var id: Int, name: String, emoji: String, items: [RoutineItem]
    enum K: String, CodingKey { case id, name, emoji, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.int(.id); name = c.str(.name, "Routine"); emoji = c.str(.emoji, "✨"); items = (try? c.decode([RoutineItem].self, forKey: .items)) ?? []
    }
    var minutes: Int { items.reduce(0) { $0 + $1.duration } }
}

struct Trophy: Decodable, Hashable { var key: String, emoji: String, name: String, desc: String, got: Bool }
struct InsightDay: Decodable, Hashable {
    var date: String, done: Int, mood: Double?
    enum K: String, CodingKey { case date, done, mood }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = c.str(.date); done = c.int(.done); mood = try? c.decodeIfPresent(Double.self, forKey: .mood)
    }
}
struct Insights: Decodable {
    var streak = 0, best = 0, total = 0, weekDone = 0, focusWeek = 0, goodDays = 0
    var days: [InsightDay] = []
    var trophies: [Trophy] = []
    enum K: String, CodingKey { case streak, best, total, week_done, focus_week, days, trophies, good_days }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        goodDays = c.int(.good_days); streak = c.int(.streak); best = c.int(.best); total = c.int(.total); weekDone = c.int(.week_done); focusWeek = c.int(.focus_week)
        days = (try? c.decode([InsightDay].self, forKey: .days)) ?? []; trophies = (try? c.decode([Trophy].self, forKey: .trophies)) ?? []
    }
}

struct LinkedCalendar: Decodable, Identifiable, Hashable {
    var id: Int, name: String, url: String, emoji: String, color: String, error: String, n: Int
    var hoursFrom: String, hoursTo: String, hideRepeats: Bool, hideDupes: Bool
    enum K: String, CodingKey { case id, name, url, emoji, color, error, n, hours_from, hours_to, hide_repeats, hide_dupes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.int(.id); name = c.str(.name); url = c.str(.url); emoji = c.str(.emoji, "📅"); color = c.str(.color, "#9AA8BA")
        error = c.str(.error); n = c.int(.n)
        hoursFrom = c.str(.hours_from); hoursTo = c.str(.hours_to); hideRepeats = c.bool(.hide_repeats)
        hideDupes = c.int(.hide_dupes, 1) != 0
    }
}
struct CalendarList: Decodable { var calendars: [LinkedCalendar]; var feed: String }

struct FamilyLink: Decodable, Identifiable, Hashable {
    var token: String, name: String, see: String, lastUsed: String, joined: String, device: String, invitePath: String, web: Bool
    var id: String { token }
    enum K: String, CodingKey { case token, name, see, last_used, joined, device, invite_path, web }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        token = c.str(.token); name = c.str(.name); see = c.str(.see, "all"); lastUsed = c.str(.last_used)
        joined = c.str(.joined); device = c.str(.device); invitePath = c.str(.invite_path); web = c.bool(.web)
    }
    var status: String {
        if !joined.isEmpty { return "Joined on \(device.isEmpty ? "their phone" : device)" }
        if !invitePath.isEmpty { return "Invite waiting to be used" }
        return web ? "Uses a web link" : "No invite waiting"
    }
}

struct AIStatus: Decodable {
    var ok = false, provider = "ollama", error = "", hasKey = false, model = "", auto = true
    var models: [String] = []
    enum K: String, CodingKey { case ok, provider, error, has_key, model, models, auto }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        ok = c.bool(.ok); provider = c.str(.provider, "ollama"); error = c.str(.error); hasKey = c.bool(.has_key)
        model = c.str(.model); models = (try? c.decode([String].self, forKey: .models)) ?? []
        auto = (try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? true
    }
}

/// A suggestion from the AI helper, to review before adding.
struct AITask: Decodable, Identifiable, Hashable {
    var id = UUID()
    var title: String, emoji: String, minutes: Int, priority: String, steps: [Step]
    var on = true
    enum K: String, CodingKey { case title, emoji, minutes, priority, steps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = c.str(.title); emoji = c.str(.emoji, "📝"); minutes = c.int(.minutes, 15); priority = c.str(.priority, "soon")
        steps = (try? c.decode([Step].self, forKey: .steps)) ?? []
    }
    var dict: [String: Any] { ["title": title, "emoji": emoji, "minutes": minutes, "priority": priority, "steps": steps.map(\.dict)] }
}
struct FoundPlan: Decodable, Identifiable, Hashable {
    var id = UUID()
    var title: String, emoji: String, color: String, kind: String, date: String, start: String, minutes: Int, notes: String
    var on = true
    enum K: String, CodingKey { case title, emoji, color, kind, date, start, minutes, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = c.str(.title); emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); kind = c.str(.kind, "todo")
        date = c.str(.date); start = c.str(.start); minutes = c.int(.minutes, 30); notes = c.str(.notes)
    }
}

// MARK: - Dates and times

enum Day {
    static let short = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let iso: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func date(_ s: String) -> Date { iso.date(from: s) ?? Date() }
    static func string(_ d: Date) -> String { iso.string(from: d) }
    static var today: String { string(Date()) }
    static func add(_ s: String, _ n: Int) -> String {
        string(Calendar.current.date(byAdding: .day, value: n, to: date(s)) ?? date(s))
    }
    static func addMonths(_ s: String, _ n: Int) -> String {
        string(Calendar.current.date(byAdding: .month, value: n, to: date(s)) ?? date(s))
    }
    /// Monday = 0 … Sunday = 6, like the server
    static func weekday(_ s: String) -> Int { (Calendar.current.component(.weekday, from: date(s)) + 5) % 7 }
    static func mondayOf(_ s: String) -> String { add(s, -weekday(s)) }
    static func format(_ s: String, _ fmt: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = fmt; return f.string(from: date(s))
    }
    static func friendly(_ s: String) -> String {
        if s == today { return "Today" }
        if s == add(today, 1) { return "Tomorrow" }
        if s == add(today, -1) { return "Yesterday" }
        return format(s, "EEEE d MMMM")
    }
    static func shortFriendly(_ s: String) -> String {
        if s == today { return "Today" }
        if s == add(today, 1) { return "Tomorrow" }
        return format(s, "EEE d MMM")
    }
}

enum Clock {
    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":"); guard p.count >= 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }
    static func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", ((m / 60) % 24 + 24) % 24, (m % 60 + 60) % 60) }
    static var nowMin: Int { let c = Calendar.current.dateComponents([.hour, .minute], from: Date()); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }
    static func length(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
    static func date(_ hhmm: String?) -> Date {
        let m = hhmm.flatMap(minutes) ?? 9 * 60
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    static func string(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d); return hhmm((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}
