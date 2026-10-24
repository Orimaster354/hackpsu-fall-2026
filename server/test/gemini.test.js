const test = require('node:test');
const assert = require('node:assert/strict');
const { createGeminiClient } = require('../gemini');
const { createAppServer } = require('../index');
const { connectClient } = require('../tools/client');

const jpeg = Buffer.from([255, 216, 255, 217]).toString('base64');
const response = (objects) => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(objects) }] } }] }));

test('Gemini adapter sends server key/JPEG to the official API and normalizes validated boxes', async () => {
  let request;
  const suggest = createGeminiClient({ apiKey: 'test-key', fetchImpl: async (url, options) => {
    request = { url, options };
    return response([{ label: 'Table', box_2d: [100, 200, 400, 800] }]);
  } });
  assert.deepEqual(await suggest({ photos: [jpeg], boxes: { image: 0 } }), [
    { label: 'Table', box: [0.2, 0.1, 0.6, 0.3] },
  ]);
  assert.match(request.url, /^https:\/\/generativelanguage.googleapis.com\/v1beta\/models\/[^/]+:generateContent$/);
  assert.equal(request.options.headers['x-goog-api-key'], 'test-key');
  const body = JSON.parse(request.options.body);
  assert.equal(body.contents[0].parts[0].inlineData.data, jpeg);
  assert.equal(body.generationConfig.responseMimeType, 'application/json');
  assert.deepEqual(body.generationConfig.thinkingConfig, { thinkingLevel: 'LOW' });
  assert.ok(!request.options.body.includes('test-key'));
});

test('Gemini adapter rejects invalid photos/configuration without calling an external service', async () => {
  let calls = 0;
  const fetchImpl = async () => { calls += 1; return response([]); };
  await assert.rejects(createGeminiClient({ apiKey: '', fetchImpl })({ photos: [jpeg] }), { code: 'GEMINI_NOT_CONFIGURED' });
  const suggest = createGeminiClient({ apiKey: 'test-key', fetchImpl });
  for (const photos of [[], [jpeg, jpeg], ['not-a-jpeg'], [Buffer.from('text').toString('base64')]]) {
    await assert.rejects(suggest({ photos }), { code: 'INVALID_PHOTO' });
  }
  assert.equal(calls, 0);
});

test('Gemini errors, invalid JSON and out-of-range boxes fail without canned stations', async () => {
  for (const [fetchImpl, code] of [
    [async () => new Response('{}', { status: 429 }), 'GEMINI_UNAVAILABLE'],
    [async () => new Response('{}'), 'GEMINI_INVALID_RESPONSE'],
    [async () => response([{ label: 'Table', box_2d: [100, 0, 2000, 500] }]), 'GEMINI_INVALID_RESPONSE'],
    [async () => { throw new DOMException('Timeout', 'TimeoutError'); }, 'GEMINI_TIMEOUT'],
  ]) {
    await assert.rejects(createGeminiClient({ apiKey: 'test-key', fetchImpl })({ photos: [jpeg] }), { code });
  }
  assert.deepEqual(await createGeminiClient({ apiKey: 'test-key', fetchImpl: async () => response([]) })({ photos: [jpeg] }), []);
});

test('suggest is host-only and sends image suggestions privately to the requesting host', async (t) => {
  let calls = 0;
  const objects = [{ label: 'Table', box: [0.2, 0.1, 0.6, 0.3] }];
  const app = createAppServer({ suggest: async () => { calls += 1; return objects; } });
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const host = await connectClient(url);
  host.send({ t: 'create', name: 'Host' });
  const identity = await host.waitFor((event) => event.t === 'joined');
  const guest = await connectClient(url);
  const guestEvents = [];
  guest.socket.on('message', (raw) => guestEvents.push(JSON.parse(raw.toString())));
  guest.send({ t: 'join', name: 'Guest', room: identity.room });
  await guest.waitFor((event) => event.t === 'joined');
  host.send({ t: 'suggest', photos: [jpeg] });
  assert.deepEqual(await host.waitFor((event) => event.t === 'suggestions'), { t: 'suggestions', objects });
  host.send({ t: 'ready', ready: true });
  await guest.waitFor((event) => event.t === 'lobby' && event.players[0].ready);
  assert.ok(!guestEvents.some((event) => event.t === 'suggestions'));
  guest.send({ t: 'suggest', photos: [jpeg] });
  await assert.rejects(guest.waitFor((event) => event.t === 'suggestions'), /HOST_ONLY/);
  assert.equal(calls, 1);
});
