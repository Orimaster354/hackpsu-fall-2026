'use strict';
// Verifies the reference geometry against the fixture. Run: node check-geometry.js
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const g = require('./postit-geometry');

const fx = JSON.parse(fs.readFileSync(path.join(__dirname, 'sweep-observations.json'), 'utf8'));
const notes = g.placeNotes({ frames: fx.frames, intrinsics: fx.intrinsics, polygon: fx.polygon, grid: fx.grid });

// Ground truth: which note each observation really was.
const truth = (n) => fx.frames[n.best.frameIndex].detections[n.best.detection].noteId;
assert.equal(notes.length, fx.expectedNotes.length, `expected ${fx.expectedNotes.length} physical notes, got ${notes.length}`);
for (const expected of fx.expectedNotes) {
  const found = notes.find((n) => truth(n) === expected.noteId);
  assert.ok(found, `note ${expected.noteId} was not placed`);
  assert.deepEqual(found.tile, expected.tile, `note ${expected.noteId}: tile ${JSON.stringify(found.tile)} != ${JSON.stringify(expected.tile)}`);
  const miss = Math.hypot(found.hit[0] - expected.wall[0], found.hit[1] - expected.wall[1]);
  assert.ok(miss < 0.05, `note ${expected.noteId}: wall hit off by ${miss.toFixed(3)} m`);
  const merged = fx.frames.filter((f) => f.detections.some((d) => d.noteId === expected.noteId)).length;
  assert.equal(found.observations.length, merged, `note ${expected.noteId}: ${found.observations.length} merged observations, expected ${merged}`);
}
for (const n of notes) assert.ok(fx.grid.edge.some((e) => e.x === n.tile.x && e.y === n.tile.y), 'every placed tile is an edge tile');

// Pixel -> ray -> pixel round trip.
const pose = fx.frames[7].pose;
const [dx, dy, dz] = g.pixelToWorldDirection(pose, fx.intrinsics, 1234, 321);
const back = g.worldToPixel(pose, fx.intrinsics, [pose.x + dx * 3, pose.y + dy * 3, pose.z + dz * 3]);
assert.ok(Math.abs(back.u - 1234) < 0.01 && Math.abs(back.v - 321) < 0.01, 'pixel round trip');

// Rays pointing at the floor or ceiling carry no usable bearing and are skipped.
assert.equal(g.placeObservation({ pose: { ...pose, qx: 0.7071, qy: 0, qz: 0, qw: 0.7071 }, intrinsics: fx.intrinsics,
  box: [940, 520, 40, 40], polygon: fx.polygon, grid: fx.grid }), null, 'steep ray is ignored');

// Spacing: 2 m Euclidean between tile centers. (0,1) and (0,4) are 3 apart; (3,0) and (4,0) are 1 apart.
const picks = g.enforceSpacing([{ id: 'a', tile: { x: 3, y: 0 } }, { id: 'b', tile: { x: 4, y: 0 } }, { id: 'c', tile: { x: 0, y: 1 } },
  { id: 'd', tile: { x: 0, y: 4 } }, { id: 'e', tile: { x: 4, y: 3 } }]);
assert.deepEqual(picks.map((p) => p.id), ['a', 'c', 'd', 'e']);

console.log(`OK: ${notes.length} notes placed from ${fx.frames.reduce((s, f) => s + f.detections.length, 0)} observations, all tiles match`);
