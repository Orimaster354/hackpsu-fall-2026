const test = require('node:test');
const assert = require('node:assert/strict');
const { createAppServer } = require('../index');
const { connectClient } = require('../tools/client');
const manualSetup = require('../fixtures/manual-setup.json');

async function game(t) {
  let now = 1000000;
  const app = createAppServer({ manualSetup, now: () => now });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const clients = [];
  const actors = [];
  for (let index = 0; index < 4; index += 1) clients.push(await connectClient(`ws://127.0.0.1:${address.port}/ws`));
  clients[0].send({ t: 'create', name: 'Host' });
  const identity = await clients[0].waitFor((event) => event.t === 'joined');
  actors.push({ client: clients[0], id: identity.playerId });
  for (let index = 1; index < 4; index += 1) {
    clients[index].send({ t: 'join', room: identity.room, name: `Player ${index}` });
    actors.push({ client: clients[index], id: (await clients[index].waitFor((event) => event.t === 'joined')).playerId });
  }
  clients[0].send({ t: 'confirmSetup' });
  await Promise.all(clients.map((client) => client.waitFor((event) => event.t === 'setup' && event.setupConfirmed)));
  clients[0].send({ t: 'start' });
  for (const actor of actors) actor.role = (await actor.client.waitFor((event) => event.t === 'role')).role;
  const all = async (predicate) => {
    const states = await Promise.all(clients.map((client) => client.waitFor(predicate)));
    states.forEach((state) => {
      assert.deepEqual(state, states[0]);
      if (state.players) assert.ok(state.players.every((player) => !('role' in player)));
    });
    return states[0];
  };
  const move = (actor, tile) => {
    actor.client.send({ t: 'tile', tile, source: 'manual' });
    actor.client.send({ t: 'tile', tile, source: 'manual' });
  };
  await all((event) => event.t === 'state' && event.phase === 'playing');
  for (const actor of actors) move(actor, { x: 0, y: 0 });
  await all((event) => event.t === 'state' && event.players.every((player) => player.tile?.x === 0 && player.tile?.y === 0));
  const error = async (actor, message, code) => {
    actor.client.send(message);
    assert.equal((await actor.client.waitFor((event) => event.t === 'error')).code, code);
  };
  return { actors, impostor: actors.find((actor) => actor.role === 'impostor'),
    crew: actors.filter((actor) => actor.role === 'crew'), all, move, error, advance: (ms) => { now += ms; } };
}

test('four clients synchronize kill, frozen body, report, dead-vote rejection and ejection', async (t) => {
  const g = await game(t);
  const [victim, reporter, voter] = g.crew;
  await g.error(reporter, { t: 'kill', targetId: victim.id }, 'IMPOSTOR_ONLY');
  await g.error(g.impostor, { t: 'kill', targetId: victim.id }, 'KILL_COOLDOWN');
  g.advance(25000);
  g.impostor.client.send({ t: 'kill', targetId: victim.id });
  const state = await g.all((event) => event.t === 'state' && event.phase === 'playing'
    && event.players.find((player) => player.id === victim.id)?.alive === false);
  assert.deepEqual(state.players.find((player) => player.id === victim.id).tile, { x: 0, y: 0 });
  assert.equal(state.tasksTotal, 6);
  assert.deepEqual(await victim.client.waitFor((event) => event.t === 'killed'), { t: 'killed' });
  await g.error(victim, { t: 'tile', tile: { x: 3, y: 3 }, source: 'manual' }, 'PLAYER_DEAD');
  reporter.client.send({ t: 'report', bodyId: victim.id });
  const meeting = await g.all((event) => event.t === 'meeting');
  assert.equal(meeting.bodyOf, victim.id);
  await g.error(victim, { t: 'vote', target: g.impostor.id }, 'PLAYER_DEAD');
  reporter.client.send({ t: 'vote', target: g.impostor.id });
  voter.client.send({ t: 'vote', target: g.impostor.id });
  g.impostor.client.send({ t: 'vote', target: 'skip' });
  const result = await g.all((event) => event.t === 'result');
  assert.deepEqual(result, { t: 'result', ejected: g.impostor.id, role: 'impostor', winner: 'crew' });
  await g.all((event) => event.t === 'state' && event.phase === 'ended');
});

test('four clients synchronize sabotage, task rejection, station fix and resumed task progress', async (t) => {
  const g = await game(t);
  const crew = g.crew[0];
  g.impostor.client.send({ t: 'sabotage' });
  const dark = await g.all((event) => event.t === 'state' && event.lightsOut);
  assert.equal(dark.tasksDone, 0);
  await g.error(crew, { t: 'taskDone', stationId: 'dial' }, 'LIGHTS_OUT');
  await g.error(crew, { t: 'fix', stationId: 'fix' }, 'INVALID_FIX');
  g.move(crew, { x: 0, y: 2 });
  crew.client.send({ t: 'fix', stationId: 'fix' });
  await g.all((event) => event.t === 'state' && !event.lightsOut
    && event.players.find((player) => player.id === crew.id)?.tile?.y === 2);
  g.move(crew, { x: 0, y: 0 });
  crew.client.send({ t: 'taskDone', stationId: 'dial' });
  const restored = await g.all((event) => event.t === 'state' && !event.lightsOut && event.tasksDone === 1);
  assert.equal(restored.tasksTotal, 9);
  await g.error(g.impostor, { t: 'sabotage' }, 'SABOTAGE_COOLDOWN');
});
