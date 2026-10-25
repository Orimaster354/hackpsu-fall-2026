import Combine
import SwiftUI

/// What a task view tells its host.
struct TaskReport {
    let progress: (Double) -> Void
    let complete: () -> Void
}

/// Everything a task view needs: the sensor to read and where to report.
struct TaskContext {
    let sensor: MotionSensor
    let report: TaskReport
    let telemetry: TaskTelemetry
}

private struct DriveModel<Model: MotionTaskModel>: ViewModifier {
    @Binding var model: Model
    let context: TaskContext
    var onSample: (MotionSample) -> Void = { _ in }
    @State private var finished = false

    func body(content: Content) -> some View {
        content.onReceive(context.sensor.samples) { sample in
            guard !finished else { return }
            // Played on the AR prop: nothing counts while the camera is pointed away from it.
            guard context.telemetry.canAdvance else { return }
            model.step(sample)
            onSample(sample)
            context.report.progress(model.progress)
            if model.isComplete {
                finished = true
                context.report.complete()
            }
        }
    }
}

private extension View {
    func drive<Model: MotionTaskModel>(
        _ model: Binding<Model>,
        _ context: TaskContext,
        onSample: @escaping (MotionSample) -> Void = { _ in }
    ) -> some View {
        modifier(DriveModel(model: model, context: context, onSample: onSample))
    }
}

/// A round play area shared by the four tasks.
private struct Arena<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: 240, height: 240)
            .background(.black.opacity(0.4), in: Circle())
            .background(Theme.Palette.surface, in: Circle())
            .overlay {
                Circle().strokeBorder(highlighted ? Theme.Palette.success : Theme.Palette.surfaceStroke, lineWidth: highlighted ? 3 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

// MARK: Shake

struct ShakeTaskView: View {
    let context: TaskContext
    @State private var model = ShakeModel()
    @State private var wobble = false

    var body: some View {
        Arena {
            VStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.Palette.crew)
                    .symbolEffect(.wiggle, options: .repeating, isActive: wobble)
                Text("\(model.count) / \(ShakeModel.needed)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }
        }
        .drive($model, context) { _ in context.telemetry.joltCount = model.count }
        .onAppear { wobble = true }
        .sensoryFeedback(.impact(weight: .light), trigger: model.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shake the phone")
        .accessibilityValue("\(model.count) of \(ShakeModel.needed)")
    }
}

// MARK: Balance

struct BalanceTaskView: View {
    let context: TaskContext
    @State private var model = BalanceModel()

    private let arena: CGFloat = 240
    private let ball: CGFloat = 28

    var body: some View {
        Arena(highlighted: model.inZone) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.Palette.success.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    .frame(width: arena * BalanceModel.zoneRadius * 2, height: arena * BalanceModel.zoneRadius * 2)
                Circle()
                    .fill(model.inZone ? Theme.Palette.success : Theme.Palette.crew)
                    .frame(width: ball, height: ball)
                    .offset(x: model.x * (arena - ball) / 2, y: model.y * (arena - ball) / 2)
            }
        }
        .drive($model, context) { _ in
            context.telemetry.ballX = model.x
            context.telemetry.ballY = model.y
            context.telemetry.good = model.inZone
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tilt the phone to keep the ball in the ring")
        .accessibilityValue(model.inZone ? "In the ring" : "Outside the ring")
    }
}

// MARK: Dial

struct DialTaskView: View {
    let context: TaskContext
    @State private var model = DialModel()

    var body: some View {
        VStack(spacing: 14) {
            Arena(highlighted: model.dwellTime > 0) {
                ZStack {
                    ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                        marker(index: index, target: target)
                    }
                    if let angle = model.angle {
                        needle.rotationEffect(.degrees(-angle))
                    } else {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            Text(model.angle == nil ? "Raise the phone upright" : "Turn the phone like a dial")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .drive($model, context) { _ in
            context.telemetry.dialAngle = model.angle ?? 0
            context.telemetry.good = model.dwellTime > 0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Turn the phone to line up the needle with each marker")
        .accessibilityValue("\(model.index) of \(model.targets.count) markers")
    }

    /// The needle points to world up. Turning the phone clockwise by a moves it a degrees
    /// counter-clockwise on the screen, so a target rotation R sits at screen angle -R.
    private var needle: some View {
        Capsule()
            .fill(Theme.Palette.textPrimary)
            .frame(width: 6, height: 100)
            .offset(y: -50)
            .overlay(Circle().fill(Theme.Palette.textPrimary).frame(width: 14, height: 14))
    }

    private func marker(index: Int, target: Double) -> some View {
        let done = index < model.index
        let current = index == model.index
        return Circle()
            .fill(done ? Theme.Palette.success : (current ? Theme.Palette.warning : Theme.Palette.textSecondary.opacity(0.4)))
            .frame(width: current ? 22 : 14, height: current ? 22 : 14)
            .offset(y: -100)
            .rotationEffect(.degrees(-target))
    }
}

// MARK: Steady

struct SteadyTaskView: View {
    let context: TaskContext
    @State private var model = SteadyModel()
    @State private var wobble = CGSize.zero

    var body: some View {
        VStack(spacing: 14) {
            Arena(highlighted: model.upright && model.steady) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: model.progress)
                        .stroke(Theme.Palette.success, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(14)
                    Circle()
                        .fill(model.upright && model.steady ? Theme.Palette.success : Theme.Palette.crew)
                        .frame(width: 28, height: 28)
                        .offset(wobble)
                }
            }
            Text(status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .drive($model, context) { sample in
            context.telemetry.good = model.upright && model.steady
            // The dot shows the shake: it jumps with rotation and acceleration, and rests when still.
            let amount = min(1, (sample.rotationRate / 2 + sample.userAcceleration) / 1.0)
            wobble = CGSize(width: .random(in: -1 ... 1) * amount * 80, height: .random(in: -1 ... 1) * amount * 80)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold the phone upright and steady")
        .accessibilityValue(status)
    }

    private var status: String {
        if !model.upright { return "Raise the phone upright" }
        return model.steady ? "Steady… keep it still" : "Too shaky, hold still"
    }
}

// MARK: Hammer

struct HammerTaskView: View {
    let context: TaskContext
    @State private var model = HammerModel()
    @State private var swing = false

    /// Nail height, from fully out (1) to flush (0), as the hits land.
    private var nailOut: CGFloat { CGFloat(1 - model.progress) }

    var body: some View {
        Arena {
            ZStack {
                // The wood the nail goes into.
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.brown.opacity(0.75))
                    .frame(width: 150, height: 56)
                    .offset(y: 70)
                // The nail: a shaft that sinks and a head that rides on top of it.
                VStack(spacing: 0) {
                    Capsule().fill(Theme.Palette.textPrimary).frame(width: 34, height: 8)
                    Capsule().fill(Theme.Palette.textSecondary).frame(width: 8, height: 14 + 70 * nailOut)
                }
                // Length is 22 (flush) to 92 (fully out); the tip stays at y = 56, inside the wood, so the head sinks.
                .offset(y: 45 - 35 * nailOut)
                .animation(.easeOut(duration: 0.12), value: model.hits)
                // The hammer comes down on every hit.
                Image(systemName: "hammer.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.Palette.crew)
                    .rotationEffect(.degrees(swing ? 20 : -50), anchor: .bottomTrailing)
                    .offset(x: 52, y: -62)
                    .animation(.easeOut(duration: 0.1), value: swing)
                Text("\(model.hits) / \(HammerModel.needed)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .offset(y: -100)
            }
        }
        .drive($model, context) { _ in
            context.telemetry.strikeCount = model.hits
        }
        .onChange(of: model.hits) { _, _ in
            swing = true
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                swing = false
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.hits)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Swing the phone down like a hammer")
        .accessibilityValue("\(model.hits) of \(HammerModel.needed) hits")
    }
}

// MARK: Pattern

struct PatternTaskView: View {
    let context: TaskContext
    @State private var model = PatternModel()

    var body: some View {
        VStack(spacing: 14) {
            Arena {
                HStack(spacing: 10) {
                    ForEach(Array(model.sequence.enumerated()), id: \.offset) { index, direction in
                        let done = index < model.index
                        let current = index == model.index
                        Image(systemName: done ? "checkmark" : direction.symbol)
                            .font(.system(size: current ? 34 : 26, weight: .bold))
                            .foregroundStyle(done ? Theme.Palette.success : (current ? Theme.Palette.warning : Theme.Palette.textSecondary.opacity(0.5)))
                            .frame(width: 40)
                    }
                }
            }
            Text(model.flat ? "Lower the edge the arrow points to, then level the phone" : "Hold the phone flat")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .drive($model, context) { sample in
            // The ball on the prop's tray rolls the way the phone is tilted.
            context.telemetry.ballX = max(-1, min(1, sample.gravityX * 2))
            context.telemetry.ballY = max(-1, min(1, -sample.gravityY * 2))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tilt the phone in the pattern shown")
        .accessibilityValue("\(model.index) of \(model.sequence.count)")
    }
}
