const test = require('node:test');
const assert = require('node:assert/strict');
const { RoomManager } = require('../rooms');
const { validateRoomSetup } = require('../contracts');
const {
  KILL_COOLDOWN_MS, SABOTAGE_COOLDOWN_MS, MELTDOWN_MS, FIX_PAIR_WINDOW_MS, SCOUT_COOLDOWN_MS, MIN_PLAYERS, MAX_PLAYERS,
  impostorCount,
} = require('../game');
const manualSetup = require('../fixtures/manual-setup.json');

/**
 * A room of `players` fake sockets on the 5 x 5 fixture. With `randomIndex` returning 0 the host is the (first)
 * impostor, and the next crew members become the Medic and then the Scout, so every test knows who is who.
 * `picks` queues the answers for later random choices (such as which fix station a sabotage targets).
 */
function build({ players = 5, start = true, fixes = 1, emergencies = 1 } = {}) {
  let now = 1000000;
  const timers = [];
  const picks = [];
  const fixture = structuredClone(manualSetup);
  fixture.stations = [
    { id: 'task-a', name: 'Dial', tile: { x: 0, y: 0 }, task: 'dial', kind: 'task' },
    { id: 'task-b', name: 'Hold', tile: { x: 4, y: 0 }, task: 'hold', kind: 'task' },
    ...(fixes >= 1 ? [{ id: 'fix', name: 'Lights', tile: { x: 0, y: 2 }, task: 'hold', kind: 'fix' }] : []),
    ...(fixes >= 2 ? [{ id: 'fix2', name: 'Panel', tile: { x: 4, y: 2 }, task: 'hold', kind: 'fix' }] : []),
    { id: 'emergency', name: 'Emergency', tile: { x: 2, y: 2 }, task: 'hold', kind: 'emergency' },
    ...(emergencies >= 2 ? [{ id: 'emergency2', name: 'Emergency 2', tile: { x: 2, y: 4 }, task: 'hold', kind: 'emergency' }] : []),
  ];
  const manager = new RoomManager({
    manualSetup: fixture, now: () => now,
    randomIndex: () => (picks.length ? picks.shift() : 0),
    setTimer: (callback, delay) => { const timer = { callback, delay, cleared: false }; timers.push(timer); return timer; },
    clearTimer: (timer) => { if (timer) timer.cleared = true; },
  });
  const socket = () => ({ readyState: 1, events: [], send(raw) { this.events.push(JSON.parse(raw)); } });
  const { room, player: host } = manager.create('Host', socket());
  for (let index = 1; index < players; index += 1) manager.join(room.code, `Crew ${index}`, socket());
  const list = [...room.players.values()];
  room.game.confirmSetup(host);
  if (start) room.game.start(host);
  return {
    room, game: room.game, host, players: list, picks, timers,
    advance: (ms) => { now += ms; },
    move(player, x, y) {
      room.game.tile(player, { tile: { x, y }, source: 'manual' });
      room.game.tile(player, { tile: { x, y }, source: 'manual' });
    },
    events: (player, type) => player.socket.events.filter((event) => event.t === type),
    /** Impostor kills `victim` on tile (x, y) once the cooldown allows. */
    kill(killer, victim, x, y) {
      this.move(killer, x, y);
      this.move(victim, x, y);
      this.advance(KILL_COOLDOWN_MS);
      room.game.kill(killer, { targetId: victim.id });
    },
  };
}

const rejects = (action, code) => assert.throws(action, (error) => error.code === code);

// ---- Players and roles -------------------------------------------------------------------------------------------

test('a game needs 4 to 10 connected players', () => {
  assert.equal(MIN_PLAYERS, 4);
  assert.equal(MAX_PLAYERS, 10);
  rejects(() => build({ players: 3 }), 'NEED_FOUR_PLAYERS');
  for (const players of [4, 7, 10]) assert.equal(build({ players }).room.phase, 'playing');
  const full = build({ players: 10, start: false });
  assert.equal(full.room.players.size, 10);
});

test('one impostor up to six players, two from seven', () => {
  assert.deepEqual([4, 5, 6, 7, 8, 9, 10].map(impostorCount), [1, 1, 1, 2, 2, 2, 2]);
  for (const players of [4, 5, 6, 7, 8, 9, 10]) {
    const s = build({ players });
    assert.equal(s.players.filter((player) => player.role === 'impostor').length, impostorCount(players), `${players} players`);
  }
});

test('every game has exactly one Medic and one Scout, both crew; impostors have no power', () => {
  for (const players of [4, 6, 10]) {
    const s = build({ players });
    const withPower = s.players.filter((player) => player.power);
    assert.deepEqual(withPower.map((player) => player.power).sort(), ['medic', 'scout']);
    assert.ok(withPower.every((player) => player.role === 'crew'));
    assert.ok(s.players.filter((player) => player.role === 'impostor').every((player) => player.power === null));
  }
});

test('the private role message carries the power, and impostors learn their partners', () => {
  const s = build({ players: 8 });
  const impostors = s.players.filter((player) => player.role === 'impostor');
  assert.equal(impostors.length, 2);
  for (const impostor of impostors) {
    const message = s.events(impostor, 'role').at(-1);
    assert.equal(message.role, 'impostor');
    assert.equal(message.power, null);
    assert.deepEqual(message.partners, impostors.filter((other) => other !== impostor).map((other) => other.id));
  }
  const medic = s.players.find((player) => player.power === 'medic');
  assert.deepEqual(s.events(medic, 'role').at(-1), { t: 'role', role: 'crew', power: 'medic', partners: [] });
  // Public state never reveals roles or powers.
  const state = s.events(medic, 'state').at(-1);
  assert.ok(state.players.every((member) => !('role' in member) && !('power' in member)));
  // A reconnecting player gets the same private message.
  assert.deepEqual(s.game.roleMessage(medic), s.events(medic, 'role').at(-1));
});

// ---- Medic -------------------------------------------------------------------------------------------------------

test('the Medic revives a fresh body once, and only on its tile', () => {
  const s = build({ players: 5 });
  const [host, medic, scout, victim, other] = s.players;
  assert.equal(medic.power, 'medic');
  s.kill(host, victim, 1, 1);
  assert.equal(victim.alive, false);
  rejects(() => s.game.ability(medic, { targetId: victim.id }), 'INVALID_BODY'); // not on the tile yet
  s.move(medic, 1, 1);
  s.game.ability(medic, { targetId: victim.id });
  assert.equal(victim.alive, true);
  assert.equal(victim.reportable, false);
  assert.equal(s.events(victim, 'revived').length, 1);
  assert.equal(s.events(medic, 'state').at(-1).players.find((member) => member.id === victim.id).alive, true);
  // Once per game.
  s.kill(host, other, 1, 1);
  rejects(() => s.game.ability(medic, { targetId: other.id }), 'ABILITY_USED');
  // Others cannot use it.
  rejects(() => s.game.ability(victim, { targetId: other.id }), 'NO_ABILITY');
  rejects(() => s.game.ability(host, { targetId: other.id }), 'CREW_ONLY');
  assert.equal(scout.power, 'scout');
});

test('a body that was reported cannot be revived', () => {
  const s = build({ players: 5 });
  const [host, medic, , victim] = s.players;
  s.kill(host, victim, 1, 1);
  s.move(medic, 1, 1);
  s.game.report(medic, { bodyId: victim.id });
  s.game.finishMeeting();
  assert.equal(s.room.phase, 'playing');
  rejects(() => s.game.ability(medic, { targetId: victim.id }), 'INVALID_BODY');
});

test('reviving brings the crew back into the task count', () => {
  const s = build({ players: 5 });
  const [host, medic, , victim] = s.players;
  const before = s.game.counts().tasksTotal;
  s.kill(host, victim, 1, 1);
  assert.equal(s.game.counts().tasksTotal, before - 2);
  s.move(medic, 1, 1);
  s.game.ability(medic, { targetId: victim.id });
  assert.equal(s.game.counts().tasksTotal, before);
});

// ---- Scout -------------------------------------------------------------------------------------------------------

test('the Scout sees where others stand (counts, no names), twice, with a cooldown', () => {
  const s = build({ players: 5 });
  const [host, medic, scout, a, b] = s.players;
  assert.equal(scout.power, 'scout');
  s.move(a, 1, 1);
  s.move(b, 1, 1);
  s.move(medic, 3, 3);
  s.move(scout, 0, 4);
  s.move(host, 2, 0);
  s.game.ability(scout, {});
  const ping = s.events(scout, 'scout').at(-1);
  const byTile = Object.fromEntries(ping.tiles.map((tile) => [`${tile.x},${tile.y}`, tile.count]));
  assert.deepEqual(byTile, { '1,1': 2, '3,3': 1, '2,0': 1 });
  assert.ok(ping.tiles.every((tile) => Object.keys(tile).sort().join() === 'count,x,y'), 'only tiles and counts');
  assert.equal(ping.usesLeft, 1);
  rejects(() => s.game.ability(scout, {}), 'ABILITY_COOLDOWN');
  s.advance(SCOUT_COOLDOWN_MS);
  s.game.ability(scout, {});
  assert.equal(s.events(scout, 'scout').at(-1).usesLeft, 0);
  s.advance(SCOUT_COOLDOWN_MS);
  rejects(() => s.game.ability(scout, {}), 'ABILITY_USED');
});

test('a dead player does not show up on the scout ping', () => {
  const s = build({ players: 5 });
  const [host, , scout, victim] = s.players;
  s.kill(host, victim, 1, 1);
  s.move(scout, 4, 4);
  s.game.ability(scout, {});
  const tiles = s.events(scout, 'scout').at(-1).tiles;
  // The killer stands on (1,1) next to the body. Only the living killer is counted there, not the victim.
  assert.deepEqual(tiles, [{ x: 1, y: 1, count: 1 }]);
});

// ---- Sabotages ---------------------------------------------------------------------------------------------------

test('there are exactly three sabotages and an unknown one is refused', () => {
  const s = build();
  rejects(() => s.game.sabotage(s.host, { kind: 'flood' }), 'INVALID_SABOTAGE');
  for (const kind of ['lights', 'jammer', 'meltdown']) {
    const t = build();
    t.game.sabotage(t.host, { kind });
    assert.equal(t.events(t.players[1], 'state').at(-1).sabotage.kind, kind);
  }
});

test('lights out still works as before and reports through the old flag too', () => {
  const s = build();
  s.game.sabotage(s.host, {});
  const state = s.events(s.players[1], 'state').at(-1);
  assert.equal(state.lightsOut, true);
  assert.equal(state.sabotage.kind, 'lights');
  assert.equal(state.sabotage.fixStationId, 'fix');
  s.move(s.players[1], 0, 0);
  rejects(() => s.game.taskDone(s.players[1], { stationId: 'task-a' }), 'LIGHTS_OUT');
  s.move(s.players[1], 0, 2);
  s.game.fix(s.players[1], { stationId: 'fix' });
  assert.equal(s.events(s.players[1], 'state').at(-1).sabotage, null);
  assert.equal(s.events(s.players[1], 'state').at(-1).lightsOut, false);
});

test('only one sabotage at a time, and they share one cooldown', () => {
  const s = build();
  s.game.sabotage(s.host, { kind: 'jammer' });
  rejects(() => s.game.sabotage(s.host, { kind: 'meltdown' }), 'SABOTAGE_ACTIVE');
  s.move(s.players[1], 0, 2);
  s.game.fix(s.players[1], { stationId: 'fix' });
  rejects(() => s.game.sabotage(s.host, { kind: 'meltdown' }), 'SABOTAGE_COOLDOWN');
  s.advance(SABOTAGE_COOLDOWN_MS);
  s.game.sabotage(s.host, { kind: 'meltdown' });
  assert.equal(s.game.activeSabotage.kind, 'meltdown');
});

test('the comms jammer stops reports and emergency meetings but not tasks, until one crew repairs it', () => {
  const s = build({ players: 6 });
  const [host, c1, , c3, c4] = s.players;
  s.kill(host, c3, 1, 1);
  s.move(c1, 1, 1);
  s.game.sabotage(host, { kind: 'jammer' });
  rejects(() => s.game.report(c1, { bodyId: c3.id }), 'SABOTAGE_BLOCKS_MEETING');
  s.move(c4, 2, 2);
  rejects(() => s.game.emergency(c4), 'SABOTAGE_BLOCKS_MEETING');
  s.move(c4, 0, 0);
  s.game.taskDone(c4, { stationId: 'task-a' }); // tasks are still allowed
  s.move(c4, 0, 2);
  s.game.fix(c4, { stationId: 'fix' });
  assert.equal(s.game.activeSabotage, null);
  s.game.report(c1, { bodyId: c3.id });
  assert.equal(s.room.phase, 'meeting');
});

test('a meltdown needs two crew repairing together, or the impostors win when the timer ends', () => {
  const s = build({ players: 6 });
  const [host, c1, c2, c3] = s.players;
  s.game.sabotage(host, { kind: 'meltdown' });
  const timer = s.timers.find((item) => item.delay === MELTDOWN_MS);
  assert.ok(timer, 'a meltdown timer was started');
  assert.equal(s.game.state().sabotage.endsAt, 1000000 + MELTDOWN_MS);
  rejects(() => s.game.emergency(c1), 'SABOTAGE_BLOCKS_MEETING');

  // One crew member alone does not stop it.
  s.move(c1, 0, 2);
  s.game.fix(c1, { stationId: 'fix' });
  assert.equal(s.game.activeSabotage.kind, 'meltdown');
  assert.equal(s.game.state().sabotage.holders, 1);

  // A second crew member who is not on the station does not count.
  s.move(c2, 0, 0);
  rejects(() => s.game.fix(c2, { stationId: 'fix' }), 'INVALID_FIX');

  // A second crew member on the station within the window does.
  s.move(c2, 0, 2);
  s.advance(FIX_PAIR_WINDOW_MS - 1000);
  s.game.fix(c2, { stationId: 'fix' });
  assert.equal(s.game.activeSabotage, null);
  assert.equal(timer.cleared, true, 'the countdown stops');
  assert.equal(c3.alive, true);
});

test('two repairs too far apart in time do not stop a meltdown, and the timer then ends the game', () => {
  const s = build({ players: 6 });
  const [host, c1, c2] = s.players;
  s.game.sabotage(host, { kind: 'meltdown' });
  const timer = s.timers.find((item) => item.delay === MELTDOWN_MS);
  s.move(c1, 0, 2);
  s.move(c2, 0, 2);
  s.game.fix(c1, { stationId: 'fix' });
  s.advance(FIX_PAIR_WINDOW_MS + 500);
  s.game.fix(c2, { stationId: 'fix' });
  assert.equal(s.game.activeSabotage.kind, 'meltdown', 'the first hold had expired');
  timer.callback();
  assert.equal(s.game.winner, 'impostor');
  assert.equal(s.room.phase, 'ended');
  assert.deepEqual(s.events(c1, 'result').at(-1), { t: 'result', ejected: null, role: null, winner: 'impostor' });
});

test('a meltdown timer that fires after it was repaired does nothing', () => {
  const s = build({ players: 6 });
  const [host, c1, c2] = s.players;
  s.game.sabotage(host, { kind: 'meltdown' });
  const timer = s.timers.find((item) => item.delay === MELTDOWN_MS);
  s.move(c1, 0, 2);
  s.move(c2, 0, 2);
  s.game.fix(c1, { stationId: 'fix' });
  s.game.fix(c2, { stationId: 'fix' });
  timer.callback();
  assert.equal(s.game.winner, null);
  assert.equal(s.room.phase, 'playing');
});

test('a dead crew member cannot help repair a meltdown', () => {
  const s = build({ players: 6 });
  const [host, c1, c2, c3] = s.players;
  s.game.sabotage(host, { kind: 'meltdown' });
  s.move(c3, 0, 2);
  s.game.fix(c3, { stationId: 'fix' });
  s.kill(host, c3, 0, 2);
  s.move(c1, 0, 2);
  s.game.fix(c1, { stationId: 'fix' });
  assert.equal(s.game.activeSabotage.kind, 'meltdown', "the dead player's hold no longer counts");
  assert.equal(c2.alive, true);
});

test('the server picks which fix station a sabotage targets, and only that one repairs it', () => {
  const s = build({ players: 5, fixes: 2 });
  s.picks.push(1);
  s.game.sabotage(s.host, { kind: 'jammer' });
  assert.equal(s.game.state().sabotage.fixStationId, 'fix2');
  s.move(s.players[1], 0, 2);
  rejects(() => s.game.fix(s.players[1], { stationId: 'fix' }), 'INVALID_FIX');
  s.move(s.players[1], 4, 2);
  s.game.fix(s.players[1], { stationId: 'fix2' });
  assert.equal(s.game.activeSabotage, null);
});

test('jammer and meltdown need a fix station; lights keep working without one', () => {
  const s = build({ players: 5, fixes: 0 });
  rejects(() => s.game.sabotage(s.host, { kind: 'jammer' }), 'NO_FIX_STATION');
  rejects(() => s.game.sabotage(s.host, { kind: 'meltdown' }), 'NO_FIX_STATION');
  s.game.sabotage(s.host, { kind: 'lights' });
  assert.equal(s.game.lightsOut, true);
});

// ---- Emergency stations and limits ---------------------------------------------------------------------------------

test('an emergency meeting can be called from any room\'s emergency station', () => {
  const s = build({ players: 5, emergencies: 2 });
  s.move(s.players[1], 2, 4);
  s.game.emergency(s.players[1]);
  assert.equal(s.room.phase, 'meeting');
  const t = build({ players: 5, emergencies: 2 });
  t.move(t.players[1], 3, 3);
  rejects(() => t.game.emergency(t.players[1]), 'EMERGENCY_TILE');
});

test('a game has at most five task stations', () => {
  const grid = structuredClone(manualSetup.grid);
  const taskAt = (i, x, y) => ({ id: `t${i}`, name: `Task ${i}`, tile: { x, y }, task: ['dial', 'hold', 'shake', 'gesture', 'hammer', 'orbs'][i], kind: 'task' });
  const emergency = { id: 'emergency', name: 'E', tile: { x: 2, y: 2 }, task: 'hold', kind: 'emergency' };
  const spots = [[0, 0], [2, 0], [4, 0], [4, 2], [4, 4], [2, 4]];
  const five = spots.slice(0, 5).map(([x, y], i) => taskAt(i, x, y));
  assert.equal(validateRoomSetup(grid, [emergency, ...five]).stations.length, 6);
  assert.throws(() => validateRoomSetup(grid, [emergency, ...spots.map(([x, y], i) => taskAt(i, x, y))]), (error) => error.code === 'TOO_MANY_TASKS');
});

test('the two new AR tasks are valid station task types', () => {
  const grid = structuredClone(manualSetup.grid);
  const stations = [
    { id: 'emergency', name: 'E', tile: { x: 2, y: 2 }, task: 'hold', kind: 'emergency' },
    { id: 'a', name: 'Orbs', tile: { x: 0, y: 0 }, task: 'orbs', kind: 'task' },
    { id: 'b', name: 'Signal', tile: { x: 4, y: 0 }, task: 'signal', kind: 'task' },
  ];
  assert.deepEqual(validateRoomSetup(grid, stations).stations.map((station) => station.task), ['hold', 'orbs', 'signal']);
});
