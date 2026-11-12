import SwiftUI

/// Which sheet is open.
enum Sheet: Identifiable {
    case detail(Item)
    case edit(Item?, Preset)
    case dictate((String) -> Void)
    case mood
    case review
    case couldnt(Item)
    case smart(String)
    var id: String {
        switch self {
        case .detail(let i): return "d\(i.id)"
        case .edit(let i, _): return "e\(i?.id ?? "new")"
        case .dictate: return "dictate"
        case .mood: return "mood"
        case .review: return "review"
        case .couldnt(let i): return "c\(i.id)"
        case .smart: return "smart"
        }
    }
}

/// Starting values for a new activity.
struct Preset {
    var kind = "event"
    var date: String? = nil
    var start: String? = nil
    var title = ""
    var plan = false
}

struct TodayView: View {
    @Bindable var planner: Planner
    @Binding var sheet: Sheet?
    @State private var quick = ""
    @FocusState private var quickFocus: Bool
    @AppStorage("pacely.calm") private var calm = true
    @AppStorage("pacely.simple") private var simple = false
    /// The calm layout (Me › Calm layout): just a top line, Now and the timeline. Everything else is one tap away.
    @AppStorage("pacely.calmLayout") private var calmLayout = false
    @State private var topOpen = false
    @State private var leftOpen = false
    @State private var addOpen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !calmLayout {
                        Picker("View", selection: $planner.mode) {
                            ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch planner.mode {
                    case .day: dayContent
                    case .week: WeekList(planner: planner)
                    case .month: MonthGrid(planner: planner)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
                .frame(maxWidth: .infinity, minHeight: 600, alignment: .top)
                .modifier(SwipeDays(planner: planner))      // swipe anywhere, even on cards
            }
            .coordinateSpace(name: SwipeDays.space)
            .onChange(of: planner.mode) { _, _ in Feedback.tap(); Task { await planner.load() } }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await planner.changed() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: header

    private var title: String {
        switch planner.mode {
        case .day: return ["Today", "Tomorrow", "Yesterday"].contains(Day.friendly(planner.date)) ? Day.friendly(planner.date) : Day.format(planner.date, "EEEE")
        case .week: return planner.date >= Day.mondayOf(Day.today) && planner.date < Day.add(Day.mondayOf(Day.today), 7) ? "This week" : "Week of " + Day.format(Day.mondayOf(planner.date), "d MMM")
        case .month: return Day.format(planner.date, "MMMM yyyy")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 34, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                if planner.mode == .day { Text(Day.format(planner.date, "d MMMM")).font(Look.f(.title3)).foregroundStyle(.secondary) }
            }
            Spacer()
            if planner.date != Day.today {
                Button("Today") { Feedback.tap(); planner.go(Day.today) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            if calmLayout {
                // Calm layout: Day, Week or Month sits in one small button instead of a full-width bar
                Menu {
                    Picker("View", selection: $planner.mode) {
                        ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) { Text(planner.mode.rawValue); Image(systemName: "chevron.down").font(.caption.bold()) }
                        .font(Look.f(.subheadline).weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.secondarySystemFill), in: Capsule())
                }
                .accessibilityLabel("Showing \(planner.mode.rawValue). Change view")
            } else if planner.mode == .day {
                Button { withAnimation(.easeInOut(duration: 0.25)) { simple.toggle() }; Feedback.sound(simple ? "toggle-on" : "toggle-off") } label: {
                    Image(systemName: simple ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(Look.f(.title3)).frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered).clipShape(Circle())
                .accessibilityLabel(simple ? "Show everything" : "Show less")
            }
        }
        .padding(.top, 8)
    }

    // MARK: day

    @ViewBuilder private var dayContent: some View {
        if calmLayout { calmDay } else { fullDay }
    }

    /// Calm layout: three things. A single line for the day (office day, when to leave), what's happening now, and the timeline.
    @ViewBuilder private var calmDay: some View {
        WeekStrip(planner: planner)
        calmTopLine
        if !planner.day.quiet.isEmpty { QuietCard(planner: planner) }
        quickAdd
        if !planner.leftovers.isEmpty {
            Button { withAnimation(.easeInOut(duration: 0.25)) { leftOpen.toggle() }; Feedback.tap() } label: {
                HStack {
                    Label("\(planner.leftovers.count) thing\(planner.leftovers.count == 1 ? "" : "s") from before", systemImage: "tray")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(leftOpen ? 180 : 0))
                }
                .font(Look.f(.subheadline)).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if leftOpen { LeftoversCard(planner: planner) }
        }
        VStack(alignment: .leading, spacing: 14) {
            if planner.isToday, let cur = current { NowCard(planner: planner, item: cur, calm: calm || Feedback.lowStim, sheet: $sheet) }
            timeline
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
        .saturation(0.8)     // softer colours; amber still shows for things that need you
    }

    /// "🏢 Office day · 🚇 Leave 07:35". Tap to see the details.
    @ViewBuilder private var calmTopLine: some View {
        let leg: (CommuteLeg, Bool)? = {
            guard planner.isToday, let c = planner.day.commute else { return nil }
            if let to = c.to, Clock.nowMin <= (Clock.minutes(to.leave) ?? 0) + to.minutes { return (to, false) }
            if let back = c.back { return (back, true) }
            return c.to.map { ($0, false) }
        }()
        let bits: [String] = planner.day.allday.map { "\($0.emoji) \($0.allday == "office" ? "Office" : $0.allday == "home" ? "Home" : $0.title)" }
            + (leg.map { ["\($0.1 ? "🏠" : "🚇") \($0.0.leave)"] } ?? [])
        let warn = leg?.0.status.contains { !$0.good } ?? false
        if !bits.isEmpty {
            Button { withAnimation(.easeInOut(duration: 0.25)) { topOpen.toggle() }; Feedback.tap() } label: {
                HStack(spacing: 8) {
                    Text(bits.joined(separator: "  ·  ")).font(Look.f(.subheadline).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    if warn { Circle().fill(Color.orange.opacity(0.7)).frame(width: 8, height: 8).accessibilityLabel("Some delays") }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(topOpen ? 180 : 0)).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(topOpen ? "Hides the details" : "Shows the details")
            if topOpen {
                VStack(spacing: 8) {
                    ForEach(planner.day.allday) { a in AllDayBanner(item: a) { if !a.isCal { sheet = .detail(a) } } }
                    if let lg = leg { CommuteCard(planner: planner, c: lg.0, home: lg.1) }
                }
            }
        }
    }

    @ViewBuilder private var fullDay: some View {
        if !simple { WeekStrip(planner: planner) }
        if !planner.day.allday.isEmpty {
            VStack(spacing: 8) {
                ForEach(planner.day.allday) { a in AllDayBanner(item: a) { if !a.isCal { sheet = .detail(a) } } }
            }
        }
        if !planner.day.quiet.isEmpty { QuietCard(planner: planner) }
        if planner.isToday, let c = planner.day.commute {
            // Morning: the way there. Once you've arrived: the way home.
            if let to = c.to, Clock.nowMin <= (Clock.minutes(to.leave) ?? 0) + to.minutes { CommuteCard(planner: planner, c: to) }
            else if let back = c.back { CommuteCard(planner: planner, c: back, home: true) }
            else if let to = c.to { CommuteCard(planner: planner, c: to) }
        }
        if simple {
            VStack(alignment: .leading, spacing: 14) {
                if planner.isToday, let cur = current { NowCard(planner: planner, item: cur, calm: calm, sheet: $sheet) }
                if let n = nextUp {
                    Text(current == nil ? "Next" : "Then").font(Look.f(.title3).bold())
                    ItemCard(planner: planner, item: n, sheet: $sheet)
                } else if current == nil {
                    Text("Nothing else planned. That's okay.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                let rest = planner.day.items.filter { !$0.done && !$0.isCal }.count - (current == nil ? 0 : 1) - (nextUp == nil ? 0 : 1)
                if rest > 0 {
                    Button("\(rest) more today · show everything") { withAnimation { simple = false } }.font(Look.f(.subheadline))
                }
            }
        } else {
        quickAdd
        if !planner.leftovers.isEmpty { LeftoversCard(planner: planner) }
        VStack(alignment: .leading, spacing: 14) {
            if planner.isToday, let cur = current { NowCard(planner: planner, item: cur, calm: calm, sheet: $sheet) }
            timeline
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
        }
    }

    /// The next thing still to do (after what's happening now).
    private var nextUp: Item? {
        let n = planner.isToday ? Clock.nowMin : -1
        let open = planner.day.items.filter { !$0.done && !$0.isCal && $0.id != current?.id }
        return open.first { ($0.startMin ?? 9999) >= n } ?? open.first { $0.startMin == nil }
    }

    private var current: Item? {
        let n = Clock.nowMin
        return planner.day.items.first { !$0.isCal && !$0.done && ($0.startMin ?? 9999) <= n && n < ($0.endMin ?? 0) }
    }

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add… e.g. call GP 9am", text: $quick)
                    .focused($quickFocus)
                    .submitLabel(.done)
                    .onSubmit(addQuick)
                    .onChange(of: quickFocus) { _, f in
                        // Calm layout: the extra add buttons appear while you're adding, and tuck away a moment after
                        if f { withAnimation { addOpen = true } }
                        else { Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if !quickFocus && quick.isEmpty { withAnimation { addOpen = false } } } }
                    }
                    .padding(.horizontal, 14).frame(minHeight: 50)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if !calmLayout || addOpen {
                Button { sheet = .dictate { t in quick = t; quickFocus = true } } label: {
                    Image(systemName: "mic.fill").font(Look.f(.title3)).frame(width: 50, height: 50)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityLabel("Say it")
                if planner.me.has("smartevent") {
                    Button { let t = quick; quick = ""; sheet = .smart(t) } label: {
                        Image(systemName: "sparkle.magnifyingglass").font(Look.f(.title3)).frame(width: 50, height: 50)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .accessibilityLabel("Find it online and plan it")
                }
                }
                Button(action: addQuick) {
                    Image(systemName: "plus").font(Look.f(.title2).bold()).frame(width: 50, height: 50)
                        .background(Look.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).foregroundStyle(.white)
                }
                .accessibilityLabel("Add")
            }
            let hint = Smart.shared.parse(quick, today: Day.today).hint
            if !quick.isEmpty && !hint.isEmpty { Text(hint).font(Look.f(.subheadline)).foregroundStyle(Look.accent) }
            let rec = planner.recent.filter { r in !planner.day.items.contains { $0.title.lowercased() == r.title.lowercased() } }.prefix(6)
            if !rec.isEmpty && (!calmLayout || addOpen) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(rec), id: \.self) { r in
                            Chip(text: r.title, color: r.color, emoji: r.emoji) { Task { await planner.addAgain(r) } }
                        }
                    }
                }
                .swipeExclusion("recent")
            }
        }
    }

    private func addQuick() {
        let t = quick.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { sheet = .edit(nil, Preset(date: planner.date)); return }
        quick = ""
        Task { await planner.quickAdd(t) }
    }

    // MARK: timeline

    @ViewBuilder private var timeline: some View {
        let timed = planner.day.items.filter { $0.startMin != nil }
        let anytime = planner.day.items.filter { $0.startMin == nil }
        if timed.isEmpty && anytime.isEmpty {
            VStack(spacing: 8) {
                Image("pi-leaf").resizable().renderingMode(.template).frame(width: 40, height: 40).foregroundStyle(Look.accent)
                Text(planner.day.quiet.isEmpty ? "Nothing planned" : "A quiet day").font(Look.f(.headline))
                Text("Type above, or tap ＋ to add something.").font(Look.f(.subheadline)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        }
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(timed.enumerated()), id: \.element.id) { i, it in
                if i > 0, let prevEnd = timed[i - 1].endMin, let s = it.startMin, s - prevEnd >= 15 {
                    FreeGap(minutes: s - prevEnd)
                }
                if planner.isToday, let s = it.startMin, i == timed.firstIndex(where: { ($0.startMin ?? 0) > Clock.nowMin }),
                   s > Clock.nowMin, current == nil {
                    NowLine()
                }
                HStack(alignment: .top, spacing: 10) {
                    Text(it.start ?? "").font(Look.f(.subheadline).monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        .padding(.top, 16)
                    ItemCard(planner: planner, item: it, sheet: $sheet)
                }
            }
        }
        if !anytime.isEmpty {
            Text(planner.isToday ? "Any time today" : "Any time").font(Look.f(.title3).bold()).padding(.top, 10)
            LazyVStack(spacing: 10) {
                ForEach(anytime) { it in ItemCard(planner: planner, item: it, sheet: $sheet) }
            }
        }
    }
}

struct FreeGap: View {
    let minutes: Int
    var body: some View {
        HStack(spacing: 8) {
            Text("····").foregroundStyle(.tertiary)
            Text("\(Clock.length(minutes)) free").font(Look.f(.subheadline)).foregroundStyle(.secondary)
        }
        .padding(.leading, 58)
    }
}

struct NowLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(Clock.hhmm(Clock.nowMin)).font(Look.f(.caption).bold().monospacedDigit()).foregroundStyle(.red).frame(width: 48, alignment: .leading)
            Rectangle().fill(.red).frame(height: 2)
        }
    }
}

/// Mon–Sun along the top. Tap a day to see it.
struct WeekStrip: View {
    @Bindable var planner: Planner
    @State private var target: String?
    var body: some View {
        let mon = Day.mondayOf(planner.date)
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let d = Day.add(mon, i)
                let on = d == planner.date
                Button { Feedback.tap(); planner.go(d) } label: {
                    VStack(spacing: 4) {
                        Text(Day.short[i]).font(Look.f(.caption).weight(.semibold))
                        Text(Day.format(d, "d")).font(Look.f(.title3).bold())
                        Capsule().fill(d == Day.today ? Look.accent : .clear).frame(width: 18, height: 4)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(on ? Look.accent.opacity(0.85) : (target == d ? Look.accent.opacity(0.25) : .clear), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(on ? .white : (d == Day.today ? Look.accent : .primary))
                    .scaleEffect(target == d ? 1.08 : 1)
                }
                .buttonStyle(.plain)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, !id.isEmpty, let it = (planner.day.items + planner.todos).first(where: { $0.id == id }) else { return false }
                    Feedback.success(); Feedback.sound("drop")
                    var body: [String: Any] = ["date": d]
                    if it.isTodo { body["kind"] = "event"; body["start"] = NSNull() }
                    Task { await planner.update(it, body, message: "Moved to \(Day.shortFriendly(d).lowercased())") }
                    return true
                } isTargeted: { t in
                    if t { target = d; Feedback.tap(); Feedback.sound("hover") } else if target == d { target = nil }
                }
            }
        }
    }
}

/// One activity on the timeline. Tap to open; hold for quick actions.
struct ItemCard: View {
    @Bindable var planner: Planner
    let item: Item
    @Binding var sheet: Sheet?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EmojiTile(emoji: item.emoji, color: item.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(Look.f(.headline)).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    if !item.addedBy.isEmpty {
                        Label("\(item.addedBy)", image: "pi-love-note").font(Look.f(.caption).bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(hex: "#EE8FA6").opacity(0.3), in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(item.isCal ? "\(item.timeText) · \(item.calendar)" : item.timeText + (item.leave != nil && !item.done ? " · leave \(item.leave!)" : ""))
                    if item.masterId != nil { Image(systemName: "repeat") }
                }
                .font(Look.f(.subheadline)).foregroundStyle(.secondary)
                if !item.steps.isEmpty && !item.done {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.steps.prefix(8).enumerated()), id: \.offset) { i, s in
                            StepRow(step: s, color: item.color) { Task { await planner.toggleStep(item, i) } }
                        }
                        if item.steps.count > 8 { Text("+\(item.steps.count - 8) more steps").font(Look.f(.caption)).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if !item.isCal {
                DoneCircle(done: item.done, color: item.color) { Task { await planner.toggleDone(item) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .block(item.color, done: item.done)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture { Feedback.tap(); sheet = .detail(item) }
        .contextMenu { if !item.isCal { ItemMenu(planner: planner, item: item, sheet: $sheet) } }
        .draggable(item.isCal ? "" : item.id) {
            HStack(spacing: 8) { EmojiTile(emoji: item.emoji, color: item.color, size: 32); Text(item.title).font(Look.f(.headline)) }
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .onAppear { Feedback.soft(); Feedback.sound("pickup") }
        }
        .sensoryFeedback(.success, trigger: item.done) { _, new in new }
        .accessibilityElement(children: .contain)
    }
}

/// Hold an activity for these.
struct ItemMenu: View {
    @Bindable var planner: Planner
    let item: Item
    @Binding var sheet: Sheet?
    var body: some View {
        Button { Task { await planner.toggleDone(item) } } label: { Label(item.done ? "Mark not done" : "Done", systemImage: "checkmark.circle") }
        if !item.done && item.kind == "event" {
            Button { Task { await planner.runningLate(10) } } label: { Label("I'm running late (10 min)", systemImage: "clock.arrow.circlepath") }
            Button { sheet = .couldnt(item) } label: { Label("Couldn't do it today", systemImage: "cloud.rain") }
            if item.startMin != nil {
                Button { Task { await planner.update(item, ["start": Clock.hhmm((item.startMin ?? 0) + 15)], message: "Moved 15 minutes later") } } label: {
                    Label("15 minutes later", systemImage: "arrow.down.circle")
                }
            }
            Button { Task { await planner.update(item, ["date": Day.add(item.date ?? planner.date, 1)], message: "Moved to tomorrow") } } label: {
                Label("Tomorrow", systemImage: "arrow.right.circle")
            }
            Button { Task { await planner.update(item, ["kind": "todo", "date": NSNull(), "start": NSNull()], message: "Moved to your to-do list") } } label: {
                Label("To-do list", systemImage: "checklist")
            }
        }
        Button { sheet = .edit(item, Preset()) } label: { Label("Edit", systemImage: "pencil") }
        Button(role: .destructive) { Task { await planner.delete(item) } } label: { Label("Delete", systemImage: "trash") }
    }
}

/// What's happening now, big and calm.
struct NowCard: View {
    @Bindable var planner: Planner
    let item: Item
    let calm: Bool
    @Binding var sheet: Sheet?
    var body: some View {
        let s = Clock.date(item.start), e = s.addingTimeInterval(TimeInterval(item.duration * 60))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let frac = max(0, min(1, ctx.date.timeIntervalSince(s) / max(60, e.timeIntervalSince(s))))
                    ZStack {
                        Circle().stroke(Color(hex: item.color).opacity(0.25), lineWidth: 8)
                        Circle().trim(from: 0, to: 1 - frac).stroke(Color(hex: item.color), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        PacelyIcon(emoji: item.emoji, size: 30).foregroundStyle(Color(hex: item.color))
                    }
                    .frame(width: 74, height: 74)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOW").font(Look.f(.caption).weight(.heavy)).foregroundStyle(Look.accent)
                    Text(item.title).font(Look.f(.title3).bold()).lineLimit(2)
                    if calm {
                        Text("until \(Clock.hhmm(item.endMin ?? 0))").foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: s...max(e, s.addingTimeInterval(60)), countsDown: true).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { Task { await planner.toggleDone(item) } } label: { Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Look.accent)
                Button { Task { await planner.runningLate(10) } } label: { Label("Running late", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .card()
        .onTapGesture { sheet = .detail(item) }
    }
}

struct QuietCard: View {
    @Bindable var planner: Planner
    var body: some View {
        let q = planner.day.quiet
        let undone = planner.day.items.filter { !$0.isCal && !$0.done }
        HStack(alignment: .top, spacing: 12) {
            Image("pi-" + (["off": "palm", "sick": "unwell", "holiday": "plane"][q] ?? "palm")).resizable().renderingMode(.template)
                .frame(width: 34, height: 34).foregroundStyle(Look.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(["off": "Day off", "sick": "Sick day", "holiday": "Holiday"][q] ?? "Day off"): reminders are quiet").font(Look.f(.headline))
                Text(q == "sick" ? "Rest up. Nothing here has to happen today." : "Enjoy it. Nothing here has to happen today.")
                    .font(Look.f(.subheadline)).foregroundStyle(.secondary)
                if !undone.isEmpty {
                    Menu {
                        Button("Tomorrow") { Task { await planner.leftovers("move", to: Day.add(planner.date, 1), ids: undone.map(\.num)) } }
                        Button("The next weekday") {
                            var d = Day.add(planner.date, 1)
                            while Day.weekday(d) >= 5 { d = Day.add(d, 1) }
                            Task { await planner.leftovers("move", to: d, ids: undone.map(\.num)) }
                        }
                        Button("My to-do list") { Task { await planner.leftovers("todo", ids: undone.map(\.num)) } }
                    } label: {
                        Text("Move \(undone.count) thing\(undone.count == 1 ? "" : "s") to another day").font(Look.f(.subheadline).bold())
                    }
                    .buttonStyle(.bordered).padding(.top, 4)
                }
            }
        }
        .card()
    }
}

struct LeftoversCard: View {
    @Bindable var planner: Planner
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(planner.leftovers.count) thing\(planner.leftovers.count == 1 ? "" : "s") left from before").font(Look.f(.headline))
            ForEach(planner.leftovers.prefix(4)) { l in
                HStack { IconText(emoji: l.emoji, text: l.title).font(Look.f(.subheadline)); Text(Day.format(l.date ?? Day.today, "EEE")).font(Look.f(.caption)).foregroundStyle(.secondary) }
            }
            if planner.leftovers.count > 4 { Text("and \(planner.leftovers.count - 4) more").font(Look.f(.caption)).foregroundStyle(.secondary) }
            Flow {
                Chip(text: "Move to today", on: true) { Task { await planner.leftovers("today"); planner.say("Moved to today") } }
                Chip(text: "To-do list") { Task { await planner.leftovers("todo"); planner.say("Moved to your to-do list") } }
                Chip(text: "Let them go") { Task { await planner.leftovers("let_go"); planner.say("Let go. Fresh start") } }
                Chip(text: "Not now") { UserDefaults.standard.set(Day.today, forKey: "pacely.leftDismiss"); planner.leftovers = [] }
            }
        }
        .card()
    }
}

// MARK: - Week and month

struct WeekList: View {
    @Bindable var planner: Planner
    var body: some View {
        let mon = Day.mondayOf(planner.date)
        VStack(spacing: 10) {
            ForEach(0..<7, id: \.self) { i in
                let d = Day.add(mon, i)
                let w = planner.week[d]
                Button { planner.mode = .day; planner.go(d) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(Day.format(d, "EEEE d")).font(Look.f(.headline)).foregroundStyle(d == Day.today ? Look.accent : .primary)
                            ForEach(Array((w?.items ?? []).filter { !$0.allday.isEmpty }.prefix(2).enumerated()), id: \.offset) { _, x in
                                IconText(emoji: x.emoji, text: x.title, size: 13).font(Look.f(.caption).weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color(hex: x.color).opacity(0.3), in: Capsule())
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let w, w.n > 0 { Text("\(w.done)/\(w.n)").font(Look.f(.subheadline).monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        if let w, !w.items.filter({ $0.allday.isEmpty }).isEmpty {
                            ForEach(Array(w.items.filter { $0.allday.isEmpty }.prefix(6).enumerated()), id: \.offset) { _, x in
                                HStack(spacing: 8) {
                                    Text(x.start ?? (x.allday.isEmpty ? "—" : "All day")).font(Look.f(.caption).monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 50, alignment: .leading)
                                    IconText(emoji: x.emoji, text: x.title, size: 15).font(Look.f(.subheadline)).strikethrough(x.done).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4).padding(.horizontal, 8)
                                .background(Color(hex: x.color).opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if w.items.count > 6 { Text("+\(w.items.count - 6) more").font(Look.f(.caption)).foregroundStyle(.secondary) }
                        } else {
                            Text("Nothing planned").font(Look.f(.subheadline)).foregroundStyle(.secondary)
                        }
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MonthGrid: View {
    @Bindable var planner: Planner
    var body: some View {
        let first = Day.string(Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Day.date(planner.date))) ?? Date())
        let start = Day.mondayOf(first)
        let month = Day.format(first, "MM")
        VStack(spacing: 8) {
            HStack { ForEach(Day.short, id: \.self) { Text($0).font(Look.f(.caption).bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0..<42, id: \.self) { i in
                    let d = Day.add(start, i)
                    let w = planner.month[d]
                    Button { planner.mode = .day; planner.go(d) } label: {
                        VStack(spacing: 4) {
                            Text(Day.format(d, "d")).font(Look.f(.subheadline).weight(d == Day.today ? .heavy : .medium))
                                .foregroundStyle(d == Day.today ? Look.accent : (Day.format(d, "MM") == month ? .primary : .secondary))
                            HStack(spacing: 2) {
                                ForEach(Array((w?.items ?? []).prefix(4).enumerated()), id: \.offset) { _, x in
                                    Circle().fill(Color(hex: x.color)).frame(width: 6, height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .opacity(Day.format(d, "MM") == month ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}


/// Swipe left or right for the next or previous day, week or month (only on the plan itself,
/// so sideways-scrolling buttons don't change the day).
struct SwipeDays: ViewModifier {
    static let space = "pacely.swipeDays"
    /// Rows that scroll sideways themselves (like the "add again" chips): a swipe that starts there scrolls them instead.
    @MainActor static var exclusions: [String: CGRect] = [:]
    @Bindable var planner: Planner
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .named(SwipeDays.space))
                    .onEnded { v in
                        let dx = v.translation.width, dy = v.translation.height
                        guard abs(dx) > 70, abs(dy) < abs(dx) * 0.6 else { return }
                        if SwipeDays.exclusions.values.contains(where: { $0.contains(v.startLocation) }) { return }
                        withAnimation(.easeOut(duration: 0.2)) { planner.move(dx < 0 ? 1 : -1) }
                    }
            )
    }
}

extension View {
    /// Marks a sideways-scrolling row so day swipes leave it alone.
    func swipeExclusion(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SwipeDays.space)) } action: { SwipeDays.exclusions[id] = $0 }
            .onDisappear { SwipeDays.exclusions[id] = nil }
    }
}


/// All-day things (office days, days off, notes) shown as calm banners across the top of the day.
struct AllDayBanner: View {
    let item: Item
    let tap: () -> Void
    var kind: String {
        if item.isCal { return item.calendar.isEmpty ? "From your calendar" : "From \(item.calendar)" }
        return ["office": "Office day", "home": "Working from home", "off": "Day off", "sick": "Sick day", "holiday": "Holiday"][item.allday] ?? "All day"
    }
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                PacelyIcon(emoji: item.emoji, size: 22).foregroundStyle(.black.opacity(0.7))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: item.color).opacity(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(Look.f(.headline))
                    Text(kind + (item.masterId != nil ? " · repeats" : "") + (item.addedBy.isEmpty ? "" : " · from \(item.addedBy)"))
                        .font(Look.f(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color(hex: item.color).opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
