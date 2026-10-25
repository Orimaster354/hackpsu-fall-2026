import ARKit
import RealityKit
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
    @Environment(\.gameAudio) private var audio
    @State private var sensor = MotionSensor()
    @State private var camera = CameraFeed()
    @State private var preview = TaskARPreview()
    @State private var telemetry = TaskTelemetry()
    @Environment(PositionCoordinator.self) private var position
    @Environment(GameSession.self) private var session
    @State private var attempt = 0
    @State private var progress = 0.0
    @State private var outcome = Outcome.running
    @State private var deadline = Date.now
    /// Counts finished tasks, to play the screen flash.
    @State private var flashes = 0

    static let timeLimit: TimeInterval = 15

    private enum Outcome { case running, awaitingTile, success, timedOut, cancelled }

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
        .overlay { CompletionFlash(trigger: flashes) }
        .preferredColorScheme(.dark)
        // Never open a second camera while ARKit owns it: that interrupts AR and loses the player's place.
        .task {
            guard session.canAttemptTasks else { return }
            if position.mode == .manual, sharedARView == nil {
                (position.ar as? ARPositionProvider)?.prepareForManualTask()
                await preview.start()
            }
            guard !Task.isCancelled, session.canAttemptTasks else { preview.stop(); return }
            if arView == nil { await camera.start() }
        }
        .task(id: attempt) { await runClock() }
        .onChange(of: session.canAttemptTasks) { _, allowed in
            if !allowed { cancelAttempt() }
        }
        .onChange(of: playsInAR) { _, inAR in telemetry.requiresAim = inAR }
        .onDisappear {
            sensor.stop()
            camera.stop()
            preview.stop()
        }
        .onChange(of: canFinish) { _, canFinish in
            if canFinish, outcome == .awaitingTile { finish() }
        }
        .sensoryFeedback(.success, trigger: outcome) { _, new in new == .success }
        .sensoryFeedback(.error, trigger: outcome) { _, new in new == .timedOut }
    }

    // MARK: Pieces

    /// Old rooms can still decode Tilt, but play the supported hold-steady task.
    private var task: TaskKind { station.task == .tilt ? .hold : station.task }

    /// True on the station's tile with the lights on, the same rule `completeTask` applies.
    private var canFinish: Bool { session.canDoTask(at: station) }

    /// The AR session's shared view, whenever ARKit owns the camera (even while it is still finding its place, or
    /// when the player chose manual tiles). The task is drawn on that view, never on a second camera.
    private var sharedARView: ARView? {
        guard let provider = position.ar as? ARPositionProvider else { return nil }
        return provider.taskARView
    }

    private var arView: ARView? { sharedARView ?? preview.arView }

    /// Visual tracking is independent of tile input. Manual games may use a local task-only AR frame.
    /// If tracking is unavailable, retain the 2D task controls.
    private var playsInAR: Bool {
        guard arView != nil else { return false }
        if position.mode == .manual {
            if preview.arView != nil { return preview.isTracking }
            return (position.ar as? ARPositionProvider)?.isSessionRunning == true
                && sharedARView?.session.currentFrame?.camera.trackingState == .normal
        }
        return position.status == .tracking
    }

    /// One line on what the prop shows for this task.
    private var arHint: String {
        switch task {
        case .shake: "Shake the phone. The block in front of you jolts with every hit."
        case .tilt, .hold: "Hold the phone steady. The orb swells while you keep still."
        case .dial: "Turn the phone. The knob in front of you turns with it."
        case .gesture: "Tilt the pattern. The ball on the tray follows your phone."
        case .hammer: "Swing the phone down. The hammer drives the nail into the wood."
        }
    }

    /// The room through the camera under a dark scrim so the text stays readable, or the plain
    /// backdrop when the camera is not available.
    @ViewBuilder private var backdrop: some View {
        if let arView {
            ZStack {
                TaskARBackdrop(arView: arView, task: task, telemetry: telemetry, inFrontOfCamera: position.mode == .manual)
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
            // The 2D controls are the task in manual mode. In AR they stay alive (they run the rules from the
            // motion sensor) but are hidden, so the player sees one thing to play: the prop in the room.
            ZStack {
                switch task {
                case .shake: ShakeTaskView(context: context)
                case .tilt, .hold: SteadyTaskView(context: context)
                case .dial: DialTaskView(context: context)
                case .gesture: PatternTaskView(context: context)
                case .hammer: HammerTaskView(context: context)
                }
            }
            .id(attempt)
            .frame(width: playsInAR ? 1 : nil, height: playsInAR ? 1 : nil)
            .clipped()
            .opacity(playsInAR ? 0 : (outcome == .running ? 1 : 0.35))
            .allowsHitTesting(!playsInAR)
            if playsInAR, outcome == .running { aimGuide }
        }
        .frame(minHeight: playsInAR ? 180 : 0)
        .overlay {
            switch outcome {
            case .running, .cancelled: EmptyView()
            case .awaitingTile:
                Label("Step back onto the task tile to finish", systemImage: "location.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.warning)
                    .multilineTextAlignment(.center)
                    .padding()
            case .success:
                ZStack {
                    CompletionBurst(size: 230).offset(y: -34)
                    Text("TASK COMPLETE")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .tracking(2.5)
                        .foregroundStyle(.white)
                        .shadow(color: Theme.Palette.success.opacity(0.8), radius: 10)
                        .popOnAppear(delay: 0.15)
                        .offset(y: 112)
                }
            case .timedOut:
                Label("Time's up", systemImage: "clock.badge.exclamationmark.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.danger)
            }
        }
    }

    /// Shown over the AR scene while the task is played on the prop: what to do, or how to get the prop back
    /// in view. The telemetry fields are plain, so a timeline polls them.
    private var aimGuide: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            VStack(spacing: 10) {
                if telemetry.aimed {
                    Label(arHint, systemImage: "viewfinder")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                } else {
                    Label("Point the camera at the prop to keep going", systemImage: "scope")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.Palette.warning)
                    Button("Bring the prop back") { telemetry.recenterRequested = true }
                        .buttonStyle(.game(.secondary))
                        .fixedSize()
                }
            }
            .multilineTextAlignment(.center)
            .padding(14)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        switch task {
        case .shake: "Shake the phone hard \(ShakeModel.needed) times."
        case .tilt, .hold: "Hold the phone upright and keep it steady for \(Int(SteadyModel.holdSeconds)) seconds."
        case .dial: "Hold the phone upright and turn it like a dial to line the needle up with each marker."
        case .gesture: "Hold the phone flat and tilt it in the pattern shown: lower the edge each arrow points to, then level the phone before the next move."
        case .hammer: "Swing the phone down like a hammer to drive the nail in. \(HammerModel.needed) hard hits."
        }
    }

    private func cancelAttempt() {
        outcome = .cancelled
        sensor.stop()
        camera.stop()
        preview.stop()
        dismiss()
    }

    private func runClock() async {
        guard session.canAttemptTasks else { cancelAttempt(); return }
        progress = 0
        telemetry.reset()
        telemetry.requiresAim = playsInAR
        outcome = .running
        deadline = .now.addingTimeInterval(Self.timeLimit)
        sensor.start()
        try? await Task.sleep(for: .seconds(Self.timeLimit))
        guard !Task.isCancelled, outcome == .running else { return }
        guard session.canAttemptTasks else { cancelAttempt(); return }
        sensor.stop()
        telemetry.state = .timedOut
        outcome = .timedOut
        audio?.play(.taskFailed)
    }

    private func succeed() {
        guard outcome == .running, session.canAttemptTasks else { return }
        sensor.stop()
        telemetry.progress = 1
        progress = 1
        if canFinish { finish() } else { outcome = .awaitingTile }
    }

    private func finish() {
        guard session.canAttemptTasks, canFinish,
              outcome == .running || outcome == .awaitingTile else { return }
        outcome = .success
        audio?.play(.taskComplete)
        flashes += 1
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
