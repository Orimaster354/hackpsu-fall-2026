import SwiftUI

/// Stands in for the Core Motion task screens (Phase 2, `MyApp/Tasks/`) so a round can finish
/// before they exist. The real task views replace this one view in `GameView`: they show a
/// station's `task` kind and call back with success or failure.
struct TaskPlaceholderView: View {
    let station: MapStation
    let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            StationIcon(kind: .task, size: 64)
            VStack(spacing: 6) {
                Text(station.name)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("The \(station.task.rawValue) task is not built yet. Hold the button to finish this one.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HoldToConfirmButton(title: "Hold to finish", duration: 2) {
                onFinish()
                dismiss()
            }
            Button("Not now") { dismiss() }
                .buttonStyle(.game(.text))
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground { GameBackdrop() }
        .preferredColorScheme(.dark)
    }
}
