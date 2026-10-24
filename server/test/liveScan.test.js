const test = require('node:test');
const assert = require('node:assert/strict');
const { LiveScan, MAX_FRAME_BYTES } = require('../liveScan');
const { RoomError } = require('../errors');
const { createAppServer } = require('../index');
const { connectClient } = require('../tools/client');
const jpeg = Buffer.from([255, 216, 255, 217]).toString('base64');
const objects = [{ label: 'desk lamp', box: [0.2, 0.1, 0.6, 0.4] }];
const flush = () => new Promise((resolve) => setImmediate(resolve));

async function fixture(t, options = {}) {
  let now = 0;
  const jobs = [];
  const events = [];
  const scan = new LiveScan({ apiKey: 'test-only-key', notify: (message) => events.push(message), now: () => now,
    detect: (message, { signal }) => new Promise((resolve, reject) => jobs.push({ message, signal, resolve, reject })), ...options });
  await scan.start(); t.after(() => scan.stop());
  return { scan, jobs, events, setNow: (value) => { now = value; } };
}

test('live frames retain exact request correlation and replace queued frames under backpressure', async (t) => {
  const { scan, jobs, events, setNow } = await fixture(t);
  scan.frame({ frameId: 'f1', timestampMs: 10, jpeg });
  setNow(1000); scan.frame({ frameId: 'f2', timestampMs: 1010, jpeg });
  setNow(2000); scan.frame({ frameId: 'f3', timestampMs: 2010, jpeg });
  assert.equal(scan.current.frameId, 'f1'); assert.equal(scan.pending.frameId, 'f3');
  assert.equal(jobs.length, 1);
  jobs[0].resolve(objects); await flush();
  assert.deepEqual(events.find((event) => event.t === 'scan_detections'), { t: 'scan_detections', frameId: 'f1', timestampMs: 10, objects });
  assert.equal(scan.current.frameId, 'f3'); assert.equal(scan.pending, null);
  assert.equal(jobs.length, 2);
  jobs[1].resolve(objects); await flush();
  assert.deepEqual(events.filter((event) => event.t === 'scan_detections').map((event) => event.frameId), ['f1', 'f3']);
  assert.ok(!JSON.stringify(events).includes('test-only-key'));
});

test('live input rejects malformed, repeated, out-of-order and excessive frames', async (t) => {
  const { scan, setNow } = await fixture(t);
  assert.throws(() => scan.frame({ frameId: 'x', timestampMs: -1, jpeg }), { code: 'INVALID_SCAN_FRAME' });
  assert.throws(() => scan.frame({ frameId: 'x', timestampMs: 0, jpeg: 'bad' }), { code: 'INVALID_PHOTO' });
  assert.throws(() => scan.frame({ frameId: 'x', timestampMs: 0, jpeg: 'A'.repeat(Math.ceil(MAX_FRAME_BYTES / 3) * 4 + 4) }), { code: 'INVALID_SCAN_FRAME' });
  scan.frame({ frameId: 'x', timestampMs: 1, jpeg });
  assert.throws(() => scan.frame({ frameId: 'y', timestampMs: 2, jpeg }), { code: 'SCAN_RATE_LIMIT' });
  setNow(1000);
  assert.throws(() => scan.frame({ frameId: 'x', timestampMs: 2, jpeg }), { code: 'INVALID_SCAN_FRAME' });
  assert.throws(() => scan.frame({ frameId: 'y', timestampMs: 1, jpeg }), { code: 'INVALID_SCAN_FRAME' });
});

test('stop aborts the active request, clears buffered media and ignores late results', async (t) => {
  const { scan, jobs, events } = await fixture(t);
  scan.frame({ frameId: 'f1', timestampMs: 0, jpeg });
  scan.stop();
  assert.equal(jobs[0].signal.aborted, true);
  jobs[0].resolve(objects); await flush();
  assert.equal(events.filter((event) => event.t === 'scan_detections').length, 0);
  assert.equal(scan.pending, null); assert.equal(scan.current, null);
  assert.throws(() => scan.frame({ frameId: 'f2', timestampMs: 1000, jpeg }), { code: 'SCAN_NOT_READY' });
});

test('provider quota errors stop streaming instead of retrying continuously', async (t) => {
  const { scan, jobs, events, setNow } = await fixture(t);
  scan.frame({ frameId: 'f1', timestampMs: 0, jpeg });
  setNow(1000); scan.frame({ frameId: 'f2', timestampMs: 1000, jpeg });
  jobs[0].reject(new RoomError('GEMINI_UNAVAILABLE', 'Provider rate limit.')); await flush();
  assert.equal(scan.closed, true); assert.equal(jobs.length, 1);
  assert.equal(events.find((event) => event.t === 'error').code, 'GEMINI_UNAVAILABLE');
});

test('live scan duration limit closes the session automatically', async (t) => {
  let stopped;
  const done = new Promise((resolve) => { stopped = resolve; });
  const { scan } = await fixture(t, { sessionDurationMs: 15, onStop: stopped });
  // The session timer is unref'ed in production; this bounded timer keeps the test alive.
  const hold = setTimeout(() => {}, 1000);
  try { await done; assert.equal(scan.closed, true); } finally { clearTimeout(hold); }
});

test('live detections are host-private and game start terminates scanning', async (t) => {
  const app = createAppServer({ liveScanOptions: { apiKey: 'test-only-key', detect: async () => objects } });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const host = await connectClient(url);
  host.send({ t: 'create', name: 'Host' });
  const identity = await host.waitFor((event) => event.t === 'joined');
  const guests = []; const guestEvents = [];
  for (let index = 0; index < 3; index += 1) {
    const guest = await connectClient(url);
    guest.socket.on('message', (raw) => guestEvents.push(JSON.parse(raw.toString())));
    guest.send({ t: 'join', name: `Guest ${index}`, room: identity.room });
    await guest.waitFor((event) => event.t === 'joined'); guests.push(guest);
  }
  guests[0].send({ t: 'scan_start' });
  await assert.rejects(guests[0].waitFor((event) => event.t === 'scan_status'), /HOST_ONLY/);
  host.send({ t: 'scan_start' });
  await host.waitFor((event) => event.t === 'scan_status' && event.state === 'ready');
  const room = app.rooms.rooms.get(identity.room); const scan = room.liveScan;
  const monitor = await (await fetch(`http://127.0.0.1:${address.port}/api/dashboard`)).text();
  assert.ok(!monitor.includes('test-only-key'));
  host.send({ t: 'scan_frame', frameId: 'live-1', timestampMs: 0, jpeg });
  const result = await host.waitFor((event) => event.t === 'scan_detections');
  assert.equal(result.frameId, 'live-1'); assert.deepEqual(result.objects, objects);
  assert.ok(!guestEvents.some((event) => event.t === 'scan_detections' || event.t === 'scan_status'));
  host.send({ t: 'start' });
  await host.waitFor((event) => event.t === 'scan_status' && event.reason === 'game_started');
  assert.equal(room.liveScan, null); assert.equal(scan.closed, true);
});

test('host disconnect stops its scan and aborts in-flight detection', async (t) => {
  let signal;
  const app = createAppServer({ liveScanOptions: { apiKey: 'test-only-key', detect: (_message, options) => {
    signal = options.signal;
    return new Promise(() => {});
  } } });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const host = await connectClient(`ws://127.0.0.1:${address.port}/ws`);
  host.send({ t: 'create', name: 'Host' });
  const identity = await host.waitFor((event) => event.t === 'joined');
  host.send({ t: 'scan_start' });
  await host.waitFor((event) => event.t === 'scan_status' && event.state === 'ready');
  host.send({ t: 'scan_frame', frameId: 'live-1', timestampMs: 0, jpeg });
  host.send({ t: 'ready', ready: true });
  await host.waitFor((event) => event.t === 'lobby' && event.players[0].ready);
  const room = app.rooms.rooms.get(identity.room);
  const stopped = new Promise((resolve) => room.players.get(identity.playerId).socket.once('close', resolve));
  host.socket.close(); await stopped;
  assert.equal(room.liveScan, null); assert.equal(signal.aborted, true);
});
