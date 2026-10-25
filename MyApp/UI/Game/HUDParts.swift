import SwiftUI

/// Tasks done out of tasks total, for living crew only (docs: `tasksTotal`). When a task gets done,
/// by anyone, the count rolls up, a "+1" floats off it and a flash of light runs along the bar.
struct TaskProgressBar: View {
    let done: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the times the total went up, to play the flash.
    @State private var gains = 0

    private var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    private struct Gain {
        var sweep = 0.0
        var chip = 0.0
        var rise = 0.0
    }

    var body: some View {
        let reduced = reduceMotion
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tasks")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text("\(done) of \(total)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(done)))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .overlay(alignment: .topTrailing) { chip(reduced: reduced) }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.4))
                        .overlay { Capsule().strokeBorder(Theme.Palette.neon.opacity(0.2), lineWidth: 1) }
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.Palette.neon, Theme.Palette.success], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * fraction)
                        .shadow(color: Theme.Palette.neon.opacity(fraction > 0 ? 0.5 : 0), radius: 6)
                        .keyframeAnimator(initialValue: Gain(), trigger: gains) { bar, gain in
                            bar.overlay { shimmer(gain.sweep, reduced: reduced) }
                        } keyframes: { _ in
                            KeyframeTrack(\.sweep) { CubicKeyframe(1, duration: 0.7) }
                            KeyframeTrack(\.chip) {
                                CubicKeyframe(1, duration: 0.12)
                                LinearKeyframe(1, duration: 0.4)
                                CubicKeyframe(0, duration: 0.4)
                            }
                            KeyframeTrack(\.rise) { CubicKeyframe(1, duration: 0.9) }
                        }
                }
            }
            .frame(height: 10)
        }
        .animation(reduced ? nil : .easeOut(duration: 0.3), value: done)
        .onChange(of: done) { old, new in
            if new > old { gains += 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tasks")
        .accessibilityValue("\(done) of \(total) done")
    }

    /// A band of light crossing the filled part of the bar.
    private func shimmer(_ sweep: Double, reduced: Bool) -> some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, Color.white.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(32, proxy.size.width * 0.4))
                .offset(x: -proxy.size.width * 0.4 + sweep * proxy.size.width * 1.4)
                .opacity(!reduced && sweep > 0 && sweep < 1 ? 1 : 0)
        }
        .clipShape(Capsule())
    }

    /// The "+1" that rises off the count. It is driven by its own animator so it can fade on its own.
    private func chip(reduced: Bool) -> some View {
        Text("+1")
            .font(.system(.footnote, design: .rounded, weight: .heavy))
            .foregroundStyle(Theme.Palette.success)
            .shadow(color: Theme.Palette.success.opacity(0.7), radius: 6)
            .keyframeAnimator(initialValue: Gain(), trigger: gains) { text, gain in
                text
                    .opacity(gain.chip)
                    .offset(y: reduced ? -14 : -14 - gain.rise * 10)
            } keyframes: { _ in
                KeyframeTrack(\.chip) {
                    CubicKeyframe(1, duration: 0.12)
                    LinearKeyframe(1, duration: 0.4)
                    CubicKeyframe(0, duration: 0.4)
                }
                KeyframeTrack(\.rise) { CubicKeyframe(1, duration: 0.9) }
            }
            .accessibilityHidden(true)
    }
}

/// The player's own role, hidden unless they hold it. Anyone glancing at the phone sees nothing.
struct RolePeekChip: View {
    let role: PlayerRole?
    @State private var peeking = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: peeking ? (role?.symbol ?? "eye") : "eye")
            Text(peeking ? (role?.title ?? "") : (typeSize.isAccessibilitySize ? "Role" : "Hold to see role"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.system(.footnote, design: .rounded, weight: .bold))
        .foregroundStyle(peeking ? (role?.tint ?? Theme.Palette.textPrimary) : Theme.Palette.textSecondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Theme.Palette.surface, in: Capsule())
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {}, onPressingChanged: { peeking = $0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peeking ? "Your role: \(role?.title ?? "unknown")" : "Your role is hidden")
        .accessibilityHint("Double tap to show or hide it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { peeking.toggle() }
    }
}

/// Which position source is active. Tapping it opens the sheet where manual mode is chosen.
struct PositionChip: View {
    @Environment(PositionCoordinator.self) private var position
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: position.mode == .ar ? "viewfinder" : "hand.tap.fill")
                Text(position.mode == .ar ? "AR" : "Manual")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            .font(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Theme.Palette.surface, in: Capsule())
        }
        .buttonStyle(.game(.text))
        .accessibilityLabel("Position source")
        .accessibilityValue(spoken)
    }

    private var dot: Color {
        switch position.status {
        case .tracking: Theme.Palette.success
        case .searching: Theme.Palette.warning
        case .failed: Theme.Palette.danger
        case .idle: Theme.Palette.textSecondary
        }
    }

    private var spoken: String {
        let mode = position.mode == .ar ? "AR tracking" : "Manual tiles"
        switch position.status {
        case .tracking: return "\(mode), working"
        case .searching: return "\(mode), looking for you"
        case let .failed(reason): return "\(mode), \(reason)"
        case .idle: return mode
        }
    }
}

/// Choose between AR and manual tiles, and turn on the testing overlay. Manual mode is both the
/// fallback when relocalization fails and the way to test without AR.
struct PositionSheet: View {
    @Environment(PositionCoordinator.self) private var position
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.showEveryone) private var showEveryone = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if position.canUseAR {
                        Picker("Position source", selection: Binding(
                            get: { position.mode },
                            set: { $0 == .ar ? position.useAR() : position.useManual() }
                        )) {
                            Text("AR tracking").tag(TileSource.ar)
                            Text("Manual tiles").tag(TileSource.manual)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Label("AR tracking is not connected yet. You place yourself on the map.", systemImage: "hand.tap.fill")
                    }
                } header: {
                    Text("Source")
                } footer: {
                    Text("Manual tiles is the fallback when AR cannot find you, and the way to test without AR. Both send the same tile message.")
                }

                if position.canUseAR {
                    Section {
                        Label(position.arDetail.message, systemImage: position.arDetail.icon)
                        Button("Retry AR") { position.retryAR() }
                    } header: {
                        Text("AR status")
                    } footer: {
                        Text("Retry AR downloads the host's room map again and looks for your place from scratch. It never starts a new room origin.")
                    }
                }

                Section {
                    Toggle("Show everyone on the map", isOn: $showEveryone)
                        .disabled(position.mode != .manual)
                } header: {
                    Text("Testing")
                } footer: {
                    Text("Real games never show other players. This only helps when you test alone on one phone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background { GameBackdrop().ignoresSafeArea() }
            .navigationTitle("Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
