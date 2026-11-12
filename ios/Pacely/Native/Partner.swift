import SwiftUI
import UserNotifications

// MARK: - Partner mode: the same app, signed in with someone's share link instead of a password.
// You see what they've chosen to share, add things for them, and get a gentle note when they tick off something you added.

extension Store {
    static var partnerToken: String {
        get { UserDefaults.standard.string(forKey: "partnerToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "partnerToken") }
    }
    static var isPartner: Bool { !server.isEmpty && !partnerToken.isEmpty && token.isEmpty }

    /// An invite: "https://plan.example.com/join/CODE" or "pacely://join?server=…&code=…" → server and code
    static func parseInvite(_ raw: String) -> (server: String, code: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URLComponents(string: s), u.scheme == "pacely", u.host == "join",
           let server = u.queryItems?.first(where: { $0.name == "server" })?.value,
           let code = u.queryItems?.first(where: { $0.name == "code" })?.value {
            return (server, code)
        }
        guard let r = s.range(of: #"https?://[^\s/]+(?:/[^\s]*?)?/join/[A-Za-z0-9_\-]{8,}"#, options: .regularExpression) else { return nil }
        let link = String(s[r])
        guard let jr = link.range(of: "/join/", options: .backwards) else { return nil }
        return (String(link[..<jr.lowerBound]), String(link[jr.upperBound...]))
    }
}

struct SharedItem: Decodable, Identifiable, Hashable {
    var id: Int, date: String, start: String?, duration: Int, title: String, emoji: String, color: String, allday: String
    var done: Bool, mine: Bool
    enum K: String, CodingKey { case id, date, start, duration, title, emoji, color, allday, done, mine }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.int(.id); date = c.str(.date); start = c.optStr(.start); duration = c.int(.duration, 30); title = c.str(.title)
        emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); allday = c.str(.allday); done = c.bool(.done); mine = c.bool(.mine)
    }
}
struct SharedPlan: Decodable {
    var name: String, owner: String, see: String, today: String, items: [SharedItem], todos: [SharedList]
    enum K: String, CodingKey { case name, owner, see, today, items, todos }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = c.str(.name); owner = c.str(.owner, "them"); see = c.str(.see, "all"); today = c.str(.today)
        items = (try? c.decode([SharedItem].self, forKey: .items)) ?? []
        todos = (try? c.decode([SharedList].self, forKey: .todos)) ?? []
    }
}
/// A list you sent (like the shopping), and how much of it has been ticked off.
struct SharedList: Decodable, Identifiable, Hashable {
    var id: Int, title: String, emoji: String, color: String, done: Bool, total: Int, got: Int
    enum K: String, CodingKey { case id, title, emoji, color, done, steps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.int(.id); title = c.str(.title); emoji = c.str(.emoji, "📝"); color = c.str(.color, "#7CB8F0"); done = c.bool(.done)
        let steps = (try? c.decode([Step].self, forKey: .steps)) ?? []
        total = steps.count; got = steps.filter(\.d).count
    }
}

enum PartnerAPI {
    static var base: String { "/s/" + Store.partnerToken }

    /// Swaps a one-time invite for this phone's own private key. The invite then stops working for anyone else.
    @MainActor
    static func join(_ invite: String, state: AppState) async -> Bool {
        guard let p = Store.parseInvite(invite) else {
            state.joinMessage = "That doesn't look like a Pacely invite. Ask for a new one."
            return false
        }
        if Store.isSetUp {
            state.joinMessage = "This phone is already signed in to its own plan. Sign out in Me first to use it as a partner."
            return false
        }
        let oldServer = Store.server
        Store.server = p.server
        do {
            let d = try await API.request("/join/" + p.code, method: "POST", body: ["device": UIDevice.current.name], useToken: false)
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            guard let tok = j["token"] as? String, !tok.isEmpty else { throw APIError.http(500, "") }
            Store.partnerToken = tok
            Store.token = ""
            Feedback.success(); Feedback.sound("welcome")
            state.didSetUp()
            return true
        } catch {
            Store.server = oldServer
            state.joinMessage = "That invite has already been used or has run out. Each invite works once. Ask for a new one."
            Feedback.sound("gentle-error")
            return false
        }
    }
    /// Their plan: from the server, kept on this phone so it opens instantly and works with no signal.
    static func load() async throws -> SharedPlan {
        do {
            let d = try await API.request(base + "/data?days=42", useToken: false, timeout: saved == nil ? 30 : 10)
            let plan = try JSONDecoder().decode(SharedPlan.self, from: d)
            LocalCopy.save("/api/partner-data", d)
            return plan
        } catch {
            if isOffline(error), let s = saved { return s }
            throw error
        }
    }
    static var saved: SharedPlan? { LocalCopy.load("/api/partner-data").flatMap { try? JSONDecoder().decode(SharedPlan.self, from: $0) } }

    /// Background check: let the partner know when something they added has been done.
    static func refresh() async {
        guard Store.isPartner, let plan = try? await load() else { return }
        let key = "pacely.partnerDone"
        var seen = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        let first = UserDefaults.standard.object(forKey: key) == nil
        for it in plan.items where it.mine && it.done && !seen.contains(it.id) {
            seen.insert(it.id)
            if first { continue }
            let c = UNMutableNotificationContent()
            c.title = "\(plan.owner) did it"
            c.body = "\(it.title) ✓"
            c.sound = Sounds.notification("pacely-added")
            c.threadIdentifier = "pacely-partner"
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pacely-pdone-\(it.id)", content: c, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: key)
    }
}

struct PartnerSetupView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Ask them to send you an invite from Me › Share with family. Tap it on this phone and Pacely opens by itself. Or copy it and paste it here.")
                        .foregroundStyle(.secondary)
                }
                Section("Their invite") {
                    TextField("https://…/join/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button { if let s = UIPasteboard.general.string { link = s } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button { Task { await connect() } } label: {
                    HStack { if busy { ProgressView() }; Text("Connect").bold() }
                }
                .disabled(busy || link.isEmpty)
            }
            .navigationTitle("I help someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func connect() async {
        busy = true; error = nil
        defer { busy = false }
        if await PartnerAPI.join(link, state: state) { dismiss() } else { error = state.joinMessage; state.joinMessage = nil }
    }
}

struct PartnerRootView: View {
    @EnvironmentObject var state: AppState
    @State private var plan: SharedPlan?
    @State private var error: String?
    @State private var adding = false
    @State private var toast: String?
    @State private var confirmLeave = false
    @State private var smart = false
    @State private var tidy = false
    @Environment(\.scenePhase) private var phase
    /// How to look at their plan: one day, the list of what's coming up, or the month
    @AppStorage("pacely.partnerView") private var view = "list"
    @State private var pday = Day.today

    var body: some View {
        NavigationStack {
            List {
                if let plan {
                    if !plan.todos.isEmpty {
                        Section("Lists you've sent") {
                            ForEach(plan.todos) { l in
                                HStack(spacing: 12) {
                                    EmojiTile(emoji: l.emoji, color: l.color, size: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(l.title).strikethrough(l.done)
                                        Text(l.done ? "All done" : l.total > 0 ? "\(l.got) of \(l.total) ticked off" : "On \(plan.owner)'s to-do list")
                                            .font(Look.f(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if l.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                }
                                .swipeActions {
                                    if !l.done {
                                        Button("Remove", role: .destructive) {
                                            Task { _ = try? await API.request(PartnerAPI.base + "/item/\(l.id)", method: "DELETE", useToken: false); await load() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Picker("View", selection: $view) {
                            Text("Day").tag("day"); Text("Coming up").tag("list"); Text("Month").tag("month")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: view) { _, _ in Feedback.tap() }
                    }
                    .listRowBackground(Color.clear)
                    if view == "day" { dayView(plan) }
                    else if view == "month" { monthView(plan) }
                    else {
                    let days = Dictionary(grouping: plan.items.filter { $0.date >= plan.today }, by: \.date)
                    if days.isEmpty {
                        Section { Text(plan.see == "own" ? "Nothing you've added is coming up." : "Nothing planned yet.").foregroundStyle(.secondary) }
                    }
                    ForEach(days.keys.sorted(), id: \.self) { d in
                        Section(Day.friendly(d)) {
                            ForEach(days[d]!.sorted { ($0.start ?? "") < ($1.start ?? "") }) { it in row(it) }
                        }
                    }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(plan.map { "\($0.owner)'s plan" } ?? "Pacely")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add something", systemImage: "plus.circle.fill") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { tidy = true } label: { Label("Send a list (shopping and so on)", systemImage: "list.bullet.clipboard") }
                        Button { smart = true } label: { Label("Find it online and plan it", systemImage: "sparkle.magnifyingglass") }
                    } label: { Label("More ways to add", systemImage: "sparkles") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Stop using this link", role: .destructive) { confirmLeave = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .refreshable { await load() }
            .onAppear { KeyboardTidy.install() }
            .task {
                if plan == nil { plan = PartnerAPI.saved }      // instant, from this phone
                if UserDefaults.standard.object(forKey: "pacely.welcomeSound") as? Bool ?? true { Feedback.sound("welcome") }
                await load()
            }
            .task(id: phase) {
                // Live: when they tick something off or change their plan, it shows here straight away
                guard phase == .active else { return }
                var v = -1
                while !Task.isCancelled {
                    do {
                        let d = try await API.request(PartnerAPI.base + "/live?v=\(v)&wait=25", useToken: false, timeout: 40)
                        let nv = P.json(d)["v"] as? Int ?? v
                        if v >= 0 && nv != v { await load() }
                        v = nv
                    } catch {
                        if Task.isCancelled { return }
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                    }
                }
            }
            .sheet(isPresented: $tidy) {
                TidyListSheet(target: .partner(owner: plan?.owner ?? "them") { msg in toast = msg; Task { await load() } })
            }
            .sheet(isPresented: $smart) {
                SmartEventSheet(target: .partner(owner: plan?.owner ?? "them") { msg in toast = msg; Task { await load() } }, text: "")
            }
            .overlay { if Planner.shared.aiBusy > 0 { ThinkingGlow() } }
            .sheet(isPresented: $adding) {
                PartnerAddView(owner: plan?.owner ?? "them") { msg in toast = msg; Task { await load() } }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(Look.f(.subheadline).bold()).padding(.horizontal, 18).padding(.vertical, 12)
                        .foregroundStyle(Color(.systemBackground)).background(Color(.label), in: Capsule()).padding(.bottom, 30)
                        .task { try? await Task.sleep(nanoseconds: 2_500_000_000); self.toast = nil }
                }
            }
            .confirmationDialog("Stop using this link on this phone?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { Store.partnerToken = ""; state.isSetUp = false }
            }
            .safeAreaInset(edge: .bottom) {
                if plan?.see == "all" {
                    Text("Things marked private never show here.").font(Look.f(.footnote)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8).background(.bar)
                }
            }
        }
    }

    // MARK: day and month views

    @ViewBuilder private func dayView(_ plan: SharedPlan) -> some View {
        let items = plan.items.filter { $0.date == pday }
        Section {
            HStack {
                Button { pday = Day.add(pday, -1); Feedback.tap() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).disabled(pday <= Day.add(plan.today, -1)).accessibilityLabel("Day before")
                Spacer()
                VStack(spacing: 2) {
                    Text(Day.friendly(pday)).font(Look.f(.headline))
                    if pday != plan.today { Button("Back to today") { pday = plan.today }.font(Look.f(.caption)).buttonStyle(.borderless) }
                }
                Spacer()
                Button { pday = Day.add(pday, 1); Feedback.tap() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel("Next day")
            }
            .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                if abs(v.translation.width) > 70 { pday = Day.add(pday, v.translation.width < 0 ? 1 : -1); Feedback.tap() }
            })
        }
        let allday = items.filter { $0.start == nil }
        let timed = items.filter { $0.start != nil }.sorted { ($0.start ?? "") < ($1.start ?? "") }
        if !allday.isEmpty { Section("All day") { ForEach(allday) { row($0) } } }
        Section(timed.isEmpty && allday.isEmpty ? "" : "Through the day") {
            if timed.isEmpty && allday.isEmpty {
                Text(plan.see == "own" ? "Nothing you've added on this day." : "Nothing planned. A free day.").foregroundStyle(.secondary)
            }
            ForEach(timed) { it in
                HStack(alignment: .top, spacing: 10) {
                    Text(it.start ?? "").font(Look.f(.subheadline).monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    row(it)
                }
            }
        }
    }

    @ViewBuilder private func monthView(_ plan: SharedPlan) -> some View {
        let first = Day.date(String(plan.today.prefix(8)) + "01")
        let cal = Calendar(identifier: .iso8601)
        let start = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: first) + 5) % 7), to: first)!
        let cells = (0..<42).map { Day.string(cal.date(byAdding: .day, value: $0, to: start)!) }
        let byDay = Dictionary(grouping: plan.items, by: \.date)
        let month = String(plan.today.prefix(7))
        Section {
            Text(Day.format(plan.today, "MMMM yyyy")).font(Look.f(.headline))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(Look.f(.caption).bold()).foregroundStyle(.secondary)
                }
                ForEach(cells, id: \.self) { d in
                    let its = byDay[d] ?? []
                    Button {
                        pday = d; view = "day"; Feedback.tap()
                    } label: {
                        VStack(spacing: 4) {
                            Text(String(Int(d.suffix(2)) ?? 0)).font(Look.f(.callout).weight(d == plan.today ? .heavy : .regular))
                                .foregroundStyle(d.hasPrefix(month) ? (d < plan.today ? Color.secondary : Color.primary) : Color.secondary.opacity(0.4))
                            HStack(spacing: 2) {
                                ForEach(its.prefix(3)) { Circle().fill(Color(hex: $0.color)).frame(width: 5, height: 5) }
                            }
                            .frame(height: 6)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(d == plan.today ? Look.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Day.friendly(d)), \(its.count) thing\(its.count == 1 ? "" : "s")")
                }
            }
        } footer: { Text("Tap a day to see it. Shows the next 6 weeks.") }
    }

    private func row(_ it: SharedItem) -> some View {
        HStack(spacing: 12) {
            EmojiTile(emoji: it.emoji, color: it.color, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.title).strikethrough(it.done).foregroundStyle(it.done ? .secondary : .primary)
                Text(it.allday.isEmpty ? (it.start.map { "\($0) · \(Clock.length(it.duration))" } ?? "Any time") : "All day")
                    .font(Look.f(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if it.mine { Image("pi-love-note").renderingMode(.template).foregroundStyle(Color(hex: "#EE8FA6")).accessibilityLabel("You added this") }
            if it.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done") }
        }
        .swipeActions {
            if it.mine && !it.done {
                Button("Remove", role: .destructive) {
                    Task { _ = try? await API.request(PartnerAPI.base + "/item/\(it.id)", method: "DELETE", useToken: false); Feedback.sound("delete"); await load() }
                }
            }
        }
    }

    private func load() async {
        do { plan = try await PartnerAPI.load(); error = nil; await PartnerAPI.refresh() }
        catch { self.error = "Couldn't load the plan. The link may have been switched off." }
    }
}

struct PartnerAddView: View {
    let owner: String
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var day = Date()
    @State private var when = "any"
    @State private var time = Clock.date("09:00")
    @State private var notes = ""
    @State private var touched = false
    @State private var listening = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What is it?") {
                    HStack {
                        TextField("e.g. Pick up prescription tomorrow 11am", text: $title, axis: .vertical)
                        Button { listening = true } label: { Image(systemName: "mic.fill") }.buttonStyle(.borderless)
                    }
                    let hint = Smart.shared.parse(title, today: Day.today).hint
                    if !hint.isEmpty && !touched { Text(hint).font(Look.f(.subheadline)).foregroundStyle(Look.accent) }
                }
                Section("When") {
                    DatePicker("Day", selection: $day, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        .onChange(of: day) { _, _ in touched = true }
                    Picker("Time", selection: $when) { Text("Any time").tag("any"); Text("At a time").tag("time"); Text("All day").tag("allday") }
                        .pickerStyle(.segmented).onChange(of: when) { _, _ in touched = true }
                    if when == "time" { DatePicker("Start", selection: $time, displayedComponents: .hourAndMinute) }
                }
                Section("Note (optional)") { TextField("Anything to remember", text: $notes, axis: .vertical) }
            }
            .navigationTitle("Add for \(owner)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Sending…" : "Add") { Task { await send() } }.bold().disabled(title.isEmpty || busy) }
            }
            .sheet(isPresented: $listening) { DictationView { t in title = t }.presentationDetents([.medium]) }
            .task { await Smart.shared.load() }
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        let p = Smart.shared.parse(title, today: Day.today)
        var body: [String: Any] = ["title": p.title ?? title, "date": Day.string(day), "notes": notes]
        if when == "time" { body["start"] = Clock.string(time) }
        if when == "allday" { body["allday"] = "day" }
        if !touched {
            if let d = p.date { body["date"] = d }
            if let s = p.start { body["start"] = s }
            if let a = p.allday { body["allday"] = a == "day" ? "day" : a; body["start"] = NSNull() }
        }
        if let m = p.duration { body["duration"] = m }
        do {
            _ = try await API.request(PartnerAPI.base + "/add", method: "POST", body: body, useToken: false)
            Feedback.success(); Feedback.sound("add")
            done("Added to \(owner)'s plan")
            dismiss()
        } catch { Feedback.sound("gentle-error") }
    }
}
