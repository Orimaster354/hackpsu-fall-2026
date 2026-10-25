const test = require('node:test');
const assert = require('node:assert/strict');
const { createStationPlanner, planningCandidates, validatePlan } = require('../stationPlanner');
const result = { passes: [{ pass: 'overview', detections: [
  { label: 'chair', t: 1, box: [0, 0, 0.2, 0.2], confidence: 0.9, frameJpeg: 'PRIVATE_IMAGE_BYTES' },
  { label: 'desk', t: 2, box: [0.2, 0.2, 0.4, 0.4], confidence: 0.7 },
] }, { pass: 'edge', detections: [{ label: 'door', t: 3, box: [0.4, 0.4, 0.2, 0.2], confidence: 0.6 }] }] };
const valid = { summary: 'Review these landmarks; physical positions are not known.',
  suggestions: [{ candidateId: 'overview:1', kind: 'task', task: 'hold', reason: 'The detected desk is a recognizable candidate; confirm it in person.' }] };

test('station reasoning sends only detection metadata, never frame images or arbitrary coordinates', async () => {
  let request;
  const planner = createStationPlanner({ apiKey: 'test-key', fetchImpl: async (url, options) => {
    request = { url, options };
    return new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify(valid) }] } }] }));
  } });
  const plan = await planner.plan(result);
  assert.equal(plan.status, 'needs_geometry'); assert.equal(plan.placementReady, false);
  assert.equal(plan.suggestions[0].label, 'desk'); assert.equal(plan.suggestions[0].pass, 'overview');
  assert.ok(!request.options.body.includes('PRIVATE_IMAGE_BYTES'));
  assert.ok(!request.options.body.includes('test-key'));
  const body = JSON.parse(request.options.body);
  assert.equal(body.contents[0].parts.length, 1);
  assert.equal(JSON.parse(body.contents[0].parts[0].text).geometryAvailable, false);
  assert.equal(request.options.headers['x-goog-api-key'], 'test-key');
});

test('reasoning rejects unknown IDs, duplicate IDs, emergency placement and invented tiles', () => {
  const candidates = planningCandidates(result);
  for (const change of [{ candidateId: 'invented:0' }, { kind: 'emergency' }, { task: 'climb' }, { tile: { x: 1, y: 1 } }]) {
    assert.throws(() => validatePlan({ ...valid, suggestions: [{ ...valid.suggestions[0], ...change }] }, candidates), { code: 'PLANNER_INVALID_RESPONSE' });
  }
  assert.throws(() => validatePlan({ ...valid, suggestions: [valid.suggestions[0], valid.suggestions[0]] }, candidates), { code: 'PLANNER_INVALID_RESPONSE' });
});

test('empty detections skip Gemini and model failures remain explicit', async () => {
  let calls = 0;
  const planner = createStationPlanner({ apiKey: 'test-key', fetchImpl: async () => { calls += 1; return new Response(null, { status: 429 }); } });
  const empty = await planner.plan({ passes: [{ pass: 'overview', detections: [] }, { pass: 'edge', detections: [] }] });
  assert.equal(empty.status, 'no_candidates'); assert.equal(calls, 0);
  await assert.rejects(planner.plan(result), { code: 'PLANNER_QUOTA' }); assert.equal(calls, 1);
});

test('planner shortlist excludes weak YOLO scores and repeated labels without changing detection IDs', () => {
  const candidates = planningCandidates({ passes: [{ pass: 'overview', detections: [
    { label: 'chair', t: 1, box: [0, 0, 0.2, 0.2], confidence: 0.6 },
    { label: 'television', t: 2, box: [0, 0, 0.2, 0.2], confidence: 0.49 },
  ] }, { pass: 'edge', detections: [{ label: 'chair', t: 3, box: [0, 0, 0.2, 0.2], confidence: 0.9 }] }] });
  assert.equal(candidates.length, 1); assert.equal(candidates[0].id, 'edge:0');
});
