import ARKit
import SwiftUI

/// The full-screen view a crew member does a task in, over the live camera when it is available.
/// It picks the Core Motion task for the station's `task` kind, runs a 15 s clock, and calls
/// `onFinish` once on success. An idle phone runs out the clock and fails. `onFinish` is what
/// reports `taskDone`, which the server only accepts on the station's tile, so a finished task
/// waits for the player to be back on the tile instead of reporting from the wrong place.
struct MotionTaskSheet: View {
    let station: MapStation
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sensor = MotionSensor()
    @State private var camera = CameraFeed()
    @State private var telemetry = TaskTelemetry()
    @Environment(PositionCoordinator.self) private var position
    @Environment(GameSession.self) private var session
    @State private var attempt = 0
    @State private var progress = 0.0
    @State private var outcome = Outcome.running
    @State private var deadline = Date.now

    static let timeLimit: TimeInterval = 15

    private enum Outcome { case running, awaitingTile, success, timedOut }

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
        .gameColumn()
        .frame(maxHeight: .infinity, alignment: .top)
        .background { backdrop.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .task { if arSession == nil { await camera.start() } }
        .task(id: attempt) { await runClock() }
        .onDisappear {
            sensor.stop()
            camera.stop()
        }
        .onChange(of: canFinish) { _, canFinish in
            if canFinish, outcome == .awaitingTile { finish() }
        }
        .sensoryFeedback(.success, trigger: outcome) { _, new in new == .success }
        .sensoryFeedback(.error, trigger: outcome) { _, new in new == .timedOut }
    }

    // MARK: Pieces

    /// True on the station's tile with the lights on, the same rule `completeTask` applies.
    private var canFinish: Bool { session.canDoTask(at: station) }

    /// The AR module's session, when the phone is tracking in the room. Then the camera belongs to
    /// ARKit and the task is drawn on it; otherwise the plain camera feed is used.
    private var arSession: ARSession? {
        guard position.mode == .ar, position.status == .tracking else { return nil }
        return (position.ar as? ARPositionProvider)?.arSession
    }

    /// The room through the camera under a dark scrim so the text stays readable, or the plain
    /// backdrop when the camera is not available.
    @ViewBuilder private var backdrop: some View {
        if let arSession {
            ZStack {
                TaskARBackdrop(session: arSession, task: station.task, telemetry: telemetry)
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
        } else if camera.status == .running {
            ZStack {
                CameraBackdrop(session: camera.session)
                LinearGradient(
                    colors: [.black.opacity(0.7), .black.opacity(0.25), .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            GameBackdrop()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            StationIcon(kind: .task, size: 48)
            Text(station.name)
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(instruction)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if outcome == .running, !canFinish { offTileNotice }
            clock
        }
    }

    private var offTileNotice: some View {
        Label("You are off the task tile. Step back onto it to finish.", systemImage: "location.slash.fill")
            .font(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.Palette.warning)
            .multilineTextAlignment(.center)
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
            report: TaskReport(
                progress: {
                    guard outcome == .running else { return }
                    progress = $0
                    telemetry.progress = $0
                },
                complete: succeed
            ),
            telemetry: telemetry
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
            case .awaitingTile:
                Label("Step back onto the task tile to finish", systemImage: "location.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.warning)
                    .multilineTextAlignment(.center)
                    .padding()
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
        case .gesture: "Hold the phone flat and tilt it in the pattern shown: lower the edge each arrow points to, then level the phone before the next move."
        }
    }

    private func runClock() async {
        progress = 0
        telemetry.reset()
        outcome = .running
        deadline = .now.addingTimeInterval(Self.timeLimit)
        sensor.start()
        try? await Task.sleep(for: .seconds(Self.timeLimit))
        guard !Task.isCancelled, outcome == .running else { return }
        sensor.stop()
        telemetry.state = .timedOut
        outcome = .timedOut
    }

    private func succeed() {
        guard outcome == .running else { return }
        sensor.stop()
        telemetry.progress = 1
        progress = 1
        if canFinish { finish() } else { outcome = .awaitingTile }
    }

    private func finish() {
        outcome = .success
        telemetry.state = .success
        telemetry.progress = 1
        progress = 1
        onFinish()
        Task {
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}
