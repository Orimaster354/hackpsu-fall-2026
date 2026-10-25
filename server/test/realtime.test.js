const test = require('node:test');
const assert = require('node:assert/strict');
const { createAppServer } = require('../index');
const { runRound } = require('../tools/fakeClient');
const { connectClient } = require('../tools/client');
const manualSetup = require('../fixtures/manual-setup.json');

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
