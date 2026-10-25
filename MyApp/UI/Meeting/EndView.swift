import SwiftUI

/// The end of the game (docs: `phase: ended`, `result.winner`). The protocol does not name the
/// impostor unless they were voted out, so this only names them when it knows.
struct EndView: View {
    @Environment(GameSession.self) private var session

    private var crewWon: Bool { session.winner == .crew }
    private var tint: Color { crewWon ? Theme.Palette.crew : Theme.Palette.impostor }

    var body: some View {
        ScrollScreen(spacing: 24, top: 40) {
            banner.staggeredEntrance(0)
            summary.staggeredEntrance(1)
            players.staggeredEntrance(2)
        } bar: {
            Button("Back to start") { session.leave() }
                .buttonStyle(.game(.primary))
                .accessibilityIdentifier("backToStartButton")
        }
        .background {
            RadialGradient(colors: [tint.opacity(0.3), .clear], center: .top, startRadius: 20, endRadius: 420)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .sensoryFeedback(session.didWin == true ? .success : .warning, trigger: session.winner)
    }

    private var banner: some View {
        VStack(spacing: 12) {
            Image(systemName: crewWon ? "wrench.and.screwdriver.fill" : "theatermasks.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(tint)
                .popOnAppear(delay: 0.25)
                .background { CompletionBurst(tint: tint, size: 300, showsCheck: false) }
            Text(crewWon ? "CREW WINS" : "IMPOSTOR WINS")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .tracking(2)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let didWin = session.didWin {
                Text(didWin ? "You won" : "You lost")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var summary: some View {
        VStack(spacing: 6) {
            Text(reason).fontWeight(.semibold)
            if let name = knownImpostor {
                Label("\(name) was the Impostor", systemImage: "theatermasks.fill")
                    .foregroundStyle(Theme.Palette.impostor)
            }
            Text("Tasks finished: \(session.tasksDone) of \(session.tasksTotal)")
                .foregroundStyle(Theme.Palette.textSecondary)
                .monospacedDigit()
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private var players: some View {
        VStack(spacing: 8) {
            ForEach(session.players) { player in
                HStack(spacing: 12) {
                    PlayerAvatar(name: player.name, colorIndex: session.colorIndex(of: player.id))
                    SplitLine {
                        Text(player.name)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                    } extras: {
                        Text(player.alive ? "Alive" : "Eliminated")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .gameCard()
    }

    private var reason: String {
        if crewWon { return session.lastResult?.role == .impostor ? "The impostor was voted out." : "Every task is done." }
        return "The crew was outnumbered."
    }

    private var knownImpostor: String? {
        guard session.lastResult?.role == .impostor else { return nil }
        return session.player(session.lastResult?.ejected)?.name
    }
}

#Preview("Crew wins") {
    RootView(session: .mock(.endCrew))
}

#Preview("Impostor wins") {
    RootView(session: .mock(.endImpostor))
}
