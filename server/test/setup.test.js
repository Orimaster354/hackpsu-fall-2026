const test = require('node:test');
const assert = require('node:assert/strict');
const { RoomManager } = require('../rooms');
const { validateRoomSetup, walkable } = require('../contracts');
const { createAppServer } = require('../index');
const { connectClient } = require('../tools/client');
const manualSetup = require('../fixtures/manual-setup.json');

function roomWithPlayers(options = {}) {
  const manager = new RoomManager(options);
  const socket = () => ({ readyState: 1, send() {} });
  const { room, player: host } = manager.create('Host', socket());
  const guests = [];
  for (let index = 0; index < 3; index += 1) guests.push(manager.join(room.code, `Guest ${index}`, socket()).player);
  return { room, host, guests };
}

test('normal rooms have no fabricated setup and cannot start before server setup and confirmation', () => {
  const { room, host } = roomWithPlayers();
  assert.equal(room.grid, null); assert.equal(room.setupConfirmed, false);
  assert.throws(() => room.game.start(host), { code: 'SETUP_NOT_CONFIRMED' });
  assert.throws(() => room.game.confirmSetup(host), { code: 'SETUP_MISSING' });
  assert.throws(() => room.game.handle(host, { ...manualSetup, t: 'setRoom' }), { code: 'UNKNOWN_EVENT' });
  room.game.applySetup(manualSetup);
  assert.equal(room.grid.originX, -2.5); assert.equal(room.grid.originZ, 1.5);
  assert.throws(() => room.game.start(host), { code: 'SETUP_NOT_CONFIRMED' });
  room.game.confirmSetup(host); room.game.start(host);
  assert.equal(room.phase, 'playing');
});

test('station editing is atomic, host-only, edge-only, spaced and locked after confirmation', () => {
  const { room, host, guests } = roomWithPlayers({ manualSetup });
  const original = structuredClone(room.stations);
  assert.throws(() => room.game.confirmSetup(guests[0]), { code: 'HOST_ONLY' });
  assert.throws(() => room.game.editStation(guests[0], { station: original[0] }), { code: 'HOST_ONLY' });
  assert.throws(() => room.game.editStation(host, { station: { ...original[0], tile: { x: 1, y: 1 } } }), { code: 'STATION_NOT_EDGE' });
  assert.throws(() => room.game.editStation(host, { station: { ...original[0], tile: { x: 1, y: 2 } } }), { code: 'STATION_NOT_EDGE' });
  assert.throws(() => room.game.editStation(host, { station: { ...original[0], tile: { x: 0, y: 1 } } }), { code: 'STATIONS_TOO_CLOSE' });
  assert.deepEqual(room.stations, original);
  const emergency = original.find((station) => station.kind === 'emergency');
  assert.throws(() => room.game.editStation(host, { station: { id: emergency.id, delete: true } }), { code: 'EMERGENCY_LOCKED' });
  room.game.editStation(host, { station: { ...original[0], name: 'Renamed dial' } });
  assert.equal(room.stations[0].name, 'Renamed dial');
  room.game.editStation(host, { station: { id: 'tilt', delete: true } });
  assert.ok(!room.stations.some((station) => station.id === 'tilt'));
  room.game.editStation(host, { station: original.find((station) => station.id === 'tilt') });
  room.game.confirmSetup(host);
  room.game.confirmSetup(host); // Retry is an idempotent acknowledgement.
  assert.throws(() => room.game.editStation(host, { station: original[0] }), { code: 'SETUP_LOCKED' });
  assert.throws(() => room.game.applySetup(manualSetup), { code: 'SETUP_LOCKED' });
});

test('new grid contract validates origins, playable/edge subsets and emergency station', () => {
  assert.deepEqual(validateRoomSetup(manualSetup.grid, manualSetup.stations).grid, manualSetup.grid);
  assert.throws(() => validateRoomSetup({ cols: 5, rows: 5, tileSize: 1, blocked: [] }, manualSetup.stations), { code: 'INVALID_GRID' });
  const hole = structuredClone(manualSetup.grid);
  hole.playable = hole.playable.filter((tile) => tile.x !== 1 || tile.y !== 1);
  assert.equal(walkable({ x: 1, y: 1 }, hole), false);
  assert.equal(walkable({ x: 0, y: 0 }, hole), true);
  const duplicate = structuredClone(manualSetup.grid);
  duplicate.playable[1] = duplicate.playable[0];
  assert.throws(() => validateRoomSetup(duplicate, manualSetup.stations), { code: 'INVALID_GRID' });
  assert.throws(() => validateRoomSetup(manualSetup.grid, manualSetup.stations.filter((station) => station.kind !== 'emergency')), { code: 'INVALID_EMERGENCY' });
});

test('station spacing uses Euclidean tile-center distance, including diagonal pairs', () => {
  const station = (id, x, y) => ({ id, name: id, tile: { x, y }, task: 'hold', kind: 'task' });
  const emergency = manualSetup.stations.find((item) => item.kind === 'emergency');
  assert.throws(() => validateRoomSetup(manualSetup.grid,
    [station('a', 0, 1), station('b', 1, 0), emergency]), { code: 'STATIONS_TOO_CLOSE' });
  assert.equal(validateRoomSetup(manualSetup.grid,
    [station('a', 0, 0), station('b', 2, 0), emergency]).stations.length, 3);
});

test('setup edits, confirmation and reconnect use the documented shared JSON messages', async (t) => {
  const app = createAppServer({ manualSetup });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const host = await connectClient(url);
  host.send({ t: 'create', name: 'Host' });
  const identity = await host.waitFor((event) => event.t === 'joined');
  const draft = await host.waitFor((event) => event.t === 'setup');
  assert.deepEqual(draft, { ...manualSetup, zones: [] });
  const guest = await connectClient(url);
  guest.send({ t: 'join', room: identity.room, name: 'Guest' });
  await guest.waitFor((event) => event.t === 'joined');
  host.send({ t: 'start', setupConfirmed: true });
  assert.equal((await host.waitFor((event) => event.t === 'error')).code, 'SETUP_NOT_CONFIRMED');
  host.send({ t: 'editStation', station: { ...draft.stations[0], name: 'Edited station' } });
  for (const client of [host, guest]) {
    const edited = await client.waitFor((event) => event.t === 'setup' && event.stations[0].name === 'Edited station');
    assert.equal(edited.setupConfirmed, false);
  }
  host.send({ t: 'confirmSetup' });
  const confirmed = await host.waitFor((event) => event.t === 'setup' && event.setupConfirmed);
  assert.deepEqual(await guest.waitFor((event) => event.t === 'setup' && event.setupConfirmed), confirmed);
  assert.equal((await guest.waitFor((event) => event.t === 'lobby' && event.setupConfirmed)).setupConfirmed, true);
  const replacement = await connectClient(url);
  replacement.send({ t: 'join', room: identity.room, name: 'Host', playerId: identity.playerId });
  assert.equal((await replacement.waitFor((event) => event.t === 'joined')).playerId, identity.playerId);
  assert.deepEqual(await replacement.waitFor((event) => event.t === 'setup'), confirmed);
  host.socket.close();
});
