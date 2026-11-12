import SwiftUI

/// Tapping an activity.
struct ItemDetail: View {
    @Bindable var planner: Planner
    @State var item: Item
    @Binding var sheet: Sheet?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EmojiTile(emoji: item.emoji, color: item.color, size: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(Look.f(.largeTitle).bold()).fixedSize(horizontal: false, vertical: true)
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    if !item.steps.isEmpty {
                        Text("Steps").font(Look.f(.title3).bold())
                        VStack(spacing: 0) {
                            ForEach(Array(item.steps.enumerated()), id: \.offset) { i, s in
                                StepRow(step: s, color: item.color) {
                                    item.steps[i].d.toggle()
                                    Task { var x = item; x.steps[i].d.toggle(); await planner.toggleStep(x, i) }
                                }
                                .padding(.vertical, 10)
                                if i < item.steps.count - 1 { Divider() }
                            }
                        }
                        .card()
                    }
                    GettingThere(item: item)
                    if !item.notes.isEmpty {
                        Text(item.isCal ? "Where" : "Notes").font(Look.f(.title3).bold())
                        Text(item.notes).textSelection(.enabled).card()
                    }
                    actions
                }
                .padding(20)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .confirmationDialog(item.masterId != nil ? "Delete repeating activity" : "Delete “\(item.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if item.masterId != nil {
                    Button("Just this one", role: .destructive) { dismiss(); Task { await planner.delete(item) } }
                    Button("This and all future ones", role: .destructive) { dismiss(); Task { await planner.delete(item, all: true) } }
                } else {
                    Button("Delete", role: .destructive) { dismiss(); Task { await planner.delete(item) } }
                }
            }
        }
    }

    private var subtitle: String {
        if item.isTodo { return "To-do · " + (["now": "Now", "soon": "Soon", "later": "Later"][item.priority] ?? "Soon") }
        var s = item.allday.isEmpty ? item.timeText : "All day" + (["off": " · day off, reminders quiet", "sick": " · sick day, reminders quiet",
                                                                   "holiday": " · holiday, reminders quiet"][item.allday] ?? "")
        if let d = item.date, d != planner.date { s = Day.shortFriendly(d) + " · " + s }
        if item.masterId != nil { s += " · repeats" }
        if !item.addedBy.isEmpty { s += " · added by \(item.addedBy)" }
        if item.isPrivate { s += " · private" }
        if item.isCal { s += " · from \(item.calendar.isEmpty ? "your calendar" : item.calendar)" }
        return s
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            if item.isCal {
                Text("This comes from a linked calendar, so change it in that calendar.").font(Look.f(.subheadline)).foregroundStyle(.secondary)
            } else {
                callButtons
                Button { dismiss(); Task { await planner.toggleDone(item) } } label: {
                    Label(item.done ? "Mark not done" : "Mark done", systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Look.accent)
                if !item.done && item.kind == "event" && item.allday.isEmpty {
                    Button { sheet = .couldnt(item) } label: { Label("Couldn't do it today", systemImage: "cloud.rain").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { dismiss(); FocusModel.shared.start(for: item); NotificationCenter.default.post(name: .pacelyTab, object: "focus") } label: {
                        Label("Start focus timer", systemImage: "hourglass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    HStack(spacing: 8) {
                        if item.startMin != nil {
                            moveButton("−15 min") { ["start": Clock.hhmm(max(0, (item.startMin ?? 0) - 15))] }
                            moveButton("+15 min") { ["start": Clock.hhmm(min(1439, (item.startMin ?? 0) + 15))] }
                        }
                        moveButton("Tomorrow") { ["date": Day.add(item.date ?? planner.date, 1)] }
                        moveButton("To-do") { ["kind": "todo", "date": NSNull(), "start": NSNull()] }
                    }
                }
                if item.isTodo && !item.done {
                    Button { sheet = .edit(item, Preset(kind: "event", date: Day.today, plan: true)) } label: {
                        Label("Plan it for a day", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                HStack(spacing: 10) {
                    Button { sheet = .edit(item, Preset()) } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.large)
    }

    private func moveButton(_ label: String, _ body: @escaping () -> [String: Any]) -> some View {
        Button(label) {
            dismiss()
            Task { await planner.update(item, body(), message: label == "To-do" ? "Moved to your to-do list" : label == "Tomorrow" ? "Moved to tomorrow" : "Moved") }
        }
        .buttonStyle(.bordered).font(Look.f(.subheadline).weight(.semibold)).frame(maxWidth: .infinity)
    }

    @ViewBuilder private var callButtons: some View {
        if let n = planner.number(for: item.title) {
            Button {
                if let u = URL(string: "tel:" + n.number.filter { $0.isNumber || $0 == "+" }) { openURL(u) }
            } label: { Label("Call \(n.label)", systemImage: "phone.fill").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).tint(.green)
        } else if item.title.range(of: #"\b(call|ring|phone)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            HStack(spacing: 10) {
                Button {
                    let q = item.title.replacingOccurrences(of: #"\b(call|ring|phone|about|the)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
                        .trimmingCharacters(in: .whitespaces)
                    if let u = URL(string: "https://www.google.com/search?q=" + ((q.isEmpty ? item.title : q) + " phone number near me")
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) { openURL(u) }
                } label: { Label("Find the number", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                NavigationLink {
                    NumberEditor(planner: planner, existing: nil, fromTitle: item.title)
                } label: { Label("Save a number", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// "Couldn't do it today": never a failure, just a different day.
struct CouldntSheet: View {
    @Bindable var planner: Planner
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @State private var pick = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var picking = false

    var body: some View {
        let did = item.steps.filter(\.d).count, left = item.steps.count - did
        let partial = did > 0 && left > 0
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("That's okay. It happens.").font(Look.f(.title2).bold())
                Text(partial ? "You did \(did) of \(item.steps.count) steps. Where should the \(left == 1 ? "last step" : "\(left) steps left") go?"
                             : "Where should “\(item.title)” go?")
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    option("Tomorrow", Day.add(Day.today, 1))
                    let nwd = nextWeekday()
                    if nwd != Day.add(Day.today, 1) { option("Next weekday (\(Day.format(nwd, "EEEE")))", nwd) }
                    if picking {
                        DatePicker("Day", selection: $pick, in: Date()..., displayedComponents: .date).datePickerStyle(.graphical)
                        option("Move it to \(Day.format(Day.string(pick), "EEE d MMM"))", Day.string(pick), prominent: true)
                    } else {
                        Button { withAnimation { picking = true } } label: { Text("Pick a day…").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    }
                    option("My to-do list", "todo")
                    option("Let it go", "let_go")
                }
                .controlSize(.large)
                Spacer()
            }
            .padding(20)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func nextWeekday() -> String {
        var d = Day.add(Day.today, 1)
        while Day.weekday(d) >= 5 { d = Day.add(d, 1) }
        return d
    }
    private func option(_ label: String, _ to: String, prominent: Bool = false) -> some View {
        Button {
            dismiss()
            Task { await planner.couldnt(item, to: to) }
        } label: { Text(label).frame(maxWidth: .infinity) }
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
    }
}

/// Lets one view pick bordered or prominent at runtime.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

extension Notification.Name {
    static let pacelyTab = Notification.Name("pacelyTab")
}
