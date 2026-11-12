import SwiftUI
import Observation
import JavaScriptCore
import AVFoundation
import UIKit

// MARK: - Talking to the server

enum P {
    static let decoder = JSONDecoder()

    /// Asks the server, saves the answer on the phone, and if the server can't be reached
    /// uses the saved copy instead (Planner.offline then shows a small note).
    static func get<T: Decodable>(_ path: String, as: T.Type = T.self, local: Bool = true, timeout: TimeInterval? = nil) async throws -> T {
        let saved = local ? LocalCopy.load(path) : nil
        do {
            let d = try await API.request(path, timeout: timeout ?? (saved == nil ? 30 : 10))
            let v = try decoder.decode(T.self, from: d)
            if local { LocalCopy.save(path, d) }
            await MainActor.run { Planner.shared.offline = false }
            return v
        } catch {
            if let saved, isOffline(error), let v = try? decoder.decode(T.self, from: saved) {
                await MainActor.run { Planner.shared.offline = true }
                return v
            }
            throw error
        }
    }
    /// The saved copy only, straight away (no waiting for the server).
    static func peek<T: Decodable>(_ path: String, as: T.Type = T.self) -> T? {
        LocalCopy.load(path).flatMap { try? decoder.decode(T.self, from: $0) }
    }
    /// Sends a change. If the server can't be reached it waits in the Outbox and goes when it can.
    @discardableResult
    static func send(_ path: String, _ method: String = "POST", _ body: [String: Any] = [:]) async throws -> Data {
        do {
            let d = try await API.request(path, method: method, body: body)
            await MainActor.run { Planner.shared.offline = false }
            return d
        } catch {
            guard isOffline(error), !path.hasPrefix("/api/ai") else { throw error }
            Outbox.add(path, method, body)
            await MainActor.run {
                Planner.shared.offline = true
                Planner.shared.pending = Outbox.count
                Planner.shared.say("Saved on your phone. It'll sync when your server answers.")
            }
            return Data("{}".utf8)
        }
    }
    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// AI requests run as background jobs on the server; this waits for the answer.
    static func ai(_ path: String, _ body: [String: Any], jobBase: String = "/api/ai/job", useToken: Bool = true) async throws -> Data {
        let gen = await MainActor.run { () -> Int in Planner.shared.aiBusy += 1; return Planner.shared.aiCancelGen }
        defer { Task { @MainActor in Planner.shared.aiBusy = max(0, Planner.shared.aiBusy - 1) } }
        let start = json(try await API.request(path, method: "POST", body: body, useToken: useToken))
        guard let job = start["job"] as? String else {
            return try JSONSerialization.data(withJSONObject: start)
        }
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if await MainActor.run(body: { Planner.shared.aiCancelGen }) != gen {
                _ = try? await API.request("\(jobBase)/\(job)/cancel", method: "POST", body: [:], useToken: useToken)
                throw CancellationError()
            }
            let d = try await API.request("\(jobBase)/\(job)", useToken: useToken)
            let j = json(d)
            switch j["status"] as? String {
            case "done":
                return try JSONSerialization.data(withJSONObject: j["result"] ?? [:])
            case "error":
                throw APIError.http(500, "{\"error\": \"\((j["error"] as? String ?? "The AI helper didn't answer.").replacingOccurrences(of: "\"", with: "'"))\"}")
            default: continue
            }
        }
        throw APIError.http(504, "{\"error\": \"The AI helper took too long. Try again.\"}")
    }
}

// MARK: - App state

enum ViewMode: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }

@MainActor
@Observable
final class Planner {
    static let shared = Planner()

    var date = Day.today
    var mode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "pacely.mode") ?? "Day") ?? .day {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "pacely.mode") }
    }
    var day = DayData()
    var week: [String: WeekDay] = [:]
    var month: [String: WeekDay] = [:]
    var todos: [Item] = []
    var me = Me()
    var recent: [RecentItem] = []
    var leftovers: [Item] = []
    var routines: [Routine] = []
    var ai = AIStatus()
    var loading = false
    /// False until your day is on screen (from the saved copy or the server), so the first open never shows an empty, stuck screen
    var ready = false
    /// True while the server can't be reached; you see your saved copy
    var offline = false
    /// Changes made offline, waiting to be sent
    var pending = Outbox.count
    private var syncVersion = -1
    private var live: Task<Void, Never>?
    /// How many AI requests are running (shows the thinking glow)
    var aiBusy = 0
    /// Bumped by the Cancel button on the thinking glow; any AI request waiting stops quietly.
    var aiCancelGen = 0
    func cancelAI() {
        aiCancelGen += 1
        aiBusy = 0
        Feedback.tap()
        say("Stopped. Nothing was changed.")
    }
    var error: String?
    var toast: Toast?
    private var recentAt = Date.distantPast
    private var syncTask: Task<Void, Never>?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var action: String? = nil
        var run: (() -> Void)? = nil
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    func say(_ text: String, action: String? = nil, run: (() -> Void)? = nil) {
        toast = Toast(text: text, action: action, run: run)
    }

    func fail(_ e: Error) {
        if e is CancellationError { return }   // you pressed Cancel, that's not a problem
        Feedback.sound("gentle-error")
        error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        say(error ?? "Something went wrong")
    }

    var isToday: Bool { date == Day.today }

    func start() async {
        showSavedCopy()
        Task { await Smart.shared.load() }          // smart typing catches up on its own; nothing waits for it
        await loadMe()
        async let r: Void = loadRoutines()
        async let a: Void = loadAI()
        async let t: Void = loadTodos()
        await load()
        ready = true
        _ = await (r, a, t)
        startLive()
    }

    /// Puts the last saved copy on screen straight away.
    func showSavedCopy() {
        if let m: Me = P.peek("/api/me") { me = m }
        if let r: [Routine] = P.peek("/api/routines") { routines = r }
        if let a: AIStatus = P.peek("/api/ai/status") { ai = a }
        if let t: [Item] = P.peek("/api/todos") { todos = t }
        switch mode {
        case .day: if let d: DayData = P.peek("/api/day?date=\(date)") { day = d; ready = true }
        case .week: if let w: [String: WeekDay] = P.peek("/api/week?start=\(Day.mondayOf(date))") { week = w; ready = true }
        case .month: break
        }
    }

    // MARK: live two-way sync

    /// While Pacely is open it keeps a quiet line open to your server. The moment anything changes
    /// (you, your partner, the AI helper, your calendars), every screen refreshes by itself.
    func startLive() {
        live?.cancel()
        if Store.localOnly {
            // Everything is on this phone: no server to listen to. Refresh when the engine says something changed.
            live = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .pacelyLocalChanged) {
                    if Task.isCancelled { return }
                    await self?.changed(quiet: true)
                }
            }
            return
        }
        live = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Outbox.count > 0 {
                    let sent = await Outbox.flush()
                    self.pending = Outbox.count
                    if sent > 0 { await self.changed() }
                }
                do {
                    let r: SyncVersion = try await P.get("/api/live?v=\(self.syncVersion)&wait=25", local: false, timeout: 40)
                    if Task.isCancelled { return }
                    let was = self.syncVersion
                    self.syncVersion = r.v
                    if was >= 0 && r.v != was { await self.changed(quiet: true) }
                } catch {
                    if Task.isCancelled { return }
                    if isOffline(error) { self.offline = true }
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                }
            }
        }
    }
    func stopLive() { live?.cancel(); live = nil }

    func loadMe() async { if let m = try? await P.get("/api/me", as: Me.self) { me = m } }
    func loadRoutines() async { if let r = try? await P.get("/api/routines", as: [Routine].self) { routines = r } }
    func loadAI() async { if let s = try? await P.get("/api/ai/status", as: AIStatus.self) { ai = s } }

    /// Reloads whatever the Today screen is showing.
    func load() async {
        loading = true
        defer { loading = false }
        do {
            switch mode {
            case .day:
                if day.date != date, let saved: DayData = P.peek("/api/day?date=\(date)") { day = saved }
                day = try await P.get("/api/day?date=\(date)")
                if isToday && me.has("leftovers") && UserDefaults.standard.string(forKey: "pacely.leftDismiss") != Day.today {
                    leftovers = (try? await P.get("/api/leftovers", as: [Item].self)) ?? []
                } else { leftovers = [] }
            case .week:
                week = try await P.get("/api/week?start=\(Day.mondayOf(date))")
            case .month:
                let first = Day.string(Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Day.date(date))) ?? Date())
                let gridStart = Day.mondayOf(first)
                var all: [String: WeekDay] = [:]
                for w in 0..<6 {
                    let part: [String: WeekDay] = (try? await P.get("/api/week?start=\(Day.add(gridStart, w * 7))")) ?? [:]
                    all.merge(part) { a, _ in a }
                }
                month = all
            }
            if me.has("smart") && Date().timeIntervalSince(recentAt) > 300 {
                recent = (try? await P.get("/api/recent", as: [RecentItem].self)) ?? recent
                recentAt = Date()
            }
            error = nil
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func loadTodos() async { if let t = try? await P.get("/api/todos", as: [Item].self) { todos = t } }

    /// After any change: reload, and let reminders, widgets and the Lock Screen catch up.
    func changed(quiet: Bool = false) async {
        await load()
        await loadTodos()
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            await Scheduler.refresh()
        }
    }

    func go(_ newDate: String) { date = newDate; Task { await load() } }
    func move(_ dir: Int) {
        switch mode {
        case .day: date = Day.add(date, dir)
        case .week: date = Day.add(date, dir * 7)
        case .month: date = Day.addMonths(date, dir)
        }
        Feedback.tap(); Feedback.sound("swipe")
        Task { await load() }
    }

    // MARK: actions

    func toggleDone(_ it: Item) async {
        guard !it.isCal else { return }
        do {
            var b: [String: Any] = ["done": !it.done]
            if it.masterId != nil { b["scope"] = "this" }
            try await P.send("/api/activities/\(it.id)", "PUT", b)
            if !it.done {
                clearNotifications(forItem: it.num)
                Feedback.success(); Feedback.sound("done")
                say(["Nice one", "Done", "Ticked off", "Well done"].randomElement()!)
            }
            await changed()
        } catch { fail(error) }
    }

    func toggleStep(_ it: Item, _ i: Int) async {
        guard i < it.steps.count else { return }
        var steps = it.steps
        steps[i].d.toggle()
        if steps[i].d { Feedback.soft(); Feedback.sound("step") }
        // show it straight away
        if let k = day.items.firstIndex(where: { $0.id == it.id }) { day.items[k].steps = steps }
        if let k = todos.firstIndex(where: { $0.id == it.id }) { todos[k].steps = steps }
        do {
            var b: [String: Any] = ["steps": steps.map(\.dict)]
            if it.masterId != nil { b["scope"] = "this" }
            try await P.send("/api/activities/\(it.id)", "PUT", b)
            if steps.allSatisfy(\.d) && !it.done {
                say("All steps done", action: "Tick it off") { Task { var x = it; x.steps = steps; await self.toggleDone(x) } }
            }
        } catch { fail(error) }
    }

    func update(_ it: Item, _ body: [String: Any], message: String? = nil) async {
        var b = body
        if it.masterId != nil && b["scope"] == nil { b["scope"] = "this" }
        do {
            try await P.send("/api/activities/\(it.id)", "PUT", b)
            if let message { say(message) }
            await changed()
        } catch { fail(error) }
    }

    func delete(_ it: Item, all: Bool = false) async {
        do {
            try await P.send("/api/activities/\(it.id)?scope=\(all ? "all" : "this")", "DELETE")
            clearNotifications(forItem: it.num)
            Feedback.sound("delete")
            say("Deleted")
            await changed()
        } catch { fail(error) }
    }

    @discardableResult
    func create(_ body: [String: Any], quiet: Bool = false) async -> Int? {
        do {
            let d = P.json(try await P.send("/api/activities", "POST", body))
            if !quiet { Feedback.success(); Feedback.sound("add") }
            recentAt = .distantPast
            await changed()
            return d["id"] as? Int
        } catch { fail(error); return nil }
    }

    /// "Pick up meds tomorrow 11am" → added, with an Undo.
    func quickAdd(_ text: String) async {
        let p = Smart.shared.parse(text, today: Day.today)
        let title = p.title ?? text
        var body: [String: Any] = ["kind": "event", "title": title, "date": p.date ?? date, "duration": p.duration ?? 30,
                                   "remind": 0, "end_alert": 1]
        body["start"] = p.start ?? NSNull()
        if let a = p.allday { body["allday"] = a; body["start"] = NSNull() }
        if let r = p.repeatRule { body["repeat"] = r }
        if let g = Smart.shared.guess(title) { body["emoji"] = g.emoji; body["color"] = g.color }
        if let id = await create(body) {
            let target = body["date"] as? String ?? date
            let where_ = target == date ? "" : " to " + Day.shortFriendly(target).lowercased()
            say("Added \(title)\(where_)", action: "Undo") {
                Task { try? await P.send("/api/activities/\(id)?scope=all", "DELETE"); Feedback.sound("undo"); await self.changed() }
            }
        }
    }

    func addAgain(_ r: RecentItem) async {
        var start = r.start
        if let s = start, isToday, let m = Clock.minutes(s), m < Clock.nowMin { start = nil }
        let body: [String: Any] = ["kind": "event", "title": r.title, "emoji": r.emoji, "color": r.color, "duration": r.duration,
                                   "steps": r.steps.map { ["t": $0.t, "d": false, "m": $0.m ?? 0] }, "date": date,
                                   "start": start ?? NSNull(), "remind": 0, "end_alert": 1]
        if let id = await create(body) {
            say("Added \(r.title)\(start.map { " at \($0)" } ?? "")", action: "Undo") {
                Task { try? await P.send("/api/activities/\(id)", "DELETE"); Feedback.sound("undo"); await self.changed() }
            }
        }
    }

    func runningLate(_ mins: Int = 10) async {
        do {
            let d = P.json(try await P.send("/api/shift", "POST", ["minutes": mins]))
            let n = d["moved"] as? Int ?? 0
            say(n > 0 ? "Moved \(n) thing\(n == 1 ? "" : "s") back \(mins) min. No rush" : "Nothing left to move today")
            await changed()
        } catch { fail(error) }
    }

    func leftovers(_ action: String, to: String? = nil, ids: [Int]? = nil) async {
        var b: [String: Any] = ["action": action, "ids": ids ?? leftovers.map(\.num)]
        if let to { b["to"] = to }
        do {
            try await P.send("/api/leftovers", "POST", b)
            if ids == nil { leftovers = [] }
            await changed()
        } catch { fail(error) }
    }

    /// Couldn't do it today: keeps what got done, and carries on just the rest.
    func couldnt(_ it: Item, to: String) async {
        let left = it.steps.filter { !$0.d }, did = it.steps.filter(\.d)
        let partial = !did.isEmpty && !left.isEmpty
        do {
            if partial {
                if to != "let_go" {
                    var b: [String: Any] = ["title": it.title, "emoji": it.emoji, "color": it.color,
                                            "duration": max(10, left.reduce(0) { $0 + ($1.m ?? 0) } == 0 ? it.duration : left.reduce(0) { $0 + ($1.m ?? 0) }),
                                            "steps": left.map { Step(t: $0.t, d: false, m: $0.m).dict }, "notes": it.notes,
                                            "remind": it.remind, "end_alert": it.endAlert]
                    if to == "todo" { b["kind"] = "todo"; b["priority"] = "soon" } else { b["kind"] = "event"; b["date"] = to; b["start"] = NSNull() }
                    try await P.send("/api/activities", "POST", b)
                }
                var b: [String: Any] = ["steps": did.map(\.dict), "done": true]
                if it.masterId != nil { b["scope"] = "this" }
                try await P.send("/api/activities/\(it.id)", "PUT", b)
            } else if to == "let_go" {
                try await P.send("/api/activities/\(it.id)?scope=this", "DELETE")
            } else if to == "todo" {
                var b: [String: Any] = ["kind": "todo", "date": NSNull(), "start": NSNull()]
                if it.masterId != nil { b["scope"] = "this" }
                try await P.send("/api/activities/\(it.id)", "PUT", b)
            } else {
                var b: [String: Any] = ["date": to]
                if it.masterId != nil { b["scope"] = "this" }
                try await P.send("/api/activities/\(it.id)", "PUT", b)
            }
            clearNotifications(forItem: it.num)
            say(to == "let_go" ? "Let go. That's fine" : to == "todo" ? "On your to-do list for when you're ready"
                : "Moved to \(Day.format(to, "EEEE")). Be kind to yourself")
            await changed()
        } catch { fail(error) }
    }

    func saveSettings(_ body: [String: Any]) async {
        do { try await P.send("/api/settings", "PUT", body); await loadMe() } catch { fail(error) }
    }

    func number(for title: String) -> SavedNumber? {
        let t = " " + title.lowercased() + " "
        return me.numbers.first { n in
            (n.words.isEmpty ? n.label : n.words).lowercased().split(whereSeparator: { $0 == "," || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.contains { t.contains($0) }
        }
    }
}

// MARK: - Haptics and sounds

@MainActor
enum Feedback {
    /// Low-stimulation mode (Me): no sounds, no haptics, no animation, softer colours
    static var lowStim: Bool { UserDefaults.standard.bool(forKey: "pacely.lowStim") }
    static var hapticsOn: Bool { !lowStim && (UserDefaults.standard.object(forKey: "pacely.haptics") as? Bool ?? true) }
    static var soundsOn: Bool { !lowStim && (UserDefaults.standard.object(forKey: "pacely.sounds") as? Bool ?? true) }
    static func tap() { if hapticsOn { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    static func soft() { if hapticsOn { UIImpactFeedbackGenerator(style: .soft).impactOccurred() } }
    static func success() { if hapticsOn { UINotificationFeedbackGenerator().notificationOccurred(.success) } }

    /// Plays one of your own sounds from the Sounds folder (done, step, add, timer, next-step), if it's there.
    static func sound(_ name: String) {
        guard soundsOn else { return }
        for ext in ["caf", "wav", "m4a", "mp3", "aiff"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                SoundPlayer.shared.play(url)
                return
            }
        }
    }
}

// MARK: - Smart typing (shares its rules with the web app, by running the server's smart.js)

struct Parsed {
    var title: String?
    var date: String?
    var start: String?
    var duration: Int?
    var allday: String?
    var repeatRule: [String: Any]?
    var hint: String {
        var bits: [String] = []
        if let date { bits.append(Day.shortFriendly(date)) }
        if let allday { bits.append(["off": "day off", "sick": "sick day", "holiday": "holiday"][allday] ?? "all day") }
        else if let start { bits.append(start) }
        if let duration { bits.append(Clock.length(duration)) }
        if let r = repeatRule, let t = r["type"] as? String {
            bits.append(t == "daily" ? "every day" : t == "weekdays" ? "weekdays" : "repeats")
        }
        return bits.isEmpty ? "" : "✨ " + bits.joined(separator: " · ")
    }
    var found: Bool { date != nil || start != nil || duration != nil || allday != nil || repeatRule != nil }
}

@MainActor
final class Smart {
    static let shared = Smart()
    private var ctx: JSContext?
    private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("smart.js")

    func load() async {
        if ctx == nil, let s = try? String(contentsOf: cache, encoding: .utf8) { setUp(s) }
        // The copy that comes with the app: works with no server, and on the very first open
        if ctx == nil, let u = Bundle.main.url(forResource: "smart", withExtension: "js"), let s = try? String(contentsOf: u, encoding: .utf8) { setUp(s) }
        if Store.localOnly { return }
        if let d = try? await API.request("/smart.js", useToken: false), let s = String(data: d, encoding: .utf8), s.contains("PacelySmart") {
            try? d.write(to: cache)
            setUp(s)
        }
    }
    private func setUp(_ src: String) {
        let c = JSContext()
        c?.evaluateScript("var window = this; var globalThis = this;")
        c?.evaluateScript(src)
        if c?.objectForKeyedSubscript("PacelySmart")?.isUndefined == false { ctx = c }
    }

    func guess(_ title: String) -> (emoji: String, color: String)? {
        guard let g = ctx?.objectForKeyedSubscript("PacelySmart")?.invokeMethod("guess", withArguments: [title]),
              !g.isNull, !g.isUndefined,
              let e = g.objectForKeyedSubscript("emoji")?.toString(), let c = g.objectForKeyedSubscript("color")?.toString() else { return nil }
        return (e, c)
    }

    func parse(_ text: String, today: String) -> Parsed {
        guard let r = ctx?.objectForKeyedSubscript("PacelySmart")?.invokeMethod("parse", withArguments: [text, today]),
              let o = r.toDictionary() as? [String: Any] else { return Parsed(title: text) }
        var p = Parsed()
        p.title = o["title"] as? String
        p.date = o["date"] as? String
        p.start = o["start"] as? String
        p.duration = (o["duration"] as? NSNumber)?.intValue
        p.allday = o["allday"] as? String
        p.repeatRule = o["repeat"] as? [String: Any]
        return p
    }
}
