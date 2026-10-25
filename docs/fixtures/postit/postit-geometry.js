'use strict';
// Reference implementation of the sticky-note placement geometry (docs/architecture.md, "Sticky-note scan").
// Dependency-free so server/ can port it as is. Units are meters in the host's ARKit world frame
// (y up, floor plane = x/z, camera looks along its own -z axis).

const NUDGE_M = 0.01;       // step back from the wall so a hit on the far boundary stays inside the grid
const MAX_RANGE_M = 15;     // ignore rays that travel farther than this before hitting a wall
const MERGE_RADIUS_M = 0.75; // observations whose wall hits are this close are one physical note
const MIN_HORIZONTAL = 0.2; // ignore rays that point mostly up or down (no usable bearing on the floor plane)

// Rotates v by the unit quaternion (qx,qy,qz,qw).
function rotate({ qx, qy, qz, qw }, v) {
  const [x, y, z] = v;
  const tx = 2 * (qy * z - qz * y);
  const ty = 2 * (qz * x - qx * z);
  const tz = 2 * (qx * y - qy * x);
  return [x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)];
}

function conjugate(q) { return { qx: -q.qx, qy: -q.qy, qz: -q.qz, qw: q.qw }; }

// Pixel (u right, v down) in the image the intrinsics describe -> world-space ray direction.
function pixelToWorldDirection(pose, intrinsics, u, v) {
  const { fx, fy, cx, cy } = intrinsics;
  return rotate(pose, [(u - cx) / fx, -(v - cy) / fy, -1]);
}

// World point -> pixel, or null when it is behind the camera. Used to build synthetic fixtures.
function worldToPixel(pose, intrinsics, point) {
  const rel = [point[0] - pose.x, point[1] - pose.y, point[2] - pose.z];
  const [x, y, z] = rotate(conjugate(pose), rel);
  if (z >= -1e-6) return null;
  return { u: intrinsics.cx + (intrinsics.fx * x) / -z, v: intrinsics.cy - (intrinsics.fy * y) / -z };
}

// First intersection of the horizontal ray (origin ox,oz; direction dx,dz) with the closed polygon [[x,z],...].
function rayToBoundary(ox, oz, dx, dz, polygon) {
  let best = null;
  for (let i = 0; i < polygon.length; i++) {
    const [ax, az] = polygon[i];
    const [bx, bz] = polygon[(i + 1) % polygon.length];
    const ex = bx - ax, ez = bz - az;
    const denom = dx * ez - dz * ex;
    if (Math.abs(denom) < 1e-9) continue;
    const t = ((ax - ox) * ez - (az - oz) * ex) / denom;   // distance along the ray
    const s = ((ax - ox) * dz - (az - oz) * dx) / denom;   // position along the edge, 0..1
    if (t > 1e-6 && s >= -1e-9 && s <= 1 + 1e-9 && (best === null || t < best)) best = t;
  }
  return best;
}

// grid: { cols, rows, tileSize, originX, originZ, edge:[{x,y}] }
function tileOf(grid, px, pz) {
  const x = Math.floor((px - grid.originX) / grid.tileSize);
  const y = Math.floor((pz - grid.originZ) / grid.tileSize);
  return { x: Math.min(Math.max(x, 0), grid.cols - 1), y: Math.min(Math.max(y, 0), grid.rows - 1) };
}

function nearestEdgeTile(grid, tile) {
  const key = (t) => `${t.x},${t.y}`;
  if (grid.edge.some((e) => key(e) === key(tile))) return tile;
  let best = null, bestD = Infinity;
  for (const e of grid.edge) {
    const d = (e.x - tile.x) ** 2 + (e.y - tile.y) ** 2;
    if (d < bestD) { bestD = d; best = e; }
  }
  return best;
}

// One detection (box [x,y,w,h] in pixels of the sent image) in one frame -> wall hit + edge tile, or null.
function placeObservation({ pose, intrinsics, box, polygon, grid }) {
  const u = box[0] + box[2] / 2, v = box[1] + box[3] / 2;
  const [dx, dy, dz] = pixelToWorldDirection(pose, intrinsics, u, v);
  const horizontal = Math.hypot(dx, dz);
  if (horizontal / Math.hypot(dx, dy, dz) < MIN_HORIZONTAL) return null;
  const ux = dx / horizontal, uz = dz / horizontal;
  const t = rayToBoundary(pose.x, pose.z, ux, uz, polygon);
  if (t === null || t > MAX_RANGE_M) return null;
  const hit = [pose.x + ux * t, pose.z + uz * t];
  const inside = [pose.x + ux * (t - NUDGE_M), pose.z + uz * (t - NUDGE_M)];
  return { hit, tile: nearestEdgeTile(grid, tileOf(grid, inside[0], inside[1])), range: t };
}

// Frames: [{ index, t, pose, detections:[{ label, box, confidence }] }]. Returns one entry per physical note:
// observations whose wall hits are within MERGE_RADIUS_M merge; the strongest observation represents the note.
function placeNotes({ frames, intrinsics, polygon, grid, minConfidence = 0.50 }) {
  const observations = [];
  for (const frame of frames) {
    frame.detections.forEach((detection, d) => {
      if (detection.confidence != null && detection.confidence < minConfidence) return;
      const placed = placeObservation({ pose: frame.pose, intrinsics, box: detection.box, polygon, grid });
      if (placed) observations.push({ ...placed, frameIndex: frame.index, detection: d, confidence: detection.confidence ?? 0 });
    });
  }
  observations.sort((a, b) => b.confidence - a.confidence);
  const notes = [];
  for (const o of observations) {
    const home = notes.find((n) => Math.hypot(n.hit[0] - o.hit[0], n.hit[1] - o.hit[1]) <= MERGE_RADIUS_M);
    if (home) { home.observations.push({ frameIndex: o.frameIndex, detection: o.detection }); continue; }
    notes.push({ hit: o.hit, tile: o.tile, confidence: o.confidence, best: { frameIndex: o.frameIndex, detection: o.detection },
      observations: [{ frameIndex: o.frameIndex, detection: o.detection }] });
  }
  return notes;
}

// Greedy selection in the planner's preference order, keeping station centers >= minSpacing apart (Euclidean, meters).
function enforceSpacing(tiles, tileSize = 1, minSpacing = 2) {
  const kept = [];
  for (const item of tiles) {
    const clash = kept.some((k) => Math.hypot(k.tile.x - item.tile.x, k.tile.y - item.tile.y) * tileSize < minSpacing - 1e-9);
    if (!clash) kept.push(item);
  }
  return kept;
}

module.exports = { rotate, conjugate, pixelToWorldDirection, worldToPixel, rayToBoundary, tileOf, nearestEdgeTile,
  placeObservation, placeNotes, enforceSpacing, NUDGE_M, MAX_RANGE_M, MERGE_RADIUS_M };
