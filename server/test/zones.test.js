const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createAppServer } = require('../index');
const { layout } = require('../zones');
const poses = require('../../docs/fixtures/poses.json');
const fx = require('../../docs/fixtures/postit/sweep-observations.json');

const jpeg = fs.readFileSync(path.join(__dirname, '../../docs/fixtures/postit/tiny-frame.jpg')).toString('base64');
const sweepBody = (zone) => structuredClone({ zone, vantage: fx.vantage, intrinsics: fx.intrinsics,
  frames: fx.frames.map(({ index, t, pose }) => ({ index, t, pose, jpeg })) });
const fixtureDetector = { async detect(frames) {
  return frames.map((frame) => ({ ...frame, detections: fx.frames.find((item) => item.index === frame.index).detections }));
} };
const unavailablePlanner = { async planCandidates() { throw new Error('Gemini unavailable'); } };

async function roomServer(t, players = 2) {
  const app = createAppServer({ sweepDetector: fixtureDetector, stationPlanner: unavailablePlanner });
  const messages = [];
  const socket = () => ({ readyState: 1, send: (raw) => messages.push(JSON.parse(raw)) });
  const { room, player: host } = app.rooms.create('Host', socket());
  for (let index = 1; index < players; index += 1) app.rooms.join(room.code, `Guest ${index}`, socket());
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const base = `http://127.0.0.1:${address.port}`;
  const post = async (step, body, id = host.id) => {
    const response = await fetch(`${base}/scan/${room.code}/${step}`, { method: 'POST',
      headers: { 'content-type': 'application/json', 'X-Player-Id': id }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const scan = async (zone, name) => {
    const perimeter = await post('perimeter', { zone, name, poses });
    assert.equal(perimeter.status, 200, JSON.stringify(perimeter.body));
    const sweep = await post('sweep', sweepBody(zone));
    assert.equal(sweep.status, 200, JSON.stringify(sweep.body));
    return { perimeter: perimeter.body, sweep: sweep.body };
  };
  const putMap = (zone, bytes = Buffer.from('map-' + zone)) => fetch(`${base}/map/${room.code}${zone ? `?zone=${zone}` : ''}`, {
    method: 'POST', headers: { 'content-type': 'application/octet-stream', 'X-Player-Id': host.id }, body: bytes });
  const getMap = (zone) => fetch(`${base}/map/${room.code}${zone ? `?zone=${zone}` : ''}`);
  const lastSetup = () => messages.filter((message) => message.t === 'setup').at(-1);
  return { app, room, host, post, scan, putMap, getMap, messages, lastSetup, base };
}

const tasksOf = (stations) => stations.filter((station) => station.kind === 'task');

test('one scanned room behaves exactly as before, and tells clients about its single zone', async (t) => {
  const { room, scan, lastSetup } = await roomServer(t);
  const result = await scan('z1', 'Lounge');
  assert.equal(result.perimeter.zone, 'z1');
  assert.equal(room.grid.originX, -0.5, 'a single room keeps its own ARKit origin in the combined grid');
  const setup = lastSetup();
  assert.equal(setup.zones.length, 1);
  assert.deepEqual(setup.zones[0].offset, { x: 0, y: 0 });
  assert.equal(setup.zones[0].name, 'Lounge');
  assert.deepEqual(setup.zones[0].grid, room.grid);
  assert.equal(setup.stations.filter((station) => station.kind === 'emergency').length, 1);
});

test('two rooms share one combined grid, with a gap, and one emergency station each', async (t) => {
  const { room, scan, lastSetup } = await roomServer(t);
  await scan('z1', 'Lounge');
  await scan('z2', 'Kitchen');
  const setup = lastSetup();
  assert.deepEqual(setup.zones.map((zone) => zone.id), ['z1', 'z2']);
  assert.deepEqual(setup.zones[1].offset, { x: 6, y: 0 }, 'the second room starts after the first plus a one-tile gap');
  assert.equal(room.grid.cols, 11);
  assert.equal(room.grid.rows, 5);
  assert.equal(room.grid.originX, 0, 'a multi-room grid has no single ARKit origin');
  assert.equal(room.grid.playable.length, 50);
  const playable = new Set(room.grid.playable.map((tile) => `${tile.x},${tile.y}`));
  assert.ok(!playable.has('5,2'), 'the gap tile between the rooms cannot be stood on');
  assert.ok(playable.has('6,0') && playable.has('10,4'));
  const emergencies = setup.stations.filter((station) => station.kind === 'emergency');
  assert.deepEqual(emergencies.map((station) => station.id), ['emergency', 'z2-emergency']);
  assert.deepEqual(emergencies.map((station) => station.tile), [{ x: 2, y: 2 }, { x: 8, y: 2 }]);
  // Each room keeps its own local grid, in its own ARKit frame, for the phones standing in it.
  assert.equal(setup.zones[1].grid.originX, -0.5);
  assert.equal(setup.zones[1].grid.cols, 5);
});

test('the whole game has at most five task stations, shared out across rooms, none repeating', async (t) => {
  const { scan, lastSetup } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  await scan('z3');
  const stations = lastSetup().stations;
  const tasks = tasksOf(stations);
  assert.equal(tasks.length, 5);
  assert.equal(new Set(tasks.map((station) => station.task)).size, 5, `repeat in ${tasks.map((s) => s.task)}`);
  const perRoom = [0, 6, 12].map((x) => tasks.filter((station) => station.tile.x >= x && station.tile.x < x + 5).length);
  assert.deepEqual(perRoom, [2, 2, 1], 'round-robin gives every room a share before any room a second helping');
  assert.equal(stations.filter((station) => station.kind === 'fix').length, 3, 'a fix station in every room');
  assert.equal(stations.filter((station) => station.kind === 'emergency').length, 3);
  assert.ok(stations.every((station, index, all) => all.findIndex((other) => other.id === station.id) === index), 'ids are unique');
});

test('each room has its own ARWorldMap', async (t) => {
  const { room, scan, putMap, getMap, lastSetup, messages } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  assert.equal((await putMap('z1', Buffer.from('first'))).status, 204);
  assert.equal(room.mapsReady(), false, 'the second room still has no map');
  assert.equal((await putMap('z2', Buffer.from('second'))).status, 204);
  assert.equal(room.mapsReady(), true);
  assert.equal(Buffer.from(await (await getMap('z1')).arrayBuffer()).toString(), 'first');
  assert.equal(Buffer.from(await (await getMap('z2')).arrayBuffer()).toString(), 'second');
  assert.equal(Buffer.from(await (await getMap()).arrayBuffer()).toString(), 'first', 'no zone means the first room');
  assert.equal((await getMap('z3')).status, 404);
  assert.equal((await putMap('z3')).status, 404, 'cannot upload a map for a room that was not scanned');
  assert.equal((await putMap('nonsense')).status, 400);
  const lobby = messages.filter((message) => message.t === 'lobby').at(-1);
  assert.deepEqual(lobby.zones.map((zone) => zone.hasMap), [true, true]);
  assert.equal(lobby.hasMap, true);
  assert.equal(lastSetup().zones.length, 2);
});

test('doors join rooms; confirming needs every room connected', async (t) => {
  const { room, host, scan, lastSetup } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  const door = { a: { zone: 'z1', tile: { x: 4, y: 2 } }, b: { zone: 'z2', tile: { x: 0, y: 2 } } };
  assert.throws(() => room.game.confirmSetup(host), (error) => error.code === 'ZONES_NOT_CONNECTED');
  room.game.handle(host, { t: 'setDoors', doors: [door] });
  const zones = lastSetup().zones;
  assert.deepEqual(zones[0].doors, [{ tile: { x: 4, y: 2 }, toZone: 'z2', toTile: { x: 0, y: 2 } }]);
  assert.deepEqual(zones[1].doors, [{ tile: { x: 0, y: 2 }, toZone: 'z1', toTile: { x: 4, y: 2 } }]);
  room.game.handle(host, { t: 'confirmSetup' });
  assert.equal(room.setupConfirmed, true);
  assert.throws(() => room.game.handle(host, { t: 'setDoors', doors: [] }), (error) => error.code === 'SETUP_LOCKED');
});

test('bad doors are refused', async (t) => {
  const { room, host, scan } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  const bad = (doors) => assert.throws(() => room.game.handle(host, { t: 'setDoors', doors }), (error) => error.code === 'INVALID_DOORS');
  const edge = { x: 4, y: 2 };
  bad([{ a: { zone: 'z1', tile: edge }, b: { zone: 'z1', tile: { x: 0, y: 2 } } }]); // same room
  bad([{ a: { zone: 'z1', tile: { x: 2, y: 2 } }, b: { zone: 'z2', tile: { x: 0, y: 2 } } }]); // not an edge tile
  bad([{ a: { zone: 'z1', tile: edge }, b: { zone: 'z3', tile: { x: 0, y: 2 } } }]); // room not scanned
  bad([{ a: { zone: 'z1', tile: edge }, b: { zone: 'z2', tile: { x: 0, y: 2 } } },
    { a: { zone: 'z2', tile: { x: 0, y: 1 } }, b: { zone: 'z1', tile: { x: 4, y: 1 } } }]); // second door for the same pair
  bad('not a list');
  assert.throws(() => room.game.handle(room.players.get([...room.players.keys()][1]), { t: 'setDoors', doors: [] }),
    (error) => error.code === 'HOST_ONLY');
});

test('a chain of three rooms is connected only when the doors link them all', async (t) => {
  const { room, host, scan } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  await scan('z3');
  const d12 = { a: { zone: 'z1', tile: { x: 4, y: 2 } }, b: { zone: 'z2', tile: { x: 0, y: 2 } } };
  const d23 = { a: { zone: 'z2', tile: { x: 4, y: 2 } }, b: { zone: 'z3', tile: { x: 0, y: 2 } } };
  room.game.handle(host, { t: 'setDoors', doors: [d12] });
  assert.throws(() => room.game.confirmSetup(host), (error) => error.code === 'ZONES_NOT_CONNECTED');
  room.game.handle(host, { t: 'setDoors', doors: [d12, d23] });
  room.game.confirmSetup(host);
  assert.equal(room.setupConfirmed, true);
});

test('rescanning a room invalidates its map and doors but not the others', async (t) => {
  const { room, host, post, scan, putMap } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  await putMap('z1');
  await putMap('z2');
  room.game.handle(host, { t: 'setDoors', doors: [{ a: { zone: 'z1', tile: { x: 4, y: 2 } }, b: { zone: 'z2', tile: { x: 0, y: 2 } } }] });
  assert.equal((await post('perimeter', { zone: 'z2', poses })).status, 200);
  assert.equal(room.maps.has('z2'), false, 'the rescanned room needs a new map');
  assert.equal(room.maps.has('z1'), true);
  assert.deepEqual(room.doors, [], 'a door to a rescanned room is gone');
  assert.equal(room.zones.size, 2);
});

test('removing a room re-lays out the rest, and removing them all clears the setup', async (t) => {
  const { room, host, scan, lastSetup } = await roomServer(t);
  await scan('z1');
  await scan('z2');
  room.game.handle(host, { t: 'removeZone', zone: 'z1' });
  assert.deepEqual(lastSetup().zones.map((zone) => zone.id), ['z2']);
  assert.deepEqual(lastSetup().zones[0].offset, { x: 0, y: 0 }, 'the remaining room moves to the start');
  assert.equal(room.grid.originX, -0.5);
  assert.throws(() => room.game.handle(host, { t: 'removeZone', zone: 'z5' }), (error) => error.code === 'INVALID_ZONE');
  room.game.handle(host, { t: 'removeZone', zone: 'z2' });
  assert.equal(room.grid, null);
  assert.deepEqual(room.stations, []);
});

test('at most six rooms, with valid ids', async (t) => {
  const { post, scan } = await roomServer(t);
  for (const id of ['z1', 'z2', 'z3', 'z4', 'z5']) await scan(id);
  assert.equal((await post('perimeter', { zone: 'z6', poses })).status, 200);
  const bad = await post('perimeter', { zone: 'z7', poses });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.code, 'INVALID_ZONE');
  const nameBad = await post('perimeter', { zone: 'z1', name: '', poses });
  assert.equal(nameBad.status, 400);
});

test('a sweep needs that room\'s own perimeter first', async (t) => {
  const { post, scan } = await roomServer(t);
  await scan('z1');
  const early = await post('sweep', sweepBody('z2'));
  assert.equal(early.status, 409);
  assert.equal(early.body.code, 'SETUP_MISSING');
});

test('rooms are laid out left to right and wrap onto a new row past 60 columns', () => {
  const zone = (cols, rows) => ({ geometry: { grid: { cols, rows } } });
  const placed = layout([zone(30, 8), zone(25, 12), zone(20, 5), zone(10, 4)]);
  assert.deepEqual(placed.map((entry) => entry.offset), [{ x: 0, y: 0 }, { x: 31, y: 0 }, { x: 0, y: 13 }, { x: 21, y: 13 }]);
});

test('players can stand and kill in the second room, using combined tiles', async (t) => {
  const { app, room, host, scan } = await roomServer(t, 4);
  await scan('z1');
  await scan('z2');
  room.game.handle(host, { t: 'setDoors', doors: [{ a: { zone: 'z1', tile: { x: 4, y: 2 } }, b: { zone: 'z2', tile: { x: 0, y: 2 } } }] });
  room.game.confirmSetup(host);
  const players = [...room.players.values()];
  room.game.start(host);
  const move = (player, x, y) => { room.game.tile(player, { tile: { x, y }, source: 'ar' }); room.game.tile(player, { tile: { x, y }, source: 'ar' }); };
  assert.throws(() => room.game.tile(players[0], { tile: { x: 5, y: 2 }, source: 'ar' }), (error) => error.code === 'INVALID_TILE');
  const impostor = players.find((player) => player.role === 'impostor');
  const crew = players.find((player) => player.role === 'crew');
  move(impostor, 8, 2);
  move(crew, 8, 2);
  assert.deepEqual(crew.tile, { x: 8, y: 2 });
  assert.ok(app);
});
