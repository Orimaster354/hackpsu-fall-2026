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
