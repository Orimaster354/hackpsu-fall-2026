import SwiftUI

/// The main HUD while the game is on: task progress, the room map, and the actions that make
/// sense on the tile the player is standing on. It offers actions, the server decides them.
/// A dead player gets the ghost screen instead.
struct GameView: View {
    @Environment(GameSession.self) private var session
    @Environment(PositionCoordinator.self) private var position
    @AppStorage(SettingsKey.showEveryone) private var showEveryone = false
    @State private var taskStation: MapStation?
    /// The station whose task was just closed. It does not reopen until the player leaves its tile.
    @State private var snoozedStationID: String?
    @State private var showPosition: Bool

    /// `showPositionSheet` is for previews and screenshots.
    init(showPositionSheet: Bool = false) {
        _showPosition = State(initialValue: showPositionSheet)
    }

    private var inDark: Bool { session.lightsOut && session.role == .crew && session.isAlive }

    var body: some View {
        ScrollScreen(top: 8) {
            VStack(spacing: 16) {
                header.staggeredEntrance(0)
                if session.isAlive {
                    if inDark { LightsOutBanner() }
                    mapSection.staggeredEntrance(1)
                } else {
                    GhostView().staggeredEntrance(1)
                }
            }
            .brightness(inDark ? -0.2 : 0)
        } bar: {
            if session.isAlive { actions }
        }
        .fullScreenCover(item: $taskStation) { station in
            MotionTaskSheet(station: station) { session.completeTask(at: station) }
        }
        .onChange(of: session.taskStationHere?.id) { _, _ in openTaskOnArrival() }
        .onChange(of: session.canDoTaskHere) { _, _ in openTaskOnArrival() }
        .onChange(of: taskStation) { old, new in
            if new == nil, let old { snoozedStationID = old.id }
        }
        .sheet(isPresented: $showPosition) { PositionSheet() }
        .sensoryFeedback(.warning, trigger: session.isAlive) { old, new in old && !new }
        .task(id: session.error) {
            guard session.error != nil, (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            session.dismissError()
        }
    }

    /// With AR tracking, stepping onto an unfinished task tile opens its task (and the camera),
    /// once per visit. In manual mode the player taps "Do task" instead, so a map tap never
    /// launches a task by accident.
    private func openTaskOnArrival() {
        let here = session.taskStationHere
        if here?.id != snoozedStationID { snoozedStationID = nil }
        guard position.mode == .ar, taskStation == nil, !showPosition,
              let station = here, station.id != snoozedStationID,
              session.canDoTask(at: station) else { return }
        taskStation = station
    }

    // MARK: Header and map

    private var header: some View {
        VStack(spacing: 12) {
            TaskProgressBar(done: session.tasksDone, total: session.tasksTotal)
            ViewThatFits(in: .horizontal) {
                HStack {
                    RolePeekChip(role: session.role)
                    Spacer()
                    if session.isAlive { PositionChip { showPosition = true } }
                }
                VStack(alignment: .leading, spacing: 8) {
                    RolePeekChip(role: session.role)
                    if session.isAlive { PositionChip { showPosition = true } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The tile this phone is reporting, shown on the map until the server accepts it.
    private var pendingTile: MapTile? {
        position.tile == session.myTile ? nil : position.tile
    }

    private var myInitial: String {
        String(session.me?.name.first ?? "Y").uppercased()
    }

    /// The testing overlay: everyone else's tile. Only in manual mode, and only when asked for.
    private var othersOnMap: [PlayerInfo] {
        guard showEveryone, position.mode == .manual else { return [] }
        return session.players.filter { $0.id != session.myID }
    }

    /// The map is the input in manual mode and a read-only display under AR.
    private var tapHandler: ((MapTile) -> Void)? {
        position.mode == .manual ? { position.pick($0) } : nil
    }

    @ViewBuilder private var mapSection: some View {
        if let grid = session.grid {
            VStack(spacing: 10) {
                positionPrompt
                RoomMapView(
                    grid: grid,
                    stations: session.stations,
                    myTile: session.myTile,
                    pendingTile: pendingTile,
                    myColorIndex: session.myColorIndex,
                    myInitial: myInitial,
                    completed: session.completedStationIDs,
                    showFix: session.lightsOut,
                    showStationIcons: session.isAlive,
                    others: othersOnMap,
                    onTap: tapHandler
                )
                MapLegend(showsFix: session.lightsOut)
            }
        } else {
            Text("Waiting for the room map…")
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    @ViewBuilder private var positionPrompt: some View {
        if position.mode == .manual {
            let placed = session.myTile != nil || position.tile != nil
            PromptLine(
                icon: "hand.tap.fill",
                text: placed ? "Tap the tile you are standing on" : "Tap your tile on the map to start",
                emphasized: !placed
            )
        } else {
            switch position.status {
            case .searching: PromptLine(icon: "viewfinder", text: "Finding your place in the room…", emphasized: true)
            case .tracking: PromptLine(icon: "checkmark.circle.fill", text: "AR is tracking you", emphasized: false)
            case let .failed(reason): PromptLine(icon: "exclamationmark.triangle.fill", text: reason, emphasized: true)
            case .idle: EmptyView()
            }
        }
        if position.offerManual {
            HStack(spacing: 12) {
                Text("Can't find your place in the room.")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button { position.useManual() } label: {
                    Text("Use manual tiles").padding(.horizontal, 16)
                }
                .buttonStyle(.game(.secondary))
                .fixedSize()
            }
            .padding(12)
            .gameCard(radius: Theme.Radius.control)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if let error = session.error { ErrorMessage(text: error.message) }

            if session.role == .impostor {
                KillPad(targets: session.killTargetsHere, cooldownEndsAt: session.killCooldownEndsAt, onKill: session.kill)
            }

            if session.canReportHere {
                Button {
                    if let body = session.bodiesHere.first { session.report(body) }
                } label: {
                    Label("Report body", systemImage: "exclamationmark.bubble.fill")
                }
                .buttonStyle(.game(.primary, tint: Theme.Palette.emergency))
                .accessibilityIdentifier("reportButton")
            }

            if session.canCallEmergency {
                Button { session.callEmergency() } label: {
                    Label("Call emergency meeting", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.game(.primary, tint: Theme.Palette.emergency))
                .accessibilityIdentifier("emergencyButton")
            }

            if session.role == .crew { crewControls }

            if session.role == .impostor {
                Button { session.sabotage() } label: {
                    Label("Sabotage: lights out", systemImage: "lightbulb.slash.fill")
                }
                .buttonStyle(.game(.secondary))
                .disabled(session.lightsOut)
                .accessibilityIdentifier("sabotageButton")
            }
        }
    }

    @ViewBuilder private var crewControls: some View {
        if session.canFixHere, let fix = session.fixStation {
            HoldToConfirmButton(title: "Hold to fix the lights", duration: 3) { session.fix(fix) }
                .accessibilityIdentifier("fixButton")
        } else if let station = session.taskStationHere {
            if session.completedStationIDs.contains(station.id) {
                Label("\(station.name): done", systemImage: "checkmark.circle.fill")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.Palette.success)
                    .frame(minHeight: 56)
            } else {
                Button { taskStation = station } label: {
                    Label("Do task: \(station.name)", systemImage: "hand.tap.fill")
                }
                .buttonStyle(.game(.primary))
                .disabled(!session.canDoTaskHere)
                .accessibilityIdentifier("taskButton")
            }
        } else if !session.canReportHere && !session.canCallEmergency && !session.lightsOut {
            Text("Walk to a ? tile on the map to do a task.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

private struct PromptLine: View {
    let icon: String
    let text: String
    let emphasized: Bool

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(.subheadline, design: .rounded, weight: emphasized ? .bold : .medium))
            .foregroundStyle(emphasized ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LightsOutBanner: View {
    var body: some View {
        Label("Lights out. Tasks are off until the fix station is held.", systemImage: "lightbulb.slash.fill")
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.Palette.warning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gameCard(radius: Theme.Radius.control)
            .brightness(0.2)
    }
}

#Preview("HUD, on a task station") {
    RootView(session: .mock(.hud))
}

#Preview("HUD, impostor with a target") {
    RootView(session: .mock(.hudImpostor))
}

#Preview("Ghost") {
    RootView(session: .mock(.ghost))
}
