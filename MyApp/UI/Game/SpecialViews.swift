import SwiftUI

// The three sabotages, the two crew powers, and the notices that go with them. Each view only offers an action
// or shows what the server said; the rules live on the server.

extension SabotageKind {
    var title: String {
        switch self {
        case .lights: "Lights out"
        case .jammer: "Comms jammer"
        case .meltdown: "Meltdown"
        }
    }

    var shortTitle: String {
        switch self {
        case .lights: "Lights"
        case .jammer: "Jammer"
        case .meltdown: "Meltdown"
        }
    }

    var symbol: String {
        switch self {
        case .lights: "lightbulb.slash.fill"
        case .jammer: "antenna.radiowaves.left.and.right.slash"
        case .meltdown: "flame.fill"
        }
    }

    var tint: Color {
        switch self {
        case .lights: Theme.Palette.warning
        case .jammer: Theme.Palette.neon
        case .meltdown: Theme.Palette.emergency
        }
    }

    /// The label on the hold-to-repair button.
    var fixTitle: String {
        switch self {
        case .lights: "Hold to fix the lights"
        case .jammer: "Hold to restore comms"
        case .meltdown: "Hold with a partner to stop the meltdown"
        }
    }

    /// What the impostors get out of it, shown on their button.
    var impostorHint: String {
        switch self {
        case .lights: "Crew cannot do tasks."
        case .jammer: "No reports or meetings, and the crew map goes dark."
        case .meltdown: "Crew have one minute and need two people at the fix station."
        }
    }
}

extension Power {
    var title: String {
        switch self {
        case .medic: "Medic"
        case .scout: "Scout"
        }
    }

    var symbol: String {
        switch self {
        case .medic: "cross.case.fill"
        case .scout: "dot.radiowaves.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .medic: Theme.Palette.success
        case .scout: Theme.Palette.neon
        }
    }

    var briefing: String {
        switch self {
        case .medic: "Once per game, stand on a freshly killed player's phone before anyone reports it and revive them."
        case .scout: "Twice per game, ping to see which tiles have people on them. You see counts, never names."
        }
    }
}

/// A sabotage is on. Lights have their own screen effects; this covers the jammer and the meltdown, with the
/// meltdown's countdown and how many crew are already holding the repair.
struct SabotageBanner: View {
    let sabotage: SabotageState
    let fixName: String?
    let isImpostor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(sabotage.kind.title.uppercased(), systemImage: sabotage.kind.symbol)
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .tracking(1)
                Spacer()
                if sabotage.kind == .meltdown, let endsAt = sabotage.endsAt { countdown(endsAt) }
            }
            .foregroundStyle(sabotage.kind.tint)
            Text(detail)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gameCard(radius: Theme.Radius.control)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(sabotage.kind.tint.opacity(0.6), lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var place: String { fixName.map { "the fix station (\($0))" } ?? "the fix station" }

    private var detail: String {
        if isImpostor {
            return "\(sabotage.kind.impostorHint) The crew must repair it at \(place)."
        }
        switch sabotage.kind {
        case .lights:
            return "Tasks are off. Repair it at \(place)."
        case .jammer:
            return "Reports and meetings are off and your map is scrambled. Repair it at \(place)."
        case .meltdown:
            return "Two crew must hold the repair together at \(place) before the timer ends. \(min(sabotage.holders, 2)) of 2 holding."
        }
    }

    private func countdown(_ endsAt: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = max(0, Date(timeIntervalSince1970: Double(endsAt) / 1000).timeIntervalSince(context.date))
            Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(left <= 15 ? Theme.Palette.danger : Theme.Palette.textPrimary)
        }
    }
}

/// The impostor's three sabotage buttons. Only one sabotage can run at a time, and they share a cooldown.
struct SabotageControls: View {
    let active: SabotageState?
    let onChoose: (SabotageKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SabotageKind.allCases, id: \.self) { kind in
                Button { onChoose(kind) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: kind.symbol)
                        Text(kind.shortTitle).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.game(.secondary))
                .disabled(active != nil)
                .accessibilityLabel("Sabotage: \(kind.title)")
                .accessibilityHint(kind.impostorHint)
                .accessibilityIdentifier("sabotage-\(kind.rawValue)")
            }
        }
    }
}

/// The crew power button: the Medic's revive (only on a fresh body) or the Scout's ping.
struct AbilityControls: View {
    @Environment(GameSession.self) private var session

    var body: some View {
        if session.canReviveHere, let body = session.bodiesHere.first {
            Button { session.useAbility() } label: {
                Label("Revive \(body.name)", systemImage: Power.medic.symbol)
            }
            .buttonStyle(.game(.primary, tint: Power.medic.tint))
            .accessibilityIdentifier("reviveButton")
        } else if session.canScout {
            Button { session.useAbility() } label: {
                Label("Scout ping (\(session.scoutPing?.usesLeft ?? 2) left)", systemImage: Power.scout.symbol)
            }
            .buttonStyle(.game(.secondary))
            .accessibilityIdentifier("scoutButton")
        }
    }
}

/// A short notice for the player the Medic brought back.
struct RevivedBanner: View {
    var body: some View {
        Label("The Medic brought you back. You are in the game again.", systemImage: Power.medic.symbol)
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(Power.medic.tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gameCard(radius: Theme.Radius.control)
    }
}
