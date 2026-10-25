const assert = require('node:assert/strict');
const { connectClient } = require('./client');

async function runRound(url, log = console.log) {
  const clients = [];
  try {
    for (let index = 0; index < 4; index += 1) clients.push(await connectClient(url));
    clients[0].send({ t: 'create', name: 'Host bot' });
    const host = await clients[0].waitFor((event) => event.t === 'joined');
    const identities = [host];
    for (let index = 1; index < 4; index += 1) {
      clients[index].send({ t: 'join', room: host.room, name: `Crew bot ${index}` });
      identities.push(await clients[index].waitFor((event) => event.t === 'joined'));
    }
    log(`Four bots joined ${host.room}`);
    clients[0].send({ t: 'setRoom', grid: { cols: 5, rows: 5, tileSize: 1, blocked: [] }, stations: [
      { id: 'dial', name: 'Demo dial', tile: { x: 0, y: 0 }, task: 'dial', kind: 'task' },
      { id: 'fix', name: 'Lights', tile: { x: 1, y: 1 }, task: 'hold', kind: 'fix' },
    ] });
    await clients[0].waitFor((event) => event.t === 'lobby' && event.stations.length === 2);
    for (const client of clients) {
      client.send({ t: 'ready', ready: true });
      client.send({ t: 'tile', tile: { x: 0, y: 0 }, source: 'manual' });
      client.send({ t: 'tile', tile: { x: 0, y: 0 }, source: 'manual' });
    }
    await clients[0].waitFor((event) => event.t === 'lobby'
      && event.players.every((player) => player.ready && player.tile));
    clients[0].send({ t: 'start' });
    const roles = await Promise.all(clients.map((client) => client.waitFor((event) => event.t === 'role')));
    assert.equal(roles.filter((event) => event.role === 'impostor').length, 1);
    const playing = await Promise.all(clients.map((client) => client.waitFor((event) => event.t === 'state' && event.phase === 'playing')));
    playing.forEach((state) => { assert.deepEqual(state, playing[0]); assert.ok(state.players.every((player) => !('role' in player))); });
    log('Private roles delivered; all clients see identical playing state');
    const crewIndex = roles.findIndex((event) => event.role === 'crew');
    const impostorIndex = roles.findIndex((event) => event.role === 'impostor');
    clients[crewIndex].send({ t: 'taskDone', stationId: 'dial' });
    await clients[0].waitFor((event) => event.t === 'state' && event.tasksDone === 1);
    clients[crewIndex].send({ t: 'emergency' });
    await Promise.all(clients.map((client) => client.waitFor((event) => event.t === 'meeting')));
    for (const client of clients) client.send({ t: 'vote', target: identities[impostorIndex].playerId });
    const ended = await Promise.all(clients.map((client) => client.waitFor((event) => event.t === 'state' && event.phase === 'ended')));
    ended.forEach((state) => assert.deepEqual(state, ended[0]));
    for (const client of clients) {
      const result = await client.waitFor((event) => event.t === 'result');
      assert.equal(result.winner, 'crew');
      assert.equal(result.ejected, identities[impostorIndex].playerId);
    }
    log('PASS: lobby → playing → meeting → ended; task, votes, and crew victory synchronized');
    return { room: host.room, players: ended[0].players.length, phase: ended[0].phase };
  } finally {
    for (const client of clients) client.socket.close();
  }
}

async function main() {
  const url = process.env.WS_URL || 'ws://127.0.0.1:8080/ws';
  const room = process.argv[2];
  if (!room) return runRound(url);
  const client = await connectClient(url);
  client.send({ t: 'join', room, name: `Bot ${Date.now().toString().slice(-4)}` });
  const identity = await client.waitFor((event) => event.t === 'joined');
  client.send({ t: 'ready', ready: true });
  console.log(`Bot ${identity.playerId.slice(0, 8)} joined ${room}; press Ctrl+C to disconnect.`);
  client.socket.on('message', (raw) => console.log(raw.toString()));
  process.once('SIGINT', () => client.socket.close());
}

if (require.main === module) main().catch((error) => { console.error(error); process.exitCode = 1; });
module.exports = { runRound };
