import SwiftUI

/// Add or change an activity or to-do.
struct EditorView: View {
    @Bindable var planner: Planner
    let original: Item?
    let preset: Preset
    @Environment(\.dismiss) private var dismiss

    @State private var a: Item
    @State private var tripBusy = false
    @State private var tripNote: String?
    @State private var when = "time"          // time, any, allday
    @State private var startTime = Date()
    @State private var day = Date()
    @State private var picked = false         // emoji or colour chosen by hand
    @State private var touched: Set<String> = []
    @State private var newStep = ""
    @State private var showEmojis = false
    @State private var breaking = false
    @State private var listening = false
    @FocusState private var titleFocus: Bool

    init(planner: Planner, original: Item?, preset: Preset) {
        self.planner = planner
        self.original = original
        self.preset = preset
        var it = original ?? Item(title: preset.title, kind: preset.kind)
        if preset.plan { it.kind = "event"; it.date = preset.date ?? Day.today }
        if original == nil {
            it.date = preset.date ?? planner.date
            it.start = preset.start
            it.endAlert = true
        }
        _a = State(initialValue: it)
        _when = State(initialValue: !it.allday.isEmpty ? "allday" : (it.start == nil ? (original == nil && preset.start == nil ? "time" : "any") : "time"))
        let base = it.start ?? (it.date == Day.today ? Clock.hhmm(((Clock.nowMin + 14) / 15) * 15) : "09:00")
        _startTime = State(initialValue: Clock.date(base))
        _day = State(initialValue: Day.date(it.date ?? Day.today))
        _picked = State(initialValue: original != nil && !preset.plan)
    }

    private var isNew: Bool { original == nil || preset.plan }
    private var isEvent: Bool { a.kind == "event" }

    var body: some View {
        NavigationStack {
            Form {
                if isNew && isEvent && a.title.isEmpty && !planner.recent.isEmpty {
                    Section("Add again") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(planner.recent.prefix(8), id: \.self) { r in
                                    Chip(text: r.title, color: r.color, emoji: r.emoji) { useRecent(r) }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        Button { showEmojis.toggle() } label: { EmojiTile(emoji: a.emoji, color: a.color, size: 50) }
                            .buttonStyle(.plain)
                        TextField(isNew ? "e.g. Pick up meds tomorrow 11am" : "What is it?", text: $a.title, axis: .vertical)
                            .font(Look.f(.title3).weight(.semibold))
                            .focused($titleFocus)
                            .onChange(of: a.title) { _, v in
                                if !picked, let g = Smart.shared.guess(v) { a.emoji = g.emoji; a.color = g.color }
                            }
                        Button { listening = true } label: { Image(systemName: "mic.fill") }.buttonStyle(.borderless)
                    }
                    if isNew && isEvent {
                        let hint = Smart.shared.parse(a.title, today: Day.today).hint
                        if !hint.isEmpty { Text(hint).font(Look.f(.subheadline)).foregroundStyle(Look.accent) }
                    }
                    if showEmojis { emojiPicker }
                }

                if isEvent {
                    Section("When") {
                        Picker("When", selection: $when) {
                            Text("At a time").tag("time"); Text("Any time").tag("any"); Text("All day").tag("allday")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: when) { _, v in touched.insert("start"); if v == "allday" && a.allday.isEmpty { a.allday = "day" } }
                        DatePicker("Day", selection: $day, displayedComponents: .date)
                            .onChange(of: day) { _, _ in touched.insert("date") }
                        if when == "time" {
                            DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                                .onChange(of: startTime) { _, _ in touched.insert("start") }
                        }
                        if when == "allday" {
                            Picker("Kind of day", selection: $a.allday) {
                                Text("Just a note").tag("day"); Text("In the office").tag("office"); Text("Working from home").tag("home")
                                Text("Day off").tag("off"); Text("Sick day").tag("sick"); Text("Holiday").tag("holiday")
                            }
                            .onChange(of: a.allday) { _, v in
                                if !picked, let e = ["office": ("🏢", "#9AA8BA"), "home": ("🏠", "#73CBA8"), "off": ("🌴", "#73CBA8"),
                                                     "sick": ("🤒", "#9AA8BA"), "holiday": ("✈️", "#7CB8F0")][v] {
                                    a.emoji = e.0; a.color = e.1
                                    if a.title.isEmpty { a.title = ["office": "In the office", "home": "Working from home", "off": "Day off", "sick": "Sick day", "holiday": "Holiday"][v] ?? "" }
                                }
                            }
                            Text(["day", "office", "home"].contains(a.allday) ? "Shows across the top of the day. Set it to repeat for regular days, like office days."
                                 : "Shows across the top of the day, and reminders stay quiet that day.")
                                .font(Look.f(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                    if when != "allday" {
                        Section("How long") {
                            Flow {
                                ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { m in
                                    Chip(text: Clock.length(m), on: a.duration == m) { a.duration = m; touched.insert("dur") }
                                }
                            }
                            .padding(.vertical, 4)
                            Stepper("\(Clock.length(a.duration))", value: $a.duration, in: 5...600, step: 5)
                        }
                    }
                } else {
                    Section("How soon") {
                        Picker("Priority", selection: $a.priority) { Text("Now").tag("now"); Text("Soon").tag("soon"); Text("Later").tag("later") }
                            .pickerStyle(.segmented)
                    }
                }

                Section {
                    ForEach($a.steps) { $s in
                        HStack {
                            Image(systemName: s.d ? "checkmark.square.fill" : "square").foregroundStyle(s.d ? Color(hex: a.color) : .secondary)
                                .onTapGesture { s.d.toggle() }
                            TextField("Step", text: $s.t)
                            Menu {
                                ForEach([0, 2, 5, 10, 15, 20, 30, 45, 60], id: \.self) { m in Button(m == 0 ? "No time" : "\(m) min") { s.m = m == 0 ? nil : m } }
                            } label: { Text(s.m.map { "\($0)m" } ?? "⏱").font(Look.f(.subheadline)).foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { a.steps.remove(atOffsets: $0) }
                    .onMove { a.steps.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("Add a step", text: $newStep).onSubmit(addStep).submitLabel(.next)
                        Button("Add", action: addStep).disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if planner.ai.ok && !a.title.isEmpty {
                        Button { Task { await breakDown() } } label: {
                            Label(breaking ? "Thinking…" : "Break it into steps for me", systemImage: "sparkles")
                        }
                        .disabled(breaking)
                    }
                } header: { Text("Steps") } footer: { Text("Small steps make starting easier. Swipe a step left to remove it.") }

                if isEvent {
                    Section("Repeat") {
                        Picker("Repeat", selection: $a.rep.type) {
                            Text("Doesn't repeat").tag("none"); Text("Every day").tag("daily"); Text("Weekdays").tag("weekdays"); Text("Some days").tag("days")
                        }
                        .onChange(of: a.rep.type) { _, _ in touched.insert("rep") }
                        if a.rep.type == "days" {
                            HStack {
                                ForEach(0..<7, id: \.self) { d in
                                    Chip(text: String(Day.short[d].prefix(2)), on: a.rep.days.contains(d)) {
                                        if let k = a.rep.days.firstIndex(of: d) { a.rep.days.remove(at: k) } else { a.rep.days.append(d) }
                                    }
                                }
                            }
                        }
                    }
                }
                if isEvent && when != "allday" {
                    Section {
                        Picker("Remind me", selection: $a.remind) {
                            Text("At the start").tag(0); Text("5 min before").tag(5); Text("10 min before").tag(10); Text("15 min before").tag(15)
                            Text("30 min before").tag(30); Text("1 hour before").tag(60); Text("No reminder").tag(-1)
                        }
                        Toggle("Warn me 5 min before it ends", isOn: $a.endAlert)
                        Toggle(isOn: $a.nag) {
                            VStack(alignment: .leading) {
                                Text("Keep nudging me until it's done")
                                Text("For important things like medication: 3 gentle reminders, 10 minutes apart").font(Look.f(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("Reminders") }
                }

                Section("Colour") {
                    HStack {
                        ForEach(Look.palette, id: \.self) { c in
                            Circle().fill(Color(hex: c)).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.primary, lineWidth: a.color == c ? 3 : 0))
                                .onTapGesture { a.color = c; picked = true; Feedback.tap() }
                        }
                    }
                }
                if isEvent && when != "allday" {
                    Section {
                        TextField("Where (a place or postcode)", text: $a.location)
                            .onChange(of: a.location) { _, _ in a.leave = nil; a.travelMin = 0; tripNote = nil }
                        if planner.me.has("travel") && !a.location.isEmpty {
                            Button { Task { await workOutTrip() } } label: {
                                HStack { Label(tripBusy ? "Working it out…" : "When should I leave?", systemImage: "car"); Spacer(); if tripBusy { ProgressView() } }
                            }
                            .disabled(tripBusy)
                        }
                        if let note = tripNote ?? (a.tripText.isEmpty ? nil : a.tripText) { Text(note).font(Look.f(.subheadline)).foregroundStyle(Look.accent) }
                        TextField("Website (optional)", text: $a.link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Getting there") }
                }
                Section("Notes") {
                    TextField("Anything to remember: who, where, what to bring", text: $a.notes, axis: .vertical).lineLimit(3...10)
                }
                if planner.me.has("share") && isEvent {
                    Section {
                        Toggle(isOn: $a.isPrivate) { Label("Private", systemImage: "lock") }
                    } footer: { Text("Private things never show to family you share your plan with.") }
                }
            }
            .thinkingGlow(planner)
            .navigationTitle(isNew ? (isEvent ? "New activity" : "New to-do") : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.bold() }
            }
            .onAppear { if isNew && a.title.isEmpty { titleFocus = true } }
            .sheet(isPresented: $listening) {
                DictationView { t in a.title = a.title.isEmpty ? t : a.title + " " + t }.presentationDetents([.medium])
            }
        }
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                ForEach(Look.emojis, id: \.self) { e in
                    Text(e).font(Look.f(.title2)).frame(width: 36, height: 36)
                        .background(a.emoji == e ? Look.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { a.emoji = e; picked = true; showEmojis = false; Feedback.tap() }
                }
            }
            TextField("Or type any emoji", text: Binding(get: { "" }, set: { v in if let c = v.last { a.emoji = String(c); picked = true } }))
                .font(Look.f(.subheadline))
        }
    }

    private func addStep() {
        let t = newStep.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        a.steps.append(Step(t: t)); newStep = ""
    }

    private func useRecent(_ r: RecentItem) {
        a.title = r.title; a.emoji = r.emoji; a.color = r.color; a.duration = r.duration
        a.steps = r.steps.map { Step(t: $0.t, d: false, m: $0.m) }
        if let s = r.start { startTime = Clock.date(s); when = "time" }
        picked = true
    }

    private func breakDown() async {
        breaking = true
        defer { breaking = false }
        do {
            let d = P.json(try await P.ai("/api/ai/breakdown", ["title": a.title, "notes": a.notes]))
            let steps = (d["steps"] as? [[String: Any]] ?? []).compactMap { s -> Step? in
                guard let t = s["t"] as? String, !t.isEmpty else { return nil }
                return Step(t: t, d: false, m: s["m"] as? Int)
            }
            if !steps.isEmpty { a.steps = steps; Feedback.success() }
            if let m = d["minutes"] as? Int, m > 0, !touched.contains("dur") { a.duration = m }
        } catch { planner.fail(error) }
    }

    /// Asks the server how long it takes to get there, and when to leave to arrive a little early.
    private func workOutTrip() async {
        tripBusy = true; defer { tripBusy = false }
        do {
            let d = try await P.send("/api/trip", "POST", ["place": a.location, "date": Day.string(day), "start": when == "time" ? Clock.string(startTime) : ""])
            let j = P.json(d)
            if let e = j["error"] as? String { tripNote = e; return }
            a.travelMin = j["minutes"] as? Int ?? 0
            a.travelBy = j["by"] as? String ?? ""
            a.leave = (j["leave"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            tripNote = a.tripText + (a.leave != nil ? ", arriving \(j["buffer"] as? Int ?? 10) min early" : "")
            Feedback.soft()
        } catch { tripNote = "Couldn't work it out just now." }
    }

    private func save() async {
        var title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { planner.say("Give it a name first"); titleFocus = true; return }
        var date = Day.string(day)
        var start: String? = when == "time" ? Clock.string(startTime) : nil
        var allday = when == "allday" ? (a.allday.isEmpty ? "day" : a.allday) : ""
        var duration = a.duration
        var rep = a.rep
        if isNew && isEvent {
            let p = Smart.shared.parse(title, today: Day.today)
            if p.found, let t = p.title, !t.isEmpty {
                title = t
                if let d = p.date, !touched.contains("date") { date = d }
                if let ad = p.allday, !touched.contains("start") { allday = ad; start = nil }
                else if let s = p.start, !touched.contains("start") { start = s; allday = "" }
                if let m = p.duration, !touched.contains("dur") { duration = m }
                if let r = p.repeatRule, !touched.contains("rep"), let t = r["type"] as? String { rep = Repeat(type: t, days: r["days"] as? [Int] ?? []) }
            }
        }
        if rep.type == "days" && rep.days.isEmpty { rep.type = "none" }
        var body: [String: Any] = ["title": title, "emoji": a.emoji, "color": a.color, "notes": a.notes, "private": a.isPrivate, "nag": a.nag,
                                   "steps": a.steps.filter { !$0.t.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.dict)]
        if isEvent {
            body.merge(["kind": "event", "date": date, "start": start ?? NSNull(), "allday": allday, "duration": duration,
                        "remind": a.remind, "end_alert": a.endAlert, "repeat": rep.dict]) { _, n in n }
            if allday.isEmpty {
                if a.travelMin > 0, a.leave != nil, let s = start, s != a.start, let m = Clock.minutes(s) {
                    a.leave = Clock.hhmm(max(0, m - a.travelMin - planner.me.travel.buffer))   // moved the time: move when to leave too
                }
                body.merge(["location": a.location, "link": a.link, "leave": a.leave ?? NSNull(),
                            "travel_min": a.travelMin > 0 ? a.travelMin : NSNull(), "travel_by": a.travelBy.isEmpty ? NSNull() : a.travelBy]) { _, n in n }
            }
        } else {
            body.merge(["kind": "todo", "priority": a.priority]) { _, n in n }
        }
        if let o = original, !preset.plan {
            if o.masterId != nil {
                let all = await askScope()
                guard let all else { return }
                body["scope"] = all ? "all" : "this"
            }
            dismiss()
            await planner.update(o, body, message: "Saved")
        } else {
            if let o = original, preset.plan {
                dismiss()
                await planner.update(o, body, message: "Planned for \(Day.shortFriendly(date).lowercased())")
                return
            }
            dismiss()
            if await planner.create(body) != nil {
                planner.say(date == planner.date || !isEvent ? "Added \(title)" : "Added \(title) to \(Day.shortFriendly(date).lowercased())")
            }
        }
    }

    private func askScope() async -> Bool? {
        // Repeating: change all of them unless only the day or time changed for this one
        guard let o = original else { return false }
        let onlyThis = o.title == a.title && o.steps == a.steps && o.notes == a.notes && o.emoji == a.emoji && o.color == a.color
        return !onlyThis
    }
}
