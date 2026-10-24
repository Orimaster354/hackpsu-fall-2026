const test = require('node:test');
const assert = require('node:assert/strict');
const { RoomManager } = require('../rooms');
const { KILL_COOLDOWN_MS, MEETING_MS, SABOTAGE_COOLDOWN_MS } = require('../game');

function setup({ start = true, stations = true } = {}) {
  let now = 1000000;
  let timer;
  const manager = new RoomManager({ now: () => now, randomIndex: () => 0,
    setTimer: (callback, delay) => { timer = { callback, delay }; return timer; }, clearTimer: () => { timer = null; } });
  const socket = () => ({ readyState: 1, events: [], send(raw) { this.events.push(JSON.parse(raw)); } });
  const { room, player: host } = manager.create('Host', socket());
  for (let index = 1; index < 4; index += 1) manager.join(room.code, `Crew ${index}`, socket());
  const players = [...room.players.values()];
  if (stations) room.game.setup(host, { grid: { cols: 5, rows: 5, tileSize: 1, blocked: [{ x: 4, y: 4 }] },
    stations: [
      { id: 'task', name: 'Dial', tile: { x: 1, y: 1 }, task: 'dial', kind: 'task' },
      { id: 'fix', name: 'Lights', tile: { x: 2, y: 2 }, task: 'hold', kind: 'fix' },
    ] });
  if (start) room.game.start(host);
  return { manager, room, game: room.game, host, players, advance: (ms) => { now += ms; },
    move(player, x, y, source = 'manual') {
      room.game.tile(player, { tile: { x, y }, source });
      room.game.tile(player, { tile: { x, y }, source });
    }, timer: () => timer };
}

function rejects(action, code) {
  assert.throws(action, (error) => error.code === code);
}

test('host start needs four connected players and sends exactly one private role per player', () => {
  const s = setup({ start: false });
  rejects(() => s.game.start(s.players[1]), 'HOST_ONLY');
  s.players[3].socket.readyState = 3;
  rejects(() => s.game.start(s.host), 'NEED_FOUR_PLAYERS');
  s.players[3].socket.readyState = 1;
  s.game.start(s.host);
  assert.equal(s.room.phase, 'playing');
  assert.equal(s.players.filter((player) => player.role === 'impostor').length, 1);
  for (const player of s.players) {
    const roles = player.socket.events.filter((event) => event.t === 'role');
    assert.deepEqual(roles, [{ t: 'role', role: player.role }]);
    const state = player.socket.events.find((event) => event.t === 'state');
    assert.equal(state.killCooldownEndsAt, 1000000 + KILL_COOLDOWN_MS);
    assert.ok(state.players.every((member) => !('role' in member) && !('socket' in member)));
  }
  rejects(() => s.game.start(s.host), 'INVALID_PHASE');
  rejects(() => s.manager.join(s.room.code, 'Late join', {}), 'GAME_STARTED');
});

test('tile smoothing requires consecutive reports, rejects invalid/blocked tiles and freezes meetings', () => {
  const s = setup();
  const player = s.players[1];
  s.game.tile(player, { tile: { x: 1, y: 1 }, source: 'ar' });
  assert.equal(player.tile, null);
  s.game.tile(player, { tile: { x: 2, y: 1 }, source: 'ar' });
  assert.equal(player.tile, null);
  s.game.tile(player, { tile: { x: 2, y: 1 }, source: 'ar' });
  assert.deepEqual(player.tile, { x: 2, y: 1 });
  for (const tile of [{ x: -1, y: 0 }, { x: 5, y: 0 }, { x: 1.2, y: 0 }, { x: 4, y: 4 }, null]) {
    rejects(() => s.game.tile(player, { tile, source: 'manual' }), 'INVALID_TILE');
  }
  rejects(() => s.game.tile(player, { tile: { x: 0, y: 0 }, source: 'gps' }), 'INVALID_TILE');
  s.move(player, 0, 0);
  s.game.emergency(player);
  rejects(() => s.move(player, 1, 1), 'INVALID_PHASE');
  assert.deepEqual(player.tile, { x: 0, y: 0 });
});

test('kills validate roles, proximity and cooldown; ghosts stay at bodies and cannot act', () => {
  const s = setup();
  const [impostor, victim, reporter] = s.players;
  s.move(impostor, 1, 1); s.move(victim, 1, 1); s.move(reporter, 2, 2);
  rejects(() => s.game.kill(reporter, { targetId: victim.id }), 'IMPOSTOR_ONLY');
  rejects(() => s.game.kill(impostor, { targetId: victim.id }), 'KILL_COOLDOWN');
  s.advance(KILL_COOLDOWN_MS);
  rejects(() => s.game.kill(impostor, { targetId: reporter.id }), 'INVALID_TARGET');
  s.game.kill(impostor, { targetId: victim.id });
  assert.equal(victim.alive, false);
  assert.deepEqual(victim.socket.events.filter((event) => event.t === 'killed'), [{ t: 'killed' }]);
  assert.equal(reporter.socket.events.filter((event) => event.t === 'killed').length, 0);
  rejects(() => s.move(victim, 0, 0), 'PLAYER_DEAD');
  rejects(() => s.game.taskDone(victim, { stationId: 'task' }), 'PLAYER_DEAD');
  rejects(() => s.game.kill(victim, { targetId: reporter.id }), 'PLAYER_DEAD');
  rejects(() => s.game.emergency(victim), 'PLAYER_DEAD');
  rejects(() => s.game.report(victim, { bodyId: victim.id }), 'PLAYER_DEAD');
  rejects(() => s.game.report(reporter, { bodyId: victim.id }), 'INVALID_BODY');
  s.move(reporter, 1, 1);
  rejects(() => s.game.kill(impostor, { targetId: reporter.id }), 'KILL_COOLDOWN');
  s.game.report(reporter, { bodyId: victim.id });
  assert.equal(s.room.phase, 'meeting');
  assert.equal(s.game.meeting.bodyOf, victim.id);
  assert.equal(s.timer().delay, MEETING_MS);
  rejects(() => s.game.vote(victim, { target: 'skip' }), 'PLAYER_DEAD');
  s.game.vote(impostor, { target: 'skip' });
  s.game.vote(reporter, { target: 'skip' });
  s.game.vote(s.players[3], { target: 'skip' });
  rejects(() => s.game.report(reporter, { bodyId: victim.id }), 'INVALID_BODY');
  assert.deepEqual(victim.tile, { x: 1, y: 1 });
});

test('meeting vote majority ejects the impostor, reveals only the ejected role and ends the game', () => {
  const s = setup();
  s.move(s.players[1], 0, 0);
  s.game.emergency(s.players[1]);
  s.game.vote(s.host, { target: 'skip' });
  rejects(() => s.game.vote(s.host, { target: s.players[1].id }), 'ALREADY_VOTED');
  rejects(() => s.game.vote(s.players[1], { target: 'missing' }), 'INVALID_VOTE');
  for (const player of s.players.slice(1)) s.game.vote(player, { target: s.host.id });
  assert.equal(s.room.phase, 'ended');
  assert.equal(s.game.winner, 'crew');
  assert.equal(s.timer(), null);
  const results = s.host.socket.events.filter((event) => event.t === 'result');
  assert.deepEqual(results, [{ t: 'result', ejected: s.host.id, role: 'impostor', winner: 'crew' }]);
  rejects(() => s.game.kill(s.host, { targetId: s.players[1].id }), 'INVALID_PHASE');
});

test('ties, skip majorities and timed-out minority votes do not eject anyone', () => {
  for (const votes of [[0, 0, 1, 1], ['skip', 'skip', 'skip', 0], [0]]) {
    const s = setup();
    s.move(s.host, 0, 0);
    s.game.emergency(s.host);
    votes.forEach((vote, index) => s.game.vote(s.players[index], { target: vote === 'skip' ? 'skip' : s.players[vote].id }));
    if (s.room.phase === 'meeting') { s.advance(MEETING_MS); s.timer().callback(); }
    assert.equal(s.room.phase, 'playing');
    assert.ok(s.players.every((player) => player.alive));
    assert.equal(s.host.socket.events.find((event) => event.t === 'result').ejected, null);
  }
});

test('emergencies need the origin tile, are once per player, and are capped at three', () => {
  const s = setup();
  rejects(() => s.game.emergency(s.host), 'EMERGENCY_TILE');
  for (const player of s.players.slice(0, 3)) {
    s.move(player, 0, 0);
    s.game.emergency(player);
    for (const voter of s.players) s.game.vote(voter, { target: 'skip' });
    rejects(() => s.game.emergency(player), 'EMERGENCY_USED');
  }
  s.move(s.players[3], 0, 0);
  rejects(() => s.game.emergency(s.players[3]), 'EMERGENCY_USED');
});

test('task progress belongs to living crew, prevents duplicates, and produces a crew victory', () => {
  const s = setup();
  rejects(() => s.game.taskDone(s.host, { stationId: 'task' }), 'CREW_ONLY');
  rejects(() => s.game.taskDone(s.players[1], { stationId: 'task' }), 'INVALID_STATION');
  for (const player of s.players.slice(1)) s.move(player, 1, 1);
  s.game.taskDone(s.players[1], { stationId: 'task' });
  assert.deepEqual(s.game.counts(), { tasksDone: 1, tasksTotal: 3 });
  rejects(() => s.game.taskDone(s.players[1], { stationId: 'task' }), 'TASK_ALREADY_DONE');
  s.game.taskDone(s.players[2], { stationId: 'task' });
  s.game.taskDone(s.players[3], { stationId: 'task' });
  assert.equal(s.room.phase, 'ended');
  assert.equal(s.game.winner, 'crew');
});

test('eliminated crew progress is removed and impostor wins at crew/impostor parity', () => {
  const s = setup();
  for (const player of s.players) s.move(player, 1, 1);
  s.game.taskDone(s.players[1], { stationId: 'task' });
  s.advance(KILL_COOLDOWN_MS);
  s.game.kill(s.host, { targetId: s.players[1].id });
  assert.deepEqual(s.game.counts(), { tasksDone: 0, tasksTotal: 2 });
  s.advance(KILL_COOLDOWN_MS);
  s.game.kill(s.host, { targetId: s.players[2].id });
  assert.equal(s.game.winner, 'impostor');
  assert.equal(s.room.phase, 'ended');
});

test('sabotage blocks tasks until crew fixes lights at a fix station and respects cooldown', () => {
  const s = setup();
  const crew = s.players[1];
  s.move(crew, 1, 1);
  rejects(() => s.game.sabotage(crew), 'IMPOSTOR_ONLY');
  s.game.sabotage(s.host);
  rejects(() => s.game.sabotage(s.host), 'LIGHTS_ALREADY_OUT');
  rejects(() => s.game.taskDone(crew, { stationId: 'task' }), 'LIGHTS_OUT');
  rejects(() => s.game.fix(s.host, { stationId: 'fix' }), 'CREW_ONLY');
  rejects(() => s.game.fix(crew, { stationId: 'fix' }), 'INVALID_FIX');
  s.move(crew, 2, 2);
  s.game.fix(crew, { stationId: 'fix' });
  assert.equal(s.game.lightsOut, false);
  rejects(() => s.game.sabotage(s.host), 'SABOTAGE_COOLDOWN');
  s.advance(SABOTAGE_COOLDOWN_MS);
  s.game.sabotage(s.host);
  assert.equal(s.game.lightsOut, true);
});

test('room setup is host-only, validates station/grid types, and zero-station games allow voting', () => {
  const s = setup({ start: false, stations: false });
  const message = { grid: { cols: 5, rows: 5, tileSize: 1, blocked: [] }, stations: [] };
  rejects(() => s.game.setup(s.players[1], message), 'HOST_ONLY');
  rejects(() => s.game.setup(s.host, { ...message, grid: { ...message.grid, tileSize: 2 } }), 'INVALID_GRID');
  rejects(() => s.game.setup(s.host, { ...message, stations: [{ id: 'x' }] }), 'INVALID_STATIONS');
  s.game.setup(s.host, message);
  s.game.start(s.host);
  s.move(s.host, 0, 0);
  s.game.emergency(s.host);
  for (const player of s.players) s.game.vote(player, { target: 'skip' });
  assert.equal(s.room.phase, 'playing');
  assert.equal(s.game.winner, null);
});
