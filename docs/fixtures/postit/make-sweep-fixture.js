'use strict';
// Builds sweep-observations.json: a host standing on tile (2,2) of the 5x5 m fixture room spins 360 degrees and
// "detects" six sticky notes. Boxes come from projecting known wall points into each frame, so the reference
// geometry in postit-geometry.js must recover the same tiles. Run: node make-sweep-fixture.js
const fs = require('node:fs');
const path = require('node:path');
const { worldToPixel } = require('./postit-geometry');

const setup = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'setup.json'), 'utf8'));
const intrinsics = { fx: 1450, fy: 1450, cx: 960, cy: 540, width: 1920, height: 1080 };
const camera = { x: 2.0, y: 1.4, z: 2.0 };
const r = (n) => Math.round(n * 1000) / 1000;
const r6 = (n) => Math.round(n * 1e6) / 1e6;

// Wall points (x, height, z) on the room boundary x/z in {-0.5, 4.5}.
const notes = [
  { id: 'N1', world: [-0.5, 1.3, 1.2], tile: { x: 0, y: 1 }, context: { label: 'whiteboard', gap: 0.02 } },
  { id: 'N2', world: [2.9, 1.2, -0.5], tile: { x: 3, y: 0 }, context: { label: 'door', gap: 0.03 } },
  { id: 'N3', world: [4.5, 1.4, 3.0], tile: { x: 4, y: 3 }, context: null },
  { id: 'N4', world: [1.0, 1.3, 4.5], tile: { x: 1, y: 4 }, context: { label: 'whiteboard', gap: 0.015 } },
  { id: 'N5', world: [-0.5, 1.2, 3.7], tile: { x: 0, y: 4 }, context: null },
  { id: 'N6', world: [3.9, 1.3, -0.5], tile: { x: 4, y: 0 }, context: { label: 'window', gap: 0.05 } },
];

const frames = [];
for (let i = 0; i < 36; i++) {
  const yaw = (i * 10 * Math.PI) / 180;
  const pose = { x: camera.x, y: camera.y, z: camera.z, qx: 0, qy: r6(Math.sin(yaw / 2)), qz: 0, qw: r6(Math.cos(yaw / 2)) };
  const detections = [];
  for (const note of notes) {
    const p = worldToPixel(pose, intrinsics, note.world);
    if (!p || p.u < 30 || p.u > intrinsics.width - 30 || p.v < 30 || p.v > intrinsics.height - 30) continue;
    const entry = { noteId: note.id, label: 'sticky note', confidence: r(0.75 + 0.02 * ((i + note.id.charCodeAt(1)) % 9)),
      box: [r(p.u - 20), r(p.v - 20), 40, 40] };
    if (note.context) entry.context = [{ label: note.context.label, confidence: 0.8, imageGap: note.context.gap,
      box: [r(p.u + 40), r(p.v - 120), 160, 220] }];
    detections.push(entry);
  }
  frames.push({ index: i, t: r(i * 0.4), pose, detections });
}

const fixture = {
  description: 'Synthetic sweep from tile (2,2): 36 frames, 10 degrees apart. noteId is ground truth for the checker only; the server never receives it.',
  vantage: { x: 2, y: 2 },
  intrinsics,
  polygon: [[-0.5, -0.5], [4.5, -0.5], [4.5, 4.5], [-0.5, 4.5]],
  grid: setup.grid,
  frames,
  expectedNotes: notes.map((n) => ({ noteId: n.id, tile: n.tile, wall: [n.world[0], n.world[2]] })),
};
fs.writeFileSync(path.join(__dirname, 'sweep-observations.json'), JSON.stringify(fixture) + '\n');
console.log('frames', frames.length, 'detections', frames.reduce((s, f) => s + f.detections.length, 0));
