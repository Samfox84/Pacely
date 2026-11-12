import ActivityKit
import WidgetKit
import SwiftUI

/// Which way the Live Activity should look right now.
enum LAPhase { case upcoming, running, over }

func laPhase(_ s: PacelyActivityAttributes.ContentState, stale: Bool) -> LAPhase {
    if s.kind == "focus" { return stale ? .over : .running }
    if s.start > s.shown {
        // Put up ahead of time: it becomes "stale" at the start time, which switches it to the countdown.
        return stale ? .running : .upcoming
    }
    return stale ? .over : .running
}

func laLabel(_ s: PacelyActivityAttributes.ContentState, _ ph: LAPhase) -> String {
    if s.kind == "focus" { return ph == .over ? "FOCUS DONE" : "FOCUS" }
    switch ph {
    case .upcoming: return "NEXT"
    case .running: return "NOW"
    case .over: return "TIME'S UP"
    }
}

struct PacelyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PacelyActivityAttributes.self) { context in
            // A fixed dark card with light text: readable on any wallpaper, in light or dark mode
            ActivityFamilyView(state: context.state, phase: laPhase(context.state, stale: context.isStale))
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color(red: 0.11, green: 0.13, blue: 0.15).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let ph = laPhase(s, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PacelyIcon(emoji: s.emoji, size: 32)
                        .foregroundStyle(Color(hex: s.colorHex))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BigTimer(state: s, phase: ph)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .frame(maxWidth: 96)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(laLabel(s, ph))
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Color(hex: s.colorHex))
                        Text(s.title).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        if ph == .running && !s.isCalm {
                            ProgressView(timerInterval: s.range, countsDown: true) {
                                EmptyView()
                            } currentValueLabel: {
                                EmptyView()
                            }
                            .tint(Color(hex: s.colorHex))
                        } else if !s.nextTitle.isEmpty {
                            Text("Then \(s.nextTitle) at \(s.nextStart)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                        }
                        ActivityButtons(state: s, phase: ph)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                PacelyIcon(emoji: s.emoji, size: 18).foregroundStyle(Color(hex: s.colorHex))
            } compactTrailing: {
                Group {
                    switch ph {
                    case .upcoming:
                        Text(s.start, style: .time)
                    case .running:
                        if s.isCalm { Text(s.end, style: .time) } else { Text(timerInterval: s.range, countsDown: true).monospacedDigit() }
                    case .over:
                        Image(systemName: "checkmark.circle")
                    }
                }
                .frame(maxWidth: 52)
                .foregroundStyle(Color(hex: s.colorHex))
            } minimal: {
                PacelyIcon(emoji: s.emoji, size: 16).foregroundStyle(Color(hex: s.colorHex))
            }
            .keylineTint(Color(hex: s.colorHex))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Picks the right look: the full Lock Screen card, or a calm small card for CarPlay and Apple Watch.
struct ActivityFamilyView: View {
    @Environment(\.activityFamily) var family
    let state: PacelyActivityAttributes.ContentState
    let phase: LAPhase
    var body: some View {
        if family == .small {
            CalmSmallView(state: state, phase: phase)
        } else {
            LockScreenActivityView(state: state, phase: phase)
        }
    }
}

/// CarPlay and Apple Watch: no ticking numbers, nothing to tap. Just what it is and when it ends.
struct CalmSmallView: View {
    let state: PacelyActivityAttributes.ContentState
    let phase: LAPhase
    var body: some View {
        HStack(spacing: 10) {
            PacelyIcon(emoji: state.emoji, size: 20)
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 36, height: 36)
                .background(Color(hex: state.colorHex).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                Group {
                    switch phase {
                    case .upcoming: Text("Later, at \(state.start, style: .time)")
                    case .running: Text(state.kind == "focus" ? "Focus time" : "Until \(state.end, style: .time)")
                    case .over: Text(state.nextTitle.isEmpty ? "All done" : "Next: \(state.nextTitle)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

struct BigTimer: View {
    let state: PacelyActivityAttributes.ContentState
    let phase: LAPhase
    var body: some View {
        switch phase {
        case .upcoming:
            Text(state.start, style: .time)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        case .running:
            if state.isCalm {
                Text("until \(state.end, style: .time)")
                    .multilineTextAlignment(.trailing)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text(timerInterval: state.range, countsDown: true)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
        case .over:
            Image(systemName: "checkmark.circle")
        }
    }
}

struct ActivityButtons: View {
    let state: PacelyActivityAttributes.ContentState
    let phase: LAPhase
    var body: some View {
        if state.kind == "focus" {
            Button(intent: StopFocusIntent()) {
                Label(phase == .over ? "Close" : "Stop", systemImage: phase == .over ? "xmark" : "stop.fill")
                    .font(.caption.bold())
            }
            .tint(Color(hex: state.colorHex))
        } else {
            HStack(spacing: 6) {
                if phase != .over && state.itemId > -900000 {   // journeys (to work, home) have no "Late" button
                    Button(intent: RunningLateIntent(minutes: 10)) {
                        Label("Late", systemImage: "clock.arrow.circlepath")
                            .font(.caption.bold())
                    }
                    .tint(.secondary)
                }
                if state.itemId > 0 && phase != .upcoming {
                    Button(intent: LiveActivityDoneIntent(itemId: state.itemId)) {
                        Label("Done", systemImage: "checkmark")
                            .font(.caption.bold())
                    }
                    .tint(Color(hex: state.colorHex))
                }
            }
        }
    }
}

struct LockScreenActivityView: View {
    let state: PacelyActivityAttributes.ContentState
    let phase: LAPhase

    var body: some View {
        HStack(spacing: 14) {
            PacelyIcon(emoji: state.emoji, size: 28)
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 54, height: 54)
                .background(Color(hex: state.colorHex), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(laLabel(state, phase))
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.secondary)
                    Spacer()
                    BigTimer(state: state, phase: phase)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                Text(state.title).font(.headline).lineLimit(1)
                HStack(spacing: 10) {
                    if phase == .running && state.isCalm {
                        Spacer(minLength: 0)
                    } else if phase == .running {
                        ProgressView(timerInterval: state.range, countsDown: true) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .tint(Color(hex: state.colorHex))
                    } else if phase == .upcoming {
                        Text("Starts at \(state.start, style: .time) · \(Int(state.end.timeIntervalSince(state.start) / 60)) min")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else {
                        Text(state.nextTitle.isEmpty ? "Nicely done." : "Then \(state.nextTitle) at \(state.nextStart)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    ActivityButtons(state: state, phase: phase)
                }
                if phase == .running && !state.nextTitle.isEmpty {
                    Text("Then \(state.nextTitle) at \(state.nextStart)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(16)
    }
}
