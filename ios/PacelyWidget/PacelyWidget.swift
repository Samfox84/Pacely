import WidgetKit
import SwiftUI
import AppIntents

/// Widget settings: paste the widget link from Pacely → Me → iPhone app settings.
struct PacelyWidgetConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pacely"
    static var description = IntentDescription("Shows what's happening now and next.")

    @Parameter(title: "Widget link")
    var link: String?
}

struct PacelyEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload?
    let message: String?
    var link: String = ""
}

/// The ✓ button on the widget. Uses the widget link, which can only tick things off.
struct CompleteActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick off"
    static var description = IntentDescription("Marks a Pacely activity as done.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Widget link") var link: String
    @Parameter(title: "Activity") var itemId: Int

    init() {}
    init(link: String, itemId: Int) {
        self.link = link
        self.itemId = itemId
    }

    func perform() async throws -> some IntentResult {
        guard var comps = URLComponents(string: link) else { return .result() }
        let key = comps.queryItems?.first(where: { $0.name == "k" })?.value ?? ""
        comps.path = "/api/widget/done"
        comps.queryItems = [URLQueryItem(name: "k", value: key), URLQueryItem(name: "id", value: String(itemId))]
        if let url = comps.url {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.timeoutInterval = 15
            _ = try? await URLSession.shared.data(for: r)
        }
        return .result()
    }
}

struct DoneButton: View {
    let item: WidgetItem
    let link: String
    var body: some View {
        if let id = item.id, id > 0, !link.isEmpty {
            Button(intent: CompleteActivityIntent(link: link, itemId: id)) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Color(hex: item.color), in: Circle())
                    .foregroundStyle(.black.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
    }
}

struct PacelyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PacelyEntry {
        PacelyEntry(date: Date(), payload: .sample, message: nil)
    }

    func snapshot(for configuration: PacelyWidgetConfig, in context: Context) async -> PacelyEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration)
    }

    func timeline(for configuration: PacelyWidgetConfig, in context: Context) async -> Timeline<PacelyEntry> {
        let first = await load(configuration)
        var entries = [first]
        if let p = first.payload {
            var times: [Date] = []
            if let n = p.now { times.append(n.endDate) }
            for item in p.next {
                times.append(item.startDate)
                times.append(item.endDate)
            }
            let limit = Date().addingTimeInterval(6 * 3600)
            let unique = Array(Set(times)).filter { $0 > Date() && $0 < limit }.sorted().prefix(12)
            for t in unique {
                entries.append(PacelyEntry(date: t, payload: p.advanced(to: t), message: nil, link: first.link))
            }
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(20 * 60)))
    }

    private func load(_ config: PacelyWidgetConfig) async -> PacelyEntry {
        await PacelyLoader.load(config)
    }
}

/// Shared by the main widget and the focus widget.
enum PacelyLoader {
    static func link(_ config: PacelyWidgetConfig) -> String {
        let l = (config.link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return l.isEmpty ? BundledLink.value : l
    }

    static func load(_ config: PacelyWidgetConfig) async -> PacelyEntry {
        let link = Self.link(config)
        guard !link.isEmpty, let url = URL(string: link) else {
            return PacelyEntry(date: Date(), payload: nil, message: "Hold this widget, tap Edit Widget and paste your widget link from the Pacely app.")
        }
        do {
            var r = URLRequest(url: url)
            r.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                return PacelyEntry(date: Date(), payload: nil, message: "The widget link isn't working. Copy it again from the Pacely app.")
            }
            let p = try JSONDecoder().decode(WidgetPayload.self, from: data)
            return PacelyEntry(date: Date(), payload: p, message: nil, link: link)
        } catch {
            return PacelyEntry(date: Date(), payload: nil, message: "Can't reach Pacely right now.")
        }
    }
}

struct PacelyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PacelyWidget", intent: PacelyWidgetConfig.self, provider: PacelyProvider()) { entry in
            PacelyWidgetView(entry: entry)
        }
        .configurationDisplayName("Pacely")
        .description("What's happening now and next.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Views

struct PacelyWidgetView: View {
    let entry: PacelyEntry
    @Environment(\.widgetFamily) private var family

    private var tint: Color {
        if let n = entry.payload?.now { return Color(hex: n.color) }
        if let n = entry.payload?.next.first { return Color(hex: n.color) }
        return Color(hex: "#73CBA8")
    }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                switch family {
                case .accessoryRectangular, .accessoryCircular, .accessoryInline:
                    Color.clear
                default:
                    ZStack {
                        Color(.systemBackground)
                        tint.opacity(0.22)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let msg = entry.message {
            switch family {
            case .accessoryInline: Text("Pacely: set up widget")
            case .accessoryCircular: Image(systemName: "circle.dotted")
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pacely").font(.headline)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let p = entry.payload {
            switch family {
            case .systemSmall: SmallView(p: p, link: entry.link)
            case .systemMedium: MediumView(p: p, link: entry.link)
            case .systemLarge: LargeView(p: p, link: entry.link)
            case .accessoryRectangular: RectView(p: p)
            case .accessoryCircular: CircleView(p: p)
            case .accessoryInline: InlineView(p: p)
            default: SmallView(p: p, link: entry.link)
            }
        }
    }
}

private struct Label2: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct Bar: View {
    let item: WidgetItem
    var body: some View {
        ProgressView(timerInterval: item.range, countsDown: true) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .tint(Color(hex: item.color))
    }
}

private struct SmallView: View {
    let p: WidgetPayload
    var link: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cur = p.now {
                HStack {
                    Label2(text: "Now")
                    Spacer()
                    PacelyIcon(emoji: cur.emoji, size: 22).font(.title2)
                }
                Text(cur.title).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                HStack {
                    Text(timerInterval: cur.range, countsDown: true)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Spacer()
                    DoneButton(item: cur, link: link)
                }
                Bar(item: cur)
            } else if let n = p.next.first {
                HStack {
                    Label2(text: "Next")
                    Spacer()
                    PacelyIcon(emoji: n.emoji, size: 22).font(.title2)
                }
                Text(n.title).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                Text("at \(n.start ?? "")").font(.subheadline).foregroundStyle(.secondary)
                Text(n.startDate, style: .relative).font(.caption).foregroundStyle(.secondary)
            } else {
                Label2(text: "Today")
                Spacer()
                Text("🌿").font(.largeTitle)
                Text("All clear").font(.headline)
                Text("\(p.done) of \(p.total) done").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Row: View {
    let item: WidgetItem
    var link: String = ""
    var body: some View {
        HStack(spacing: 8) {
            PacelyIcon(emoji: item.emoji, size: 17)
                .frame(width: 28, height: 28)
                .background(Color(hex: item.color).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Text(item.start ?? "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if !link.isEmpty { DoneButton(item: item, link: link).scaleEffect(0.8) }
        }
    }
}

private struct MediumView: View {
    let p: WidgetPayload
    var link: String = ""
    var body: some View {
        HStack(spacing: 14) {
            SmallView(p: WidgetPayload(now: p.now, next: p.now == nil ? Array(p.next.prefix(1)) : [], done: p.done, total: p.total, date: p.date), link: link)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Label2(text: p.now == nil ? "Later" : "Next")
                let rest = p.now == nil ? Array(p.next.dropFirst().prefix(3)) : Array(p.next.prefix(3))
                if rest.isEmpty {
                    Text("Nothing else planned").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rest, id: \.self) { Row(item: $0) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LargeView: View {
    let p: WidgetPayload
    var link: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pacely").font(.headline)
                Spacer()
                Text("\(p.done)/\(p.total) done").font(.caption).foregroundStyle(.secondary)
            }
            if let cur = p.now {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        PacelyIcon(emoji: cur.emoji, size: 32)
                        VStack(alignment: .leading) {
                            Label2(text: "Now")
                            Text(cur.title).font(.title3.bold()).lineLimit(2)
                        }
                        Spacer()
                        Text(timerInterval: cur.range, countsDown: true)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        DoneButton(item: cur, link: link)
                    }
                    Bar(item: cur)
                    if cur.steps > 0 {
                        Text("\(cur.stepsDone) of \(cur.steps) steps done").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color(hex: cur.color).opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
            }
            Label2(text: "Coming up")
            if p.next.isEmpty {
                Text("Nothing else planned today 🌿").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(p.next.prefix(5)), id: \.self) { Row(item: $0, link: link) }
            Spacer(minLength: 0)
        }
    }
}

private struct RectView: View {
    let p: WidgetPayload
    var body: some View {
        if let cur = p.now {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cur.emoji) \(cur.title)").font(.headline).lineLimit(1)
                Text(timerInterval: cur.range, countsDown: true).monospacedDigit()
                ProgressView(timerInterval: cur.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            }
        } else if let n = p.next.first {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next · \(n.start ?? "")").font(.caption).foregroundStyle(.secondary)
                Text("\(n.emoji) \(n.title)").font(.headline).lineLimit(2)
            }
        } else {
            Text("🌿 All clear today").font(.headline)
        }
    }
}

private struct CircleView: View {
    let p: WidgetPayload
    var body: some View {
        if let cur = p.now {
            ProgressView(timerInterval: cur.range, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                PacelyIcon(emoji: cur.emoji, size: 22)
            }
            .progressViewStyle(.circular)
        } else if let n = p.next.first {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    PacelyIcon(emoji: n.emoji, size: 22)
                    Text(n.start ?? "").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                }
            }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Text("🌿")
            }
        }
    }
}

private struct InlineView: View {
    let p: WidgetPayload
    var body: some View {
        if let cur = p.now {
            Text("\(cur.emoji) \(cur.title) · until \(cur.endDate, style: .time)")
        } else if let n = p.next.first {
            Text("Next: \(n.emoji) \(n.title) \(n.start ?? "")")
        } else {
            Text("🌿 All clear")
        }
    }
}
