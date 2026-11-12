import SwiftUI

struct RoutinesView: View {
    @Bindable var planner: Planner
    @State private var editing: Routine?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Sets of activities you can add to a day in one go.").foregroundStyle(.secondary)
                }
                ForEach(planner.routines) { r in
                    NavigationLink { RoutineDetail(planner: planner, routine: r) } label: {
                        HStack(spacing: 12) {
                            PacelyIcon(emoji: r.emoji, size: 28).foregroundStyle(Look.accent).frame(width: 36)
                            VStack(alignment: .leading) {
                                Text(r.name).font(Look.f(.headline))
                                Text("\(r.items.count) activit\(r.items.count == 1 ? "y" : "ies") · \(Clock.length(r.minutes))").font(Look.f(.subheadline)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { planner.routines[$0].id }
                    Task { for id in ids { try? await P.send("/api/routines/\(id)", "DELETE") }; await planner.loadRoutines() }
                }
            }
            .navigationTitle("Routines")
            .toolbar { Button { creating = true } label: { Label("New routine", systemImage: "plus") } }
            .refreshable { await planner.loadRoutines() }
            .sheet(isPresented: $creating) { RoutineEditor(planner: planner, routine: nil) }
        }
    }
}

struct RoutineDetail: View {
    @Bindable var planner: Planner
    let routine: Routine
    @State private var day = Date()
    @State private var start = Clock.date(Clock.hhmm(((Clock.nowMin + 14) / 15) * 15))
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(routine.items) { it in
                    HStack(spacing: 12) {
                        EmojiTile(emoji: it.emoji, color: it.color, size: 36)
                        VStack(alignment: .leading) {
                            Text(it.title)
                            if !it.steps.isEmpty { Text(it.steps.joined(separator: " · ")).font(Look.f(.caption)).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Text(Clock.length(it.duration)).font(Look.f(.subheadline)).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Add it to a day") {
                DatePicker("Day", selection: $day, displayedComponents: .date)
                DatePicker("Starting at", selection: $start, displayedComponents: .hourAndMinute)
                Button {
                    Task {
                        do {
                            try await P.send("/api/routines/\(routine.id)/apply", "POST", ["date": Day.string(day), "start": Clock.string(start)])
                            Feedback.success(); planner.say("Added \(routine.name)"); await planner.changed(); dismiss()
                        } catch { planner.fail(error) }
                    }
                } label: { Label("Add \(routine.name)", systemImage: "plus.circle.fill").font(Look.f(.headline)) }
            }
        }
        .navigationTitle("\(routine.emoji) \(routine.name)")
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { RoutineEditor(planner: planner, routine: routine) }
    }
}

struct RoutineEditor: View {
    @Bindable var planner: Planner
    let routine: Routine?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "✨"
    @State private var items: [RoutineItem] = []
    @State private var newItem = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    HStack {
                        TextField("✨", text: $emoji).frame(width: 44).font(Look.f(.title2))
                        TextField("e.g. Nursery run", text: $name)
                    }
                }
                Section {
                    ForEach($items) { $it in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("📝", text: $it.emoji).frame(width: 36)
                                TextField("Activity", text: $it.title)
                            }
                            Stepper("\(Clock.length(it.duration))", value: $it.duration, in: 1...240, step: 5)
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("Add an activity", text: $newItem).onSubmit(add)
                        Button("Add", action: add)
                    }
                } header: { Text("Activities, in order") }
            }
            .navigationTitle(routine == nil ? "New routine" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.bold().disabled(name.isEmpty || items.isEmpty) }
            }
            .onAppear {
                if let r = routine { name = r.name; emoji = r.emoji; items = r.items }
            }
        }
    }

    private func add() {
        let t = newItem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var it = RoutineItem(title: t)
        if let g = Smart.shared.guess(t) { it.emoji = g.emoji; it.color = g.color }
        items.append(it); newItem = ""
    }

    private func save() async {
        let b: [String: Any] = ["name": name, "emoji": emoji.isEmpty ? "✨" : emoji, "items": items.map(\.dict)]
        do {
            if let r = routine { try await P.send("/api/routines/\(r.id)", "PUT", b) } else { try await P.send("/api/routines", "POST", b) }
            await planner.loadRoutines(); dismiss()
        } catch { planner.fail(error) }
    }
}
