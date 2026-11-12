import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Menu bar

struct MenuLabel: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let t = model.menuTitle {
                Text(t)
            } else {
                Image(systemName: "circle.dotted.circle")
            }
        }
        .onAppear {
            model.openMain = { openWindow(id: "main") }
            model.openPrefs = { openWindow(id: "prefs") }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.isSetUp {
            Button("Set up Pacely…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        } else {
            if let f = model.focusEnd, f > model.tick {
                Text("⏳ Focus: \(model.focusTitle) · \(model.minutesText(f.timeIntervalSince(model.tick))) left")
            }
            if let c = model.current {
                Text("Now: \(c.label) · \(model.minutesText(c.end.timeIntervalSince(model.tick))) left")
                if c.canTick {
                    Button("✓ Mark “\(c.item.title)” done") { Task { await model.markDone(c) } }
                }
                Button("⏳ Start focus") { model.startFocus(c) }
            } else {
                Text("Nothing happening right now")
            }
            Menu("🐢 Running late") {
                ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                    Button("Push the rest of today back \(m) min") { Task { await model.shift(minutes: m) } }
                }
            }
            Divider()
            if model.upcoming.isEmpty {
                Text("Nothing else today 🌿")
            } else {
                Text("Coming up")
                ForEach(model.upcoming.prefix(6)) { p in
                    Text("\(p.item.start)  \(p.label)")
                }
            }
            if model.offline {
                Divider()
                Text("⚠️ Can’t reach your Pacely server")
            }
        }
        Divider()
        Button("Open Pacely") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut("o")
        Button("Settings…") { openWindow(id: "prefs"); NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut(",")
        Button("Refresh") { Task { await model.refresh() } }
            .keyboardShortcut("r")
        Divider()
        Button("Quit Pacely") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Setup

private struct TokenResponse: Codable {
    let token: String
    let widget: String
}

// MARK: - First run: where should Pacely keep your plans?

struct MacWelcomeView: View {
    @EnvironmentObject var model: MacModel
    let connect: () -> Void
    @State private var error: String?
    private let teal = Color(hex: "#2F7D78")

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "circle.dotted.circle")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(teal)
                    .padding(.top, 30)
                Text("Welcome to Pacely").font(.largeTitle.bold())
                Text("Where should Pacely keep your plans?")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Label("On this Mac", systemImage: "laptopcomputer").font(.title3.bold())
                    Text("No server needed and works without internet. Your plans are saved in a file on this Mac, with a backup copy each day. Move them to another Mac or PC any time with File › Export Database.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(LocalStore.exists ? "Open my plans on this Mac" : "Start fresh") { model.chooseLocal() }
                            .buttonStyle(.borderedProminent).tint(teal)
                        Button("Load a saved file…") { loadFile() }
                    }
                    .padding(.top, 4)
                }
                .padding(18)
                .frame(maxWidth: 440, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))

                VStack(alignment: .leading, spacing: 10) {
                    Label("On my Pacely server", systemImage: "server.rack").font(.title3.bold())
                    Text("Use the same plans on your phone, watch and computers. You need a Pacely server you or someone you trust runs.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect to a server…", action: connect)
                        .padding(.top, 4)
                }
                .padding(18)
                .frame(maxWidth: 440, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))

                if let error = error { Text(error).foregroundStyle(.red) }
                Text("You can change this later in Pacely › Settings. Nothing is sent anywhere else.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Pacely backup file"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard let text = LocalStore.validBackup(data) else {
            error = "That file isn't a Pacely backup."
            return
        }
        model.chooseLocal(from: text)
    }
}

struct MacSetupView: View {
    @EnvironmentObject var model: MacModel
    var back: () -> Void = {}
    @State private var server = Store.server
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "circle.dotted.circle")
                .font(.system(size: 60, weight: .medium))
                .foregroundStyle(Color(hex: "#2F7D78"))
            Text("Pacely").font(.largeTitle.bold())
            Text("Connect to your own Pacely server. Nothing is sent anywhere else.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Form {
                TextField("Server address", text: $server, prompt: Text("plan.example.com"))
                SecureField("Pacely password", text: $password)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 380, maxHeight: 140)
            if let error = error {
                Text(error).foregroundStyle(.red)
            }
            Button {
                Task { await connect() }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text("Connect").frame(width: 160) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#2F7D78"))
            .keyboardShortcut(.defaultAction)
            .disabled(busy || server.isEmpty || password.isEmpty)
            Button("Back", action: back)
                .buttonStyle(.link)
            Spacer()
        }
        .padding(30)
    }

    @MainActor
    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        Store.server = Store.normalise(server)
        do {
            let data = try await API.request("/api/token", method: "POST", body: ["password": password], useToken: false)
            let r = try JSONDecoder().decode(TokenResponse.self, from: data)
            Store.token = r.token
            password = ""
            model.didSetUp()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Settings

struct MacSettingsView: View {
    @EnvironmentObject var model: MacModel
    @State private var popups = Store.popups
    @State private var sound = Store.sound
    @State private var banners = Store.banners
    @State private var atLogin = LoginItem.enabled
    @State private var confirmUnlink = false

    var body: some View {
        Form {
            Section {
                Toggle("Pop-up reminders", isOn: $popups)
                    .onChange(of: popups) { v in Store.popups = v }
                Text("A calm card in the top-right corner when an activity starts, 5 minutes before it ends, and when focus time is up. It won’t take over your keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play a soft sound", isOn: $sound)
                    .onChange(of: sound) { v in Store.sound = v }
                Toggle("Notification Centre banners", isOn: $banners)
                    .onChange(of: banners) { v in Store.banners = v; Task { await model.refresh() } }
                Text("Useful if you switch pop-ups off. Having both on means two alerts each time.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show a test pop-up") { model.testPopup() }
            } header: {
                Text("Reminders")
            }
            Section {
                Toggle("Open Pacely when I log in", isOn: $atLogin)
                    .onChange(of: atLogin) { v in LoginItem.set(v) }
                Text("Pacely then sits in your menu bar all day, showing what’s now and how long is left.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Start-up")
            }
            Section {
                LabeledContent("Plans are kept", value: model.isLocal ? "On this Mac" : (model.mode == "server" ? Store.server : "Not chosen yet"))
                HStack {
                    Button("Export Database…") { model.exportDatabase() }
                    Button("Import Database…") { model.importDatabase() }
                }
                .disabled(!model.isSetUp)
                if model.isLocal {
                    Button("Show Backups Folder") {
                        try? FileManager.default.createDirectory(at: LocalStore.backupsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LocalStore.backupsFolder)
                    }
                    Text("Pacely saves a copy of your plans every day and keeps the last 14.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Change Where Plans Are Kept…") { model.changeStorage() }
                    .disabled(!model.isSetUp)
            } header: {
                Text("Your plans")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .confirmationDialog("Unlink this Mac from Pacely?", isPresented: $confirmUnlink) {
            Button("Unlink", role: .destructive) { model.signOut() }
        }
    }
}
