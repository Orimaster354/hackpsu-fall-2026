const test = require('node:test');
const assert = require('node:assert/strict');
const { createVideoDetector, normalizeDetections } = require('../videoLab');
const { createAppServer } = require('../index');
const mp4 = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypisom000000000000')]);
const json = (value) => new Response(JSON.stringify(value));
const videos = ['overview', 'edge'].map((pass) => ({ pass, bytes: mp4, duration: 30 }));

function provider({ quota = false, invalid = false } = {}) {
  const calls = []; let fileCount = 0;
  const fetchImpl = async (url, options = {}) => {
    calls.push({ url, options });
    if (options.method === 'DELETE') return new Response(null, { status: 204 });
    if (url.endsWith('/upload/v1beta/files')) return new Response(null, { headers: { 'x-goog-upload-url': `https://generativelanguage.googleapis.com/upload/session${++fileCount}` } });
    if (url.includes('/upload/session')) return json({ file: { name: `files/clip${fileCount}`, state: 'PROCESSING' } });
    if (url.includes('/v1beta/files/')) return json({ name: url.split('/v1beta/')[1], state: 'ACTIVE', uri: url, videoMetadata: { videoDuration: '30s' } });
    if (url.includes(':generateContent')) {
      if (quota) return new Response(null, { status: 429 });
      return json({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: invalid ? 'invalid json' : JSON.stringify([
        { pass: 'overview', label: 'Wooden table', t: 2.5, box_2d: [100, 200, 500, 800] },
        { pass: 'edge', label: 'Door', t: 8, box_2d: [0, 100, 900, 500] },
      ]) }] } }], usageMetadata: { totalTokenCount: 123 } });
    }
    throw new Error('Unexpected provider URL');
  };
  return { calls, fetchImpl };
}

test('two full videos upload, become active, share one inference request and are deleted', async () => {
  const fake = provider();
  const detector = createVideoDetector({ apiKey: 'test-key', fetchImpl: fake.fetchImpl, pollMs: 0 });
  const result = await detector.detect(videos);
  assert.deepEqual(result.passes[0].detections, [{ label: 'Wooden table', t: 2.5, box: [0.2, 0.1, 0.6, 0.4] }]);
  assert.equal(result.passes[1].detections[0].t, 8);
  const generation = fake.calls.filter((call) => call.url.includes(':generateContent'));
  assert.equal(generation.length, 1);
  const body = JSON.parse(generation[0].options.body);
  assert.equal(body.contents[0].parts.filter((part) => part.fileData).length, 2);
  assert.ok(body.contents[0].parts.filter((part) => part.fileData).every((part) => part.videoMetadata.fps === 1));
  assert.equal(fake.calls.filter((call) => call.options.method === 'DELETE').length, 2);
  assert.equal(fake.calls.filter((call) => call.options.body === mp4).length, 2);
  assert.ok(!JSON.stringify(result).includes('test-key'));
});

test('provider quota/invalid JSON failures clean up both uploaded files without fallback detections', async () => {
  for (const [option, code] of [['quota', 'GEMINI_QUOTA'], ['invalid', 'GEMINI_INVALID_RESPONSE']]) {
    const fake = provider({ [option]: true });
    await assert.rejects(createVideoDetector({ apiKey: 'test-key', fetchImpl: fake.fetchImpl, pollMs: 0 }).detect(videos), { code });
    assert.equal(fake.calls.filter((call) => call.options.method === 'DELETE').length, 2);
  }
});

test('timestamps stay in their own video and generic labels are omitted', () => {
  assert.deepEqual(normalizeDetections([{ pass: 'edge', label: 'object', t: 3, box_2d: [0, 0, 100, 100] }], { overview: 5, edge: 5 }), { overview: [], edge: [] });
  for (const item of [{ pass: 'third', t: 1 }, { pass: 'overview', t: 6 }, { pass: 'edge', t: -1 }]) {
    assert.throws(() => normalizeDetections([{ ...item, label: 'Desk', box_2d: [0, 0, 100, 100] }], { overview: 5, edge: 5 }), { code: 'GEMINI_INVALID_RESPONSE' });
  }
});

function form() {
  const value = new FormData();
  for (const pass of ['overview', 'edge']) { value.set(pass, new Blob([mp4], { type: 'video/mp4' }), `${pass}.mp4`); value.set(`${pass}Duration`, '30'); }
  return value;
}

test('local dashboard accepts two MP4 uploads, streams progress and rejects invalid/missing inputs', async (t) => {
  let calls = 0;
  const app = createAppServer({ videoDetector: { configured: true, model: 'test-model', async detect(input, { notify }) {
    calls += 1; assert.deepEqual(input, videos); notify('Analyzing test clips'); return { passes: [] };
  } } });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const base = `http://127.0.0.1:${address.port}`;
  for (const route of ['/dashboard/videos', '/dashboard/videos.js', '/dashboard/videos.css']) assert.equal((await fetch(base + route)).status, 200);
  const url = base + '/api/dashboard/video-test';
  assert.equal((await (await fetch(url)).json()).model, 'test-model');
  assert.equal((await fetch(url, { method: 'POST', body: form() })).status, 400);
  assert.equal((await fetch(url, { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1', Origin: 'https://other.example' }, body: form() })).status, 400);
  const response = await fetch(url, { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1' }, body: form() });
  const events = (await response.text()).trim().split('\n').map((line) => JSON.parse(line));
  assert.ok(events.some((event) => event.message === 'Analyzing test clips'));
  assert.equal(events.at(-1).type, 'result'); assert.equal(calls, 1);
  const missing = form(); missing.delete('edge');
  assert.equal((await fetch(url, { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1' }, body: missing })).status, 400);
  const bad = form(); bad.set('edge', new Blob(['not really an mp4 video'], { type: 'video/mp4' }), 'bad.mp4');
  assert.equal((await fetch(url, { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1' }, body: bad })).status, 400);
  assert.equal(calls, 1);
});

test('one video test at a time and cancellation reaches the detector', async (t) => {
  let entered; const started = new Promise((resolve) => { entered = resolve; });
  let aborted; const stopped = new Promise((resolve) => { aborted = resolve; });
  const app = createAppServer({ videoDetector: { configured: true, model: 'test-model', async detect(input, { signal }) {
    entered(); await new Promise((resolve) => signal.addEventListener('abort', resolve, { once: true })); aborted(); throw new Error('aborted');
  } } });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const url = `http://127.0.0.1:${address.port}/api/dashboard/video-test`;
  const controller = new AbortController();
  const first = fetch(url, { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1' }, body: form(), signal: controller.signal }).then((response) => response.text()).catch(() => {});
  await started;
  assert.equal((await fetch(url, { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1' }, body: form() })).status, 409);
  controller.abort(); await stopped; await first;
});
