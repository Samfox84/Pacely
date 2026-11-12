import WidgetKit
import SwiftUI

// Watch-face complications for Pacely (watchOS 10+).
// They read your widget link from Config/widget-link.txt, which is built into the app.

private func hexColor(_ hex: String) -> Color {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    if !(s.count == 6 && Scanner(string: s).scanHexInt64(&v)) { v = 0x7CB8F0 }
    return Color(red: Double((v >> 16) & 0xFF) / 255.0, green: Double((v >> 8) & 0xFF) / 255.0, blue: Double(v & 0xFF) / 255.0)
}

struct WItem: Codable, Hashable {
    let title: String
    let emoji: String
    let color: String
    let start: String?
    let startTs: Double
    let endTs: Double
    let done: Bool
    var startDate: Date { Date(timeIntervalSince1970: startTs) }
    var endDate: Date { Date(timeIntervalSince1970: max(endTs, startTs + 60)) }
    var range: ClosedRange<Date> { startDate...endDate }
}

struct WPayload: Codable, Hashable {
    let now: WItem?
    let next: [WItem]
    let done: Int
    let total: Int

    func at(_ t: Date) -> WPayload {
        var all: [WItem] = []
        if let n = now { all.append(n) }
        all.append(contentsOf: next)
        all.sort { $0.startTs < $1.startTs }
        return WPayload(now: all.first { $0.startDate <= t && t < $0.endDate && !$0.done },
                        next: all.filter { $0.startDate > t && !$0.done }, done: done, total: total)
    }
}

struct WEntry: TimelineEntry {
    let date: Date
    let payload: WPayload?
    let needsLink: Bool
}

private var bundledLink: String {
    guard let url = Bundle.main.url(forResource: "widget-link", withExtension: "txt"),
          let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("http") } ?? ""
}

struct WProvider: TimelineProvider {
    func placeholder(in context: Context) -> WEntry {
        let n = Date()
        return WEntry(date: n, payload: WPayload(now: WItem(title: "Breakfast", emoji: "🥣", color: "#F4A07A", start: "08:00",
                                                         startTs: n.addingTimeInterval(-300).timeIntervalSince1970,
                                                         endTs: n.addingTimeInterval(900).timeIntervalSince1970, done: false),
                                              next: [], done: 1, total: 4), needsLink: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WEntry>) -> Void) {
        Task {
            let first = await load()
            var entries = [first]
            if let p = first.payload {
                var times: [Date] = []
                if let n = p.now { times.append(n.endDate) }
                for i in p.next { times.append(i.startDate); times.append(i.endDate) }
                let limit = Date().addingTimeInterval(6 * 3600)
                for t in Array(Set(times)).filter({ $0 > Date() && $0 < limit }).sorted().prefix(12) {
                    entries.append(WEntry(date: t, payload: p.at(t), needsLink: false))
                }
            }
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(20 * 60))))
        }
    }

    private func load() async -> WEntry {
        let link = bundledLink
        guard !link.isEmpty, let url = URL(string: link) else { return WEntry(date: Date(), payload: nil, needsLink: true) }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(WPayload.self, from: data) else {
            return WEntry(date: Date(), payload: nil, needsLink: false)
        }
        return WEntry(date: Date(), payload: p, needsLink: false)
    }
}

struct PacelyComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PacelyComplication", provider: WProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Pacely")
        .description("What's now and next.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct ComplicationView: View {
    let entry: WEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let p = entry.payload
        switch family {
        case .accessoryCircular:
            if let cur = p?.now {
                ProgressView(timerInterval: cur.range, countsDown: true) { EmptyView() } currentValueLabel: { Text(cur.emoji) }
                    .progressViewStyle(.circular)
                    .tint(hexColor(cur.color))
            } else if let n = p?.next.first {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Text(n.emoji)
                        Text(n.start ?? "").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }
                }
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "circle.dotted.circle")
                }
            }
        case .accessoryCorner:
            if let cur = p?.now {
                Text(cur.emoji)
                    .widgetLabel {
                        ProgressView(timerInterval: cur.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(hexColor(cur.color))
                    }
            } else if let n = p?.next.first {
                Text(n.emoji).widgetLabel(n.start ?? "Next")
            } else {
                Image(systemName: "circle.dotted.circle").widgetLabel("Pacely")
            }
        case .accessoryInline:
            if let cur = p?.now {
                Text("\(cur.emoji) \(cur.title) · \(cur.endDate, style: .timer)")
            } else if let n = p?.next.first {
                Text("Next \(n.start ?? ""): \(n.emoji) \(n.title)")
            } else {
                Text(entry.needsLink ? "Pacely: add widget link" : "🌿 All clear")
            }
        default:
            if let cur = p?.now {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cur.emoji) \(cur.title)").font(.headline).lineLimit(1)
                    Text(timerInterval: cur.range, countsDown: true).monospacedDigit()
                    ProgressView(timerInterval: cur.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(hexColor(cur.color))
                }
            } else if let n = p?.next.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next · \(n.start ?? "")").font(.caption).foregroundStyle(.secondary)
                    Text("\(n.emoji) \(n.title)").font(.headline).lineLimit(2)
                }
            } else if entry.needsLink {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pacely").font(.headline)
                    Text("Add your widget link to Config/widget-link.txt and rebuild").font(.caption2).lineLimit(3)
                }
            } else {
                Text("🌿 All clear today").font(.headline)
            }
        }
    }
}

@main
struct PacelyWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        PacelyComplication()
    }
}
