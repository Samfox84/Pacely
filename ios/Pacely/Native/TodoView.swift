import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TodoView: View {
    @Bindable var planner: Planner
    @Binding var sheet: Sheet?
    @State private var text = ""
    @State private var showDone = false
    @State private var ai: AISheet?
    @State private var photo: PhotosPickerItem?
    @State private var showPhoto = false
    @State private var sorting = false

    enum AISheet: Identifiable { case dump, chat, notes, tidy, review([AITask]); var id: String { "\(self)".prefix(6).description } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { open(.dump) } label: { Label("Brain dump: turn thoughts into a plan", systemImage: "sparkles").font(Look.f(.headline)) }
                        .listRowBackground(Look.accent.opacity(0.85)).foregroundStyle(.white)
                    Button { open(.chat) } label: { Label("Talk it through", systemImage: "bubble.left.and.bubble.right") }
                    Button { if needsGemini("Photo to tasks") { showPhoto = true } } label: { Label("Photo to tasks", systemImage: "camera") }
                    Button { open(.notes) } label: { Label("Meeting notes or a transcript → plans", systemImage: "doc.text") }
                }
                Section {
                    HStack {
                        TextField("Add a to-do…", text: $text).onSubmit(add).submitLabel(.done)
                        Button("Add", action: add).bold().disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                let openList = planner.todos.filter { !$0.done }
                if openList.isEmpty {
                    Section {
                        VStack(spacing: 6) {
                            Image("pi-leaf").resizable().renderingMode(.template).frame(width: 36, height: 36).foregroundStyle(Look.accent)
                            Text("All clear").font(Look.f(.headline))
                            Text("Nothing waiting. Enjoy it.").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                ForEach(["now", "soon", "later"], id: \.self) { p in
                    let list = openList.filter { ($0.priority.isEmpty ? "soon" : $0.priority) == p }
                    if !list.isEmpty {
                        Section(["now": "Now", "soon": "Soon", "later": "Later"][p]!) {
                            ForEach(list) { t in row(t) }
                        }
                    }
                }
                let done = planner.todos.filter(\.done)
                if !done.isEmpty {
                    Section {
                        Button(showDone ? "Hide done (\(done.count))" : "Show done (\(done.count))") { withAnimation { showDone.toggle() } }
                        if showDone {
                            ForEach(done) { t in row(t) }
                            Button("Clear done", role: .destructive) {
                                Task { try? await P.send("/api/todos/clear"); await planner.loadTodos() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("To-do")
            .toolbar {
                Button { ai = .tidy } label: { Label("Make a list from a message", systemImage: "list.bullet.clipboard") }
                if planner.ai.ok && planner.todos.filter({ !$0.done }).count > 1 {
                    Button { Task { await sort() } } label: { Label(sorting ? "Sorting…" : "Sort for me", systemImage: "wand.and.stars") }
                        .disabled(sorting)
                }
            }
            .refreshable { await planner.loadTodos() }
            .task { await planner.loadTodos() }
            .photosPicker(isPresented: $showPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, p in if let p { Task { await photoTasks(p) } } }
            .sheet(item: $ai) { s in
                switch s {
                case .dump: BrainDumpView(planner: planner) { tasks in ai = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ai = .review(tasks) } }
                case .chat: ChatView(planner: planner) { tasks in ai = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ai = .review(tasks) } }
                case .notes: NotesToPlansView(planner: planner)
                case .tidy: TidyListSheet(target: .mine(planner))
                case .review(let t): AIReviewView(planner: planner, tasks: t)
                }
            }
        }
    }

    private func row(_ t: Item) -> some View {
        HStack(spacing: 12) {
            DoneCircle(done: t.done, color: t.color) { Task { await planner.toggleDone(t) } }
            VStack(alignment: .leading, spacing: 2) {
                IconText(emoji: t.emoji, text: t.title).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                if !t.steps.isEmpty || !t.addedBy.isEmpty {
                    Text([t.steps.isEmpty ? nil : "\(t.stepsDone) of \(t.steps.count) done", t.addedBy.isEmpty ? nil : "💌 from \(t.addedBy)"].compactMap { $0 }.joined(separator: " · "))
                        .font(Look.f(.caption)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { sheet = .detail(t) }
        .swipeActions(edge: .leading) {
            Button { Task { await planner.toggleDone(t) } } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await planner.delete(t) } } label: { Label("Delete", systemImage: "trash") }
            Button { sheet = .edit(t, Preset(kind: "event", date: Day.today, plan: true)) } label: { Label("Plan", systemImage: "calendar") }.tint(Look.accent)
        }
        .contextMenu {
            ForEach(["now", "soon", "later"], id: \.self) { p in
                Button(["now": "Now", "soon": "Soon", "later": "Later"][p]!) { Task { await planner.update(t, ["priority": p]) } }
            }
            Button { sheet = .edit(t, Preset(kind: "event", date: Day.today, plan: true)) } label: { Label("Plan it for a day", systemImage: "calendar") }
            Button { sheet = .edit(t, Preset()) } label: { Label("Edit", systemImage: "pencil") }
        }
    }

    private func add() {
        let v = text.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        text = ""
        var b: [String: Any] = ["kind": "todo", "title": v, "priority": "soon"]
        if let g = Smart.shared.guess(v) { b["emoji"] = g.emoji; b["color"] = g.color }
        Task { await planner.create(b) }
    }

    private func open(_ s: AISheet) {
        if !planner.ai.ok {
            planner.say(planner.ai.error.isEmpty ? "Set up the AI helper first, in Me › AI helper" : planner.ai.error)
            return
        }
        ai = s
    }

    private func needsGemini(_ what: String) -> Bool {
        guard planner.ai.ok && planner.ai.provider == "gemini" else {
            planner.say("\(what) needs Gemini. Add a key in Me › AI helper."); return false
        }
        return true
    }

    private func sort() async {
        sorting = true
        defer { sorting = false }
        do { _ = try await P.ai("/api/ai/prioritise", [:]); planner.say("Sorted into Now, Soon and Later"); await planner.loadTodos() }
        catch { planner.fail(error) }
    }

    private func photoTasks(_ p: PhotosPickerItem) async {
        photo = nil
        guard let data = try? await p.loadTransferable(type: Data.self), let img = UIImage(data: data) else { planner.say("That photo couldn't be opened"); return }
        let scale = min(1, 1600 / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = small.jpegData(compressionQuality: 0.85) else { return }
        planner.say("📷 Reading your photo…")
        do {
            let r = try await P.ai("/api/ai/photo", ["image": "data:image/jpeg;base64," + jpg.base64EncodedString()])
            let tasks = (try? P.decoder.decode(TaskList.self, from: r).tasks) ?? []
            ai = tasks.isEmpty ? nil : .review(tasks)
            if tasks.isEmpty { planner.say("I couldn't find any tasks in that photo") }
        } catch { planner.fail(error) }
    }
}

struct TaskList: Decodable { var tasks: [AITask] }

// MARK: - AI helper screens

struct BrainDumpView: View {
    @Bindable var planner: Planner
    let done: ([AITask]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var listening = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Write or say everything on your mind, in any order. I'll turn it into tasks with small steps.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Button { listening = true } label: { Label("Say it", systemImage: "mic.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                Button { Task { await go() } } label: {
                    HStack { if busy { ProgressView() }; Text(busy ? "Making a plan…" : "✨ Make it a plan") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Look.accent).controlSize(.large)
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy && planner.ai.provider != "gemini" {
                    Text("The private helper on your server can take a minute or two.").font(Look.f(.footnote)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .thinkingGlow(planner)
            .navigationTitle("Brain dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $listening) { DictationView { t in text = (text + " " + t).trimmingCharacters(in: .whitespaces) }.presentationDetents([.medium]) }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await P.ai("/api/ai/plan", ["text": text])
            let t = (try? P.decoder.decode(TaskList.self, from: r).tasks) ?? []
            if t.isEmpty { planner.say("I couldn't find any tasks in that") } else { done(t) }
        } catch { planner.fail(error) }
    }
}

/// Look over the AI's suggestions and choose what to add.
struct AIReviewView: View {
    @Bindable var planner: Planner
    @State var tasks: [AITask]
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "todo"
    @State private var start = Clock.date(Clock.hhmm(((Clock.nowMin + 14) / 15) * 15))
    @State private var gap = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($tasks) { $t in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: t.on ? "checkmark.circle.fill" : "circle").foregroundStyle(t.on ? Look.accent : .secondary)
                                    .onTapGesture { t.on.toggle(); Feedback.tap() }
                                TextField("Task", text: $t.title).font(Look.f(.headline))
                                Text(Clock.length(t.minutes)).font(Look.f(.caption)).foregroundStyle(.secondary)
                            }
                            ForEach(t.steps) { s in Text("• \(s.t)\(s.m.map { " (\($0)m)" } ?? "")").font(Look.f(.subheadline)).foregroundStyle(.secondary) }
                        }
                        .opacity(t.on ? 1 : 0.5)
                    }
                } header: { Text("Untick anything you don't want") }
                Section("Add them") {
                    Picker("Add to", selection: $mode) { Text("To-do list").tag("todo"); Text("Today, one after another").tag("schedule") }
                        .pickerStyle(.segmented)
                    if mode == "schedule" {
                        DatePicker("Starting at", selection: $start, displayedComponents: .hourAndMinute)
                        Stepper("Break between: \(gap) min", value: $gap, in: 0...30, step: 5)
                    }
                }
            }
            .navigationTitle("\(tasks.count) suggestion\(tasks.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(tasks.filter(\.on).count)") { Task { await add() } }.bold().disabled(!tasks.contains(where: \.on))
                }
            }
        }
    }

    private func add() async {
        let pick = tasks.filter(\.on)
        do {
            try await P.send("/api/ai/add", "POST", ["tasks": pick.map(\.dict), "mode": mode, "date": Day.today,
                                                      "start": Clock.string(start), "gap": gap])
            Feedback.success(); Feedback.sound("add")
            planner.say("Added \(pick.count)")
            dismiss()
            await planner.changed()
        } catch { planner.fail(error) }
    }
}

struct ChatView: View {
    @Bindable var planner: Planner
    let review: ([AITask]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var history: [[String: String]] = (UserDefaults.standard.array(forKey: "pacely.chat") as? [[String: String]]) ?? []
    @State private var text = ""
    @State private var busy = false
    @State private var pending: [AITask] = []
    @State private var listening = false
    @AppStorage("pacely.chatWeek") private var includeWeek = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if history.isEmpty {
                                bubble("Hi. What's on your mind?", mine: false)
                                Toggle("Let it see how my week went", isOn: $includeWeek).font(Look.f(.subheadline)).padding(.top, 6)
                            }
                            ForEach(Array(history.enumerated()), id: \.offset) { _, m in bubble(m["text"] ?? "", mine: m["role"] == "user") }
                            if busy { bubble("…", mine: false) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: history.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                }
                if !pending.isEmpty {
                    Button { review(pending) } label: { Label("Review \(pending.count) suggested task\(pending.count == 1 ? "" : "s")", systemImage: "sparkles").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Look.accent).padding(.horizontal, 16)
                }
                HStack(spacing: 8) {
                    TextField("Type, or tap the mic", text: $text, axis: .vertical).lineLimit(1...5)
                        .padding(10).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    Button { listening = true } label: { Image(systemName: "mic.fill").font(Look.f(.title3)) }
                    Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
            .thinkingGlow(planner)
            .navigationTitle("Talk it through")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New chat") { history = []; pending = []; save() } }
            }
            .sheet(isPresented: $listening) { DictationView { t in text = t }.presentationDetents([.medium]) }
        }
    }

    private func bubble(_ t: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(t).padding(12)
                .background(mine ? Look.accent : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(mine ? .white : .primary)
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func save() { UserDefaults.standard.set(Array(history.suffix(30)), forKey: "pacely.chat") }

    private func send() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let before = history
        history.append(["role": "user", "text": t]); text = ""; busy = true
        defer { busy = false }
        do {
            let r = P.json(try await P.ai("/api/ai/chat", ["text": t, "history": before, "week": before.isEmpty && includeWeek]))
            history.append(["role": "assistant", "text": r["reply"] as? String ?? "Tell me a bit more?"])
            if let tasks = r["tasks"], let d = try? JSONSerialization.data(withJSONObject: tasks) {
                pending = (try? P.decoder.decode([AITask].self, from: d)) ?? []
            }
            save()
        } catch { history.removeLast(); text = t; planner.fail(error) }
    }
}

/// Paste or open meeting notes, a transcript, an email or a letter; pick out appointments and things to do.
struct NotesToPlansView: View {
    @Bindable var planner: Planner
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var found: [FoundPlan]? = nil
    @State private var importing = false
    @State private var listening = false

    var body: some View {
        NavigationStack {
            Group {
                if let found { review(found) } else { input }
            }
            .thinkingGlow(planner)
            .navigationTitle(found == nil ? "Notes → plans" : "Found \(found!.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let f = found, !f.isEmpty {
                    ToolbarItem(placement: .confirmationAction) { Button("Add \(f.filter(\.on).count)") { Task { await add() } }.bold() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "vtt") ?? .text, UTType(filenameExtension: "srt") ?? .text]) { r in
                if case .success(let url) = r {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if var t = try? String(contentsOf: url, encoding: .utf8) {
                        if ["vtt", "srt"].contains(url.pathExtension.lowercased()) {
                            t = t.split(separator: "\n").filter { l in !l.contains("-->") && Int(l.trimmingCharacters(in: .whitespaces)) == nil && !l.hasPrefix("WEBVTT") }.joined(separator: "\n")
                        }
                        text = t
                    }
                }
            }
            .sheet(isPresented: $listening) { DictationView { t in text = (text + " " + t).trimmingCharacters(in: .whitespaces) }.presentationDetents([.medium]) }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste meeting notes, a transcript, an email or a letter. I'll find appointments and things to do, and you choose which to add.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 220).padding(8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Button { importing = true } label: { Label("Choose a file", systemImage: "doc").frame(maxWidth: .infinity) }
                Button { if let s = UIPasteboard.general.string { text = s } } label: { Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }
                Button { listening = true } label: { Label("Say it", systemImage: "mic.fill").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            Button { Task { await go() } } label: {
                HStack { if busy { ProgressView() }; Text(busy ? "Reading it…" : "✨ Find plans") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Look.accent).controlSize(.large)
            .disabled(busy || text.count < 10)
            Spacer()
        }
        .padding(20)
    }

    private func review(_ list: [FoundPlan]) -> some View {
        List {
            if list.isEmpty { Text("I couldn't find any appointments or things to do in that.").foregroundStyle(.secondary) }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, x in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: x.on ? "checkmark.circle.fill" : "circle").font(Look.f(.title3)).foregroundStyle(x.on ? Look.accent : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        IconText(emoji: x.emoji, text: x.title).font(Look.f(.headline))
                        Text(x.kind == "event" ? "\(Day.format(x.date, "EEE d MMM"))\(x.start.isEmpty ? "" : " · \(x.start)")" : "To-do list")
                            .font(Look.f(.subheadline)).foregroundStyle(.secondary)
                        if !x.notes.isEmpty { Text(x.notes).font(Look.f(.footnote)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { found?[i].on.toggle(); Feedback.tap() }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        do {
            let r = P.json(try await P.ai("/api/ai/extract", ["text": text]))
            let d = try JSONSerialization.data(withJSONObject: r["items"] ?? [])
            found = (try? P.decoder.decode([FoundPlan].self, from: d)) ?? []
        } catch { planner.fail(error) }
    }

    private func add() async {
        let pick = (found ?? []).filter(\.on)
        for x in pick {
            let b: [String: Any] = x.kind == "event"
                ? ["kind": "event", "title": x.title, "emoji": x.emoji, "color": x.color, "date": x.date, "start": x.start.isEmpty ? NSNull() : x.start,
                   "duration": x.minutes, "notes": x.notes, "remind": x.start.isEmpty ? 0 : 15, "end_alert": false]
                : ["kind": "todo", "title": x.title, "emoji": x.emoji, "color": x.color, "notes": x.notes, "priority": "soon"]
            try? await P.send("/api/activities", "POST", b)
        }
        Feedback.success(); Feedback.sound("add")
        planner.say("Added \(pick.count)")
        dismiss()
        await planner.changed()
    }
}
