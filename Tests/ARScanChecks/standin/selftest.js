'use strict';
// Proves the stand-in itself: real lobby over WebSocket, the two scan routes, the rejection cases, and that the
// colour detector plus reference geometry recover the 6 note tiles from rendered JPEGs of the reference fixture.
// Needs Node 22+ and `cd server && npm install` (for the real server's `ws`). Run: node selftest.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const repo = path.resolve(__dirname, '../../..');
const { createStandIn } = require('./server');

const poses = JSON.parse(fs.readFileSync(path.join(repo, 'docs/fixtures/poses.json'), 'utf8'));
const fixture = JSON.parse(fs.readFileSync(path.join(repo, 'docs/fixtures/postit/sweep-observations.json'), 'utf8'));
let checks = 0;
const ok = (cond, message) => { checks++; assert.ok(cond, message); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'standin-'));
  const app = createStandIn({ outDir: path.join(work, 'captures'), log: () => {} });
  const address = await app.listen(0, '127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const socket = new WebSocket(`ws://127.0.0.1:${address.port}/ws`);
  const inbox = [];
  socket.onmessage = (event) => inbox.push(JSON.parse(event.data));
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  const waitFor = async (pred, label, ms = 5000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) { const hit = inbox.find(pred); if (hit) return hit; await sleep(20); }
    throw new Error(`timed out waiting for ${label}; got ${inbox.map((m) => m.t).join(',')}`);
  };
  const post = (route, body, headers = {}) => fetch(`${base}${route}`, {
    method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body),
  });

  try {
    socket.send(JSON.stringify({ t: 'create', name: 'Host' }));
    const joined = await waitFor((m) => m.t === 'joined', 'joined');
    const room = joined.room, host = { 'x-player-id': joined.playerId };
    const lobby = await waitFor((m) => m.t === 'lobby', 'lobby');
    ok(lobby.hostId === joined.playerId && lobby.grid === null, 'new room has a host and no grid');

    // Rejections
    let res = await post(`/scan/${room}/perimeter`, { poses }, { 'x-player-id': 'someone-else' });
    ok(res.status === 403 && (await res.json()).code === 'HOST_ONLY', 'non-host is refused');
    res = await post(`/scan/${room}/sweep`, { vantage: { x: 2, y: 2 }, intrinsics: fixture.intrinsics, frames: [] }, host);
    ok(res.status === 409 && (await res.json()).code === 'SETUP_MISSING', 'sweep before perimeter is refused');
    res = await post(`/scan/${room}/perimeter`, { poses: poses.slice(0, 50) }, host);
    ok(res.status === 400 && (await res.json()).code === 'SCAN_UPLOAD_INVALID', 'fewer than 100 poses is refused');
    const line = Array.from({ length: 200 }, (_, i) => ({ t: i / 10, x: i / 20, y: 1.4, z: 0, qx: 0, qy: 0, qz: 0, qw: 1 }));
    res = await post(`/scan/${room}/perimeter`, { poses: line }, host);
    ok(res.status === 422 && (await res.json()).code === 'SCAN_FAILED', 'an open walk is SCAN_FAILED');
    res = await post(`/scan/NOPE`.replace('NOPE', 'ZZZZ') + '/perimeter', { poses }, host);
    ok(res.status === 404, 'unknown room is 404');

    // Perimeter
    res = await post(`/scan/${room}/perimeter`, { poses }, host);
    const peri = await res.json();
    ok(res.status === 200 && peri.ok && peri.cols === 5 && peri.rows === 5 && peri.edgeTiles === 16, `perimeter result ${JSON.stringify(peri)}`);
    const setup = await waitFor((m) => m.t === 'setup' && m.grid, 'setup with a grid');
    ok(setup.grid.originX === -0.5 && setup.grid.originZ === -0.5, `origin (${setup.grid.originX}, ${setup.grid.originZ})`);
    ok(setup.stations.length === 1 && setup.stations[0].kind === 'emergency', 'setup carries only the emergency station');
    const steps = inbox.filter((m) => m.t === 'processing').map((m) => m.step);
    ok(steps.includes('polygon'), 'a processing event was broadcast');

    // Sweep from rendered fixture JPEGs
    const imageDir = path.join(work, 'images');
    fs.mkdirSync(imageDir);
    execFileSync('python3', ['-I', path.join(__dirname, 'render_fixture.py'), path.join(repo, 'docs/fixtures/postit/sweep-observations.json'), imageDir]);
    const frames = fixture.frames.map((f) => ({
      index: f.index, t: f.t, pose: f.pose,
      jpeg: fs.readFileSync(path.join(imageDir, `frame-${String(f.index).padStart(3, '0')}.jpg`)).toString('base64'),
    }));
    const body = { vantage: fixture.vantage, intrinsics: fixture.intrinsics, frames };

    res = await post(`/scan/${room}/sweep`, { ...body, intrinsics: { ...fixture.intrinsics, width: 1900 } }, host);
    ok(res.status === 400 && /intrinsics/.test((await res.json()).message), 'JPEG size must match the intrinsics');
    res = await post(`/scan/${room}/sweep`, { ...body, frames: frames.slice(0, 5) }, host);
    ok(res.status === 400, 'fewer than 8 frames is refused');

    res = await post(`/scan/${room}/sweep`, body, host);
    const sweep = await res.json();
    ok(res.status === 200 && sweep.ok, `sweep result ${JSON.stringify(sweep)}`);
    ok(sweep.notesFound === fixture.expectedNotes.length, `expected ${fixture.expectedNotes.length} notes, got ${sweep.notesFound}`);
    const reportDir = fs.readdirSync(path.join(work, 'captures'))[0];
    const report = JSON.parse(fs.readFileSync(path.join(work, 'captures', reportDir, 'report.json'), 'utf8'));
    const found = new Set(report.notes.map((n) => `${n.tile.x},${n.tile.y}`));
    for (const expected of fixture.expectedNotes) ok(found.has(`${expected.tile.x},${expected.tile.y}`), `note tile ${JSON.stringify(expected.tile)} was recovered from JPEGs`);
    ok(report.stations.length >= 1 && report.stations.length <= 4, 'stations were chosen');
    const final = await waitFor((m) => m.t === 'setup' && m.stations.length > 1, 'setup with stations');
    ok(final.stations.filter((s) => s.kind === 'emergency').length === 1, 'exactly one emergency station in the final setup');

    // World map through the real server route
    const mapBytes = Buffer.from('fake-arworldmap-bytes');
    res = await fetch(`${base}/map/${room}`, { method: 'POST', headers: { 'content-type': 'application/octet-stream', ...host }, body: mapBytes });
    ok(res.status === 204, `map upload status ${res.status}`);
    const back = Buffer.from(await (await fetch(`${base}/map/${room}`)).arrayBuffer());
    ok(back.equals(mapBytes), 'map round trip');
    await waitFor((m) => m.t === 'lobby' && m.hasMap === true, 'lobby with hasMap');
  } finally {
    socket.close();
    await app.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
  console.log(`OK (stand-in): ${checks} checks`);
}

main().catch((error) => { console.error('FAILED (stand-in):', error.message); process.exit(1); });
