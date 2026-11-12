import SwiftUI
import WatchKit

struct WatchHome: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if !model.linked {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pacely").font(.headline)
                        Text(model.message ?? "Open Pacely on your iPhone to link this watch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    if let cur = model.current {
                        NowCard(item: cur)
                    }
                    if let m = model.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(model.current == nil ? "Coming up" : "Next") {
                        if model.upcoming.isEmpty && !model.loading {
                            Text("🌿 All clear").foregroundStyle(.secondary)
                        }
                        ForEach(model.upcoming.filter { $0.id != model.current?.id }) { item in
                            NavigationLink(value: item) { ItemRow(item: item) }
                        }
                    }
                    let done = model.items.filter { $0.done }
                    if !done.isEmpty {
                        Section("Done") {
                            ForEach(done) { item in
                                ItemRow(item: item).opacity(0.5)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                if model.linked {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            AddView()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .navigationDestination(for: WatchItem.self) { item in
                ItemDetail(itemId: item.id)
            }
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
        }
    }
}

struct NowCard: View {
    @EnvironmentObject var model: WatchModel
    let item: WatchItem

    var body: some View {
        let start = model.dayStart(item) ?? Date()
        let end = start.addingTimeInterval(TimeInterval(max(1, item.duration) * 60))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NOW").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(hex: item.color))
                Spacer()
                Text(item.emoji)
            }
            Text(item.title).font(.headline).lineLimit(2)
            Text(timerInterval: start...end, countsDown: true)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
            ProgressView(timerInterval: start...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(Color(hex: item.color))
            if item.numericId != nil {
                Button {
                    Task { await model.toggleDone(item) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(Color(hex: item.color))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(Color(hex: item.color).opacity(0.25)))
    }
}

struct ItemRow: View {
    let item: WatchItem
    var body: some View {
        HStack(spacing: 8) {
            Text(item.emoji)
                .frame(width: 30, height: 30)
                .background(Color(hex: item.color).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(item.start ?? "Anytime").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ItemDetail: View {
    @EnvironmentObject var model: WatchModel
    let itemId: String

    var body: some View {
        if let item = model.items.first(where: { $0.id == itemId }) {
            List {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.emoji).font(.title)
                    Text(item.title).font(.headline)
                    Text("\(item.start ?? "Anytime") · \(item.duration) min").font(.caption).foregroundStyle(.secondary)
                }
                if !item.steps.isEmpty {
                    Section("Steps") {
                        ForEach(Array(item.steps.enumerated()), id: \.offset) { idx, step in
                            Button {
                                Task { await model.toggleStep(item, idx) }
                            } label: {
                                HStack {
                                    Image(systemName: step.d ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(step.d ? Color(hex: item.color) : .secondary)
                                    Text(step.t).strikethrough(step.d)
                                }
                            }
                        }
                    }
                }
                if item.numericId != nil {
                    Button {
                        Task { await model.toggleDone(item) }
                    } label: {
                        Label(item.done ? "Not done" : "Mark done", systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(Color(hex: item.color))
                }
            }
            .navigationTitle(item.emoji)
        } else {
            Text("This has changed. Go back and refresh.")
        }
    }
}

/// Add a to-do by talking, scribbling or typing.
struct AddView: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        List {
            TextField("What do you need to do?", text: $text)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    save(now: false)
                } label: {
                    Label("Add to to-do list", systemImage: "checklist")
                }
                Button {
                    save(now: true)
                } label: {
                    Label("Do it now (15 min)", systemImage: "play.fill")
                }
                .tint(Color(hex: "#73CBA8"))
            } else {
                Text("Tap above, then speak, scribble or type.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if failed {
                Text("Couldn't add that. Check your iPhone has signal and try again.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .disabled(busy)
        .navigationTitle("Add")
    }

    private func save(now: Bool) {
        busy = true
        failed = false
        Task {
            let ok = await model.add(text, now: now)
            busy = false
            if ok { dismiss() } else { failed = true }
        }
    }
}
