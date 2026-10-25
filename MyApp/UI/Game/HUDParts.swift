import SwiftUI

/// Tasks done out of tasks total, for living crew only (docs: `tasksTotal`).
struct TaskProgressBar: View {
    let done: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tasks")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text("\(done) of \(total)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.surface)
                    Capsule().fill(Theme.Palette.success).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: done)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tasks")
        .accessibilityValue("\(done) of \(total) done")
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
