const test = require('node:test');
const assert = require('node:assert/strict');
const { RoomManager } = require('../rooms');
const { createAppServer } = require('../index');
const { connectClient } = require('../tools/client');
const { validateRoomSetup } = require('../contracts');
const socket = () => ({ readyState: 1, send() {} });

test('demo preset is valid, editable and isolated from normal rooms', () => {
  const manager = new RoomManager();
  const { room, player } = manager.create('Demo', socket(), true);
  assert.equal(room.demo, true);
  assert.equal(room.hasMap, false);
  assert.equal(room.setupConfirmed, false);
  validateRoomSetup(room.grid, room.stations);
  assert.equal(room.grid.cols, 8);
  assert.deepEqual(new Set(room.stations.filter(s => s.kind === 'task').map(s => s.task)),
    new Set(['shake', 'hold', 'dial', 'gesture', 'hammer']));
  room.game.editStation(player, { station: { ...room.stations[0], name: 'Custom shake', tile: { x: 0, y: 2 } } });
  assert.equal(room.stations[0].name, 'Custom shake');
  const normal = manager.create('Normal', socket()).room;
  assert.equal(normal.demo, false);
  assert.equal(normal.grid, null);
  assert.equal(normal.stations.length, 0);
  assert.throws(() => manager.create('Bad', socket(), 'true'), { code: 'INVALID_DEMO' });
});

test('demo room joins and reconnects with its flag, then runs manual tasks and sabotage over real sockets', async t => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const host = await connectClient(url);
  host.send({ t: 'create', name: 'Host', demo: true });
  const identity = await host.waitFor(e => e.t === 'joined');
  const setup = await host.waitFor(e => e.t === 'setup');
  const lobby = await host.waitFor(e => e.t === 'lobby');
  assert.equal(lobby.demo, true);
  assert.equal(lobby.hasMap, false);
  assert.equal(lobby.setupConfirmed, false);
  const actors = [{ client: host, id: identity.playerId }];
  for (let i = 1; i < 4; i++) {
    const client = await connectClient(url);
    client.send({ t: 'join', room: identity.room, name: `Guest ${i}` });
    actors.push({ client, id: (await client.waitFor(e => e.t === 'joined')).playerId });
    assert.equal((await client.waitFor(e => e.t === 'lobby')).demo, true);
  }
  host.send({ t: 'confirmSetup' });
  await host.waitFor(e => e.t === 'setup' && e.setupConfirmed);
  host.send({ t: 'start' });
  for (const actor of actors) {
    actor.role = (await actor.client.waitFor(e => e.t === 'role')).role;
    await actor.client.waitFor(e => e.t === 'state' && e.phase === 'playing');
  }
  const impostor = actors.find(a => a.role === 'impostor');
  const crew = actors.find(a => a.role === 'crew');
  const move = async tile => {
    crew.client.send({ t: 'tile', tile, source: 'manual' });
    crew.client.send({ t: 'tile', tile, source: 'manual' });
    await crew.client.waitFor(e => e.t === 'state' && e.players.some(p =>
      p.id === crew.id && p.tile?.x === tile.x && p.tile?.y === tile.y && p.tileSource === 'manual'));
  };
  await move(setup.stations.find(s => s.id === 'demo-shake').tile);
  impostor.client.send({ t: 'sabotage' });
  await crew.client.waitFor(e => e.t === 'state' && e.lightsOut);
  crew.client.send({ t: 'taskDone', stationId: 'demo-shake' });
  assert.equal((await crew.client.waitFor(e => e.t === 'error')).code, 'LIGHTS_OUT');
  const fix = setup.stations.find(s => s.kind === 'fix');
  await move(fix.tile);
  crew.client.send({ t: 'fix', stationId: fix.id });
  await crew.client.waitFor(e => e.t === 'state' && !e.lightsOut);
  let done = 0;
  for (const station of setup.stations.filter(s => s.kind === 'task')) {
    await move(station.tile);
    crew.client.send({ t: 'taskDone', stationId: station.id });
    const count = ++done;
    await crew.client.waitFor(e => e.t === 'state' && e.tasksDone === count);
  }
  const replacement = await connectClient(url);
  replacement.send({ t: 'join', room: identity.room, name: 'Host', playerId: identity.playerId });
  await replacement.waitFor(e => e.t === 'joined');
  assert.equal((await replacement.waitFor(e => e.t === 'lobby')).demo, true);
  assert.equal((await replacement.waitFor(e => e.t === 'setup')).setupConfirmed, true);
  await replacement.waitFor(e => e.t === 'role');
  assert.equal((await replacement.waitFor(e => e.t === 'state')).tasksDone, 5);
});
