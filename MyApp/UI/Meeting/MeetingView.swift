import SwiftUI

/// A meeting: who called it, a countdown, and one vote per living player. A vote is final, so
/// choosing a player and sending it are two steps. Ghosts watch but cannot vote (docs).
struct MeetingView: View {
    @Environment(GameSession.self) private var session
    @State private var choice: Vote?
    @State private var totalSeconds: Double = 30

    var body: some View {
        if let meeting = session.meeting {
            content(meeting)
        } else {
            ProgressView().tint(.white)
        }
    }

    private func content(_ meeting: MeetingInfo) -> some View {
        ScrollScreen(spacing: 20, top: 24) {
            header(meeting).staggeredEntrance(0)
            candidates(meeting).staggeredEntrance(1)
            status(meeting).staggeredEntrance(2)
        } bar: {
            if session.isAlive && session.myVote == nil { voteBar }
        }
        .onAppear { totalSeconds = max(1, meeting.endsAt.timeIntervalSinceNow) }
    }

    // MARK: Header

    private func header(_ meeting: MeetingInfo) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: meeting.reason == .report ? "exclamationmark.bubble.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.Palette.danger)
                Text(meeting.reason == .report ? "Body reported" : "Emergency meeting")
                    .font(.system(.title, design: .rounded, weight: .heavy))
                Text(subtitle(meeting))
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            Countdown(endsAt: meeting.endsAt, total: totalSeconds)
        }
    }

    private func subtitle(_ meeting: MeetingInfo) -> String {
        if meeting.reason == .report, let body = session.player(meeting.bodyOf) {
            return "\(body.name) was found. Who did it?"
        }
        return "Talk it over, then vote."
    }

    // MARK: Voting

    private func candidates(_ meeting: MeetingInfo) -> some View {
        VStack(spacing: 8) {
            if !session.isAlive {
                Label("You are a ghost. You can watch, but you can't vote.", systemImage: "eye.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
            ForEach(session.voteCandidates) { player in
                CandidateRow(
                    player: player,
                    colorIndex: session.colorIndex(of: player.id),
                    hasVoted: meeting.votes[player.id] != nil,
                    isChosen: (session.myVote ?? choice) == .player(player.id),
                    isEnabled: session.isAlive && session.myVote == nil
                ) { choice = .player(player.id) }
            }
        }
        .padding(12)
        .gameCard()
    }

    private func status(_ meeting: MeetingInfo) -> some View {
        let alive = session.players.filter(\.alive).count
        let text: String
        switch session.myVote {
        case .player(let id)?: text = "You voted for \(session.player(id)?.name ?? "a player")."
        case .skip?: text = "You skipped the vote."
        case nil: text = session.isAlive ? "Pick a player, or skip." : "Waiting for the vote."
        }
        return VStack(spacing: 4) {
            Text(text).fontWeight(.semibold)
            Text("\(meeting.votes.count) of \(alive) have voted")
                .foregroundStyle(Theme.Palette.textSecondary)
                .monospacedDigit()
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private var voteBar: some View {
        let skip = Button("Skip vote") { session.castVote(.skip) }
            .buttonStyle(.game(.secondary))
            .accessibilityIdentifier("skipVoteButton")
        let send = Button { if let choice { session.castVote(choice) } } label: {
            Text(chosenName.map { "Vote \($0)" } ?? "Vote")
        }
        .buttonStyle(.game(.primary, tint: Theme.Palette.emergency))
        .disabled(choice == nil)
        .accessibilityIdentifier("sendVoteButton")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { skip; send }
            VStack(spacing: 12) { send; skip }
        }
    }

    private var chosenName: String? {
        if case let .player(id)? = choice { return session.player(id)?.name }
        return nil
    }
}

/// Time left, as digits and a bar. Redrawn four times a second, which reads as a clock.
private struct Countdown: View {
    let endsAt: Date
    let total: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let remaining = max(0, endsAt.timeIntervalSince(timeline.date))
            VStack(spacing: 8) {
                Text(String(format: "%d:%02d", Int(remaining.rounded(.up)) / 60, Int(remaining.rounded(.up)) % 60))
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Palette.surface)
                        Capsule()
                            .fill(remaining < 8 ? Theme.Palette.danger : Theme.Palette.crew)
                            .frame(width: proxy.size.width * min(1, remaining / total))
                    }
                }
                .frame(height: 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time left")
            .accessibilityValue("\(Int(remaining.rounded(.up))) seconds")
        }
    }
}

private struct CandidateRow: View {
    let player: PlayerInfo
    let colorIndex: Int
    let hasVoted: Bool
    let isChosen: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PlayerAvatar(name: player.name, colorIndex: colorIndex)
                SplitLine {
                    Text(player.name)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                } extras: {
                    if hasVoted { Tag(text: "Voted") }
                }
                ZStack {
                    if isChosen {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Palette.emergency)
                            .transition(IconSwap())
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(Theme.Palette.textSecondary.opacity(0.6))
                            .transition(IconSwap())
                    }
                }
                .font(.title3)
                .animation(.iconSwap, value: isChosen)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                isChosen ? Theme.Palette.emergency.opacity(0.22) : Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.gameRow)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.name + (hasVoted ? ", has voted" : ""))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Meeting") {
    RootView(session: .mock(.meeting))
}
