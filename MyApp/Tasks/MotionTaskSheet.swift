import SwiftUI

/// The sheet a crew member does a task in. It picks the Core Motion task for the station's
/// `task` kind, runs a 15 s clock, and calls `onFinish` once on success. An idle phone runs out
/// the clock and fails. `onFinish` is what reports `taskDone`, so it is never called on failure.
struct MotionTaskSheet: View {
    let station: MapStation
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sensor = MotionSensor()
    @State private var attempt = 0
    @State private var progress = 0.0
    @State private var outcome = Outcome.running
    @State private var deadline = Date.now

    static let timeLimit: TimeInterval = 15

    private enum Outcome { case running, success, timedOut }

    var body: some View {
        VStack(spacing: 20) {
            header
            if sensor.isAvailable || outcome != .running {
                arena
            } else {
                unavailable
            }
            footer
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
        .presentationBackground { GameBackdrop() }
        .preferredColorScheme(.dark)
        .task(id: attempt) { await runClock() }
        .onDisappear { sensor.stop() }
        .sensoryFeedback(.success, trigger: outcome) { _, new in new == .success }
        .sensoryFeedback(.error, trigger: outcome) { _, new in new == .timedOut }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            StationIcon(kind: .task, size: 48)
            Text(station.name)
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(instruction)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            clock
        }
    }

    private var clock: some View {
        VStack(spacing: 6) {
            ProgressView(value: progress)
                .tint(Theme.Palette.success)
                .animation(.easeOut(duration: 0.15), value: progress)
            if outcome == .running {
                TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                    let left = max(0, deadline.timeIntervalSince(timeline.date))
                    Text("\(Int(left.rounded(.up))) s left")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(left <= 5 ? Theme.Palette.warning : Theme.Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var arena: some View {
        let context = TaskContext(
            sensor: sensor,
            report: TaskReport(progress: { if outcome == .running { progress = $0 } }, complete: succeed)
        )
        ZStack {
            switch station.task {
            case .shake: ShakeTaskView(context: context)
            case .tilt: BalanceTaskView(context: context)
            case .hold: SteadyTaskView(context: context)
            case .dial: DialTaskView(context: context)
            case .gesture: PatternTaskView(context: context)
            }
        }
        .id(attempt)
        .opacity(outcome == .running ? 1 : 0.35)
        .overlay {
            switch outcome {
            case .running: EmptyView()
            case .success:
                Label("Task complete", systemImage: "checkmark.circle.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.success)
            case .timedOut:
                Label("Time's up", systemImage: "clock.badge.exclamationmark.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.danger)
            }
        }
    }

    private var unavailable: some View {
        Text("This device has no motion sensors, so the task cannot run here.")
            .font(.subheadline)
            .foregroundStyle(Theme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 40)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            if outcome == .timedOut {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.game(.primary))
            }
            #if targetEnvironment(simulator)
            if outcome == .running {
                Button("Simulator: finish task") { succeed() }
                    .buttonStyle(.game(.secondary))
            }
            #endif
            if outcome != .success {
                Button("Not now") { dismiss() }
                    .buttonStyle(.game(.text))
            }
        }
    }

    // MARK: Flow

    private var instruction: String {
        switch station.task {
        case .shake: "Shake the phone hard \(ShakeModel.needed) times."
        case .tilt: "Hold the phone flat and tilt it to keep the ball in the ring for \(Int(BalanceModel.holdSeconds)) seconds. The ball keeps drifting away."
        case .hold: "Hold the phone upright and keep it steady for \(Int(SteadyModel.holdSeconds)) seconds."
        case .dial: "Hold the phone upright and turn it like a dial to line the needle up with each marker."
        case .gesture: "Hold the phone flat and tilt it in the pattern shown, leveling it between moves."
        }
    }

    private func runClock() async {
        progress = 0
        outcome = .running
        deadline = .now.addingTimeInterval(Self.timeLimit)
        sensor.start()
        try? await Task.sleep(for: .seconds(Self.timeLimit))
        guard !Task.isCancelled, outcome == .running else { return }
        sensor.stop()
        outcome = .timedOut
    }

    private func succeed() {
        guard outcome == .running else { return }
        sensor.stop()
        outcome = .success
        progress = 1
        onFinish()
        Task {
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}
