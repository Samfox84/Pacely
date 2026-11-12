import SwiftUI
import AVFoundation

// MARK: - A copy of your plan kept on the phone

/// Every screen's last answer from the server is saved on the phone, so Pacely opens instantly
/// (even with no signal) and then quietly catches up in the background.
enum LocalCopy {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PacelyLocal", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ path: String) -> URL {
        let key = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(150))
        return dir.appendingPathComponent(key + ".json")
    }
    static func keep(_ path: String) -> Bool {
        path.hasPrefix("/api/") && !path.hasPrefix("/api/ai/job") && !path.hasPrefix("/api/live") && !path.hasPrefix("/api/ai/check")
    }
    static func save(_ path: String, _ data: Data) {
        guard keep(path) else { return }
        try? data.write(to: file(path), options: .atomic)
    }
    static func load(_ path: String) -> Data? { try? Data(contentsOf: file(path)) }
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Outbox.clear()
    }
}

/// Is this error just "couldn't reach the server right now"? (No signal, server asleep, tunnel down.)
func isOffline(_ e: Error) -> Bool {
    if let u = e as? URLError {
        return [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed].contains(u.code)
    }
    if case APIError.http(let code, _) = e { return [502, 503, 504, 521, 522, 523, 524, 530].contains(code) }
    return false
}

/// Changes you make while offline wait here, in order, and are sent as soon as the server answers again.
enum Outbox {
    struct Change: Codable { let path: String; let method: String; let body: Data? }
    private static let file = LocalCopy.dir.appendingPathComponent("outbox.json")
    private static let lock = NSLock()

    static var all: [Change] {
        lock.lock(); defer { lock.unlock() }
        return (try? JSONDecoder().decode([Change].self, from: Data(contentsOf: file))) ?? []
    }
    static var count: Int { all.count }
    private static func write(_ list: [Change]) {
        lock.lock(); defer { lock.unlock() }
        if list.isEmpty { try? FileManager.default.removeItem(at: file) }
        else { try? JSONEncoder().encode(list).write(to: file, options: .atomic) }
    }
    static func add(_ path: String, _ method: String, _ body: [String: Any]) {
        var list = all
        list.append(Change(path: path, method: method, body: try? JSONSerialization.data(withJSONObject: body)))
        write(list)
    }
    static func clear() { write([]) }

    /// Sends waiting changes. Stops at the first one that can't get through, so the order is kept.
    @discardableResult
    static func flush() async -> Int {
        var list = all
        var sent = 0
        while let ch = list.first {
            let body = ch.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            do {
                _ = try await API.request(ch.path, method: ch.method, body: body, timeout: 15)
                sent += 1
            } catch {
                if isOffline(error) { break }
                // The server said no (for example the item was deleted elsewhere): drop it, don't retry forever
            }
            list.removeFirst()
            write(list)
        }
        return sent
    }
}

// MARK: - Sounds, played off the main thread so the screen never stutters

final class SoundPlayer: @unchecked Sendable {
    static let shared = SoundPlayer()
    private let queue = DispatchQueue(label: "pacely.sound", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var ready = false

    /// Sets the sound style once (mixes with your music, respects the silent switch).
    func prepare() { queue.async { self.setUp() } }
    private func setUp() {
        guard !ready else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        ready = true
    }
    func play(_ url: URL, volume: Float = 0.7) {
        queue.async {
            self.setUp()
            let p = try? AVAudioPlayer(contentsOf: url)
            p?.volume = volume
            p?.play()
            self.player = p
        }
    }
}

// MARK: - First open: a calm screen until your day is ready

struct LoadingView: View {
    @Bindable var planner: Planner
    @State private var started = Date()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let t = ctx.date.timeIntervalSince(started)
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "sun.horizon")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Look.accent)
                    .symbolEffect(.breathe, options: .repeating)
                Text("Getting your day ready…").font(Look.f(.title3).weight(.semibold))
                if t > 6 {
                    Text("Your server is taking a while to answer. You can carry on and Pacely will catch up when it can.")
                        .font(Look.f(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Carry on") { planner.ready = true }
                        .buttonStyle(.borderedProminent).tint(Look.accent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
        .accessibilityElement(children: .contain)
    }
}

/// A small note when Pacely can't reach your server, or has changes waiting to send.
struct OfflinePill: View {
    @Bindable var planner: Planner
    var body: some View {
        if planner.offline || planner.pending > 0 {
            Label(planner.offline
                  ? (planner.pending > 0 ? "Offline · \(planner.pending) change\(planner.pending == 1 ? "" : "s") will sync later" : "Offline · showing your saved copy")
                  : "Syncing \(planner.pending) change\(planner.pending == 1 ? "" : "s")…",
                  systemImage: planner.offline ? "icloud.slash" : "arrow.triangle.2.circlepath")
                .font(Look.f(.footnote).weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
                .accessibilityLabel(planner.offline ? "Offline. Showing your saved copy." : "Syncing changes")
        }
    }
}

struct SyncVersion: Decodable { let v: Int }

// MARK: - The keyboard goes away when you're done with it

/// Tap anywhere outside a text box, or scroll, and the keyboard slides away. (Taps still reach buttons as normal.)
enum KeyboardTidy {
    @MainActor static func install() {
        UIScrollView.appearance().keyboardDismissMode = .interactive
        UIScrollView.appearance().showsVerticalScrollIndicator = false     // no web-page style scroll bars
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows where !(w.gestureRecognizers ?? []).contains(where: { $0.name == "pacely.dismissKeyboard" }) {
                let tap = UITapGestureRecognizer(target: w, action: #selector(UIView.endEditing(_:)))
                tap.name = "pacely.dismissKeyboard"
                tap.cancelsTouchesInView = false
                tap.requiresExclusiveTouchType = false
                tap.delegate = KeyboardTapDelegate.shared
                w.addGestureRecognizer(tap)
            }
        }
    }
}

final class KeyboardTapDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardTapDelegate()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Don't close the keyboard when tapping in a text box itself
        var v = touch.view
        while let x = v { if x is UITextField || x is UITextView { return false }; v = x.superview }
        return true
    }
}
