import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct PacelyWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup {
            WatchHome()
                .environmentObject(model)
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        if !(s.count == 6 && Scanner(string: s).scanHexInt64(&v)) { v = 0x7CB8F0 }
        self.init(red: Double((v >> 16) & 0xFF) / 255.0, green: Double((v >> 8) & 0xFF) / 255.0, blue: Double(v & 0xFF) / 255.0)
    }
}

struct WatchStep: Codable, Hashable {
    var t: String
    var d: Bool
    var m: Int?
}

/// One activity from /api/day. Calendar events have text ids like "c12" and can't be ticked off.
struct WatchItem: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let emoji: String
    let color: String
    let start: String?
    let duration: Int
    var done: Bool
    var steps: [WatchStep]

    var numericId: Int? { Int(id) }

    enum CodingKeys: String, CodingKey { case id, kind, title, emoji, color, start, duration, done, steps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) } else { id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString }
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "event"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        emoji = (try? c.decode(String.self, forKey: .emoji)) ?? "📝"
        color = (try? c.decode(String.self, forKey: .color)) ?? "#7CB8F0"
        start = try? c.decode(String.self, forKey: .start)
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 30
        if let b = try? c.decode(Bool.self, forKey: .done) { done = b } else { done = ((try? c.decode(Int.self, forKey: .done)) ?? 0) != 0 }
        steps = (try? c.decode([WatchStep].self, forKey: .steps)) ?? []
    }
}

private struct DayResponse: Decodable {
    let date: String
    let items: [WatchItem]
}

@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var items: [WatchItem] = []
    @Published var loading = false
    @Published var message: String?
    @Published var linked = false

    private let d = UserDefaults.standard
    var server: String { d.string(forKey: "server") ?? "" }
    var token: String { d.string(forKey: "token") ?? "" }

    override init() {
        super.init()
        linked = !server.isEmpty && !token.isEmpty
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func dayStart(_ item: WatchItem) -> Date? {
        guard let s = item.start else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let day = DateFormatter()
        day.locale = f.locale
        day.timeZone = f.timeZone
        day.dateFormat = "yyyy-MM-dd"
        return f.date(from: "\(day.string(from: Date())) \(s)")
    }

    var current: WatchItem? {
        let now = Date()
        return items.first { i in
            guard !i.done, let st = dayStart(i) else { return false }
            return st <= now && now < st.addingTimeInterval(TimeInterval(i.duration * 60))
        }
    }

    var upcoming: [WatchItem] {
        let now = Date()
        return items.filter { i in
            guard !i.done else { return false }
            guard let st = dayStart(i) else { return true }
            return st > now
        }
    }

    func refresh() async {
        guard linked, let url = URL(string: server + "/api/day") else {
            askPhone()
            return
        }
        loading = true
        defer { loading = false }
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode == 401 {
                message = "Open Pacely on your iPhone to link your watch again."
                return
            }
            items = try JSONDecoder().decode(DayResponse.self, from: data).items
            message = nil
        } catch {
            message = "Can't reach Pacely right now."
        }
    }

    func put(_ item: WatchItem, _ body: [String: Any]) async {
        guard let id = item.numericId, let url = URL(string: server + "/api/activities/\(id)") else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "PUT"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var b = body
        b["scope"] = "this"
        r.httpBody = try? JSONSerialization.data(withJSONObject: b)
        _ = try? await URLSession.shared.data(for: r)
    }

    /// Adds something from the watch. "now" puts it in today's plan straight away for 15 minutes.
    func add(_ title: String, now: Bool) async -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let url = URL(string: server + "/api/activities") else { return false }
        var body: [String: Any] = ["title": t, "emoji": "📝", "priority": "soon"]
        if now {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd"
            let tf = DateFormatter()
            tf.locale = f.locale
            tf.timeZone = f.timeZone
            tf.dateFormat = "HH:mm"
            body["kind"] = "event"
            body["date"] = f.string(from: Date())
            body["start"] = tf.string(from: Date())
            body["duration"] = 15
        } else {
            body["kind"] = "todo"
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return false }
        WKHaptic.success()
        await refresh()
        return true
    }

    func toggleDone(_ item: WatchItem) async {
        WKHaptic.success()
        await put(item, ["done": !item.done])
        await refresh()
    }

    func toggleStep(_ item: WatchItem, _ index: Int) async {
        var steps = item.steps
        guard steps.indices.contains(index) else { return }
        steps[index].d.toggle()
        WKHaptic.click()
        let payload = steps.map { s -> [String: Any] in
            var x: [String: Any] = ["t": s.t, "d": s.d]
            if let m = s.m { x["m"] = m }
            return x
        }
        if let i = items.firstIndex(of: item) { items[i].steps = steps }
        await put(item, ["steps": payload])
    }

    private func save(_ ctx: [String: Any]) {
        guard let s = ctx["server"] as? String, let t = ctx["token"] as? String, !s.isEmpty, !t.isEmpty else { return }
        d.set(s, forKey: "server")
        d.set(t, forKey: "token")
        linked = true
        Task { await refresh() }
    }

    func askPhone() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            message = linked ? message : "Open Pacely on your iPhone to link this watch."
            return
        }
        WCSession.default.sendMessage(["want": "login"], replyHandler: { reply in
            Task { @MainActor in self.save(reply) }
        }, errorHandler: nil)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            if !ctx.isEmpty { self.save(ctx) } else if !self.linked { self.askPhone() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.save(applicationContext) }
    }
}

/// Small wrapper so haptics read clearly.
enum WKHaptic {
    static func success() { WKInterfaceDevice.current().play(.success) }
    static func click() { WKInterfaceDevice.current().play(.click) }
}
