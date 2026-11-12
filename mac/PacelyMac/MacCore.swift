import Foundation

/// Saved settings for this Mac. A server password is never stored, only the app key the server gives back.
enum Store {
    private static let d = UserDefaults.standard

    /// Where plans are kept: "local" (on this Mac), "server", or "" when not chosen yet.
    static var mode: String {
        get {
            if let m = d.string(forKey: "mode") { return m }
            return (!server.isEmpty && !token.isEmpty) ? "server" : ""
        }
        set { d.set(newValue, forKey: "mode") }
    }
    static var server: String {
        get { d.string(forKey: "server") ?? "" }
        set { d.set(newValue, forKey: "server") }
    }
    static var token: String {
        get { d.string(forKey: "token") ?? "" }
        set { d.set(newValue, forKey: "token") }
    }
    static var isSetUp: Bool { mode == "local" || (mode == "server" && !server.isEmpty && !token.isEmpty) }

    static var popups: Bool {
        get { d.object(forKey: "popups") as? Bool ?? true }
        set { d.set(newValue, forKey: "popups") }
    }
    static var sound: Bool {
        get { d.object(forKey: "sound") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound") }
    }
    static var banners: Bool {
        get { d.object(forKey: "banners") as? Bool ?? false }
        set { d.set(newValue, forKey: "banners") }
    }

    static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum APIError: LocalizedError {
    case http(Int, String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String { return msg }
            return "The server answered with error \(code)."
        case .message(let m):
            return m
        }
    }
}

enum API {
    static func url(_ path: String) -> URL? { URL(string: Store.server + path) }

    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, useToken: Bool = true) async throws -> Data {
        guard let u = url(path) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = 30
        if useToken && !Store.token.isEmpty { r.setValue("Bearer \(Store.token)", forHTTPHeaderField: "Authorization") }
        if let body = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200..<300).contains(h.statusCode) { throw APIError.http(h.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return data
    }
}

struct UpcomingItem: Codable, Hashable, Identifiable {
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
}

struct FocusInfo: Codable { let end: Double; let title: String? }

struct UpcomingPayload: Codable {
    let items: [UpcomingItem]
    let focus: FocusInfo?
    let tz: String?
}

/// An activity with real start and end times worked out.
struct Planned: Identifiable, Hashable {
    let item: UpcomingItem
    let start: Date
    let end: Date
    var id: Int { item.id }
    var label: String { "\(item.emoji ?? "") \(item.title)".trimmingCharacters(in: .whitespaces) }
    var canTick: Bool { item.id > 0 }
}
