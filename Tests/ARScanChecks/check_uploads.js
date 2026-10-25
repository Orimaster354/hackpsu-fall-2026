'use strict';
// Checks what the Swift side produced (run_scan_checks.sh):
//  1. the perimeter and sweep bodies satisfy the upload contract,
//  2. poses and intrinsics converted through simd matrices still reproduce the reference geometry's tiles.
// Usage: node check_uploads.js <repo root> <dir with the Swift outputs>
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const [repo, out] = process.argv.slice(2);
const { validatePerimeter, validateSweep, MAX_PERIMETER_BYTES, MAX_SWEEP_BYTES } = require('./standin/contract');
const g = require(path.join(repo, 'docs/fixtures/postit/postit-geometry.js'));

let checks = 0;
const ok = (cond, message) => { checks++; assert.ok(cond, message); };

// 1. Contract
const perimeterRaw = fs.readFileSync(path.join(out, 'perimeter-upload.json'));
ok(perimeterRaw.length <= MAX_PERIMETER_BYTES, 'perimeter body over 2 MiB');
const poses = validatePerimeter(JSON.parse(perimeterRaw));
ok(poses.length >= 199 && poses.length <= 203, `unexpected perimeter size ${poses.length}`);
ok(Math.abs(poses[0].t) < 1e-9, 'perimeter t starts at 0');

const sweepRaw = fs.readFileSync(path.join(out, 'sweep-upload.json'));
ok(sweepRaw.length <= MAX_SWEEP_BYTES, 'sweep body over 64 MiB');
const sweep = validateSweep(JSON.parse(sweepRaw));
ok(sweep.warnings.length === 0, `sweep warnings: ${sweep.warnings.join('; ')}`);
ok(sweep.frames.every((f) => f.width === 1920 && f.height === 1440), 'JPEGs are 1920x1440 landscape');

// 2. Geometry through the Swift conversions
const fx = JSON.parse(fs.readFileSync(path.join(out, 'converted-sweep.json'), 'utf8'));
const original = JSON.parse(fs.readFileSync(path.join(repo, 'docs/fixtures/postit/sweep-observations.json'), 'utf8'));
const notes = g.placeNotes({ frames: fx.frames, intrinsics: fx.intrinsics, polygon: fx.polygon, grid: fx.grid });
ok(notes.length === fx.expectedNotes.length, `expected ${fx.expectedNotes.length} notes, got ${notes.length}`);
const truth = (n) => fx.frames[n.best.frameIndex].detections[n.best.detection].noteId;
for (const expected of fx.expectedNotes) {
  const found = notes.find((n) => truth(n) === expected.noteId);
  ok(found, `note ${expected.noteId} not placed`);
  ok(found.tile.x === expected.tile.x && found.tile.y === expected.tile.y, `note ${expected.noteId}: tile ${JSON.stringify(found.tile)} != ${JSON.stringify(expected.tile)}`);
  const miss = Math.hypot(found.hit[0] - expected.wall[0], found.hit[1] - expected.wall[1]);
  ok(miss < 0.05, `note ${expected.noteId}: wall hit off by ${miss.toFixed(3)} m`);
}
// Control: the unconverted fixture gives the same answer, so a failure above is the conversion, not the geometry.
const control = g.placeNotes({ frames: original.frames, intrinsics: original.intrinsics, polygon: original.polygon, grid: original.grid });
ok(control.length === notes.length, 'control run disagrees');

console.log(`OK (node): ${checks} checks, ${notes.length} notes placed from Swift-converted poses and intrinsics`);
