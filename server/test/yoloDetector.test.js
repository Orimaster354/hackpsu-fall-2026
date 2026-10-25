const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const { PassThrough, Writable } = require('node:stream');
const { createYoloDetector, validateYoloResult, MODEL } = require('../yoloDetector');
const { createAppServer } = require('../index');
const videos = ['overview', 'edge'].map((pass) => ({ pass, bytes: Buffer.from('test video'), duration: 3, mimeType: 'video/mp4' }));
const result = () => ({ model: MODEL, passes: videos.map(({ pass, duration }) => ({ pass, duration,
  framesAnalyzed: 3, timestampSource: 'decoder presentation time', detections: [{ label: 'sticky note', t: 1,
    confidence: 0.8, frameIndex: 10, box: [0.1, 0.2, 0.03, 0.04],
    context: [{ label: 'whiteboard', box: [0.2, 0.2, 0.3, 0.4], confidence: 0.8, imageGap: 0.05 }] }] })) });

test('YOLOE adapter validates decoded-frame timestamps, class scores and normalized boxes', () => {
  assert.equal(validateYoloResult(result(), videos).passes[0].detections[0].confidence, 0.8);
  assert.equal(validateYoloResult(result(), videos).passes[0].detections[0].context[0].label, 'whiteboard');
  const grouped = result(); grouped.passes[0].detections[0].observationCount = 2;
  assert.equal(validateYoloResult(grouped, videos).passes[0].detections[0].observationCount, 2);
  for (const change of [{ t: 4 }, { box: [0.9, 0.1, 0.5, 0.5] }, { label: 'person' }, { label: 'door' },
    { context: [{ label: 'sticky note', box: [0, 0, 0.1, 0.1], confidence: 0.9, imageGap: 0.1 }] },
    { context: [{ label: 'door', box: [0, 0, 0.1, 0.1], confidence: 0.9, imageGap: 3 }] },
    { confidence: 0.2 }, { frameIndex: -1 }, { observationCount: 0 }, { observationCount: 121 }, { frameJpeg: 'not base64' }]) {
    const bad = result(); Object.assign(bad.passes[0].detections[0], change);
    assert.throws(() => validateYoloResult(bad, videos), { code: 'YOLOE_INVALID_RESPONSE' });
  }
  const duplicate = result(); duplicate.passes[1].pass = 'overview';
  assert.throws(() => validateYoloResult(duplicate, videos), { code: 'YOLOE_INVALID_RESPONSE' });
});

test('YOLOE validation accepts one overview and rejects fabricated extra or missing passes', () => {
  const single = result(); single.passes = single.passes.slice(0, 1);
  assert.equal(validateYoloResult(single, videos.slice(0, 1)).passes.length, 1);
  assert.throws(() => validateYoloResult(result(), videos.slice(0, 1)), { code: 'YOLOE_INVALID_RESPONSE' });
  assert.throws(() => validateYoloResult(single, videos), { code: 'YOLOE_INVALID_RESPONSE' });
});

function fakeProcess({ hold = false, broken = false } = {}) {
  let specs; let started;
  const entered = new Promise((resolve) => { started = resolve; });
  const spawnImpl = (program, args, options) => {
    assert.equal(program, process.execPath); assert.equal(options.windowsHide, true);
    assert.ok(args[0].endsWith('yoloe_worker.py')); assert.ok(!options.env.GEMINI_API_KEY);
    const child = new EventEmitter();
    child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.kill = () => { process.nextTick(() => child.emit('close', null)); };
    child.stdin = new Writable({ write(chunk, encoding, done) {
      specs = JSON.parse(chunk.toString()).videos;
      assert.ok(specs.every((spec) => fs.existsSync(spec.path)));
      started(); done();
      process.nextTick(() => {
        child.stdout.write(`${JSON.stringify({ type: 'progress', message: 'Fake local inference' })}\n`);
        if (!hold) {
          child.stdout.write(broken ? 'not-json\n' : `${JSON.stringify({ type: 'result', ...result() })}\n`);
          if (!broken) child.emit('close', 0);
        }
      });
    } });
    return child;
  };
  return { spawnImpl, entered, paths: () => specs.map((spec) => spec.path) };
}

test('local worker results stream to the adapter and temporary media are removed', async () => {
  const fake = fakeProcess(); const progress = [];
  const detector = createYoloDetector({ pythonPath: process.execPath, ready: true, spawnImpl: fake.spawnImpl });
  assert.equal(detector.configured, true);
  const output = await detector.detect(videos, { notify: (text) => progress.push(text) });
  assert.equal(output.model, MODEL); assert.ok(progress.includes('Fake local inference'));
  assert.ok(fake.paths().every((file) => !fs.existsSync(file)));
});

test('cancellation and invalid worker output remove local temporary uploads', async () => {
  for (const broken of [false, true]) {
    const fake = fakeProcess({ hold: !broken, broken });
    const detector = createYoloDetector({ pythonPath: process.execPath, ready: true, spawnImpl: fake.spawnImpl });
    const controller = new AbortController();
    const pending = detector.detect(videos, { signal: controller.signal });
    const checked = assert.rejects(pending, { code: broken ? 'YOLOE_INVALID_RESPONSE' : 'YOLOE_CANCELLED' });
    await fake.entered;
    if (!broken) controller.abort();
    await checked;
    assert.ok(fake.paths().every((file) => !fs.existsSync(file)));
  }
});

test('dashboard can choose local YOLOE without a configured Gemini key', async (t) => {
  let calls = 0; let planningCalls = 0; let failPlanning = false;
  const app = createAppServer({ videoDetector: { configured: false, model: 'not-configured' },
    yoloDetector: { configured: true, model: MODEL, async detect(input) { calls += 1; assert.equal(input.length, 2); return { ...result(), elapsedMs: 1 }; } },
    stationPlanner: { configured: true, model: 'test-reasoning', async plan(detections) {
      planningCalls += 1; assert.equal(detections.model, MODEL);
      if (failPlanning) throw new Error('provider failed');
      return { status: 'needs_geometry', placementReady: false, suggestions: [], summary: 'Review candidates before physical placement.' };
    } } });
  const address = await app.listen(0, '127.0.0.1'); t.after(() => app.close());
  const url = `http://127.0.0.1:${address.port}/api/dashboard/video-test`;
  const config = await (await fetch(url)).json();
  assert.equal(config.detectors.yoloe.configured, true); assert.equal(config.detectors.gemini.configured, false);
  assert.equal(config.defaultDetector, 'yoloe');
  const header = Buffer.from([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0]);
  const movie = Buffer.alloc(36); movie.writeUInt32BE(36); movie.write('moov', 4); movie.writeUInt32BE(28, 8); movie.write('mvhd', 12);
  movie.writeUInt32BE(1000, 28); movie.writeUInt32BE(3000, 32);
  const body = new FormData(); // Omitting detector now defaults to the primary local YOLOE model.
  for (const pass of ['overview', 'edge']) body.set(pass, new Blob([header, movie], { type: 'video/mp4' }), `${pass}.mp4`);
  const response = await fetch(url, { method: 'POST', headers: { 'X-Blindspot-Video-Test': '1' }, body });
  assert.equal(response.status, 200); assert.match(await response.text(), /yoloe-26s-seg.pt/); assert.equal(calls, 1);
  assert.equal(planningCalls, 0);
  body.set('reasoning', '1');
  const planned = await fetch(url, { method: 'POST', headers: { 'X-Blindspot-Video-Test': '1' }, body });
  const plannedEvents = (await planned.text()).trim().split('\n').map(JSON.parse);
  assert.equal(plannedEvents.at(-1).planning.status, 'needs_geometry');
  failPlanning = true;
  const failed = await fetch(url, { method: 'POST', headers: { 'X-Blindspot-Video-Test': '1' }, body });
  const retained = (await failed.text()).trim().split('\n').map(JSON.parse).at(-1);
  assert.equal(retained.type, 'result'); assert.equal(retained.planning.status, 'unavailable');
  assert.equal(retained.passes.length, 2); assert.equal(planningCalls, 2);
  body.set('detector', 'unknown');
  const bad = await fetch(url, { method: 'POST', headers: { 'X-Blindspot-Video-Test': '1' }, body });
  assert.equal(bad.status, 400); assert.match(await bad.text(), /INVALID_DETECTOR/);
});
