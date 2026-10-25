const WebSocket = require('ws');
const assert = require('node:assert/strict');

const url = process.env.WS_URL || 'ws://127.0.0.1:8080/ws';

function connect() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { handshakeTimeout: 5000 });
    const inbox = [];
    const waiters = [];
    socket.on('message', (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.t === 'error') {
        for (const waiter of waiters.splice(0)) {
          clearTimeout(waiter.timeout);
          waiter.reject(new Error(`${message.code}: ${message.message}`));
        }
        inbox.push(message);
        return;
      }
      const index = waiters.findIndex((waiter) => waiter.predicate(message));
      if (index < 0) inbox.push(message);
      else {
        const [waiter] = waiters.splice(index, 1);
        clearTimeout(waiter.timeout);
        waiter.resolve(message);
      }
    });
    socket.once('open', () => resolve({
      socket,
      send: (message) => socket.send(JSON.stringify(message)),
      waitFor(predicate) {
        const error = inbox.find((message) => message.t === 'error');
        if (error) return Promise.reject(new Error(`${error.code}: ${error.message}`));
        const index = inbox.findIndex(predicate);
        if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
        return new Promise((done, fail) => {
          const waiter = { predicate, resolve: done, reject: fail };
          waiter.timeout = setTimeout(() => {
            waiters.splice(waiters.indexOf(waiter), 1);
            fail(new Error('Timed out waiting for the synchronized lobby.'));
          }, 5000);
          waiters.push(waiter);
        });
      },
    }));
    socket.once('error', reject);
  });
}

async function main() {
  const clients = [];
  try {
    for (let i = 0; i < 4; i += 1) clients.push(await connect());
    clients[0].send({ t: 'create', name: 'Host' });
    const { room } = await clients[0].waitFor((message) => message.t === 'joined');
    console.log(`Created room ${room}`);

    for (let i = 1; i < 4; i += 1) {
      clients[i].send({ t: 'join', room, name: `Player ${i + 1}` });
      await clients[i].waitFor((message) => message.t === 'joined');
    }

    let reference;
    for (const client of clients) {
      const lobby = await client.waitFor((message) => message.t === 'lobby' && message.players.length === 4);
      reference ??= lobby;
      assert.deepEqual(lobby, reference, 'All four clients must receive the same lobby.');
      assert.equal(new Set(lobby.players.map((player) => player.id)).size, 4);
      console.log(`Client sees ${lobby.players.length} players in ${room}`);
    }
    for (const client of clients) client.send({ t: 'ready', ready: true });
    reference = undefined;
    for (const client of clients) {
      const lobby = await client.waitFor((message) => message.t === 'lobby'
        && message.players.length === 4 && message.players.every((player) => player.ready && player.connected));
      reference ??= lobby;
      assert.deepEqual(lobby, reference, 'Ready status must be synchronized for all four clients.');
    }
    console.log('PASS: four simultaneous clients received identical lobby state.');
    console.log('PASS: all four clients see every player connected and ready.');
  } finally {
    for (const client of clients) client.socket.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
