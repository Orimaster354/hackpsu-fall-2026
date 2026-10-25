import Foundation

/// SplitMix64. Seed it for a repeatable game, leave the seed nil for a different one each time.
struct MockRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64? = nil) {
        state = seed ?? UInt64.random(in: .min ... .max)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the bot players do. A bot is a client: it only ever sends intents, and the game decides.
/// Chances are per second, scaled by the tick length, so behavior does not depend on the tick rate.
enum MockBots {
    static func intents(for id: String, in game: MockGame, now: Date, tick: TimeInterval, rng: inout MockRandom) -> [ClientIntent] {
        guard let seat = game.seat(id), seat.info.alive else { return [] }

        if game.phase == .meeting { return vote(seat, in: game, tick: tick, rng: &rng) }
        guard game.phase == .playing else { return [] }

        let here = seat.info.tile

        if seat.role == .crew, let here,
           let body = game.seats.first(where: { !$0.info.alive && $0.info.tile == here && !game.reportedBodies.contains($0.info.id) }),
           roll(0.8, tick, &rng) {
            return [.report(bodyID: body.info.id)]
        }

        if seat.role == .crew, let here {
            if game.lightsOut, let fix = game.stations.first(where: { $0.kind == .fix }), fix.tile == here, roll(0.8, tick, &rng) {
                return [.fix(stationID: fix.id)]
            }
            if !game.lightsOut,
               let station = game.stations.first(where: { $0.kind == .task && $0.tile == here && !seat.finishedTasks.contains($0.id) }),
               roll(0.5, tick, &rng) {
                return [.taskDone(stationID: station.id)]
            }
        }

        if seat.role == .impostor, let here {
            let ready = game.killCooldownEndsAt.map { $0 <= now } ?? true
            if ready, let victim = game.seats.first(where: { $0.role == .crew && $0.info.alive && $0.info.tile == here }), roll(0.8, tick, &rng) {
                return [.kill(targetID: victim.info.id)]
            }
            if !game.lightsOut, game.sabotageReadyAt.map({ $0 <= now }) ?? true, roll(0.01, tick, &rng) {
                return [.sabotage]
            }
        }

        if here == nil || roll(0.15, tick, &rng) {
            guard let destination = destination(for: seat, in: game, rng: &rng) else { return [] }
            // Two identical reports in a row, which is what the server's drift filter wants.
            return [.tile(destination, source: .manual), .tile(destination, source: .manual)]
        }
        return []
    }

    private static func vote(_ seat: MockGame.Seat, in game: MockGame, tick: TimeInterval, rng: inout MockRandom) -> [ClientIntent] {
        let id = seat.info.id
        guard game.meeting?.votes[id] == nil, roll(0.4, tick, &rng) else { return [] }
        var targets = game.seats.filter { $0.info.alive && $0.info.id != id }
        if seat.role == .impostor { targets = targets.filter { $0.role == .crew } }
        guard !targets.isEmpty, let pick = targets.randomElement(using: &rng) else { return [.vote(.skip)] }
        let skipChance = seat.role == .impostor ? 0.25 : 0.35
        return [.vote(roll(skipChance, 1, &rng) ? .skip : .player(pick.info.id))]
    }

    private static func destination(for seat: MockGame.Seat, in game: MockGame, rng: inout MockRandom) -> MapTile? {
        let tiles = game.grid.playable.sorted()
        if seat.role == .crew {
            if game.lightsOut, let fix = game.stations.first(where: { $0.kind == .fix }) { return fix.tile }
            // Someone walked in on a body. Crew head there, which is how meetings happen in the mock.
            if let body = game.seats.first(where: { !$0.info.alive && !game.reportedBodies.contains($0.info.id) }),
               let spot = body.info.tile, roll(0.7, 1, &rng) { return spot }
            let open = game.stations.filter { $0.kind == .task && !seat.finishedTasks.contains($0.id) }
            if !open.isEmpty, roll(0.6, 1, &rng), let pick = open.randomElement(using: &rng) { return pick.tile }
        } else if roll(0.7, 1, &rng) {
            // Hunt: head for where a living crewmate was last seen.
            let prey = game.seats.filter { $0.role == .crew && $0.info.alive }.compactMap(\.info.tile)
            if let pick = prey.randomElement(using: &rng) { return pick }
        }
        return tiles.randomElement(using: &rng)
    }

    private static func roll(_ perSecond: Double, _ tick: TimeInterval, _ rng: inout MockRandom) -> Bool {
        Double.random(in: 0..<1, using: &rng) < perSecond * tick
    }
}
