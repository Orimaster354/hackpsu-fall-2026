const assert = require('node:assert/strict');
const test = require('node:test');
const WebSocket = require('ws');
const { createAppServer } = require('../index');

function connect(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const inbox = [];
    const waiters = [];

    socket.on('message', (raw) => {
      const message = JSON.parse(raw.toString());
      const waiterIndex = waiters.findIndex((waiter) => waiter.predicate(message));
      if (waiterIndex === -1) {
        inbox.push(message);
      } else {
        const [waiter] = waiters.splice(waiterIndex, 1);
        clearTimeout(waiter.timeout);
        waiter.resolve(message);
      }
    });
    socket.once('open', () => resolve({
      socket,
      send: (message) => socket.send(JSON.stringify(message)),
      waitFor(predicate) {
        const index = inbox.findIndex(predicate);
        if (index !== -1) return Promise.resolve(inbox.splice(index, 1)[0]);
        return new Promise((done, fail) => {
          const waiter = { predicate, resolve: done };
          waiter.timeout = setTimeout(() => {
            waiters.splice(waiters.indexOf(waiter), 1);
            fail(new Error('Timed out waiting for a WebSocket message.'));
          }, 2000);
          waiters.push(waiter);
        });
      },
    }));
    socket.once('error', reject);
  });
}

test('four fake clients share one lobby and a fifth is rejected', async (t) => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const clients = await Promise.all(Array.from({ length: 5 }, () => connect(url)));

  clients[0].send({ t: 'create', name: 'Host' });
  const host = await clients[0].waitFor((m) => m.t === 'joined');
  assert.match(host.room, /^[A-Z]{4}$/);

  for (let i = 1; i < 4; i += 1) {
    clients[i].send({ t: 'join', room: host.room, name: `Player ${i + 1}` });
    const joined = await clients[i].waitFor((m) => m.t === 'joined');
    assert.equal(joined.room, host.room);
    assert.notEqual(joined.playerId, host.playerId);
  }

  for (const client of clients.slice(0, 4)) {
    const lobby = await client.waitFor((m) => m.t === 'lobby' && m.players.length === 4);
    assert.deepEqual(lobby.players.map((player) => player.name), [
      'Host', 'Player 2', 'Player 3', 'Player 4',
    ]);
    assert.deepEqual(lobby.grid, { cols: 5, rows: 5, tileSize: 1, blocked: [] });
    assert.deepEqual(lobby.stations, []);
    assert.equal(lobby.hasMap, false);
    assert.ok(lobby.players.every((player) => !('role' in player)));
  }

  clients[4].send({ t: 'join', room: host.room, name: 'Too many' });
  const error = await clients[4].waitFor((m) => m.t === 'error');
  assert.equal(error.code, 'ROOM_FULL');
});

test('readiness and disconnect/reconnect status synchronize without losing the player', async (t) => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;

  const original = await connect(url);
  original.send({ t: 'create', name: 'Host' });
  const first = await original.waitFor((m) => m.t === 'joined');
  const observer = await connect(url);
  observer.send({ t: 'join', room: first.room, name: 'Observer' });
  await observer.waitFor((m) => m.t === 'joined');
  original.send({ t: 'ready', ready: true });
  for (const client of [original, observer]) {
    const lobby = await client.waitFor((m) => m.t === 'lobby'
      && m.players.find((player) => player.id === first.playerId)?.ready === true);
    assert.equal(lobby.players.find((player) => player.id === first.playerId).connected, true);
  }
  const room = app.rooms.rooms.get(first.room);
  const disconnected = new Promise((resolve) => room.players.get(first.playerId).socket.once('close', resolve));
  original.socket.close();
  await disconnected;
  assert.equal(room.players.get(first.playerId).socket, null);
  const offline = await observer.waitFor((m) => m.t === 'lobby'
    && m.players.find((player) => player.id === first.playerId)?.connected === false);
  assert.equal(offline.players.find((player) => player.id === first.playerId).ready, false);

  const replacement = await connect(url);
  replacement.send({ t: 'join', room: first.room, name: 'Host', playerId: first.playerId });
  const joined = await replacement.waitFor((m) => m.t === 'joined');
  const lobby = await replacement.waitFor((m) => m.t === 'lobby');
  assert.equal(joined.playerId, first.playerId);
  assert.equal(lobby.players.length, 2);
  assert.equal(lobby.players.find((player) => player.id === first.playerId).ready, false);
  assert.equal(lobby.players.find((player) => player.id === first.playerId).connected, true);
  const restored = await observer.waitFor((m) => m.t === 'lobby'
    && m.players.find((player) => player.id === first.playerId)?.connected === true
    && m.players.find((player) => player.id === first.playerId)?.ready === false);
  assert.deepEqual(restored, lobby);
  assert.ok(room.players.get(first.playerId).socket);
});

test('bad messages return protocol errors without closing the socket', async (t) => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const client = await connect(`ws://127.0.0.1:${address.port}/ws`);

  client.socket.send('{');
  assert.equal((await client.waitFor((m) => m.t === 'error')).code, 'INVALID_JSON');
  client.send({ t: 'join', room: 'XXXX', name: 'Test' });
  assert.equal((await client.waitFor((m) => m.t === 'error')).code, 'ROOM_NOT_FOUND');
  client.send({ t: 'create', name: 'Test' });
  assert.equal((await client.waitFor((m) => m.t === 'joined')).t, 'joined');
  client.send({ t: 'ready', ready: 'yes' });
  assert.equal((await client.waitFor((m) => m.t === 'error')).code, 'INVALID_READY');
});

test('dashboard serves live public status without roles or reconnect credentials', async (t) => {
  const app = createAppServer();
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const base = `http://127.0.0.1:${address.port}`;
  for (const route of ['/dashboard', '/dashboard/app.js', '/dashboard/style.css']) {
    const response = await fetch(base + route);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.ok((await response.text()).length > 0);
  }
  assert.deepEqual((await (await fetch(base + '/api/dashboard')).json()).rooms, []);
  const client = await connect(`ws://127.0.0.1:${address.port}/ws`);
  client.send({ t: 'create', name: 'Dashboard test' });
  const joined = await client.waitFor((message) => message.t === 'joined');
  const player = app.rooms.rooms.get(joined.room).players.get(joined.playerId);
  player.role = 'PRIVATE_ROLE_MARKER';
  client.send({ t: 'ready', ready: true });
  await client.waitFor((message) => message.t === 'lobby' && message.players[0].ready);
  const response = await fetch(base + '/api/dashboard');
  const text = await response.text();
  assert.ok(!text.includes('PRIVATE_ROLE_MARKER'));
  assert.ok(!text.includes(joined.playerId));
  const snapshot = JSON.parse(text);
  assert.equal(snapshot.connections, 1);
  assert.equal(snapshot.rooms[0].phase, 'lobby');
  assert.equal(snapshot.rooms[0].players[0].connected, true);
  assert.equal(snapshot.rooms[0].players[0].ready, true);
  assert.equal(snapshot.rooms[0].players[0].host, true);
  const closed = new Promise((resolve) => player.socket.once('close', resolve));
  client.socket.close();
  await closed;
  const offline = await (await fetch(base + '/api/dashboard')).json();
  assert.equal(offline.connections, 0);
  assert.equal(offline.rooms[0].players[0].connected, false);
  assert.equal(offline.rooms[0].players[0].ready, false);
});
