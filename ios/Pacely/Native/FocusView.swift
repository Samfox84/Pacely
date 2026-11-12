import SwiftUI
import UserNotifications

/// The focus timer: a colour that shrinks as time passes, with optional timed steps.
@MainActor
@Observable
final class FocusModel {
    static let shared = FocusModel()
    var minutes = UserDefaults.standard.object(forKey: "pacely.focusMins") as? Int ?? 25
    var title = ""
    var emoji = "⏳"
    var color = "#73CBA8"
    var itemId = 0
    var steps: [Step] = []
    var end: Date?
    var pausedLeft: TimeInterval?
    var started = Date()
    var total: TimeInterval = 25 * 60

    var running: Bool { end != nil }
    var paused: Bool { pausedLeft != nil }

    func start(for item: Item) {
        title = item.title; emoji = item.emoji; color = item.color; itemId = item.num
        steps = item.steps.filter { !$0.d }
        let stepMins = steps.reduce(0) { $0 + ($1.m ?? 0) }
        minutes = max(1, stepMins > 0 ? stepMins : item.duration)
        begin()
    }

    func begin() {
        total = TimeInterval(minutes * 60)
        started = Date()
        end = started.addingTimeInterval(total)
        pausedLeft = nil
        UserDefaults.standard.set(minutes, forKey: "pacely.focusMins")
        Feedback.success(); Feedback.sound("focus-start")
        sync()
    }

    func pause() {
        guard let e = end else { return }
        pausedLeft = max(0, e.timeIntervalSinceNow); end = nil
        Feedback.sound("pause")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pacely-focus"])
        Task { await LiveActivityManager.shared.endFocus() }
    }

    func resume() {
        guard let l = pausedLeft else { return }
        end = Date().addingTimeInterval(l); pausedLeft = nil
        Feedback.sound("focus-start")
        sync()
    }

    func stop(finished: Bool = false) {
        let usedMins = Int((total - (end.map { max(0, $0.timeIntervalSinceNow) } ?? pausedLeft ?? 0)) / 60)
        end = nil; pausedLeft = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pacely-focus"])
        Task {
            if usedMins >= 1 { try? await P.send("/api/focus/log", "POST", ["minutes": usedMins, "title": title]) }
            try? await P.send("/api/focus", "POST", [:])
            await LiveActivityManager.shared.endFocus()
        }
        if finished { Feedback.success(); Feedback.sound("timer") }
        title = ""; itemId = 0; steps = []
    }

    private func sync() {
        guard let e = end else { return }
        let label = title.isEmpty ? "Focus" : title
        Task {
            try? await P.send("/api/focus", "POST", ["end": Int(e.timeIntervalSince1970 * 1000), "total": Int(total),
                                                       "title": title.isEmpty ? "" : "\(emoji) \(title)", "item": itemId, "color": color])
            await LiveActivityManager.shared.startFocus(title: label, emoji: emoji, colorHex: color, start: started, end: e, itemId: itemId)
            await Scheduler.scheduleFocusEnd(at: e, title: "\(emoji) \(label)")
        }
    }

    /// Which step should be happening now, for timed steps.
    func currentStep(at now: Date) -> Int? {
        guard !steps.isEmpty, steps.contains(where: { ($0.m ?? 0) > 0 }) else { return nil }
        var t = started
        for (i, s) in steps.enumerated() {
            t = t.addingTimeInterval(TimeInterval((s.m ?? 0) * 60))
            if now < t { return i }
        }
        return steps.count - 1
    }
}

struct FocusView: View {
    @Bindable var planner: Planner
    @State private var f = FocusModel.shared
    @State private var lastStep: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = f.end.map { max(0, $0.timeIntervalSince(ctx.date)) } ?? f.pausedLeft ?? TimeInterval(f.minutes * 60)
                        let frac = f.total > 0 && (f.running || f.paused) ? left / f.total : 1
                        VStack(spacing: 18) {
                            ZStack {
                                Circle().fill(Color(hex: f.color).opacity(0.15))
                                PieShape(fraction: frac).fill(Color(hex: f.color))
                                    .animation(.linear(duration: 1), value: frac)
                                Text(f.emoji).font(.system(size: 54))
                            }
                            .frame(width: 250, height: 250)
                            Text(format(left)).font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                            if !f.title.isEmpty { Text(f.title).font(Look.f(.title3).bold()).multilineTextAlignment(.center) }
                            if let i = f.currentStep(at: ctx.date), f.running {
                                Text("Now: \(f.steps[i].t)").font(Look.f(.headline)).foregroundStyle(Color(hex: f.color))
                                    .onChange(of: i) { _, new in
                                        if lastStep != nil && lastStep != new { Feedback.soft(); Feedback.sound("next-step") }
                                        lastStep = new
                                    }
                            }
                        }
                        .onChange(of: left <= 0 && f.running) { _, over in if over { f.stop(finished: true); planner.say("Time's up. Take a breath") } }
                    }

                    if !f.running && !f.paused {
                        VStack(spacing: 12) {
                            Flow {
                                ForEach([5, 10, 15, 20, 25, 30, 45, 60], id: \.self) { m in
                                    Chip(text: "\(m) min", on: f.minutes == m) { f.minutes = m }
                                }
                            }
                            Stepper("\(f.minutes) minutes", value: $f.minutes, in: 1...240)
                            Button { f.begin() } label: { Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(Look.accent).controlSize(.large)
                        }
                    } else {
                        HStack(spacing: 12) {
                            if f.paused {
                                Button { f.resume() } label: { Label("Carry on", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                    .buttonStyle(.borderedProminent).tint(Look.accent)
                            } else {
                                Button { f.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                                    .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) { f.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        if f.itemId > 0 {
                            Button {
                                f.stop(finished: true)
                                if let it = planner.day.items.first(where: { $0.num == f.itemId }) { Task { await planner.toggleDone(it) } }
                            } label: { Label("Finished it", systemImage: "checkmark").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                    if !f.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(f.steps.enumerated()), id: \.offset) { _, s in
                                Text("• \(s.t)\(s.m.map { " · \($0) min" } ?? "")").font(Look.f(.subheadline))
                            }
                        }
                        .card()
                    }
                    Text("You'll get a gentle alert when the time is up, even if you leave Pacely.")
                        .font(Look.f(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .navigationTitle("Focus")
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The shrinking colour.
struct PieShape: Shape {
    var fraction: Double
    var animatableData: Double { get { fraction } set { fraction = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: min(r.width, r.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * max(0, min(1, fraction))), clockwise: false)
        p.closeSubpath()
        return p
    }
}
