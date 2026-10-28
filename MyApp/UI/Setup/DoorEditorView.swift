import SwiftUI

extension DoorLink {
    /// The doors the server reports, one per pair. The server lists a door under both of its rooms.
    static func links(from zones: [ZoneInfo]) -> [DoorLink] {
        var seen = Set<String>()
        var result: [DoorLink] = []
        for zone in zones {
            for door in zone.doors {
                let a = DoorEnd(zone: zone.id, tile: door.tile)
                let b = DoorEnd(zone: door.toZone, tile: door.toTile)
                let key = [a, b].map { "\($0.zone):\($0.tile.x),\($0.tile.y)" }.sorted().joined(separator: "|")
                if seen.insert(key).inserted { result.append(DoorLink(a: a, b: b)) }
            }
        }
        return result
    }
}

extension GameSession {
    /// True when every scanned room can be reached from the first through doors. A one-room game always is.
    var roomsAreConnected: Bool {
        guard let first = zones.first else { return true }
        var reached: Set<String> = [first.id]
        var frontier = [first.id]
        while let id = frontier.popLast() {
            for door in zones.first(where: { $0.id == id })?.doors ?? [] where reached.insert(door.toZone).inserted {
                frontier.append(door.toZone)
            }
        }
        return reached.count == zones.count
    }
}

/// The host marks where two scanned rooms meet: one edge tile in each room. Players walk through it, and their
/// phones switch to the other room's AR map there. Tap an edge tile in one room, then one in another.
struct DoorEditorView: View {
    @Environment(GameSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var first: DoorEnd?

    private var links: [DoorLink] { DoorLink.links(from: session.zones) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(prompt)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    ForEach(session.zones) { zone in roomMap(zone) }
                    doorList
                }
                .padding(16)
            }
            .background { GameBackdrop().ignoresSafeArea() }
            .navigationTitle("Doors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var prompt: String {
        guard let first, let zone = session.zones.first(where: { $0.id == first.zone }) else {
            return "Tap an edge tile where a door leaves a room, then the matching edge tile in the room it leads to."
        }
        return "Now tap the other end of the door, in a room other than \(zone.name)."
    }

    private func roomMap(_ zone: ZoneInfo) -> some View {
        let grid = MapGrid(zone.grid)
        let doorTiles = Set(links.flatMap { [$0.a, $0.b] }.filter { $0.zone == zone.id }.map { MapTile($0.tile) })
        return VStack(alignment: .leading, spacing: 8) {
            Text(zone.name).font(.system(.headline, design: .rounded, weight: .bold))
            RoomMapView(
                grid: grid,
                pendingTile: first?.zone == zone.id ? first.map { MapTile($0.tile) } : nil,
                editableTiles: grid.edge.subtracting(doorTiles),
                onTap: { tapped(zone, $0, grid: grid) }
            )
        }
        .padding(12)
        .gameCard()
    }

    private var doorList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Doors").font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Text("\(links.count)").monospacedDigit().foregroundStyle(Theme.Palette.textSecondary)
            }
            if links.isEmpty {
                Text("No doors yet. Without one, players cannot be told apart between rooms.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(links, id: \.a) { link in
                HStack {
                    Text("\(name(link.a.zone)) ↔ \(name(link.b.zone))")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Spacer()
                    Button(role: .destructive) {
                        session.setDoors(links.filter { $0 != link })
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove the door between \(name(link.a.zone)) and \(name(link.b.zone))")
                }
            }
            if !session.roomsAreConnected {
                Label("Some rooms cannot be reached from the first one yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.warning)
            }
        }
        .padding(12)
        .gameCard()
    }

    private func name(_ zone: String) -> String {
        session.zones.first { $0.id == zone }?.name ?? zone
    }

    private func tapped(_ zone: ZoneInfo, _ tile: MapTile, grid: MapGrid) {
        guard grid.edge.contains(tile) else { return }
        let end = DoorEnd(zone: zone.id, tile: Tile(x: tile.x, y: tile.y))
        guard let start = first, start.zone != end.zone else {
            // The first end, or a new first end in the same room.
            first = end
            return
        }
        session.setDoors(links + [DoorLink(a: start, b: end)])
        first = nil
    }
}
