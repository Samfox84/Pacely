import SwiftUI

/// The native Pacely app: five tabs, all real iPhone screens.
struct RootTabView: View {
    @State private var planner = Planner.shared
    @State private var tab = "today"
    @State private var sheet: Sheet?
    @Environment(\.scenePhase) private var phase
    @AppStorage("pacely.font") private var fontChoice = "standard"
    @AppStorage("pacely.lowStim") private var lowStim = false

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                Tab("Today", systemImage: "calendar", value: "today") { TodayView(planner: planner, sheet: $sheet) }
                Tab("To-do", systemImage: "checklist", value: "todo") { TodoView(planner: planner, sheet: $sheet) }
                Tab("Focus", systemImage: "hourglass", value: "focus") { FocusView(planner: planner) }
                Tab("Routines", systemImage: "repeat", value: "routines") { RoutinesView(planner: planner) }
                Tab("Me", systemImage: "person.crop.circle", value: "me") { MeView(planner: planner, sheet: $sheet) }
            }
            .tint(Look.accent)
            .font(Look.f(.body))
            .id(fontChoice)            // redraw everything in the chosen reading font
            .saturation(lowStim ? 0.55 : 1)                                        // low-stimulation: softer colours
            .transaction { if lowStim { $0.disablesAnimations = true; $0.animation = nil } }   // and nothing moves
            .sensoryFeedback(.selection, trigger: tab)
            .onChange(of: tab) { _, _ in Feedback.sound("tab") }
            ToastView(planner: planner)
            VStack { Spacer(); OfflinePill(planner: planner).padding(.bottom, 64) }
                .allowsHitTesting(false)
            if planner.aiBusy > 0 { ThinkingGlow() }
            if !planner.ready { LoadingView(planner: planner).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.6), value: planner.aiBusy > 0)
        .animation(.easeInOut(duration: 0.4), value: planner.ready)
        .animation(.easeInOut(duration: 0.3), value: planner.offline || planner.pending > 0)
        .onAppear { KeyboardTidy.install() }
        .task {
            if UserDefaults.standard.object(forKey: "pacely.welcomeSound") as? Bool ?? true { Feedback.sound("welcome") }
            await planner.start()
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                if planner.date < Day.today && planner.mode == .day { planner.date = Day.today }
                Task { await planner.load(); await planner.loadTodos(); planner.startLive() }
            } else if p == .background {
                planner.stopLive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pacelyTab)) { n in if let t = n.object as? String { tab = t } }
        .onOpenURL { url in open(url) }
        .task {
            // For automatic tests: launch with  -pacelyOpen pacely://todo  to open a screen directly
            if let u = UserDefaults.standard.string(forKey: "pacelyOpen"), let url = URL(string: u) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                open(url)
            }
        }
        .onChange(of: sheet?.id) { old, new in
            if new != nil && old == nil { Feedback.sound("open") } else if new == nil && old != nil { Feedback.sound("close") }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .detail(let it): ItemDetail(planner: planner, item: it, sheet: $sheet).presentationDetents([.medium, .large])
            case .edit(let it, let p): EditorView(planner: planner, original: it, preset: p)
            case .dictate(let done): DictationView(onDone: done).presentationDetents([.medium])
            case .mood: MoodSheet(planner: planner).presentationDetents([.medium, .large])
            case .review: ReviewSheet(planner: planner)
            case .couldnt(let it): CouldntSheet(planner: planner, item: it).presentationDetents([.medium, .large])
            case .smart(let t): SmartEventSheet(target: .mine(planner), text: t)
            }
        }
    }

    private func open(_ url: URL) {
        let v = url.host ?? "today"
            if ["today", "todo", "focus", "routines", "me"].contains(v) { tab = v }
            if v == "add" { tab = "today"; sheet = .edit(nil, Preset(date: planner.date)) }
            if v == "item", let id = url.pathComponents.last {
                // pacely://item/12 opens that activity
                tab = "today"
                Task {
                    if planner.day.items.isEmpty { await planner.load() }
                    if planner.todos.isEmpty { await planner.loadTodos() }
                    if let it = (planner.day.items + planner.day.allday + planner.todos).first(where: { $0.id == id }) { sheet = .detail(it) }
                }
            }
            if v == "day", let d = url.pathComponents.last, d.count == 10 { tab = "today"; planner.mode = .day; planner.go(d) }
            if v == "week" || v == "month" { tab = "today"; planner.mode = v == "week" ? .week : .month; Task { await planner.load() } }
    }
}
