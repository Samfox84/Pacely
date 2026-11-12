import SwiftUI
import CoreText

// MARK: - Find it online and plan it ("Audley End Christmas event 28 Nov 1pm")

/// What the AI helper found: a ready-to-add item, the journey, and where it looked.
struct SmartResult: Decodable {
    struct Found: Decodable {
        var title: String, emoji: String, color: String, date: String, start: String, duration: Int
        var location: String, link: String, notes: String, price: String
        var leave: String?, travelMin: Int, travelBy: String
        enum K: String, CodingKey { case title, emoji, color, date, start, duration, location, link, notes, price, leave, travel_min, travel_by }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            title = c.str(.title); emoji = c.str(.emoji, "📍"); color = c.str(.color, "#7CB8F0"); date = c.str(.date); start = c.str(.start)
            duration = c.int(.duration, 60); location = c.str(.location); link = c.str(.link); notes = c.str(.notes); price = c.str(.price)
            leave = c.optStr(.leave).flatMap { $0.isEmpty ? nil : $0 }; travelMin = c.int(.travel_min); travelBy = c.str(.travel_by)
        }
        var body: [String: Any] {
            var b: [String: Any] = ["kind": "event", "title": title, "emoji": emoji, "color": color, "date": date.isEmpty ? Day.today : date,
                                    "duration": duration, "notes": notes, "location": location, "link": link, "end_alert": false,
                                    "remind": leave == nil ? 10 : -1]
            b["start"] = start.isEmpty ? NSNull() : start
            if let leave { b["leave"] = leave }
            if travelMin > 0 { b["travel_min"] = travelMin; b["travel_by"] = travelBy }
            return b
        }
    }
    struct Trip: Decodable {
        var by: String?, minutes: Int?, leave: String?, buffer: Int?, error: String?
    }
    struct Source: Decodable, Hashable { var title: String; var url: String }
    var item: Found?
    var trip: Trip?
    var sources: [Source]?
}

/// Type or say what it is. The AI helper looks it up, finds the website, price and address, and works out when to leave.
struct SmartEventSheet: View {
    /// Where to send it: your own plan, or (in partner mode) the person you help.
    enum Target { case mine(Planner), partner(owner: String, done: (String) -> Void) }
    let target: Target
    @State var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var result: SmartResult?
    @State private var busy = false
    @State private var error: String?
    @State private var listening = false
    @State private var started = Date()

    var body: some View {
        NavigationStack {
            Group {
                if let r = result, let it = r.item { review(r, it) } else { ask }
            }
            .navigationTitle("Find it and plan it").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if busy { Planner.shared.cancelAI() }; dismiss() } } }
            .sheet(isPresented: $listening) { DictationView { t in text = t }.presentationDetents([.medium]) }
            .task { if !text.isEmpty && result == nil { await find() } }
        }
    }

    private var ask: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    TextField("e.g. Audley End Christmas event 28 Nov 1pm", text: $text, axis: .vertical).lineLimit(2...6)
                    Button { listening = true } label: { Image(systemName: "mic.fill") }.buttonStyle(.borderless).accessibilityLabel("Say it")
                }
            } footer: {
                Text("Paste a message, an email or just a few words. The AI helper looks it up online, finds the website, price and address, and works out when to leave.")
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.bubble").foregroundStyle(.secondary) } }
            Section {
                Button { Task { await find() } } label: {
                    HStack {
                        if busy {
                            ProgressView()
                            TimelineView(.periodic(from: started, by: 1)) { ctx in
                                Text("Looking it up… \(Int(ctx.date.timeIntervalSince(started)))s").monospacedDigit()
                            }
                        } else { Label("Find it", systemImage: "sparkle.magnifyingglass").bold() }
                    }
                }
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).count < 3)
            }
        }
        .thinkingGlow(Planner.shared)
    }

    private func review(_ r: SmartResult, _ it: SmartResult.Found) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EmojiTile(emoji: it.emoji, color: it.color, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(it.title).font(Look.f(.title2).bold())
                    Text(whenText(it)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !it.location.isEmpty { infoRow("mappin.and.ellipse", it.location) }
                    if let u = URL(string: it.link), !it.link.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "link").frame(width: 24).foregroundStyle(Look.accent)
                            Link(u.host()?.replacingOccurrences(of: "www.", with: "") ?? it.link, destination: u)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                    }
                    if !it.price.isEmpty { infoRow("ticket", it.price) }
                    if let t = r.trip {
                        if let m = t.minutes, m > 0 {
                            infoRow(t.by == "transit" ? "tram.fill" : "car.fill",
                                    (t.leave.map { "Leave at \($0)" } ?? "\(Clock.length(m)) away"),
                                    sub: "\(Clock.length(m)) \(t.by == "transit" ? "by public transport" : "drive")" + (t.leave != nil ? ", arriving \(t.buffer ?? 10) min early" : ""))
                        } else if let e = t.error { infoRow("car", nil, sub: e) }
                    }
                    if !it.notes.isEmpty { infoRow("note.text", it.notes) }
                }
                .card()
                if let s = r.sources, !s.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Found on").font(Look.f(.caption).bold()).foregroundStyle(.secondary)
                        ForEach(s.prefix(3), id: \.self) { src in
                            if let u = URL(string: src.url) { Link(src.title.isEmpty ? (u.host() ?? "link") : src.title, destination: u).font(Look.f(.caption)) }
                        }
                    }
                }
                Text("Check the details before you go. The AI can get things wrong.").font(Look.f(.footnote)).foregroundStyle(.secondary)
                Button { Task { await add(it) } } label: {
                    Text(addLabel).bold().frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(Look.accent)
                Button("Try different words") { result = nil }.frame(maxWidth: .infinity)
            }
            .padding(20)
        }
    }

    private var addLabel: String {
        switch target { case .mine: "Add to my plan"; case .partner(let owner, _): "Add to \(owner)'s plan" }
    }

    private func infoRow(_ icon: String, _ text: String?, sub: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Look.accent)
            VStack(alignment: .leading, spacing: 2) {
                if let text { Text(text).fixedSize(horizontal: false, vertical: true) }
                if let sub { Text(sub).font(Look.f(.subheadline)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func whenText(_ it: SmartResult.Found) -> String {
        var s = it.date.isEmpty ? "No day yet" : Day.friendly(it.date)
        if !it.start.isEmpty { s += " at \(it.start)" }
        return s + " · about \(Clock.length(it.duration))"
    }

    private func find() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return }
        busy = true; error = nil; started = Date()
        defer { busy = false }
        do {
            let d: Data
            switch target {
            case .mine: d = try await P.ai("/api/ai/event", ["text": t])
            case .partner: d = try await P.ai(PartnerAPI.base + "/ai/event", ["text": t], jobBase: PartnerAPI.base + "/ai/job", useToken: false)
            }
            let r = try JSONDecoder().decode(SmartResult.self, from: d)
            if r.item == nil { return }
            withAnimation { result = r }
            Feedback.sound("ai-done")
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "The AI helper didn't answer. Try again."
            Feedback.sound("gentle-error")
        }
    }

    private func add(_ it: SmartResult.Found) async {
        switch target {
        case .mine(let planner):
            do {
                try await P.send("/api/activities", "POST", it.body)
                Feedback.success(); Feedback.sound("add")
                planner.say("Added \(it.title)")
                dismiss()
                await planner.changed()
            } catch { planner.fail(error) }
        case .partner(let owner, let done):
            do {
                var b = it.body
                b["emoji"] = it.emoji
                _ = try await API.request(PartnerAPI.base + "/add", method: "POST", body: b, useToken: false)
                Feedback.success(); Feedback.sound("add")
                done("Added to \(owner)'s plan")
                dismiss()
            } catch { self.error = "Couldn't add it. Try again." }
        }
    }
}

// MARK: - Getting there (on an activity)

struct GettingThere: View {
    let item: Item
    var body: some View {
        if !item.location.isEmpty || !item.link.isEmpty || item.leave != nil {
            Text("Getting there").font(Look.f(.title3).bold())
            VStack(alignment: .leading, spacing: 12) {
                if !item.tripText.isEmpty {
                    Label(item.tripText, systemImage: item.travelBy == "transit" ? "tram.fill" : "car.fill").font(Look.f(.headline))
                }
                if !item.location.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                        if let u = URL(string: "https://maps.apple.com/?daddr=" + (item.location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                            Link("Directions", destination: u).padding(.leading, 30)
                        }
                    }
                }
                if let u = URL(string: item.link), !item.link.isEmpty {
                    Label { Link(u.host()?.replacingOccurrences(of: "www.", with: "") ?? item.link, destination: u) } icon: { Image(systemName: "link") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

// MARK: - Today's route to work (office days)

struct CommuteCard: View {
    @Bindable var planner: Planner
    let c: CommuteLeg
    var home = false
    @State private var checking = false
    /// Closed by default: one calm line. Tap to see the route and line details.
    @AppStorage("pacely.commuteOpen") private var open = false
    private var problem: CommuteLeg.Line? { c.status.first { !$0.good } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.25)) { open.toggle() }; Feedback.tap() } label: {
                HStack(spacing: 12) {
                    Image(systemName: home ? "house.fill" : "tram.fill").font(Look.f(.title3)).foregroundStyle(Look.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(home ? "Head home at \(c.leave)" : "Leave for work at \(c.leave)").font(Look.f(.headline))
                        if let p = problem {
                            // Shown calmly: a small amber dot and plain words, no warning sign
                            HStack(spacing: 6) {
                                Circle().fill(Color.orange.opacity(0.7)).frame(width: 7, height: 7)
                                Text("\(p.line) line: \(p.status.lowercased())").font(Look.f(.caption)).foregroundStyle(.secondary)
                            }
                        } else if !c.status.isEmpty {
                            Text("Good service").font(Look.f(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the details" : "Shows the route and line details")
            if open { details }
        }
        .card()
    }

    @ViewBuilder private var details: some View {
            Text("\(Clock.length(c.minutes)) · \(home ? "home about" : "arrive") \(c.arrive)" + (c.summary.isEmpty ? "" : " · \(c.summary)"))
                .font(Look.f(.subheadline)).foregroundStyle(.secondary)
            if !c.status.isEmpty {
                // Line chips sit side by side, or stack if there isn't room (no sideways scrolling, so day swipes still work here)
                let chips = ForEach(c.status, id: \.self) { l in
                    Text("\(l.line): \(l.status)").font(Look.f(.caption).weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(l.good ? Color(.tertiarySystemFill) : Color.yellow.opacity(0.35), in: Capsule())
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { chips }
                    VStack(alignment: .leading, spacing: 6) { chips }
                }
            }
            if let t = c.alerted, !t.isEmpty {
                // Just the change, in one short line (the route is already shown above)
                Text(t.replacingOccurrences(of: "🚇 ", with: "").replacingOccurrences(of: "🏠 ", with: "") + ".").font(Look.f(.subheadline))
            }
            if let bad = c.status.first(where: { !$0.good }), let why = bad.reason, !why.isEmpty {
                DisclosureGroup("What's happening") { Text(why).font(Look.f(.footnote)).foregroundStyle(.secondary) }.font(Look.f(.subheadline))
            }
            HStack {
                Text("Checked with TfL at \(checkedTime). Pacely checks every 5 minutes.").font(Look.f(.caption)).foregroundStyle(.secondary)
                Spacer()
                Button(checking ? "Checking…" : "Check now") {
                    Task {
                        checking = true; defer { checking = false }
                        if let n: Commute = try? await P.get("/api/commute?refresh=1", local: false) { planner.day.commute = n; planner.say("Checked with TfL just now"); await Scheduler.refresh() }
                    }
                }
                .font(Look.f(.subheadline).bold()).disabled(checking)
            }
    }
    private var checkedTime: String {
        guard let d = ISO8601DateFormatter.flexible.date(from: c.checked) else { return "—" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Me › Getting about

struct GettingAboutView: View {
    static let modeNames: [(String, String, String)] = [
        ("tube", "Tube", "tram.fill"), ("elizabeth-line", "Elizabeth line", "tram"), ("overground", "Overground", "train.side.front.car"),
        ("dlr", "DLR", "lightrail"), ("bus", "Bus", "bus"), ("national-rail", "National Rail trains", "train.side.rear.car"), ("tram", "Tram", "cablecar")]
    @Bindable var planner: Planner
    @State private var p = TravelPrefs()
    @State private var start = Clock.date("09:00")
    @State private var homeAt = Clock.date("15:00")
    @State private var saving = false
    @State private var result: String?
    var body: some View {
        Form {
            Section {
                TextField("Home postcode, e.g. SW1A 1AA", text: $p.home).textInputAutocapitalization(.characters).textContentType(.postalCode)
                TextField("Work postcode, e.g. W1A 1AA", text: $p.work).textInputAutocapitalization(.characters)
            } footer: { Text("Used to work out when to leave. Postcodes only go to free map services (postcodes.io, OpenStreetMap and TfL).") }
            Section("Work") {
                DatePicker("I start work at", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("I usually head home at", selection: $homeAt, displayedComponents: .hourAndMinute)
                Toggle("Watch my route on office days", isOn: $p.commute)
            }
            Section {
                Picker("I get about by", selection: $p.travelBy) {
                    Text("Car").tag("car"); Text("Train, tube, bus").tag("transit"); Text("Show both").tag("both")
                }
                Picker("Arrive early by", selection: $p.buffer) { ForEach([0, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) } }
                Picker("Reminders to leave", selection: $p.leaveStyle) {
                    Text("Gentle: one heads-up").tag("gentle")
                    Text("Countdown: 20, 10, 5 min").tag("countdown")
                }
            } footer: { Text("On office days Pacely checks TfL every 5 minutes before work, and again before you head home, and tells you if a delay changes things. Your journeys also show on the Lock Screen countdown and widgets.") }
            Section {
                ForEach(Self.modeNames, id: \.0) { key, name, icon in
                    Toggle(isOn: Binding(get: { p.modes.contains(key) }, set: { on in
                        if on { p.modes.append(key) } else if p.modes.count > 1 { p.modes.removeAll { $0 == key } }
                    })) { Label(name, systemImage: icon) }
                }
            } header: { Text("Public transport I'm happy to take") } footer: {
                Text("Journeys only use these, plus walking. Turn off anything you'd rather avoid.")
            }
            if let result { Section { Text(result) } }
            Button(saving ? "Saving…" : "Save") { Task { await save() } }.bold().disabled(saving)
        }
        .navigationTitle("Getting about")
        .onAppear { p = planner.me.travel; start = Clock.date(p.workStart); homeAt = Clock.date(p.homeTime) }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            try await P.send("/api/settings", "PUT", ["home": p.home, "work": p.work, "work_start": Clock.string(start), "home_time": Clock.string(homeAt), "travel_by": p.travelBy,
                                                       "travel_buffer": p.buffer, "commute": p.commute, "modes": p.modes, "leave_style": p.leaveStyle])
            await planner.loadMe()
            Feedback.sound("toggle-on")
            if !p.work.isEmpty && !p.home.isEmpty, let d = try? await P.send("/api/trip", "POST", ["place": p.work]),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let m = j["minutes"] as? Int { result = "Saved. Work is about \(Clock.length(m)) away." } else { result = j["error"] as? String ?? "Saved" }
            } else { result = "Saved" }
        } catch { planner.fail(error) }
    }
}

// MARK: - Me › Gentle nudges

struct NudgesSection: View {
    @Bindable var planner: Planner
    var body: some View {
        Section {
            nudge("drink", "Drink some water", "Every 2 hours, 10am to 8pm", "drop")
            nudge("eat", "Eat something", "Breakfast 8:30, lunch 12:30, dinner 6:30", "fork.knife")
            nudge("rest", "Take a little pause", "11am, 3pm and 7:30pm", "figure.mind.and.body")
        } header: { Text("Gentle nudges") } footer: {
            Text("Small reminders for the basics that are easy to forget when you're busy or hyperfocused.")
        }
    }
    private func nudge(_ key: String, _ title: String, _ when: String, _ icon: String) -> some View {
        Toggle(isOn: Binding(get: { planner.me.nudges[key] ?? false }, set: { on in
            planner.me.nudges[key] = on
            Feedback.sound(on ? "toggle-on" : "toggle-off")
            Task {
                try? await P.send("/api/settings", "PUT", ["nudges": planner.me.nudges])
                await Scheduler.refresh()
            }
        })) {
            Label { VStack(alignment: .leading) { Text(title); Text(when).font(Look.f(.caption)).foregroundStyle(.secondary) } } icon: { Image(systemName: icon) }
        }
    }
}

// MARK: - Easier-to-read text

enum ReadingFont: String, CaseIterable {
    case standard, easy, dyslexic
    var label: String { switch self { case .standard: "Standard"; case .easy: "Easy read (Atkinson Hyperlegible)"; case .dyslexic: "OpenDyslexic" } }
    static var current: ReadingFont { ReadingFont(rawValue: UserDefaults.standard.string(forKey: "pacely.font") ?? "standard") ?? .standard }

    /// Loads the fonts that come with Pacely (from the Fonts folder) so the app can use them.
    static func register() {
        for name in ["AtkinsonHyperlegible-Regular", "AtkinsonHyperlegible-Bold", "OpenDyslexic-Regular"] {
            for ext in ["ttf", "otf"] {
                if let u = Bundle.main.url(forResource: name, withExtension: ext) {
                    CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
                }
            }
        }
    }
}

extension Look {
    /// The app's text styles, in the reading font chosen in Me (still grows with the iPhone's text size setting).
    static func f(_ style: Font.TextStyle) -> Font {
        let size: CGFloat = switch style {
        case .largeTitle: 34; case .title: 28; case .title2: 22; case .title3: 20; case .headline: 17; case .body: 17
        case .callout: 16; case .subheadline: 15; case .footnote: 13; case .caption: 12; case .caption2: 11
        @unknown default: 17
        }
        switch ReadingFont.current {
        case .standard:
            return Font.system(style)
        case .easy:
            let bold = style == .headline || style == .largeTitle
            return .custom(bold ? "AtkinsonHyperlegible-Bold" : "AtkinsonHyperlegible-Regular", size: size + 1, relativeTo: style)
        case .dyslexic:
            return .custom("OpenDyslexic-Regular", size: size - 1, relativeTo: style)
        }
    }
}

/// A small "Test it" row for the AI helper: says how long it took, or exactly why it didn't answer.
struct AITestRow: View {
    @Bindable var planner: Planner
    @State private var result: String?
    @State private var busy = false
    var body: some View {
        Button {
            Task {
                busy = true; result = nil; defer { busy = false }
                do {
                    let d = try await P.ai("/api/ai/check", [:])
                    let j = P.json(d)
                    result = "✅ Answered in \(j["seconds"] as? Double ?? 0) seconds: “\(j["reply"] as? String ?? "")”"
                    Feedback.sound("ai-done")
                } catch is CancellationError {
                } catch {
                    result = "⚠️ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        } label: { HStack { Label("Test the AI helper", systemImage: "stethoscope"); Spacer(); if busy { ProgressView() } } }
        .disabled(busy)
        if let result { Text(result).font(Look.f(.subheadline)).textSelection(.enabled) }
    }
}

// MARK: - Tidy a linked calendar (a work calendar full of focus time and "Busy" blocks)

struct CalendarRulesView: View {
    let cal: LinkedCalendar
    let saved: () -> Void
    @State private var onlyHours = false
    @State private var from = Clock.date("09:00")
    @State private var to = Clock.date("15:30")
    @State private var hideRepeats = false
    @State private var hideDupes = true
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Only show my working hours", isOn: $onlyHours)
                if onlyHours {
                    DatePicker("From", selection: $from, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $to, displayedComponents: .hourAndMinute)
                }
            } footer: { Text("Things that start outside these hours stay in \(cal.name) but don't show in Pacely.") }
            Section {
                Toggle("Hide repeating blocks", isOn: $hideRepeats)
            } footer: { Text("Like focus time, or out-of-office every morning and evening. One-off meetings still show.") }
            Section {
                Toggle("Hide if it's already in Pacely", isOn: $hideDupes)
            } footer: { Text("If you've got something in Pacely at the same time (like a call you blocked out as “Busy” at work), only the Pacely one shows.") }
            Button(saving ? "Saving…" : "Save") {
                Task {
                    saving = true; defer { saving = false }
                    try? await P.send("/api/calendars/\(cal.id)", "PUT", [
                        "hours_from": onlyHours ? Clock.string(from) : "", "hours_to": onlyHours ? Clock.string(to) : "",
                        "hide_repeats": hideRepeats, "hide_dupes": hideDupes])
                    Feedback.sound("toggle-on")
                    saved(); dismiss()
                }
            }
            .bold()
        }
        .navigationTitle("\(cal.emoji) \(cal.name)")
        .onAppear {
            onlyHours = !cal.hoursFrom.isEmpty
            if onlyHours { from = Clock.date(cal.hoursFrom); to = Clock.date(cal.hoursTo) }
            hideRepeats = cal.hideRepeats; hideDupes = cal.hideDupes
        }
    }
}

// MARK: - A messy message into a calm list ("milk eggs bread 2 tins tomatoes and the good cheese")

struct TidiedList: Decodable {
    var title: String, emoji: String, color: String, kind: String, date: String, start: String, notes: String, steps: [String]
    var ai: Bool, note: String
    enum K: String, CodingKey { case title, emoji, color, kind, date, start, notes, steps, ai, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = c.str(.title, "List"); emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); kind = c.str(.kind, "todo")
        date = c.str(.date); start = c.str(.start); notes = c.str(.notes); steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        ai = c.bool(.ai); note = c.str(.note)
    }
}

/// Paste or say a long message. Pacely turns it into a clear list you can tick off, one thing per line.
struct TidyListSheet: View {
    let target: SmartEventSheet.Target
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var list: TidiedList?
    @State private var busy = false
    @State private var error: String?
    @State private var listening = false
    @State private var onDay = false
    @State private var day = Date()
    @State private var newStep = ""

    var body: some View {
        NavigationStack {
            Form {
                if let l = list {
                    Section {
                        HStack {
                            EmojiTile(emoji: l.emoji, color: l.color, size: 40)
                            TextField("Name", text: Binding(get: { list?.title ?? "" }, set: { list?.title = $0 })).font(Look.f(.title3).bold())
                        }
                    } footer: {
                        if !l.ai { Text(l.note.isEmpty ? "Split up without the AI helper. Check it reads right." : "The AI helper couldn't help just now, so this is a simple split. \(l.note)") }
                    }
                    Section {
                        ForEach(Array(l.steps.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 12) {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                                TextField("Item", text: Binding(get: { (list?.steps.indices.contains(i) ?? false) ? list!.steps[i] : "" },
                                                                set: { if list?.steps.indices.contains(i) ?? false { list?.steps[i] = $0 } }))
                            }
                        }
                        .onDelete { idx in list?.steps.remove(atOffsets: idx) }
                        .onMove { from, to in list?.steps.move(fromOffsets: from, toOffset: to) }
                        HStack {
                            TextField("Add something", text: $newStep).onSubmit(addStep)
                            Button("Add", action: addStep).disabled(newStep.isEmpty)
                        }
                    } header: { Text("\(l.steps.count) things") } footer: { Text("Swipe left to remove. Hold and drag to reorder.") }
                    if !l.notes.isEmpty { Section("Notes") { Text(l.notes) } }
                    Section {
                        Toggle("For a particular day", isOn: $onDay)
                        if onDay { DatePicker("Day", selection: $day, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date) }
                    } footer: { Text(onDay ? "It shows on that day." : "It goes on the to-do list.") }
                    Section {
                        Button { Task { await add() } } label: { Text(addLabel).bold().frame(maxWidth: .infinity) }
                            .disabled(l.steps.isEmpty)
                        Button("Start again") { list = nil }.frame(maxWidth: .infinity)
                    }
                } else {
                    Section {
                        HStack(alignment: .top) {
                            TextField("Paste or type it, e.g. milk eggs bread 2 tins chopped tomatoes and the good cheese", text: $text, axis: .vertical)
                                .lineLimit(4...12)
                            VStack {
                                Button { listening = true } label: { Image(systemName: "mic.fill") }.buttonStyle(.borderless).accessibilityLabel("Say it")
                                Button { if let s = UIPasteboard.general.string { text = s } } label: { Image(systemName: "doc.on.clipboard") }
                                    .buttonStyle(.borderless).accessibilityLabel("Paste")
                            }
                        }
                    } footer: { Text("A long message turns into a clear list: one thing per line, quantities first, and shopping in supermarket order.") }
                    if let error { Section { Text(error).foregroundStyle(.secondary) } }
                    Section {
                        Button { Task { await tidy() } } label: {
                            HStack { if busy { ProgressView() }; Label(busy ? "Tidying…" : "Make it a list", systemImage: "list.bullet.clipboard").bold() }
                        }
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    }
                }
            }
            .environment(\.editMode, .constant(list == nil ? .inactive : .active))
            .navigationTitle("Make a list").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if busy { Planner.shared.cancelAI() }; dismiss() } } }
            .sheet(isPresented: $listening) { DictationView { t in text = t }.presentationDetents([.medium]) }
            .thinkingGlow(Planner.shared)
        }
    }

    private var addLabel: String {
        switch target { case .mine: "Add to my plan"; case .partner(let owner, _): "Send to \(owner)" }
    }

    private func addStep() {
        let s = newStep.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, list != nil else { return }
        list?.steps.append(s); newStep = ""
    }

    private func tidy() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let d: Data
            switch target {
            case .mine: d = try await P.ai("/api/ai/tidy", ["text": text])
            case .partner: d = try await P.ai(PartnerAPI.base + "/ai/tidy", ["text": text], jobBase: PartnerAPI.base + "/ai/job", useToken: false)
            }
            let l = try JSONDecoder().decode(TidiedList.self, from: d)
            onDay = l.kind == "event" && !l.date.isEmpty
            if onDay { day = Day.date(l.date) }
            withAnimation { list = l }
            Feedback.sound("ai-done")
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't tidy it just now. Try again."
        }
    }

    private func add() async {
        guard let l = list else { return }
        var b: [String: Any] = ["title": l.title, "emoji": l.emoji, "color": l.color, "notes": l.notes,
                                "steps": l.steps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { ["t": $0, "d": false] }]
        if onDay { b["kind"] = "event"; b["date"] = Day.string(day); b["start"] = l.start.isEmpty ? NSNull() : l.start; b["duration"] = 30 }
        else { b["kind"] = "todo" }
        switch target {
        case .mine(let planner):
            do {
                try await P.send("/api/activities", "POST", b)
                Feedback.success(); Feedback.sound("add")
                planner.say("Added \(l.title)")
                dismiss()
                await planner.changed()
            } catch { planner.fail(error) }
        case .partner(let owner, let done):
            do {
                _ = try await API.request(PartnerAPI.base + "/add", method: "POST", body: b, useToken: false)
                Feedback.success(); Feedback.sound("add")
                done("Sent to \(owner)")
                dismiss()
            } catch { self.error = "Couldn't send it. Try again." }
        }
    }
}
