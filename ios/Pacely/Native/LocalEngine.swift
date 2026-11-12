import Foundation
import JavaScriptCore

/// "Just this phone" mode: Pacely runs entirely on the iPhone, with no server.
///
/// It uses the same on-device engine as the web app and the Mac app (Engine/local.js), running inside
/// JavaScriptCore. The engine answers the same requests the Pacely server does, so the rest of the app
/// doesn't need to know the difference. Your plans are saved in a file in the app's own storage
/// (Application Support/pacely-local.json), which you can export from Me › Save a copy.
///
/// Not available in this mode: sharing with a partner, live TfL journeys, and home screen widgets
/// (they need a server). Notifications, the Lock Screen countdown and the AI helper (with your own
/// Gemini key) all work.
final class LocalEngine: @unchecked Sendable {
    static let shared = LocalEngine()

    private let queue = DispatchQueue(label: "pacely.local-engine", qos: .userInitiated)
    private var ctx: JSContext?
    private var started = false
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimer = 1

    static let file: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("pacely-local.json")
    }()

    struct Failure: LocalizedError {
        let status: Int, message: String
        var errorDescription: String? { message }
    }

    // MARK: start up (on the engine's own queue, never the main thread)

    private func boot() {
        guard !started else { return }
        started = true
        guard let c = JSContext() else { return }
        c.exceptionHandler = { _, e in print("Pacely local engine:", e?.toString() ?? "?") }

        // A tiny browser-like world for the engine: timers, storage, and fetch through URLSession
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in
            guard let self else { return 0 }
            let id = self.nextTimer; self.nextTimer += 1
            let work = DispatchWorkItem { [weak self] in
                self?.timers[id] = nil
                fn.call(withArguments: [])
            }
            self.timers[id] = work
            self.queue.asyncAfter(deadline: .now() + ms / 1000, execute: work)
            return id
        }
        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers[id]?.cancel(); self?.timers[id] = nil
        }
        let save: @convention(block) (String) -> Void = { text in
            try? Data(text.utf8).write(to: LocalEngine.file, options: .atomic)
        }
        let changed: @convention(block) () -> Void = {
            Task { @MainActor in
                // The plan changed (for example a calendar finished syncing): refresh the screen
                NotificationCenter.default.post(name: .pacelyLocalChanged, object: nil)
            }
        }
        let nativeFetch: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] json, resolve, reject in
            guard let self,
                  let req = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let url = URL(string: req["url"] as? String ?? "") else {
                reject.call(withArguments: ["Bad request"]); return
            }
            var r = URLRequest(url: url)
            r.httpMethod = req["method"] as? String ?? "GET"
            r.timeoutInterval = 120
            for (k, v) in req["headers"] as? [String: String] ?? [:] { r.setValue(v, forHTTPHeaderField: k) }
            if let b = req["body"] as? String { r.httpBody = Data(b.utf8) }
            URLSession.shared.dataTask(with: r) { data, resp, err in
                self.queue.async {
                    if let err { reject.call(withArguments: [err.localizedDescription]); return }
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    resolve.call(withArguments: [["status": status, "text": text]])
                }
            }.resume()
        }
        c.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        c.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
        c.setObject(save, forKeyedSubscript: "__pacelySave" as NSString)
        c.setObject(changed, forKeyedSubscript: "__pacelyChanged" as NSString)
        c.setObject(nativeFetch, forKeyedSubscript: "__pacelyFetch" as NSString)

        let saved = (try? String(contentsOf: LocalEngine.file, encoding: .utf8)) ?? "null"
        c.evaluateScript("""
            var window = globalThis;
            window.PACELY_MODE = 'local';
            window.PACELY_LOCAL_DATA = \(saved.isEmpty ? "null" : saved);
            window.addEventListener = function () {};
            var document = { addEventListener: function () {}, visibilityState: 'visible' };
            var navigator = {};
            var console = { log: function () {}, warn: function () {}, error: function () {} };
            if (typeof URL === 'undefined') {   // JavaScriptCore has no URL class: a small one for "/api/day?date=…"
              globalThis.URL = function (path) {
                var i = path.indexOf('?'), m = {};
                this.pathname = i < 0 ? path : path.slice(0, i);
                (i < 0 ? '' : path.slice(i + 1)).split('&').forEach(function (kv) {
                  if (!kv) return;
                  var j = kv.indexOf('='), dec = function (x) { return decodeURIComponent(x.replace(/\\+/g, ' ')); };
                  var k = dec(j < 0 ? kv : kv.slice(0, j)); if (!(k in m)) m[k] = j < 0 ? '' : dec(kv.slice(j + 1));
                });
                this.searchParams = { get: function (k) { return k in m ? m[k] : null; }, has: function (k) { return k in m; } };
              };
            }
            window.webkit = { messageHandlers: {
              pacely: { postMessage: function (m) { if (m.type === 'saveLocal') __pacelySave(m.data); else if (m.type === 'changed') __pacelyChanged(); } },
              pacelyFetch: { postMessage: function (req) { return new Promise(function (res, rej) { __pacelyFetch(JSON.stringify(req), res, function (e) { rej(new Error(e)); }); }); } }
            } };
            """)
        for name in ["ical.min", "smart", "local"] {
            if let u = Bundle.main.url(forResource: name, withExtension: "js"), let src = try? String(contentsOf: u, encoding: .utf8) {
                c.evaluateScript(src, withSourceURL: u)
            }
        }
        // Answers go back to Swift as JSON text
        c.evaluateScript("""
            window.__pacelyCall = function (method, path, bodyJson, done) {
              LOCAL.call(method, path, bodyJson ? JSON.parse(bodyJson) : null)
                .then(function (r) { done(200, JSON.stringify(r === undefined ? {ok: true} : r)); })
                .catch(function (e) { done(e && e.status ? e.status : 500, JSON.stringify({error: (e && e.message) || 'Something went wrong'})); });
            };
            """)
        ctx = c
    }

    // MARK: requests

    /// Answers a Pacely API request on the phone. Same paths and replies as the server.
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let bodyJson = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.boot()
                guard let c = self.ctx, let call = c.objectForKeyedSubscript("__pacelyCall"), !call.isUndefined else {
                    cont.resume(throwing: Failure(status: 500, message: "Pacely couldn't start on this phone.")); return
                }
                var finished = false
                let done: @convention(block) (Int, String) -> Void = { status, text in
                    guard !finished else { return }
                    finished = true
                    if (200..<300).contains(status) { cont.resume(returning: Data(text.utf8)) }
                    else {
                        let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? String
                        cont.resume(throwing: APIError.http(status, text.isEmpty ? (msg ?? "") : text))
                    }
                }
                call.call(withArguments: [method.uppercased(), path, bodyJson ?? NSNull(), unsafeBitCast(done, to: AnyObject.self)])
            }
        }
    }

    /// Starts a fresh plan on this phone (or from a backup file's contents).
    func start(backup: Data? = nil) async throws {
        if let backup { try backup.write(to: LocalEngine.file, options: .atomic) }
        _ = try await request("/api/me")
    }

    /// The whole plan as a backup file (the same format the server and web app use).
    func exportText() async -> String {
        (try? await request("/api/export")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension Notification.Name {
    static let pacelyLocalChanged = Notification.Name("pacelyLocalChanged")
}
