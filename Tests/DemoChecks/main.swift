import Foundation

final class TrackingProbe: PositionProvider {
    let source = TileSource.ar
    var tile: MapTile? = nil
    var status = PositionStatus.idle
    var starts = 0
    var retries = 0
    func start(on grid: MapGrid) { starts += 1; status = .tracking }
    func stop() { status = .idle }
    func restart() { retries += 1 }
}

@main
struct DemoChecks {
    @MainActor static func main() async {
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            print("PASS: \(message)")
        }
        let session = GameSession()
        var intents: [ClientIntent] = []
        session.send = { intents.append($0) }
        session.createRoom(name: "Host", demo: true)
        check(intents == [.createDemo(name: "Host")], "demo button emits the explicit demo intent")
        check(LiveConnection.message(for: intents[0]) == .createDemo(name: "Host"), "adapter preserves demo creation")
        session.receive(.joined(playerID: "host", room: "TEST"))
        var snapshot = LobbySnapshot(players: [], grid: nil, stations: [], hasMap: false, setupConfirmed: false)
        snapshot.demo = true
        for event in LiveConnection.events(for: .lobby(snapshot)) { session.receive(event) }
        check(session.isDemo, "lobby enables demo for both host and joiners")
        session.leave()
        check(!session.isDemo, "leaving clears demo state")
        session.createRoom(name: "Host")
        check(intents.last == .create(name: "Host"), "normal create remains unchanged")
        session.leave()

        let ar = TrackingProbe()
        let position = PositionCoordinator(ar: ar)
        position.reportInterval = .milliseconds(10)
        let tile = MapTile(x: 0, y: 0)
        let grid = MapGrid(cols: 1, rows: 1, playable: [tile], edge: [tile])
        var reports: [(MapTile, TileSource)] = []
        position.begin(grid: grid, manualOnly: true) { reports.append(($0, $1)) }
        check(position.mode == .manual && !position.canUseAR && ar.starts == 0,
              "demo starts manual immediately without starting AR or downloading a worldmap")
        position.useAR()
        position.retryAR()
        position.appBecameActive()
        check(position.mode == .manual && ar.starts == 0 && ar.retries == 0,
              "demo cannot accidentally enter AR")
        position.pick(tile)
        try? await Task.sleep(for: .milliseconds(50))
        check(reports.contains { $0.0 == tile && $0.1 == .manual }, "map taps report real manual tile intents")
        position.end()
        position.begin(grid: grid) { _, _ in }
        check(position.mode == .ar && position.canUseAR && ar.starts == 1,
              "normal game can use AR again after leaving demo")
        position.end()
    }
}
