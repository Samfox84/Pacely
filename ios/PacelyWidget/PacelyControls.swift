import WidgetKit
import SwiftUI
import AppIntents

/// Control Centre and Lock Screen buttons (iOS 18): add them from Control Centre › Add a Control › Pacely.

struct RunningLateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.samfox84.pacely.late") {
            ControlWidgetButton(action: RunningLateIntent(minutes: 10)) {
                Label("Running late", systemImage: "clock.arrow.circlepath")
            }
        }
        .displayName("Running late")
        .description("Pushes the rest of today back 10 minutes.")
    }
}

struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.samfox84.pacely.add") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "pacely://add")!)) {
                Label("Add to Pacely", systemImage: "plus.circle")
            }
        }
        .displayName("Add to Pacely")
        .description("Opens Pacely ready to add something.")
    }
}
