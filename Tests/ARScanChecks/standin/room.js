'use strict';
// TEST STAND-IN for the server's perimeter -> polygon -> grid step (docs/architecture.md, "Server scan processing").
// It handles convex rooms only: the real server (owner C) simplifies the actual path and handles mild
// non-convexity. Good enough to give the app a real grid built from a real walk.
const { ContractError } = require('./contract');

const WALL_OFFSET_M = 0.5;
const CLOSE_GAP_M = 0.75;
const MIN_AREA_M2 = 4;

const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);

function convexHull(points) {
  const pts = [...points].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  if (pts.length < 3) return pts;
  const lower = [];
  for (const p of pts) {
    while (lower.length >= 2 && cross(lower.at(-2), lower.at(-1), p) <= 0) lower.pop();
    lower.push(p);
  }
  const upper = [];
  for (const p of [...pts].reverse()) {
    while (upper.length >= 2 && cross(upper.at(-2), upper.at(-1), p) <= 0) upper.pop();
    upper.push(p);
  }
  return lower.slice(0, -1).concat(upper.slice(0, -1)); // counter-clockwise
}

function area(poly) {
  let sum = 0;
  for (let i = 0; i < poly.length; i++) {
    const [ax, az] = poly[i], [bx, bz] = poly[(i + 1) % poly.length];
    sum += ax * bz - bx * az;
  }
  return sum / 2;
}

function centroid(poly) {
  let cx = 0, cz = 0, a = 0;
  for (let i = 0; i < poly.length; i++) {
    const [ax, az] = poly[i], [bx, bz] = poly[(i + 1) % poly.length];
    const f = ax * bz - bx * az;
    cx += (ax + bx) * f; cz += (az + bz) * f; a += f;
  }
  return [cx / (3 * a), cz / (3 * a)];
}

// Outward offset of a counter-clockwise convex polygon.
function offsetConvex(poly, d) {
  const lines = poly.map((a, i) => {
    const b = poly[(i + 1) % poly.length];
    const dx = b[0] - a[0], dz = b[1] - a[1], len = Math.hypot(dx, dz);
    const n = [dz / len, -dx / len]; // outward for counter-clockwise
    return { p: [a[0] + n[0] * d, a[1] + n[1] * d], d: [dx, dz] };
  });
  return lines.map((l2, i) => {
    const l1 = lines[(i - 1 + lines.length) % lines.length];
    const denom = l1.d[0] * l2.d[1] - l1.d[1] * l2.d[0];
    const t = ((l2.p[0] - l1.p[0]) * l2.d[1] - (l2.p[1] - l1.p[1]) * l2.d[0]) / denom;
    return [l1.p[0] + l1.d[0] * t, l1.p[1] + l1.d[1] * t];
  });
}

function inside(poly, x, z) {
  let c = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, zi] = poly[i], [xj, zj] = poly[j];
    if ((zi > z) !== (zj > z) && x < ((xj - xi) * (z - zi)) / (zj - zi) + xi) c = !c;
  }
  return c;
}

const scanFailed = (message) => new ContractError(422, 'SCAN_FAILED', message);

// poses: validated perimeter samples. Returns { polygon, grid, emergency } like the real server's setup step.
function gridFromPerimeter(poses) {
  const first = poses[0], last = poses.at(-1);
  const gap = Math.hypot(first.x - last.x, first.z - last.z);
  if (gap > CLOSE_GAP_M) throw scanFailed(`The walk ends ${gap.toFixed(2)} m from where it started (limit ${CLOSE_GAP_M} m).`);
  const hull = convexHull(poses.map((p) => [p.x, p.z]));
  if (hull.length < 3 || area(hull) < MIN_AREA_M2) throw scanFailed(`The enclosed area is ${hull.length < 3 ? 0 : area(hull).toFixed(1)} m², under ${MIN_AREA_M2} m².`);
  const polygon = offsetConvex(hull, WALL_OFFSET_M);
  const xs = polygon.map((p) => p[0]), zs = polygon.map((p) => p[1]);
  const originX = Math.min(...xs), originZ = Math.min(...zs);
  const cols = Math.ceil(Math.max(...xs) - originX - 1e-6), rows = Math.ceil(Math.max(...zs) - originZ - 1e-6);
  if (cols > 100 || rows > 100) throw scanFailed(`The room is ${cols} x ${rows} tiles; the grid limit is 100.`);
  const key = (x, y) => `${x},${y}`;
  const playable = [];
  const playableSet = new Set();
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    if (inside(polygon, originX + x + 0.5, originZ + y + 0.5)) { playable.push({ x, y }); playableSet.add(key(x, y)); }
  }
  if (!playable.length) throw scanFailed('No tile of the grid is inside the walked outline.');
  const edge = playable.filter(({ x, y }) => [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dy]) => !playableSet.has(key(x + dx, y + dy))));
  const [mx, mz] = centroid(polygon);
  const emergency = playable.reduce((best, t) => {
    const d = Math.hypot(originX + t.x + 0.5 - mx, originZ + t.y + 0.5 - mz);
    return !best || d < best.d - 1e-9 || (Math.abs(d - best.d) <= 1e-9 && (t.y < best.t.y || (t.y === best.t.y && t.x < best.t.x))) ? { t, d } : best;
  }, null).t;
  return { polygon, emergency, grid: { cols, rows, tileSize: 1, originX, originZ, playable, edge } };
}

module.exports = { gridFromPerimeter, convexHull, WALL_OFFSET_M };
