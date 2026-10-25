import SwiftUI

/// The room as a grid of 1 m tiles. It does three jobs from one view: the manual tile picker
/// (`onTap` set), a read-only "you are here" while AR tracks the phone (`onTap` nil), and the host's
/// setup editor (`editableTiles` outlined). Station icons are the 2D equivalents of the AR icons.
/// Tile taps change state at once: this is a high-frequency input, so nothing animates.
struct RoomMapView: View {
    let grid: MapGrid
    var stations: [MapStation] = []
    /// The tile the server accepted for me.
    var myTile: MapTile?
    /// The tile this phone is reporting, shown while it differs from `myTile`.
    var pendingTile: MapTile?
    var myColorIndex = 0
    var myInitial = "Y"
    /// Stations I have already done, drawn dimmed.
    var completed: Set<String> = []
    /// The fix station only shows while the lights are out (docs), except in the setup editor.
    var showFix = false
    /// Ghosts and dead players see no icons (docs).
    var showStationIcons = true
    var editableTiles: Set<MapTile> = []
    var selectedStationID: String?
    /// Testing overlay: where everyone is. Real play never shows this.
    var others: [PlayerInfo] = []
    var onTap: ((MapTile) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width / CGFloat(grid.cols), proxy.size.height / CGFloat(grid.rows))
            ZStack(alignment: .topLeading) {
                ForEach(grid.playable.sorted(), id: \.self) { tile in
                    cell(tile, size: size)
                        .frame(width: size, height: size)
                        .offset(x: CGFloat(tile.x) * size, y: CGFloat(tile.y) * size)
                }
            }
            .frame(width: size * CGFloat(grid.cols), height: size * CGFloat(grid.rows), alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(CGFloat(grid.cols) / CGFloat(grid.rows), contentMode: .fit)
    }

    @ViewBuilder
    private func cell(_ tile: MapTile, size: CGFloat) -> some View {
        if let onTap {
            Button { onTap(tile) } label: { content(tile, size: size) }
                .buttonStyle(.plain)
        } else {
            content(tile, size: size)
        }
    }

    private func content(_ tile: MapTile, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        let station = stations.first { $0.tile == tile && isShown($0) }
        let color = PlayerPalette.color(at: myColorIndex)
        return ZStack {
            // Floor tiles read as a faint blue grid, the walls' edge tiles as a brighter cyan one.
            shape.fill(grid.edge.contains(tile) ? Theme.Palette.neon.opacity(0.14) : Theme.Palette.glow.opacity(0.07))
            shape.strokeBorder(Theme.Palette.neon.opacity(grid.edge.contains(tile) ? 0.2 : 0.1), lineWidth: 0.5)
            if editableTiles.contains(tile) {
                shape.strokeBorder(Theme.Palette.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            if let station, station.id == selectedStationID {
                shape.strokeBorder(Theme.Palette.textPrimary, lineWidth: 2.5)
            }
            if let station {
                StationIcon(kind: station.kind, done: completed.contains(station.id), size: size * 0.56)
            }
            if tile == myTile {
                shape.strokeBorder(color, lineWidth: 3)
                Text(myInitial)
                    .font(.system(size: size * 0.2, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(color, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.06)
            } else if tile == pendingTile {
                shape.strokeBorder(color.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
            }
            otherDots(on: tile, size: size)
        }
        .padding(1.5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: tile, station: station))
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
        .accessibilityAddTraits(tile == myTile ? .isSelected : [])
    }

    @ViewBuilder
    private func otherDots(on tile: MapTile, size: CGFloat) -> some View {
        let here = others.filter { $0.tile == tile }
        if !here.isEmpty {
            HStack(spacing: size * 0.04) {
                ForEach(here) { player in
                    Group {
                        if player.alive {
                            Circle().fill(PlayerPalette.color(at: others.firstIndex(of: player) ?? 0))
                        } else {
                            Image(systemName: "xmark").font(.system(size: size * 0.14, weight: .black)).foregroundStyle(Theme.Palette.danger)
                        }
                    }
                    .frame(width: size * 0.16, height: size * 0.16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(size * 0.1)
        }
    }

    private func isShown(_ station: MapStation) -> Bool {
        guard showStationIcons else { return false }
        return station.kind != .fix || showFix
    }

    private func label(for tile: MapTile, station: MapStation?) -> String {
        var parts = ["Column \(tile.x + 1), row \(tile.y + 1)"]
        if grid.edge.contains(tile) { parts.append("edge") }
        if let station { parts.append("\(station.name), \(station.spokenKind)") }
        if tile == myTile { parts.append("you are here") }
        return parts.joined(separator: ", ")
    }
}

/// What the map's marks mean, for the 2D map where there is no AR overlay to explain them.
struct MapLegend: View {
    var showsFix = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { items }
            VStack(alignment: .leading, spacing: 8) { items }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.Palette.textSecondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var items: some View {
        item(.task, "Task")
        item(.emergency, "Meeting spot")
        if showsFix { item(.fix, "Fix") }
    }

    private func item(_ kind: StationKind, _ title: String) -> some View {
        HStack(spacing: 6) {
            StationIcon(kind: kind, size: 18)
            Text(title)
        }
    }
}
