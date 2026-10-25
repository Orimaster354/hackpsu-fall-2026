import SwiftUI

/// Shown to a player who was eliminated (docs, Phase 1). Their phone is the body, so the one
/// instruction that matters is to leave it where it is. They may wander, but do no tasks or votes.
struct GhostView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill.xmark")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
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
