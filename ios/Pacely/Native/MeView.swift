import SwiftUI
import UniformTypeIdentifiers

struct MeView: View {
    @Bindable var planner: Planner
    @Binding var sheet: Sheet?
    @EnvironmentObject var state: AppState
    @State private var insights = Insights()
    @State private var shares: [FamilyLink] = []
    @State private var cals: [LinkedCalendar] = []
    @State private var importing = false
    @State private var importData: Data?
    @State private var weekText: String?
    @AppStorage("pacely.sounds") private var sounds = true
    @AppStorage("pacely.haptics") private var haptics = true
    @AppStorage("pacely.calm") private var calm = true
    @AppStorage("pacely.lowStim") private var lowStim = false
    @AppStorage("pacely.font") private var fontChoice = "standard"
    @AppStorage("pacely.calmLayout") private var calmLayout = false
    @AppStorage("pacely.welcomeSound") private var welcomeSound = true

    var body: some View {
        NavigationStack {
            Group {
                if calmLayout {
                    // Calm layout: the everyday things here, everything else one tap away in four groups
                    List {
                        checkIn
                        thisWeek
                        Section {
                            NavigationLink { List { travelSec }.navigationTitle("Getting about") } label: { Label("Getting about", systemImage: "tram.fill") }
                            NavigationLink { List { familySec; calendarsSec; numbersSec; summarySec }.navigationTitle("Family and calendars") } label: {
                                Label("Family and calendars", systemImage: "person.2.fill")
                            }
                            NavigationLink { AISettingsView(planner: planner) } label: { Label("AI helper", systemImage: "sparkles") }
                            NavigationLink { List { behaves; plansSec; aboutSec }.navigationTitle("Settings") } label: { Label("Settings", systemImage: "gearshape") }
                        }
                        layoutSwitch
                    }
                } else {
                    List {
                        checkIn
                        thisWeek
                        layoutSwitch
                        behaves
                        numbersSec
                        summarySec
                        familySec
                        calendarsSec
                        travelSec
                        aiSec
                        plansSec
                        aboutSec
                    }
                }
            }
            .navigationTitle("Me")
            .task { await reload() }
            .refreshable { await reload() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
                if case .success(let url) = r {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    importData = try? Data(contentsOf: url)
                }
            }
            .confirmationDialog("Load this file", isPresented: Binding(get: { importData != nil }, set: { if !$0 { importData = nil } }), titleVisibility: .visible) {
                if planner.me.has("merge") { Button("Merge: keep mine and add anything new") { Task { await doImport("merge") } } }
                Button("Replace everything with the file", role: .destructive) { Task { await doImport("replace") } }
            } message: { Text("A copy of your current plans is kept first.") }
            .sheet(isPresented: Binding(get: { weekText != nil }, set: { if !$0 { weekText = nil } })) {
                WeekSummaryView(text: weekText ?? "")
            }
        }
    }

    @ViewBuilder private var checkIn: some View {
        Section {
            HStack(spacing: 10) {
                Button { sheet = .mood } label: { Label("How am I feeling?", systemImage: "cloud.sun").frame(maxWidth: .infinity) }
                Button { sheet = .review } label: { Label("Evening review", systemImage: "moon.stars").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered).controlSize(.large)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder private var thisWeek: some View {
        Section("This week") {
            HStack {
                stat("\(insights.goodDays)", "good days, last 2 weeks")
                stat("\(insights.weekDone)", "done")
                stat(Clock.length(insights.focusWeek), "focus")
            }
            if !insights.trophies.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(insights.trophies, id: \.key) { t in
                        VStack(spacing: 2) {
                            Text(t.emoji).font(Look.f(.title)).grayscale(t.got ? 0 : 1).opacity(t.got ? 1 : 0.35)
                            Text(t.name).font(Look.f(.caption2)).multilineTextAlignment(.center).lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private var behaves: some View {
        Section {
            Toggle(isOn: $lowStim) {
                VStack(alignment: .leading) {
                    Text("Low-stimulation mode")
                    Text("No sounds, no taps, no movement, softer colours. For days when everything is a bit much.").font(Look.f(.caption)).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { !planner.me.quiet.from.isEmpty }, set: { on in
                Task { await saveQuiet(on ? "20:00" : "", on ? "07:00" : "") }
            })) {
                VStack(alignment: .leading) {
                    Text("Quiet hours")
                    Text("No notifications at these times").font(Look.f(.caption)).foregroundStyle(.secondary)
                }
            }
            if !planner.me.quiet.from.isEmpty {
                DatePicker("From", selection: Binding(get: { Clock.date(planner.me.quiet.from) }, set: { d in Task { await saveQuiet(Clock.string(d), planner.me.quiet.to) } }),
                           displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: Binding(get: { Clock.date(planner.me.quiet.to) }, set: { d in Task { await saveQuiet(planner.me.quiet.from, Clock.string(d)) } }),
                           displayedComponents: .hourAndMinute)
            }
        } header: { Text("Calm and quiet") }
        Section {
            Toggle("Sounds", isOn: $sounds).onChange(of: sounds) { _, v in Feedback.sound(v ? "toggle-on" : "toggle-off") }
            if sounds {
                Toggle("A gentle hello when Pacely opens", isOn: $welcomeSound).onChange(of: welcomeSound) { _, v in Feedback.sound(v ? "welcome" : "toggle-off") }
            }
            Toggle("Gentle taps (haptics)", isOn: $haptics).onChange(of: haptics) { _, v in Feedback.sound(v ? "toggle-on" : "toggle-off") }
            Toggle(isOn: $calm) {
                VStack(alignment: .leading) {
                    Text("Calm countdown")
                    Text("“until 9:15” instead of a ticking clock. CarPlay always does this.").font(Look.f(.caption)).foregroundStyle(.secondary)
                }
            }
            .onChange(of: calm) { _, v in Feedback.sound(v ? "toggle-on" : "toggle-off"); PacelyPrefs.calm = v; Task { await Scheduler.refresh() } }
            if planner.me.has("allday") {
                Toggle(isOn: Binding(get: { planner.me.autoTick }, set: { v in planner.me.autoTick = v; Task { await planner.saveSettings(["auto_tick": v]) } })) {
                    VStack(alignment: .leading) {
                        Text("Tick off repeating things by themselves")
                        Text("School runs and other repeats are marked done when their time is over").font(Look.f(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Text style", selection: $fontChoice) {
                ForEach(ReadingFont.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .onChange(of: fontChoice) { _, _ in Feedback.sound("toggle-on") }
            NavigationLink("iPhone app settings: reminders, Calendar, widgets") { NativeSettingsView().environmentObject(state) }
        } header: { Text("How Pacely behaves") } footer: { Text("Put your own sounds in the Sounds folder in Xcode. See Sounds/README.md.") }

    }

    @ViewBuilder private var numbersSec: some View {
        if planner.me.has("numbers") {
            Section {
                ForEach(planner.me.numbers, id: \.self) { n in
                    NavigationLink { NumberEditor(planner: planner, existing: n, fromTitle: nil) } label: {
                        VStack(alignment: .leading) {
                            Label(n.label, systemImage: "phone")
                            Text("\(n.number) · shows for “\(n.words.isEmpty ? n.label : n.words)”").font(Look.f(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { NumberEditor(planner: planner, existing: nil, fromTitle: nil) } label: { Label("Add a number", systemImage: "plus") }
            } header: { Text("Phone numbers") } footer: { Text("Activities that mention them get a big Call button.") }
        }

    }

    @ViewBuilder private var summarySec: some View {
        if planner.me.has("summary") {
            Section {
                Button { Task { await shareWeek() } } label: { Label("Share how my week went", systemImage: "chart.bar.doc.horizontal") }
            } header: { Text("How my week went") } footer: {
                Text("A plain summary of plans, what got done, moods and what was hard. Share it with Gemini, a therapist or someone who supports you.")
            }
        }

    }

    @ViewBuilder private var familySec: some View {
        if planner.me.has("share") {
            Section {
                ForEach(shares) { s in
                    NavigationLink { ShareLinkView(planner: planner, link: s) { Task { await loadShares() } } } label: {
                        VStack(alignment: .leading) {
                            Label(s.name, image: "pi-love-note")
                            Text((s.see == "own" ? "Sees only what they add" : "Sees your plans and can add to them") + " · " + s.status).font(Look.f(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { NewShareView(planner: planner) { Task { await loadShares() } } } label: { Label("Make a link for someone", systemImage: "plus") }
            } header: { Text("Share with family") } footer: {
                Text("They get a one-time invite that opens Pacely on their iPhone. Once used, it stops working, so only their phone can see your plan.")
            }
        }

    }

    @ViewBuilder private var calendarsSec: some View {
        Section {
            ForEach(cals) { c in
                NavigationLink { CalendarRulesView(cal: c) { Task { await loadCals(); await planner.load() } } } label: {
                    VStack(alignment: .leading) {
                        Text("\(c.emoji) \(c.name)")
                        Text(c.error.isEmpty ? "\(c.n) events" + (c.hideRepeats || !c.hoursFrom.isEmpty ? " · tidied" : "") : c.error)
                            .font(Look.f(.caption)).foregroundStyle(c.error.isEmpty ? Color.secondary : Color.red)
                    }
                }
                .swipeActions { Button("Remove", role: .destructive) { Task { try? await P.send("/api/calendars/\(c.id)", "DELETE"); await loadCals() } } }
            }
            NavigationLink { AddCalendarView(planner: planner) { Task { await loadCals() } } } label: { Label("Link a calendar", systemImage: "plus") }
        } header: { Text("Calendars on your timeline") } footer: {
            Text("Calendars on your iPhone (including work Outlook, if it's added in iPhone Settings › Calendar › Accounts) come in through iPhone app settings. Or link any calendar with its web link here.")
        }

    }

    @ViewBuilder private var travelSec: some View {
        if planner.me.has("travel") {
            Section {
                NavigationLink { GettingAboutView(planner: planner) } label: {
                    Label { VStack(alignment: .leading) {
                        Text("Getting about")
                        Text(planner.me.travel.home.isEmpty ? "Add your home postcode to see when to leave" : "When to leave, and TfL on office days").font(Look.f(.caption)).foregroundStyle(.secondary)
                    } } icon: { Image(systemName: "tram.fill") }
                }
            }
        }
        if planner.me.has("nudges") { NudgesSection(planner: planner) }

    }

    @ViewBuilder private var aiSec: some View {
        Section("AI helper") { NavigationLink { AISettingsView(planner: planner) } label: {
            HStack {
                Text(planner.ai.provider == "gemini" ? "Google Gemini" : "Private, on your server")
                Spacer()
                Text(planner.ai.ok ? "Ready" : "Not ready").foregroundStyle(planner.ai.ok ? .green : .orange)
            }
        } }

    }

    @ViewBuilder private var plansSec: some View {
        Section("Your plans") {
            Button { Task { await PacelyWebView.Coordinator.shareExport() } } label: { Label("Save a copy", systemImage: "square.and.arrow.up") }
            Button { importing = true } label: { Label("Load a saved file…", systemImage: "square.and.arrow.down") }
            Button("Sign out", role: .destructive) { state.signOut() }
        }
    }

    @ViewBuilder private var aboutSec: some View {
        Section {
            Text("Pacely \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · made free and open source by Sam Fox, with Claude")
                .font(Look.f(.footnote)).foregroundStyle(.secondary)
        }
    }

    private func saveQuiet(_ from: String, _ to: String) async {
        planner.me.quiet = .init(from: from, to: to)
        try? await P.send("/api/settings", "PUT", ["quiet_from": from, "quiet_to": to])
        await Scheduler.refresh()
    }

    private var layoutSwitch: some View {
        Section {
            Toggle(isOn: $calmLayout) {
                VStack(alignment: .leading) {
                    Text("Calm layout")
                    Text("Today shows just the essentials, and Me is grouped. Switch back any time.").font(Look.f(.caption)).foregroundStyle(.secondary)
                }
            }
            .onChange(of: calmLayout) { _, v in Feedback.sound(v ? "toggle-on" : "toggle-off") }
        }
    }

    private func stat(_ big: String, _ small: String) -> some View {
        VStack { Text(big).font(Look.f(.title2).bold()); Text(small).font(Look.f(.caption)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }

    private func reload() async {
        await planner.loadMe()
        insights = (try? await P.get("/api/insights", as: Insights.self)) ?? insights
        await loadShares(); await loadCals(); await planner.loadAI()
    }
    private func loadShares() async { if planner.me.has("share") { shares = (try? await P.get("/api/shares", as: [FamilyLink].self)) ?? [] } }
    private func loadCals() async { cals = (try? await P.get("/api/calendars", as: CalendarList.self).calendars) ?? [] }

    private func shareWeek() async {
        do { weekText = (P.json(try await API.request("/api/summary?days=7"))["text"] as? String ?? "") + "\n\n(From my Pacely planner.)" }
        catch { planner.fail(error) }
    }

    private func doImport(_ mode: String) async {
        guard let d = importData, var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { planner.say("That isn't a Pacely file"); return }
        importData = nil
        obj["mode"] = mode
        do { try await P.send("/api/import", "POST", obj); planner.say(mode == "merge" ? "Merged" : "Loaded"); await planner.changed() }
        catch { planner.fail(error) }
    }
}

struct WeekSummaryView: View {
    @State var text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Read it first. You can change anything before sending it.").font(Look.f(.subheadline)).foregroundStyle(.secondary)
                TextEditor(text: $text).font(Look.f(.callout)).padding(8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                ShareLink(item: text) { Label("Share… (pick Gemini)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Look.accent).controlSize(.large)
                Button {
                    UIPasteboard.general.string = text
                    if let u = URL(string: "https://gemini.google.com/app") { openURL(u) }
                } label: { Label("Copy and open Gemini", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(20)
            .navigationTitle("How my week went").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

struct NumberEditor: View {
    @Bindable var planner: Planner
    let existing: SavedNumber?
    let fromTitle: String?
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var number = ""
    @State private var words = ""
    var body: some View {
        Form {
            Section("Who is it?") { TextField("e.g. GP surgery", text: $label) }
            Section("Number") { TextField("e.g. 01234 567890", text: $number).keyboardType(.phonePad) }
            Section {
                TextField("e.g. doctor, doctors, gp", text: $words)
            } header: { Text("Show the Call button when an activity mentions") } footer: { Text("Separate words with commas.") }
            if existing != nil {
                Button("Remove", role: .destructive) { Task { await save(remove: true) } }
            }
        }
        .navigationTitle(existing == nil ? "Save a number" : "Edit number")
        .toolbar { Button("Save") { Task { await save() } }.bold().disabled(label.isEmpty || number.isEmpty) }
        .onAppear {
            if let e = existing { label = e.label; number = e.number; words = e.words }
            else if let t = fromTitle {
                let g = t.replacingOccurrences(of: #"\b(call|ring|phone)\b|\?"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
                label = g.prefix(1).uppercased() + g.dropFirst(); words = g.lowercased()
            }
        }
    }
    private func save(remove: Bool = false) async {
        var list = planner.me.numbers.filter { $0 != existing }
        if !remove { list.append(SavedNumber(label: label, number: number, words: words.isEmpty ? label.lowercased() : words)) }
        await planner.saveSettings(["numbers": list.map { ["label": $0.label, "number": $0.number, "words": $0.words] }])
        planner.say(remove ? "Removed" : "Saved")
        dismiss()
    }
}

struct NewShareView: View {
    @Bindable var planner: Planner
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var me = ""
    @State private var see = "all"
    @State private var made: String?
    var body: some View {
        Form {
            if let made {
                Section {
                    Text("Send this invite to \(name). When they tap it on their iPhone, Pacely opens and they're in. It works once, then stops.").font(Look.f(.subheadline))
                    Text(made).font(Look.f(.footnote).monospaced()).textSelection(.enabled)
                    SwiftUI.ShareLink(item: inviteText(name: name, link: made)) { Label("Send the invite", systemImage: "square.and.arrow.up") }
                } footer: { Text("They need the Pacely app on their phone first. The invite runs out after 7 days.") }
            } else {
                Section("Who is it for?") { TextField("e.g. Alex", text: $name) }
                Section("Your name, shown to them") { TextField("e.g. Sam", text: $me) }
                Section {
                    Picker("They can see", selection: $see) { Text("Everything in my plan").tag("all"); Text("Only what they add").tag("own") }
                        .pickerStyle(.inline).labelsHidden()
                } header: { Text("What can they see?") } footer: { Text("Either way, they can add things and take back things they added. Anything you mark Private never shows. You can switch it off any time.") }
                Button("Make an invite") { Task { await make() } }.bold().disabled(name.isEmpty)
            }
        }
        .navigationTitle("Share with someone")
        .onAppear { me = planner.me.myName }
    }
    private func make() async {
        do {
            let r = P.json(try await P.send("/api/shares", "POST", ["name": name, "see": see, "my_name": me]))
            if let path = r["invite_path"] as? String { made = Store.server + path; done() }
        } catch { planner.fail(error) }
    }
}

func inviteText(name: String, link: String) -> String {
    "Here's your invite to my Pacely plan. Open it on your iPhone (with Pacely installed). It works once: \(link)"
}

struct ShareLinkView: View {
    @Bindable var planner: Planner
    @State var link: FamilyLink
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var confirmNew = false
    @State private var newInvite: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: link.status)
                if !link.joined.isEmpty, let d = ISO8601DateFormatter().date(from: link.joined) ?? DateFormatter.iso.date(from: link.joined) {
                    LabeledContent("Joined", value: d.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let invite = newInvite ?? (link.invitePath.isEmpty ? nil : Store.server + link.invitePath) {
                Section {
                    Text(invite).font(Look.f(.footnote).monospaced()).textSelection(.enabled)
                    SwiftUI.ShareLink(item: inviteText(name: link.name, link: invite)) { Label("Send invite to \(link.name)", systemImage: "square.and.arrow.up") }
                } header: { Text("Invite") } footer: { Text("Works once, on one phone. Runs out after 7 days.") }
            }
            Section {
                Button(link.joined.isEmpty ? "Make a new invite" : "New phone? Make a new invite") { confirmNew = true }
            } footer: { Text("When a new invite is used, the phone that used the old one is signed out.") }
            Section("What can \(link.name) see?") {
                Button(link.see == "own" ? "Let them see my plans" : "Only show what they add") {
                    Task { try? await P.send("/api/shares/\(link.token)", "PUT", ["see": link.see == "own" ? "all" : "own"]); changed(); dismiss() }
                }
            }
            Section {
                Toggle("Also allow a web page and calendar feed", isOn: Binding(get: { link.web }, set: { v in
                    link.web = v; Task { try? await P.send("/api/shares/\(link.token)", "PUT", ["web": v]); changed() }
                }))
                if link.web {
                    Text(Store.server + "/s/" + link.token).font(Look.f(.footnote).monospaced()).textSelection(.enabled)
                }
            } footer: { Text("Off is most private: only their Pacely app can see your plan. Turn on for someone without an iPhone. Anyone with that web link can see what's shared.") }
            Section { Button("Switch off sharing with \(link.name)", role: .destructive) { confirm = true } }
        }
        .navigationTitle(link.name)
        .confirmationDialog("They stop seeing your plan straight away.", isPresented: $confirm, titleVisibility: .visible) {
            Button("Switch off", role: .destructive) { Task { try? await P.send("/api/shares/\(link.token)", "DELETE"); changed(); dismiss() } }
        }
        .confirmationDialog("Make a new invite?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Make new invite") {
                Task {
                    let r = P.json((try? await P.send("/api/shares/\(link.token)/invite", "POST")) ?? Data())
                    if let p = r["invite_path"] as? String { newInvite = Store.server + p; changed() }
                }
            }
        } message: { Text("When it's used, the phone using the old one is signed out.") }
    }
}

extension DateFormatter {
    static let iso: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"; return f }()
}

struct AddCalendarView: View {
    @Bindable var planner: Planner
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
    var body: some View {
        Form {
            Section("Name") { TextField("e.g. Work", text: $name) }
            Section {
                TextField("https://… or webcal://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Calendar web link") } footer: {
                Text("Outlook: on outlook.com go to Settings › Calendar › Shared calendars › Publish a calendar, and copy the ICS link. Google: calendar settings › Secret address in iCal format. Work calendars may not allow this; then add your work account in iPhone Settings › Calendar › Accounts and turn on Calendar in iPhone app settings.")
            }
            Button(busy ? "Linking…" : "Link it") {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        let r = P.json(try await P.send("/api/calendars", "POST", ["name": name.isEmpty ? "Calendar" : name, "url": url]))
                        if let e = r["error"] as? String, !e.isEmpty { planner.say(e) } else { planner.say("Linked: \(r["events"] as? Int ?? 0) events") }
                        done(); await planner.changed(); dismiss()
                    } catch { planner.fail(error) }
                }
            }
            .bold().disabled(url.isEmpty || busy)
        }
        .navigationTitle("Link a calendar")
    }
}

struct AISettingsView: View {
    @Bindable var planner: Planner
    @State private var provider = "ollama"
    @State private var key = ""
    @State private var saving = false
    var body: some View {
        Form {
            Section {
                Picker("Use", selection: $provider) { Text("Private, on my server").tag("ollama"); Text("Google Gemini").tag("gemini") }
                    .pickerStyle(.inline).labelsHidden()
            } footer: {
                Text(provider == "gemini"
                     ? "Quicker and can read photos. What you send goes to Google; on the free tier Google may use it to improve its products."
                     : "Nothing leaves your server. Slower on older computers.")
            }
            if provider == "gemini" {
                Section {
                    SecureField(planner.ai.hasKey ? "Key saved. Paste a new one to change it" : "Paste your Gemini API key", text: $key)
                    Link("Get a free key at aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                } header: { Text("Gemini key") }
            }
            if provider == "gemini" && planner.ai.provider == "gemini" && !planner.ai.models.isEmpty {
                Section {
                    Picker("Model", selection: Binding(get: { planner.ai.auto ? "auto" : planner.ai.model }, set: { v in
                        Task {
                            try? await P.send("/api/ai/settings", "PUT", ["gemini_model": v])
                            await planner.loadAI()
                            Feedback.sound("toggle-on")
                        }
                    })) {
                        Text("Automatic (recommended)").tag("auto")
                        ForEach(planner.ai.models, id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("Gemini model") } footer: {
                    Text("Automatic starts with the steadiest model and switches if one is busy. Pick one yourself to try it. Pacely still switches if it's busy, so you're never stuck.")
                }
            }
            Section {
                Text(planner.ai.ok ? "✅ Ready\(planner.ai.model.isEmpty ? "" : " (\(planner.ai.model))")" : "⚠️ \(planner.ai.error.isEmpty ? "Not ready" : planner.ai.error)")
                AITestRow(planner: planner)
            } header: { Text("Status") } footer: {
                Text("Looking things up online (✨ next to Add) works best with Gemini, which searches Google. The private helper searches DuckDuckGo and is slower.")
            }
            Button(saving ? "Saving…" : "Save") {
                Task {
                    saving = true
                    defer { saving = false }
                    var b: [String: Any] = ["provider": provider]
                    if !key.isEmpty { b["key"] = key }
                    do { try await P.send("/api/ai/settings", "PUT", b); key = ""; await planner.loadAI(); planner.say(planner.ai.ok ? "AI helper ready" : "Saved") }
                    catch { planner.fail(error) }
                }
            }
            .bold()
        }
        .navigationTitle("AI helper")
        .onAppear { provider = planner.ai.provider }
    }
}

// MARK: - Check-ins

struct MoodSheet: View {
    @Bindable var planner: Planner
    @Environment(\.dismiss) private var dismiss
    @State private var mood: Int?
    @State private var energy: Int?
    @State private var note = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("How are you feeling?") {
                    HStack {
                        ForEach(1...5, id: \.self) { m in
                            Button { mood = m; Feedback.tap() } label: {
                                VStack(spacing: 4) {
                                    Image("pi-mood-\(m)").resizable().renderingMode(.template).frame(width: 34, height: 34)
                                        .foregroundStyle(mood == m ? Look.accent : .secondary)
                                    Text(Look.moodNames[m - 1]).font(Look.f(.caption2)).foregroundStyle(.secondary)
                                }
                                .opacity(mood == nil || mood == m ? 1 : 0.4)
                                .scaleEffect(mood == m ? 1.1 : 1)
                            }
                            .buttonStyle(.plain).frame(maxWidth: .infinity)
                        }
                    }
                }
                Section("Energy") {
                    Picker("Energy", selection: $energy) {
                        Text("—").tag(Int?.none)
                        ForEach(1...5, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Anything on your mind? (optional)") { TextField("A few words", text: $note, axis: .vertical) }
            }
            .navigationTitle("Check in").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            var b: [String: Any] = ["mood": mood ?? 3, "note": note]
                            if let energy { b["energy"] = energy }
                            try? await P.send("/api/moods", "POST", b)
                            Feedback.success(); planner.say("Thanks for checking in"); dismiss()
                        }
                    }
                    .bold().disabled(mood == nil)
                }
            }
        }
    }
}

struct ReviewSheet: View {
    @Bindable var planner: Planner
    @Environment(\.dismiss) private var dismiss
    @State private var well = ""
    @State private var hard = ""
    @State private var tomorrow = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("What went well today?") { TextField("Even small things count", text: $well, axis: .vertical) }
                Section("What was hard?") { TextField("It's okay to say", text: $hard, axis: .vertical) }
                Section("One thing for tomorrow") { TextField("Just one", text: $tomorrow, axis: .vertical) }
            }
            .navigationTitle("Evening review").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await P.send("/api/review", "POST", ["date": Day.today, "well": well, "hard": hard, "tomorrow": tomorrow])
                            Feedback.success(); planner.say("Saved. Rest well"); dismiss()
                        }
                    }
                    .bold()
                }
            }
        }
    }
}
