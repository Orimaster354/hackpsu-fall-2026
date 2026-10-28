const test = require('node:test');
const assert = require('node:assert/strict');
const { selectStations } = require('../sweep');
const { validateRoomSetup } = require('../contracts');

const note = (i, x, y, confidence) => ({ id: `sweep:${i}`, tile: { x, y }, confidence, context: [] });
const notes = [note(0, 0, 1, 0.9), note(1, 4, 1, 0.8), note(2, 1, 4, 0.7), note(3, 4, 4, 0.6), note(4, 2, 0, 0.5)];
const emergency = { tile: { x: 2, y: 2 } };
const taskTypes = (stations) => stations.filter((s) => s.kind === 'task').map((s) => s.task);

test('task stations never repeat a task type, even when Gemini repeats one', () => {
  const stations = selectStations(notes, [
    { candidateId: 'sweep:0', kind: 'task', task: 'hold' },
    { candidateId: 'sweep:1', kind: 'task', task: 'hold' },
    { candidateId: 'sweep:2', kind: 'task', task: 'hold' },
    { candidateId: 'sweep:3', kind: 'fix', task: 'hold' },
  ], emergency);
  const tasks = taskTypes(stations);
  assert.equal(tasks.length, 4, 'five spaced notes give four tasks and one fix');
  assert.equal(new Set(tasks).size, tasks.length, `repeat in ${tasks}`);
  assert.equal(tasks[0], 'hold', 'the first station keeps the type Gemini chose');
});

test('score-ranked fallback also gives each task station a different type', () => {
  const tasks = taskTypes(selectStations(notes, [], emergency));
  assert.equal(new Set(tasks).size, tasks.length);
});

test('hammer and gesture are valid task types for a station', () => {
  const grid = { cols: 5, rows: 5, tileSize: 1, originX: 0, originZ: 0,
    playable: Array.from({ length: 25 }, (_, i) => ({ x: i % 5, y: Math.floor(i / 5) })),
    edge: Array.from({ length: 25 }, (_, i) => ({ x: i % 5, y: Math.floor(i / 5) })).filter((t) => t.x === 0 || t.y === 0 || t.x === 4 || t.y === 4) };
  const stations = [
    { id: 'emergency', name: 'EMERGENCY', tile: { x: 2, y: 2 }, task: 'hold', kind: 'emergency' },
    { id: 'a', name: 'Hammer', tile: { x: 0, y: 0 }, task: 'hammer', kind: 'task' },
    { id: 'b', name: 'Pattern', tile: { x: 4, y: 0 }, task: 'gesture', kind: 'task' },
  ];
  const result = validateRoomSetup(grid, stations);
  assert.deepEqual(result.stations.map((s) => s.task), ['hold', 'hammer', 'gesture']);
  assert.throws(() => validateRoomSetup(grid, stations.map((s) =>
    s.id === 'a' ? { ...s, task: 'tilt' } : s)), { code: 'INVALID_STATIONS' });
});


test('fallback and obsolete Tilt suggestions never assign the removed ball task', () => {
  for (const suggestions of [[], [
    { candidateId: 'sweep:0', kind: 'task', task: 'tilt' },
    { candidateId: 'sweep:1', kind: 'task', task: 'tilt' },
  ]]) {
    const tasks = taskTypes(selectStations(notes, suggestions, emergency));
    assert.equal(tasks.length, 4);
    assert.ok(!tasks.includes('tilt'));
    assert.equal(new Set(tasks).size, tasks.length);
  }
});
