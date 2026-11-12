import SwiftUI

/// Pacely's look: soft colour blocks, rounded type, calm motion.
enum Look {
    static let accent = Color(red: 0.18, green: 0.49, blue: 0.47)
    static let palette = ["#7CB8F0", "#73CBA8", "#F4A07A", "#B89AE8", "#F6C453", "#EE8FA6", "#A8C686", "#D9B99B", "#9AA8BA", "#F07F6E"]
    static let emojis = ["📝", "🚗", "📞", "💊", "🩺", "👥", "💻", "📧", "📄", "💷", "🛒", "🍽️", "🧹", "🧺", "🛁", "💤", "🏃", "🐾", "👶",
                         "🎂", "📦", "📚", "🎮", "🌳", "🔧", "☕", "🧘", "🌴", "🤒", "🎙️", "🎨", "🎵", "🧠", "💌", "⭐️", "🌙"]
    static let moods = ["😞", "😕", "😐", "🙂", "😄"]
    static let moodNames = ["Low", "Not great", "Okay", "Good", "Great"]
}

extension View {
    /// The tinted card used for activities.
    func block(_ hex: String, done: Bool = false) -> some View {
        self.padding(14)
            .background(Color(hex: hex).opacity(done ? 0.12 : 0.26), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: hex).opacity(done ? 0.15 : 0.35), lineWidth: 1))
    }
    func card() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct EmojiTile: View {
    let emoji: String
    let color: String
    var size: CGFloat = 44
    var body: some View {
        PacelyIcon(emoji: emoji, size: size * 0.52)
            .foregroundStyle(.black.opacity(0.72))
            .frame(width: size, height: size)
            .background(Color(hex: color).opacity(0.9), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// A tick circle that gives a gentle tap when pressed.
struct DoneCircle: View {
    let done: Bool
    let color: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(done ? Color(hex: color) : Color.secondary.opacity(0.5), lineWidth: 2.5)
                    .background(Circle().fill(done ? Color(hex: color) : .clear))
                if done { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.black.opacity(0.7)) }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Mark not done" : "Mark done")
    }
}

/// A small step tick box used inside activity cards.
struct StepRow: View {
    let step: Step
    let color: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: step.d ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(step.d ? Color(hex: color) : .secondary)
                Text(step.t).strikethrough(step.d).foregroundStyle(step.d ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                if let m = step.m, m > 0 { Text("· \(m) min").font(Look.f(.caption)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .font(Look.f(.subheadline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The little message at the bottom ("Added Pick up meds · Undo").
struct ToastView: View {
    @Bindable var planner: Planner
    var body: some View {
        VStack {
            Spacer()
            if let t = planner.toast {
                HStack(spacing: 14) {
                    Text(t.text).font(Look.f(.subheadline).weight(.semibold)).lineLimit(3)
                    if let a = t.action, let run = t.run {
                        Button(a) { planner.toast = nil; run() }.font(Look.f(.subheadline).bold()).underline()
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .foregroundStyle(Color(.systemBackground))
                .background(Color(.label), in: Capsule())
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: t.action == nil ? 2_400_000_000 : 6_000_000_000)
                    if planner.toast?.id == t.id { withAnimation { planner.toast = nil } }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: planner.toast)
        .allowsHitTesting(planner.toast?.action != nil)
    }
}

/// Wrapping row of chips.
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > b.maxX, x > b.minX { x = b.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

/// An activity's calm icon next to its words.
struct IconText: View {
    let emoji: String
    let text: String
    var size: CGFloat = 17
    var body: some View {
        HStack(spacing: 6) {
            PacelyIcon(emoji: emoji, size: size).foregroundStyle(.secondary)
            Text(text)
        }
    }
}

struct Chip: View {
    let text: String
    var on: Bool = false
    var color: String? = nil
    var emoji: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: { Feedback.tap(); action() }) {
            HStack(spacing: 6) {
                if let emoji { PacelyIcon(emoji: emoji, size: 16).foregroundStyle(on ? .white : .secondary) }
                Text(text)
            }
            .font(Look.f(.subheadline).weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(on ? Look.accent : (color.map { Color(hex: $0).opacity(0.3) } ?? Color(.tertiarySystemFill)), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}


/// A soft glow that slowly travels around the edge of the screen while the AI helper is thinking.
/// With Reduce Motion on, it gently breathes instead of moving.
struct ThinkingGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    private let colours: [Color] = [Color(hex: "#73CBA8"), Color(hex: "#7CB8F0"), Color(hex: "#B89AE8"), Color(hex: "#EE8FA6"),
                                    Color(hex: "#F6C453"), Color(hex: "#73CBA8")]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSince(started)
            let still = reduceMotion || Feedback.lowStim
            let angle = still ? 0 : (t / 6).truncatingRemainder(dividingBy: 1) * 360   // one slow turn every 6 seconds
            let breathe = Feedback.lowStim ? 0.6 : 0.55 + 0.25 * sin(t * 2 * .pi / 4)          // 4-second breath (still in low-stimulation)
            ZStack {
                ZStack {
                    ContainerRelativeShape()
                        .strokeBorder(AngularGradient(colors: colours, center: .center, angle: .degrees(angle)), lineWidth: 10)
                        .blur(radius: 14)
                        .opacity(breathe)
                    ContainerRelativeShape()
                        .strokeBorder(AngularGradient(colors: colours, center: .center, angle: .degrees(angle)), lineWidth: 3)
                        .blur(radius: 2)
                        .opacity(breathe * 0.9)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                VStack {
                    // The only part you can touch: says how long it's been, and lets you stop it
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                        Text(t < 20 ? "Thinking… \(Int(t))s" : "Still thinking… \(Int(t))s")
                            .monospacedDigit()
                        Button("Cancel") { Planner.shared.cancelAI() }
                            .font(Look.f(.footnote).weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .accessibilityHint("Stops waiting for the AI helper")
                    }
                    .font(Look.f(.footnote).weight(.semibold))
                    .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, 6)
                    Spacer()
                }
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The AI helper is thinking")
    }
}

extension View {
    /// Shows the thinking glow over this screen or panel while the AI helper works.
    func thinkingGlow(_ planner: Planner) -> some View {
        overlay { if planner.aiBusy > 0 { ThinkingGlow() } }
            .animation(.easeInOut(duration: 0.6), value: planner.aiBusy > 0)
    }
}
