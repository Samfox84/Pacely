import AppIntents
import Foundation

/// "Hey Siri, add to Pacely"
struct AddToPacelyIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Pacely"
    static var description = IntentDescription("Adds a to-do to your Pacely list.")

    @Parameter(title: "To-do", requestValueDialog: "What should I add?")
    var item: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard Store.isSetUp else {
            return .result(dialog: "Open Pacely first and connect it to your server.")
        }
        _ = try await API.request("/api/activities", method: "POST",
                                  body: ["kind": "todo", "title": item, "priority": "soon"])
        return .result(dialog: "Added \(item) to Pacely.")
    }
}

/// "Hey Siri, what's next in Pacely"
struct WhatsNextIntent: AppIntent {
    static var title: LocalizedStringResource = "What's next in Pacely"
    static var description = IntentDescription("Tells you what you're doing now and what comes next.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard Store.isSetUp else {
            return .result(dialog: "Open Pacely first and connect it to your server.")
        }
        let data = try await API.request("/api/upcoming")
        let p = try JSONDecoder().decode(UpcomingPayload.self, from: data)
        let now = Date()
        var current: UpcomingItem?
        var next: UpcomingItem?
        for item in p.items where (item.done ?? 0) == 0 {
            guard let start = p.startDate(item) else { continue }
            let end = start.addingTimeInterval(TimeInterval(item.duration * 60))
            if start <= now && now < end && current == nil { current = item }
            if start > now && next == nil { next = item }
        }
        var parts: [String] = []
        if let c = current { parts.append("Right now: \(c.title).") }
        if let n = next { parts.append("Next is \(n.title) at \(n.start).") }
        if parts.isEmpty { parts.append("Nothing else is planned. Enjoy the space.") }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
    }
}

struct PacelyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddToPacelyIntent(),
                    phrases: ["Add to \(.applicationName)", "Add a to-do in \(.applicationName)"],
                    shortTitle: "Add to-do",
                    systemImageName: "plus.circle")
        AppShortcut(intent: UpdatePacelyIntent(),
                    phrases: ["Update \(.applicationName)", "Refresh \(.applicationName)"],
                    shortTitle: "Update Pacely",
                    systemImageName: "arrow.clockwise")
        AppShortcut(intent: RunningLateIntent(),
                    phrases: ["I'm running late in \(.applicationName)", "Running late \(.applicationName)", "Push \(.applicationName) back"],
                    shortTitle: "Running late",
                    systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: WhatsNextIntent(),
                    phrases: ["What's next in \(.applicationName)", "What am I doing in \(.applicationName)"],
                    shortTitle: "What's next",
                    systemImageName: "clock")
    }
}
