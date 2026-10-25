const test = require('node:test');
const assert = require('node:assert/strict');
const { createAppServer } = require('../index');
const { runRound } = require('../tools/fakeClient');
const { connectClient } = require('../tools/client');
const manualSetup = require('../fixtures/manual-setup.json');

test('protocol ping receives pong before joining and does not require a JSON ping event', { timeout: 5000 }, async (t) => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const client = await connectClient(`ws://127.0.0.1:${address.port}/ws`);
  const pong = new Promise((resolve) => client.socket.once('pong', resolve));
  client.socket.ping('keepalive');
  assert.equal((await pong).toString(), 'keepalive');
  client.send({ t: 'create', name: 'Ping test' });
  const joined = await client.waitFor((event) => event.t === 'joined');
  assert.equal((await client.waitFor((event) => event.t === 'lobby')).hostId, joined.playerId);
});

test('replacement closes the old socket with 4000 and its late close cannot detach the new host', { timeout: 5000 }, async (t) => {
  const app = createAppServer({ manualSetup });
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const old = await connectClient(url);
  old.send({ t: 'create', name: 'Host' });
  const identity = await old.waitFor((event) => event.t === 'joined');
  const room = app.rooms.rooms.get(identity.room);
  const oldServerSocket = room.players.get(identity.playerId).socket;
  const closed = new Promise((resolve) => old.socket.once('close', (code, reason) => resolve({ code, reason: reason.toString() })));
  const replacement = await connectClient(url);
  replacement.send({ t: 'join', room: identity.room, name: 'Host', playerId: identity.playerId });
  assert.equal((await replacement.waitFor((event) => event.t === 'joined')).playerId, identity.playerId);
  assert.deepEqual(await closed, { code: 4000, reason: 'Reconnected elsewhere' });
  replacement.send({ t: 'ready', ready: true });
  const lobby = await replacement.waitFor((event) => event.t === 'lobby' && event.players[0].ready);
  assert.equal(lobby.hostId, identity.playerId);
  assert.equal(lobby.players.length, 1);
  assert.equal(lobby.players[0].connected, true);
  room.detach(identity.playerId, oldServerSocket); // A stale close must never own the replacement.
  assert.equal(room.lobbyMessage().players[0].ready, true);
  assert.equal(room.lobbyMessage().players[0].connected, true);
  replacement.send({ t: 'confirmSetup' });
  assert.equal((await replacement.waitFor((event) => event.t === 'setup' && event.setupConfirmed)).setupConfirmed, true);
});

test('a rejected reconnect does not evict the current connection', async (t) => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const host = await connectClient(url);
  host.send({ t: 'create', name: 'Host' });
  const identity = await host.waitFor((event) => event.t === 'joined');
  const invalid = await connectClient(url);
  invalid.send({ t: 'join', room: identity.room, name: 'Wrong name', playerId: identity.playerId });
  assert.equal((await invalid.waitFor((event) => event.t === 'error')).code, 'PLAYER_NOT_FOUND');
  host.send({ t: 'ready', ready: true });
  const lobby = await host.waitFor((event) => event.t === 'lobby' && event.players[0].ready);
  assert.equal(lobby.hostId, identity.playerId);
  assert.equal(lobby.players[0].connected, true);
  assert.equal(lobby.players.length, 1);
});

test('four WebSocket bots play a complete synchronized round', async (t) => {
  const app = createAppServer({ manualSetup });
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const result = await runRound(`ws://127.0.0.1:${address.port}/ws`, () => {});
  assert.equal(result.players, 4);
  assert.equal(result.phase, 'ended');
});

test('reconnect during play restores only that player’s private role and authoritative state', async (t) => {
  const app = createAppServer({ manualSetup });
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const clients = [];
  for (let index = 0; index < 4; index += 1) clients.push(await connectClient(url));
  clients[0].send({ t: 'create', name: 'Host' });
  const host = await clients[0].waitFor((event) => event.t === 'joined');
  for (let index = 1; index < 4; index += 1) {
    clients[index].send({ t: 'join', room: host.room, name: `Crew ${index}` });
    await clients[index].waitFor((event) => event.t === 'joined');
  }
  clients[0].send({ t: 'confirmSetup' });
  await clients[0].waitFor((event) => event.t === 'setup' && event.setupConfirmed);
  clients[0].send({ t: 'start', roles: ['impostor', 'impostor', 'impostor', 'impostor'] });
  const role = await clients[0].waitFor((event) => event.t === 'role');
  await clients[0].waitFor((event) => event.t === 'state');
  const closed = new Promise((resolve) => clients[0].socket.once('close', resolve));
  clients[0].socket.close();
  await closed;
  const replacement = await connectClient(url);
  replacement.send({ t: 'join', name: 'Host', room: host.room, playerId: host.playerId });
  assert.equal((await replacement.waitFor((event) => event.t === 'joined')).playerId, host.playerId);
  assert.deepEqual(await replacement.waitFor((event) => event.t === 'role'), role);
  const state = await replacement.waitFor((event) => event.t === 'state');
  assert.equal(state.phase, 'playing');
  assert.ok(state.players.every((player) => !('role' in player)));
  const observer = await clients[1].waitFor((event) => event.t === 'state' && event.players.every((player) => player.connected));
  assert.deepEqual(observer.players, state.players);
});
