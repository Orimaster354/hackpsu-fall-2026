import Foundation

let session = GameSession()
let tile = MapTile(x: 0, y: 0)
let station = MapStation(id: "task", name: "Hold", tile: tile, task: .hold, kind: .task)
var sent: [ClientIntent] = []
session.send = { sent.append($0) }
session.receive(.joined(playerID: "crew", room: "TEST"))
session.receive(.role(.crew))
func update(alive: Bool = true, dark: Bool = false, phase: GamePhase = .playing, onTile: Bool = true) {
    session.receive(.state(GameSnapshot(phase: phase,
        players: [PlayerInfo(id: "crew", name: "Crew", tile: onTile ? tile : nil, alive: alive)],
        tasksDone: 0, tasksTotal: 3, lightsOut: dark, killCooldownEndsAt: nil, meeting: nil)))
}
func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
    print("PASS: \(message)")
}
update()
check(session.canAttemptTasks && session.canDoTask(at: station), "living crew can attempt tasks with power")
update(onTile: false)
check(session.canAttemptTasks && !session.canDoTask(at: station), "leaving tile permits motion but blocks completion")
update(dark: true)
check(!session.canAttemptTasks, "sabotage interrupts active tasks")
session.completeTask(at: station)
check(sent.isEmpty && session.completedStationIDs.isEmpty, "blackout prevents taskDone and local completion")
update()
check(session.canAttemptTasks, "power restoration permits a fresh attempt")
session.receive(.killed)
check(!session.canAttemptTasks, "private killed event immediately interrupts tasks")
session.completeTask(at: station)
check(sent.isEmpty, "death prevents taskDone")
update(phase: .meeting)
check(!session.canAttemptTasks, "meeting interrupts tasks")
update(phase: .ended)
check(!session.canAttemptTasks, "end of game interrupts tasks")
update()
session.receive(.role(.impostor))
check(!session.canAttemptTasks, "impostors cannot attempt crew tasks")
check(!TaskKind.availableTasks.contains(.tilt), "Tilt is absent from available tasks")

session.receive(.role(.crew))
session.completeTask(at: station)
session.completeTask(at: station)
check(sent == [.taskDone(stationID: station.id)], "restored living crew completes once, without duplicate intents")

// The newer sabotages leave tasks on but block meetings, and a meltdown has a countdown.
func sabotaged(_ state: SabotageState?) {
    session.receive(.state(GameSnapshot(phase: .playing,
        players: [PlayerInfo(id: "crew", name: "Crew", tile: tile, alive: true)],
        tasksDone: 0, tasksTotal: 3, lightsOut: state?.kind == .lights, killCooldownEndsAt: nil, meeting: nil, sabotage: state)))
}
sabotaged(SabotageState(kind: .jammer, fixStationId: "fix", endsAt: nil, holders: 0))
check(session.isJammed && session.meetingsBlocked && session.canAttemptTasks, "the jammer blocks meetings but not tasks")
sabotaged(SabotageState(kind: .meltdown, fixStationId: "fix", endsAt: 1_700_000_060_000, holders: 1))
check(session.meltdown != nil && session.meetingsBlocked && session.canAttemptTasks, "a meltdown blocks meetings, runs a countdown, and leaves tasks on")
sabotaged(SabotageState(kind: .lights, fixStationId: "fix", endsAt: nil, holders: 0))
check(session.lightsOut && !session.canAttemptTasks && !session.meetingsBlocked, "lights out blocks tasks only")
sabotaged(nil)
check(session.activeSabotage == nil && !session.meetingsBlocked && session.canAttemptTasks, "repairing clears the sabotage")

// Rooms: one name per scanned room, only when there are at least two.
let roomGrid = Grid(cols: 3, rows: 3, tileSize: 1, originX: 0, originZ: 0, playable: [Tile(x: 1, y: 1), Tile(x: 2, y: 1)], edge: [Tile(x: 1, y: 1)])
let roomA = ZoneInfo(id: "z1", name: "Kitchen", offset: Tile(x: 0, y: 0), grid: roomGrid, hasMap: true, doors: [])
let roomB = ZoneInfo(id: "z2", name: "Hall", offset: Tile(x: 4, y: 0), grid: roomGrid, hasMap: true, doors: [])
session.receive(.zones([roomA]))
check(session.roomLabels.isEmpty, "one room has no labels")
session.receive(.zones([roomA, roomB]))
check(session.roomLabels.map(\.name) == ["Kitchen", "Hall"] && session.roomLabels[1].tile == MapTile(x: 5, y: 1),
      "each room is named on its first tile, moved by its offset")

// Powers: the Scout can ping only as a living crew member in play.
session.receive(.power(.scout, partners: []))
check(session.power == .scout && session.canScout, "a living scout can ping")
session.receive(.power(.medic, partners: []))
check(session.power == .medic && !session.canScout, "a medic cannot ping")
