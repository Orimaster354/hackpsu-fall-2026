import SwiftUI

/// The ejection reveal after a meeting (docs: `result`). It builds up one line at a time, since
/// that is the one dramatic moment of a meeting, then moves on by itself.
struct ResultView: View {
    @Environment(GameSession.self) private var session
    @State private var step = 0

    private var result: MeetingResult? { session.pendingResult }
    private var ejected: PlayerInfo? { session.player(result?.ejected) }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("The votes are in")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)

            ZStack {
                if step >= 1 { headline.transition(Motion.swap) }
            }
            .frame(minHeight: 150)

            ZStack {
                if step >= 2 { roleLine.transition(Motion.swap) }
            }
            .frame(minHeight: 60)

            Spacer()

            Button("Continue") { session.acknowledgeResult() }
                .buttonStyle(.game(.secondary))
                .opacity(step >= 3 ? 1 : 0)
                .disabled(step < 3)
                .accessibilityHidden(step < 3)
                .accessibilityIdentifier("resultContinueButton")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .gameColumn()
        .animation(.easeOut(duration: 0.3), value: step)
        .sensoryFeedback(.impact(weight: .medium), trigger: step)
        .task {
            // Each reveal is a pause, a line, a pause. The screen leaves by itself once it has been read.
            for next in 1...3 {
                guard (try? await Task.sleep(for: .milliseconds(next == 3 ? 800 : 1200))) != nil else { return }
                step = next
            }
            guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            session.acknowledgeResult()
        }
    }

    private var headline: some View {
        VStack(spacing: 14) {
            if let ejected {
                PlayerAvatar(name: ejected.name, colorIndex: session.colorIndex(of: ejected.id))
                    .scaleEffect(2.2)
                    .frame(height: 96)
                Text("\(ejected.name) was ejected.")
                    .font(.system(.title, design: .rounded, weight: .heavy))
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("No one was ejected.")
                    .font(.system(.title, design: .rounded, weight: .heavy))
                Text("It was a tie, or the group chose to skip.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var roleLine: some View {
        if let ejected, let role = result?.role {
            Label("\(ejected.name) \(role == .impostor ? "was the Impostor." : "was not the Impostor.")", systemImage: role.symbol)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(role.tint)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview("Ejected") {
    RootView(session: .mock(.ejected))
}
