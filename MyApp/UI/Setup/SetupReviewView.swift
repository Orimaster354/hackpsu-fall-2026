import SwiftUI

/// The host's review of the room the server built (docs, Phase 3): the 2D map with its stations,
/// where the host can move, delete or add stations by tapping edge tiles, then confirms. Stations
/// only go on edge tiles. The grid and the emergency tile come from the server and are not edited.
struct SetupReviewView: View {
    @Environment(GameSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var moving = false
    @State private var showDoors = false
    @Environment(\.startRoomScan) private var startScan

    private var selected: MapStation? { session.stations.first { $0.id == selectedID } }

    /// Empty edge tiles: the places a station can be added or moved to.
    private var openEdgeTiles: Set<MapTile> {
        (session.grid?.edge ?? []).subtracting(session.stations.map(\.tile))
    }

    var body: some View {
        NavigationStack {
            ScrollScreen(top: 8) {
                Text(moving ? "Tap an edge tile to move \(selected?.name ?? "the station") there." : "Tap an empty edge tile to add a station, or tap a station to change it.")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let grid = session.grid {
                    RoomMapView(
                        grid: grid,
                        stations: session.stations,
                        showFix: true,
                        editableTiles: openEdgeTiles,
                        selectedStationID: selectedID,
                        onTap: tapped
                    )
                    MapLegend(showsFix: true)
                }

                roomsCard
                if let station = selected { editor(station) }
                stationList
            } bar: {
                confirmBar
            }
            .background { GameBackdrop().ignoresSafeArea() }
            .navigationTitle("Room setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showDoors) { DoorEditorView() }
    }

    // MARK: Rooms

    /// The scanned rooms. A game can span up to six; they join through doors the host marks.
    private var roomsCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Rooms")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Text("\(session.zones.count) of \(GameSession.maxRooms)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, 4)
            ForEach(session.zones) { zone in
                HStack(spacing: 12) {
                    Image(systemName: zone.hasMap ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(zone.hasMap ? Theme.Palette.success : Theme.Palette.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zone.name).font(.system(.body, design: .rounded, weight: .semibold)).lineLimit(1)
                        Text("\(zone.grid.playable.count) tiles · \(zone.doors.count) door\(zone.doors.count == 1 ? "" : "s")\(zone.hasMap ? "" : " · no AR map yet")")
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    if session.zones.count > 1 {
                        Button(role: .destructive) { session.removeZone(zone.id) } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove \(zone.name)")
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            HStack(spacing: 12) {
                if let startScan, session.zones.count < GameSession.maxRooms {
                    Button("Scan another room") {
                        dismiss()
                        startScan.run()
                    }
                    .buttonStyle(.game(.secondary))
                    .accessibilityIdentifier("scanAnotherRoomButton")
                }
                if session.zones.count > 1 {
                    Button("Doors") { showDoors = true }
                        .buttonStyle(.game(.secondary))
                        .accessibilityIdentifier("doorsButton")
                }
            }
            if session.zones.count > 1, !session.roomsAreConnected {
                Label("Mark a door between the rooms so players can walk from one to the next.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.warning)
            }
        }
        .padding(12)
        .gameCard()
    }

    // MARK: Editing

    private func tapped(_ tile: MapTile) {
        if let station = session.stations.first(where: { $0.tile == tile }) {
            // The emergency tile is placed by the server at the center, not on an edge.
            guard station.kind != .emergency else { return }
            selectedID = selectedID == station.id ? nil : station.id
            moving = false
            return
        }
        guard session.grid?.edge.contains(tile) == true else { return }
        if moving, var station = selected {
            station.tile = tile
            session.editStation(station)
            moving = false
        } else {
            let station = newStation(at: tile)
            session.editStation(station)
            selectedID = station.id
        }
    }

    private func newStation(at tile: MapTile) -> MapStation {
        let count = session.taskStations.count
        // A new station gets a task no other station has, so a room never repeats a challenge.
        let used = Set(session.taskStations.map { $0.task })
        let task = TaskKind.availableTasks.first { !used.contains($0) } ?? TaskKind.availableTasks[count % TaskKind.availableTasks.count]
        return MapStation(
            id: "u-\(UUID().uuidString.prefix(6).lowercased())",
            name: "Station \(count + 1)",
            tile: tile,
            task: task,
            kind: .task
        )
    }

    private func editor(_ station: MapStation) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StationIcon(kind: station.kind, size: 32)
                Text(station.name)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if station.kind == .task {
                    Picker("Task", selection: Binding(
                        get: { station.task == .tilt ? .hold : station.task },
                        set: { var edited = station; edited.task = $0; session.editStation(edited) }
                    )) {
                        ForEach(TaskKind.availableTasks, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            HStack(spacing: 12) {
                Button(moving ? "Cancel move" : "Move") { moving.toggle() }
                    .buttonStyle(.game(.secondary))
                Button {
                    session.deleteStation(id: station.id)
                    selectedID = nil
                    moving = false
                } label: {
                    Text("Delete").foregroundStyle(Theme.Palette.danger)
                }
                .buttonStyle(.game(.secondary))
            }
        }
        .padding(12)
        .gameCard()
    }

    private var stationList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Stations")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Text("\(session.stations.count)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            ForEach(session.stations) { station in
                Button { tapped(station.tile) } label: {
                    HStack(spacing: 12) {
                        StationIcon(kind: station.kind, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name).font(.system(.body, design: .rounded, weight: .semibold)).lineLimit(1)
                            Text(station.kind == .task ? "\(station.task.rawValue.capitalized) task" : station.spokenKind.capitalized)
                                .font(.footnote)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(station.tile.x + 1), \(station.tile.y + 1)")
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(
                        station.id == selectedID ? Theme.Palette.accent.opacity(0.28) : Theme.Palette.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    )
                }
                .buttonStyle(.gameRow)
                .accessibilityLabel("\(station.name), \(station.spokenKind), column \(station.tile.x + 1), row \(station.tile.y + 1)")
                .accessibilityAddTraits(station.id == selectedID ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(12)
        .gameCard()
    }

    private var confirmBar: some View {
        VStack(spacing: 6) {
            Button {
                session.confirmSetup()
                dismiss()
            } label: {
                Text(session.setupStatus == .confirmed ? "Setup confirmed" : "Confirm setup")
            }
            .buttonStyle(.game(.primary))
            .disabled(session.setupStatus != .needsReview || session.taskStations.isEmpty || !session.roomsAreConnected)
            .accessibilityIdentifier("confirmSetupButton")
            if session.taskStations.isEmpty {
                Text("Add at least one task station.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

#Preview("Setup review") {
    RootView(session: .mock(.needsSetup), preview: ScreenPreview(setupReview: true))
}
