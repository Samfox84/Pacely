import Foundation

/// Saved settings for this phone. Your password is never stored, only the app key the server gives back.
enum Store {
    static let refreshID = "io.github.samfox84.pacely.refresh"
    private static let d = UserDefaults.standard

    static var server: String {
        get { d.string(forKey: "server") ?? "" }
        set { d.set(newValue, forKey: "server") }
    }
    static var token: String {
        get { d.string(forKey: "token") ?? "" }
        set { d.set(newValue, forKey: "token") }
    }
    static var widgetCode: String {
        get { d.string(forKey: "widgetCode") ?? "" }
        set { d.set(newValue, forKey: "widgetCode") }
    }
    /// "Just this phone": no server, everything is kept on the iPhone (see LocalEngine)
    static var localOnly: Bool {
        get { d.bool(forKey: "localOnly") }
        set { d.set(newValue, forKey: "localOnly") }
    }
    static var isSetUp: Bool { localOnly || (!server.isEmpty && !token.isEmpty) }

    static var widgetLink: String {
        server.isEmpty || widgetCode.isEmpty ? "" : server + "/api/widget?k=" + widgetCode
    }

    /// Turns "plan.example.co.uk" into "https://plan.example.co.uk" with no trailing slash.
    static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum APIError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String {
                return msg
            }
            return "The server answered with error \(code)."
        }
    }
}

enum API {
    static func url(_ path: String) -> URL? {
        URL(string: Store.server + path)
    }

    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, useToken: Bool = true,
                        timeout: TimeInterval = 30) async throws -> Data {
        if Store.localOnly && path.hasPrefix("/api/") {
            return try await LocalEngine.shared.request(path, method: method, body: body)
        }
        guard let u = url(path) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if useToken && !Store.token.isEmpty {
            r.setValue("Bearer \(Store.token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200..<300).contains(h.statusCode) {
            throw APIError.http(h.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

// What /api/upcoming returns
struct UpcomingItem: Codable {
    let id: Int
    let date: String
    let start: String
    let duration: Int
    let title: String
    let emoji: String?
    let color: String?
    let remind: Int?
    let end_alert: Int?
    let done: Int?
    let nag: Int?
    let leave: String?
    let travel_min: Int?
    let travel_by: String?
}

/// Gentle body reminders (drink, eat, rest) and today's route to work, from /api/upcoming.
struct NudgePayload: Codable {
    struct Nudge: Codable { let date: String; let key: String; let time: String; let title: String; let body: String }
    struct Route: Codable { let leave: String?; let summary: String?; let date: String? }
    let nudges: [Nudge]?
    let commute: Route?
    let leave_style: String?
    let quiet_from: String?
    let quiet_to: String?
}

struct FocusInfo: Codable {
    let end: Double
    let title: String?
}

struct UpcomingPayload: Codable {
    let items: [UpcomingItem]
    let focus: FocusInfo?
    let tz: String?
}

extension UpcomingPayload {
    func at(_ date: String, _ hhmm: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz ?? TimeZone.current.identifier) ?? .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(date) \(hhmm)")
    }
    func startDate(_ item: UpcomingItem) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz ?? TimeZone.current.identifier) ?? .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(item.date) \(item.start)")
    }
}
