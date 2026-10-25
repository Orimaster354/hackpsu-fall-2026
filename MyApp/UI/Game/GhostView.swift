import SwiftUI

/// Shown to a player who was eliminated (docs, Phase 1). Their phone is the body, so the one
/// instruction that matters is to leave it where it is. They may wander, but do no tasks or votes.
struct GhostView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill.xmark")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .floating()
            Text("You were eliminated")
                .font(.system(.title2, design: .rounded, weight: .bold))
            VStack(spacing: 10) {
                Text("Leave your phone where it is. It is your body now.")
                    .fontWeight(.semibold)
                Text("You may walk around and watch, but you can't do tasks or vote. Keep this screen on.")
            }
            .font(.callout)
            .foregroundStyle(Theme.Palette.textSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .gameCard()
        .accessibilityElement(children: .combine)
    }
}

/// One red impact followed by a fade, kept above stage transitions (including a final kill).
struct DeathEffect: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var intensity = 0.0

    var body: some View {
        ZStack {
            Color.red.opacity(0.32)
            RadialGradient(colors: [.clear, .red.opacity(0.95)], center: .center,
                           startRadius: 40, endRadius: 430)
            Label("ELIMINATED", systemImage: "person.fill.xmark")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 8)
        }
        .ignoresSafeArea()
        .opacity(intensity)
        .task(id: trigger) {
            guard trigger > 0 else { return }
            withTransaction(Transaction(animation: nil)) { intensity = 1 }
            do {
                // Give an interrupted task sheet time to dismiss before fading the impact.
                try await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeOut(duration: reduceMotion ? 0.6 : 1.2)) { intensity = 0 }
            } catch { intensity = 0 }
        }
    }
}
