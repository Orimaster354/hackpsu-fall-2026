const WebSocket = require('ws');

const url = process.env.WS_URL || 'ws://127.0.0.1:8080/ws';

function connect() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const inbox = [];
    const waiters = [];
    socket.on('message', (raw) => {
      const message = JSON.parse(raw.toString());
      const index = waiters.findIndex((waiter) => waiter.predicate(message));
      if (index < 0) inbox.push(message);
      else waiters.splice(index, 1)[0].resolve(message);
    });
    socket.once('open', () => resolve({
      socket,
      send: (message) => socket.send(JSON.stringify(message)),
      waitFor(predicate) {
        const index = inbox.findIndex(predicate);
        if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
        return new Promise((done) => waiters.push({ predicate, resolve: done }));
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

    for (const client of clients) {
      const lobby = await client.waitFor((message) => message.t === 'lobby' && message.players.length === 4);
      console.log(`Client sees ${lobby.players.length} players in ${room}`);
    }
  } finally {
    for (const client of clients) client.socket.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
