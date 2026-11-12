import WidgetKit
import SwiftUI

/// Home Screen focus timer: start 10, 25 or 45 minutes with one tap, and watch the colour shrink.
struct PacelyFocusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PacelyEntry {
        PacelyEntry(date: Date(), payload: .sample, message: nil)
    }

    func snapshot(for configuration: PacelyWidgetConfig, in context: Context) async -> PacelyEntry {
        if context.isPreview { return placeholder(in: context) }
        return await PacelyLoader.load(configuration)
    }

    func timeline(for configuration: PacelyWidgetConfig, in context: Context) async -> Timeline<PacelyEntry> {
        let first = await PacelyLoader.load(configuration)
        var entries = [first]
        if let p = first.payload, let f = p.focus, f.endDate > Date() {
            // Switch back to the start buttons when the timer ends
            entries.append(PacelyEntry(date: f.endDate, payload: p.advanced(to: f.endDate.addingTimeInterval(1)), message: nil, link: first.link))
        }
        // Change the tip every half hour
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

struct PacelyFocusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PacelyFocusWidget", intent: PacelyWidgetConfig.self, provider: PacelyFocusProvider()) { entry in
            FocusWidgetView(entry: entry)
        }
        .configurationDisplayName("Pacely Focus")
        .description("A focus timer you can start straight from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private let focusTips = [
    "Phone face down. One thing at a time.",
    "Just start with the first tiny step.",
    "Water nearby? Headphones on?",
    "If a thought pops up, jot it down and come back.",
    "Done is better than perfect.",
    "Breathe out. You only need to do the next bit.",
    "Close the tabs you don't need.",
    "It's OK to stop when the timer ends."
]

private var tipOfTheMoment: String {
    let slot = Int(Date().timeIntervalSince1970 / 1800)
    return focusTips[slot % focusTips.count]
}

struct FocusWidgetView: View {
    let entry: PacelyEntry
    @Environment(\.widgetFamily) private var family

    private var focus: WidgetFocus? {
        guard let f = entry.payload?.focus, f.endDate > entry.date else { return nil }
        return f
    }
    private var tint: Color { Color(hex: focus?.color ?? "#73CBA8") }

    var body: some View {
        content
            .widgetURL(URL(string: "pacely://focus"))
            .containerBackground(for: .widget) {
                switch family {
                case .accessoryCircular, .accessoryRectangular:
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
        switch family {
        case .accessoryCircular:
            if let f = focus {
                ProgressView(timerInterval: f.range, countsDown: true) { EmptyView() } currentValueLabel: { Text("⏳") }
                    .progressViewStyle(.circular)
            } else {
                Button(intent: StartFocusIntent(minutes: 25)) {
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Text("⏳")
                            Text("25").font(.system(size: 11, weight: .bold))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        case .accessoryRectangular:
            if let f = focus {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).font(.headline).lineLimit(1)
                    Text(timerInterval: f.range, countsDown: true).monospacedDigit()
                    ProgressView(timerInterval: f.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                }
            } else {
                Button(intent: StartFocusIntent(minutes: 25)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("⏳ Focus").font(.headline)
                        Text("Tap to start 25 min").font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                FocusRing(focus: focus, tint: tint)
                    .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 8) {
                    if let f = focus {
                        Text("FOCUS").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                        Text(f.title).font(.headline).lineLimit(2)
                        Text(tipOfTheMoment).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer(minLength: 0)
                        Button(intent: StopFocusIntent()) {
                            Label("Stop", systemImage: "stop.fill").font(.caption.bold())
                        }
                        .tint(tint)
                    } else {
                        Text("FOCUS").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                        Text(tipOfTheMoment).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            ForEach([10, 25, 45], id: \.self) { m in
                                Button(intent: StartFocusIntent(minutes: m)) {
                                    Text("\(m)m").font(.caption.bold()).frame(maxWidth: .infinity)
                                }
                                .tint(tint)
                            }
                        }
                    }
                }
            }
        default:
            VStack(spacing: 8) {
                FocusRing(focus: focus, tint: tint)
                if let _ = focus {
                    Button(intent: StopFocusIntent()) {
                        Label("Stop", systemImage: "stop.fill").font(.caption.bold())
                    }
                    .tint(tint)
                } else {
                    HStack(spacing: 4) {
                        ForEach([10, 25], id: \.self) { m in
                            Button(intent: StartFocusIntent(minutes: m)) {
                                Text("\(m)m").font(.caption.bold()).frame(maxWidth: .infinity)
                            }
                            .tint(tint)
                        }
                    }
                }
            }
        }
    }
}

private struct FocusRing: View {
    let focus: WidgetFocus?
    let tint: Color
    var body: some View {
        ZStack {
            if let f = focus {
                ProgressView(timerInterval: f.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(tint)
                    .scaleEffect(2.2)
                Text(timerInterval: f.range, countsDown: true)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 70)
            } else {
                Circle().stroke(tint.opacity(0.35), lineWidth: 8)
                Text("⏳").font(.system(size: 30))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
