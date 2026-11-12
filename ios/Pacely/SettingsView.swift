import SwiftUI
import UIKit
import UserNotifications
import ActivityKit

struct NativeSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var notifStatus = "Checking…"
    @State private var copied = false
    @State private var refreshed = false
    @State private var confirmSignOut = false
    @State private var calSync = CalendarSync.enabled
    @State private var calMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Reminders") {
                    HStack {
                        Text("Notifications")
                        Spacer()
                        Text(notifStatus).foregroundStyle(.secondary)
                    }
                    Button("Open iPhone Settings for Pacely") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    Button(refreshed ? "Reminders updated ✓" : "Update reminders now") {
                        Task {
                            await Scheduler.requestPermission()
                            await Scheduler.refresh()
                            refreshed = true
                            await loadStatus()
                        }
                    }
                }
                Section {
                    Toggle("Sync with iPhone Calendar", isOn: $calSync)
                        .onChange(of: calSync) { _, on in
                            Task {
                                if on {
                                    if await CalendarSync.requestAccess() {
                                        CalendarSync.enabled = true
                                        calMessage = "Syncing… your plans will appear in a calendar called Pacely."
                                        await CalendarSync.syncIfEnabled()
                                        calMessage = "Done. Your plans are in the Pacely calendar."
                                    } else {
                                        calSync = false
                                        CalendarSync.enabled = false
                                        calMessage = "Calendar access is off. Turn it on in iPhone Settings → Pacely → Calendars → Full Access."
                                    }
                                } else {
                                    CalendarSync.enabled = false
                                    calMessage = "Stopped. The Pacely calendar stays in the Calendar app until you delete it."
                                }
                            }
                        }
                    if let m = calMessage {
                        Text(m).font(Look.f(.footnote)).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("Your Pacely plans show in the Calendar app (and on your Mac, Watch and iCloud). Move or delete one there and Pacely follows. Events from your other calendars show in Pacely. If you subscribed to the Pacely calendar link before, remove that subscription to avoid doubles.")
                }
                Section {
                    HStack {
                        Text("Live Activities")
                        Spacer()
                        Text(ActivityAuthorizationInfo().areActivitiesEnabled ? "On" : "Off").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Your current activity and focus timer show on the Lock Screen and in the Dynamic Island.")
                }
                Section {
                    Text(Store.widgetLink)
                        .font(Look.f(.footnote).monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied ✓" : "Copy widget link") {
                        UIPasteboard.general.string = Store.widgetLink
                        copied = true
                    }
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("Add a Pacely widget to your Home or Lock Screen, press and hold it, tap Edit Widget, and paste this link.")
                }
                Section {
                    Text("Say “Add to Pacely” or “What’s next in Pacely” to Siri.")
                } header: {
                    Text("Siri")
                }
                Section {
                    Text("Open the Pacely app on your Apple Watch. It links itself to this iPhone, then shows what’s now and next and lets you tick things off. Reminders also show on your watch.")
                } header: {
                    Text("Apple Watch")
                }
                Section {
                    LabeledContent("Server", value: Store.server)
                    Button("Unlink this iPhone", role: .destructive) { confirmSignOut = true }
                } header: {
                    Text("Account")
                }
            }
            .navigationTitle("iPhone app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { state.showSettings = false }
                }
            }
            .confirmationDialog("Unlink this iPhone from Pacely?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Unlink", role: .destructive) { state.signOut() }
            }
            .task { await loadStatus() }
        }
    }

    private func loadStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifStatus = "On"
        case .denied: notifStatus = "Off – turn on in Settings"
        default: notifStatus = "Not asked yet"
        }
    }
}
