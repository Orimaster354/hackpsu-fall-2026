import RealityKit
import SwiftUI

/// A shape-only lights repair, drawn with the phone's aim or directly on screen. The camera belongs to
/// PositionCoordinator; this sheet only borrows its shared view and reads poses through the controller.
struct FixTraceSheet: View {
    let station: MapStation
    let onFix: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.gameAudio) private var audio
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PositionCoordinator.self) private var position
    @Environment(GameSession.self) private var session
    @State private var controller = FixTraceController(input: .touch)
    @State private var prefersTouch = false
    @State private var preview = TaskARPreview()
    @State private var outcome = Outcome.running
    @State private var attempt = 0
    @State private var deadline = Date.now
    @State private var flashes = 0

    static let timeLimit: TimeInterval = 30
    private enum Outcome { case running, awaitingTile, success, timedOut, cancelled }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            surface.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
            .gameColumn()
            outcomeOverlay
        }
        .overlay { CompletionFlash(trigger: flashes, tint: Theme.Palette.neon) }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task {
            if position.mode == .manual, canAttempt, sharedARView == nil {
                (position.ar as? ARPositionProvider)?.prepareForManualTask()
                await preview.start()
            }
            if Task.isCancelled || !canAttempt { preview.stop() }
        }
        .task(id: usesAR) { await trackInput() }
        .task(id: attempt) { await runClock() }
        .task(id: outcome) {
            guard outcome == .success else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            dismiss()
        }
        .onChange(of: canAttempt) { _, allowed in
            if !allowed, outcome != .success { cancelAttempt() }
        }
        .onChange(of: controller.verdicts) { _, _ in
            if controller.isAccepted { matched() }
        }
        .onChange(of: canFinish) { _, allowed in
            if allowed, outcome == .awaitingTile { finish() }
        }
        .onChange(of: controller.isTracking) { _, tracking in
            if !tracking { controller.cancelStroke() }
        }
        .onChange(of: controller.cursor) { _, cursor in
            if usesAR, cursor == nil { controller.cancelStroke() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.cancelStroke() }
        }
        .onDisappear { controller.cancelStroke(); preview.stop() }
        .sensoryFeedback(.impact(weight: .light), trigger: controller.strokesStarted)
        .sensoryFeedback(trigger: controller.verdicts) { _, _ in
            controller.isAccepted ? .success : .warning
        }
        .sensoryFeedback(.selection, trigger: controller.pins)
        .sensoryFeedback(.error, trigger: outcome) { _, new in new == .timedOut }
        .accessibilityAction(named: "Restore power without drawing") { matched() }
    }

    private var canAttempt: Bool {
        session.role == .crew && session.isAlive && session.phase == .playing && session.lightsOut
    }

    /// Check both the current rule and the station this sheet was opened for before sending an intent.
    private var canFinish: Bool {
        session.canFixHere && station.kind == .fix && station.tile == session.myTile
            && session.fixStation?.id == station.id
    }

    private var sharedARView: ARView? {
        (position.ar as? ARPositionProvider)?.taskARView
    }

    private var arView: ARView? { sharedARView ?? preview.arView }

    private var usesAR: Bool { arView != nil && !prefersTouch }

    @ViewBuilder private var backdrop: some View {
        if usesAR, let arView {
            FixTraceCamera(arView: arView)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.25), .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
        } else {
            GameBackdrop()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("RESTART THE POWER")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.white)
                .shadow(color: Theme.Palette.neon.opacity(0.75), radius: 12)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Label(controller.target.title, systemImage: controller.target.symbol)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.Palette.neon)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.Palette.panel.opacity(0.95), in: Capsule())
            Text("Draw it anywhere on the panel. Only the shape counts.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            clock
        }
        .allowsHitTesting(false)
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let left = max(0, deadline.timeIntervalSince(timeline.date))
            VStack(spacing: 6) {
                ProgressView(value: outcome == .running ? left / Self.timeLimit : 0)
                    .tint(left <= 5 ? Theme.Palette.warning : Theme.Palette.neon)
                Text(outcome == .running ? "\(Int(left.rounded(.up))) s left" : clockStatus)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(outcome == .running && left <= 5 ? Theme.Palette.warning : Theme.Palette.textSecondary)
            }
        }
    }

    private var clockStatus: String {
        switch outcome {
        case .running: ""
        case .awaitingTile: "Shape matched"
        case .success: "Power restored"
        case .timedOut: "Time's up"
        case .cancelled: ""
        }
    }

    private var surface: some View {
        // Capture environment values outside the Canvas renderer (which may be Sendable).
        let reduced = reduceMotion
        let camera = usesAR ? arView : nil
        let plane = controller.plane
        let target = controller.target
        let stroke = controller.stroke
        let finished = controller.finished
        let accepted = controller.isAccepted
        let finishedAt = controller.finishedAt
        let cursorVisible = controller.cursor != nil && controller.isTracking
        let inAR = usesAR
        let succeeded = outcome == .success

        return GeometryReader { geometry in
            let rect = Self.panelRect(in: geometry.size)
            ZStack {
                TimelineView(.animation(minimumInterval: reduced ? 0.1 : 1.0 / 60)) { timeline in
                    Canvas { context, size in
                        let map: (TracePoint) -> CGPoint? = { point in
                            if inAR {
                                guard let camera, let plane,
                                      camera.bounds.width > 0, camera.bounds.height > 0,
                                      let projected = camera.project(plane.world(point)) else { return nil }
                                return CGPoint(x: projected.x * size.width / camera.bounds.width,
                                               y: projected.y * size.height / camera.bounds.height)
                            }
                            return CGPoint(x: rect.midX + point.x / DrawingPlane.width * rect.width,
                                           y: rect.midY - point.y / DrawingPlane.height * rect.height)
                        }
                        let age = max(0, timeline.date.timeIntervalSince(finishedAt))
                        FixTraceArt(
                            map: map, target: target, stroke: stroke, finished: finished,
                            finishedColor: accepted ? Theme.Palette.neon : Theme.Palette.danger,
                            finishedOpacity: succeeded ? 1 : max(0, 1 - age / 1.2),
                            glow: succeeded ? 1 : 0,
                            time: reduced ? 0 : timeline.date.timeIntervalSinceReferenceDate
                        ).draw(&context)
                        if inAR, !succeeded {
                            Self.drawReticle(&context, size: size, active: cursorVisible)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                if !inAR {
                    Rectangle().fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard outcome == .running, canAttempt else { return }
                                    let point = Self.touchPoint(value.location, size: rect.size)
                                    if controller.isPenDown {
                                        controller.touchMove(to: point)
                                    } else {
                                        controller.touchDown(at: point)
                                    }
                                }
                                .onEnded { _ in
                                    if outcome == .running, canAttempt { controller.penUp() }
                                    else { controller.cancelStroke() }
                                }
                        )
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityLabel("Drawing panel. \(target.title)")
                        .accessibilityHint("Draw the symbol, or use the Restore power without drawing action.")
                        .accessibilityAction(named: "Restore power without drawing") { matched() }
                }
            }
        }
    }

    private static func panelRect(in size: CGSize) -> CGRect {
        let width = max(1, min(size.width - 40, 380))
        let height = width * DrawingPlane.height / DrawingPlane.width
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.48 - height / 2,
                      width: width, height: height)
    }

    private static func touchPoint(_ point: CGPoint, size: CGSize) -> TracePoint {
        TracePoint((point.x / size.width - 0.5) * DrawingPlane.width,
                   (0.5 - point.y / size.height) * DrawingPlane.height)
    }

    private static func drawReticle(_ context: inout GraphicsContext, size: CGSize, active: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - 12, y: center.y))
        cross.addLine(to: CGPoint(x: center.x - 4, y: center.y))
        cross.move(to: CGPoint(x: center.x + 4, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + 12, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 12))
        cross.addLine(to: CGPoint(x: center.x, y: center.y - 4))
        cross.move(to: CGPoint(x: center.x, y: center.y + 4))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + 12))
        context.stroke(cross, with: .color(.white.opacity(active ? 0.95 : 0.25)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if outcome == .running {
                Text(controller.prompt)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.Palette.panel.opacity(0.95), in: Capsule())
                    .accessibilityAddTraits(.updatesFrequently)
                if usesAR {
                    DrawPad(isPressing: controller.isPenDown,
                            onPress: { controller.penDown() }, onRelease: { controller.penUp() })
                        .disabled(!controller.isPinned || !controller.isTracking || controller.cursor == nil)
                        .accessibilityHint("Hold while sweeping the phone's aim to draw. Release to check the shape.")
                        .accessibilityAction(named: "Restore power without drawing") { matched() }
                }
                if arView != nil {
                    Button(usesAR ? "Draw on screen instead" : "Use the camera") { prefersTouch.toggle() }
                        .buttonStyle(.game(.text))
                }
            }
            if outcome == .timedOut {
                Button("Try again") {
                    controller.retry()
                    controller.recenter()
                    outcome = .running
                    attempt += 1
                }
                .buttonStyle(.game(.primary, tint: Theme.Palette.neon))
            }
            if outcome != .success {
                HStack(spacing: 12) {
                    if usesAR, outcome == .running {
                        Button("Recenter panel") { controller.recenter() }
                            .buttonStyle(.game(.text))
                    }
                    Button("Not now") { cancelAttempt() }
                        .buttonStyle(.game(.text))
                }
            }
        }
    }

    @ViewBuilder private var outcomeOverlay: some View {
        switch outcome {
        case .running, .cancelled: EmptyView()
        case .awaitingTile:
            Label("Step back onto the fix tile", systemImage: "location.fill")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.Palette.warning)
                .multilineTextAlignment(.center)
                .padding(24)
                .gameCard()
                .padding(20)
                .accessibilityAddTraits(.isHeader)
        case .success:
            VStack(spacing: 0) {
                CompletionBurst(tint: Theme.Palette.neon, size: 230)
                Text("POWER RESTORED")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .shadow(color: Theme.Palette.neon.opacity(0.8), radius: 12)
            }
            .allowsHitTesting(false)
        case .timedOut:
            Label("Time's up", systemImage: "clock.badge.exclamationmark.fill")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.Palette.danger)
                .padding(24)
                .gameCard()
        }
    }

    // MARK: Attempt lifecycle

    private func trackInput() async {
        controller.cancelStroke()
        controller.arView = arView
        controller.input = usesAR ? .aim : .touch
        controller.recenter()
        while !Task.isCancelled {
            if outcome == .running { controller.tick() }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
    }

    private func runClock() async {
        guard canAttempt else { cancelAttempt(); return }
        deadline = .now.addingTimeInterval(Self.timeLimit)
        do { try await Task.sleep(for: .seconds(Self.timeLimit)) } catch { return }
        guard outcome == .running else { return }
        guard canAttempt else { cancelAttempt(); return }
        controller.cancelStroke()
        outcome = .timedOut
        audio?.play(.taskFailed)
    }

    /// Also used by VoiceOver. A match can wait for the tile, but can never send a fix from elsewhere.
    private func matched() {
        guard outcome == .running, canAttempt else { return }
        controller.cancelStroke()
        if canFinish { finish() } else { outcome = .awaitingTile }
    }

    private func finish() {
        guard canAttempt, canFinish, outcome == .running || outcome == .awaitingTile else { return }
        outcome = .success
        audio?.play(.taskComplete)
        flashes += 1
        onFix()
    }

    private func cancelAttempt() {
        guard outcome != .success else { return }
        controller.cancelStroke()
        outcome = .cancelled
        dismiss()
    }
}

/// Returns the tracking provider's existing view; no camera or AR session lifecycle belongs to this sheet.
private struct FixTraceCamera: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ view: ARView, context: Context) {}
}

private struct DrawPad: View {
    var isPressing: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Label("HOLD TO DRAW", systemImage: "hand.draw.fill")
            .font(.system(.headline, design: .rounded, weight: .heavy))
            .foregroundStyle(.white)
            .slabSurface(tint: Theme.Palette.neon, pressed: isPressing, dimmed: !isEnabled)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled { onPress() } }
                .onEnded { _ in onRelease() })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Hold to draw")
    }
}
