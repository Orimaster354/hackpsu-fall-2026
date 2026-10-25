'use strict';
// Black-box contract test for the sticky-note scan endpoints (docs/architecture.md, "Sticky-note scan").
// It talks to a RUNNING server over HTTP and WebSocket and checks status codes, error codes and response shapes.
//
//   cd server && npm start                       # a plain server, NOT start:manual (rooms must start without a grid)
//   node docs/fixtures/postit/contract-check.js [http://127.0.0.1:8080]
//
// Requires Node 22 and server/node_modules (for `ws`). Exits non-zero if any check fails.
const fs = require('node:fs');
const path = require('node:path');
const WebSocket = require(path.join(__dirname, '..', '..', '..', 'server', 'node_modules', 'ws'));

const base = (process.argv[2] || 'http://127.0.0.1:8080').replace(/\/$/, '');
const wsUrl = base.replace(/^http/, 'ws') + '/ws';
const poses = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'poses.json'), 'utf8'));
const sweep = JSON.parse(fs.readFileSync(path.join(__dirname, 'sweep-observations.json'), 'utf8'));
const jpeg = fs.readFileSync(path.join(__dirname, 'tiny-frame.jpg')).toString('base64');

let failures = 0;
const check = (ok, name, detail = '') => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok || !detail ? '' : ' -> ' + detail}`); if (!ok) failures++; };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function client(label) {
  const ws = new WebSocket(wsUrl);
  const c = { label, ws, id: null, room: null, frames: [] };
  ws.on('message', (d) => { const m = JSON.parse(d); c.frames.push(m); if (m.t === 'joined') { c.id = m.playerId; c.room = m.room; } });
  return new Promise((resolve, reject) => { ws.on('open', () => resolve(c)); ws.on('error', reject); });
}
const send = (c, m) => c.ws.send(JSON.stringify(m));
const last = (c, t) => [...c.frames].reverse().find((f) => f.t === t);

async function post(route, room, playerId, body) {
  const res = await fetch(`${base}/scan/${room}/${route}`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-player-id': playerId || '' },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  let json = null; try { json = await res.json(); } catch { /* not JSON */ }
  return { status: res.status, json };
}

const expectError = (r, status, code, name) => check(r.status === status && r.json?.code === code, name, `got ${r.status} ${JSON.stringify(r.json)}`);

(async () => {
  const host = await client('host');
  send(host, { t: 'create', name: 'Host' });
  await wait(300);
  const joiner = await client('joiner');
  send(joiner, { t: 'join', room: host.room, name: 'Guest' });
  await wait(300);
  check(Boolean(host.room && host.id && joiner.id), 'room created and joined');
  const room = host.room;

  // --- rejected requests ---
  expectError(await post('perimeter', room, joiner.id, { poses }), 403, 'HOST_ONLY', 'perimeter by a non-host is HOST_ONLY (403)');
  expectError(await post('sweep', room, host.id, { vantage: { x: 2, y: 2 }, intrinsics: sweep.intrinsics, frames: [] }), 409, 'SETUP_MISSING', 'sweep before perimeter is SETUP_MISSING (409)');
  expectError(await post('perimeter', room, host.id, { poses: poses.slice(0, 10) }), 400, 'SCAN_UPLOAD_INVALID', 'too few perimeter samples is SCAN_UPLOAD_INVALID (400)');
  expectError(await post('perimeter', room, host.id, '{not json'), 400, 'SCAN_UPLOAD_INVALID', 'malformed JSON is SCAN_UPLOAD_INVALID (400)');
  expectError(await post('perimeter', room, host.id, { poses: poses.slice(0, 120) }), 422, 'SCAN_FAILED', 'an open loop is SCAN_FAILED (422)');

  // --- perimeter ---
  host.frames.length = 0;
  const p = await post('perimeter', room, host.id, { poses });
  check(p.status === 200 && p.json?.ok === true && p.json.cols === 5 && p.json.rows === 5 && p.json.edgeTiles === 16,
    'fixture perimeter gives a 5x5 grid with 16 edge tiles', JSON.stringify(p));
  await wait(500);
  const setup = last(host, 'setup');
  check(Boolean(setup), 'host receives setup after the perimeter');
  if (setup) {
    const g = setup.grid;
    check(Math.abs(g.originX + 0.5) < 0.2 && Math.abs(g.originZ + 0.5) < 0.2 && g.tileSize === 1, 'grid origin is about (-0.5, -0.5) with 1 m tiles', JSON.stringify([g.originX, g.originZ, g.tileSize]));
    check(g.edge.length === 16 && g.playable.length === 25, 'grid has 25 playable and 16 edge tiles', `${g.playable.length}/${g.edge.length}`);
    const emergency = setup.stations.filter((s) => s.kind === 'emergency');
    check(emergency.length === 1 && emergency[0].tile.x === 2 && emergency[0].tile.y === 2, 'exactly one emergency station, at the center tile (2,2)', JSON.stringify(emergency));
    check(setup.stations.every((s) => s.kind === 'emergency') && setup.setupConfirmed === false, 'no task stations yet and setup is unconfirmed');
  }
  check(last(host, 'processing') != null, 'a processing event was broadcast');

  // --- sweep ---
  const frames = sweep.frames.map((f) => ({ index: f.index, t: f.t, pose: f.pose, jpeg }));
  expectError(await post('sweep', room, host.id, { vantage: { x: 2, y: 2 }, intrinsics: sweep.intrinsics, frames: frames.slice(0, 3) }), 400, 'SCAN_UPLOAD_INVALID', 'a sweep with 3 frames is SCAN_UPLOAD_INVALID (400)');
  expectError(await post('sweep', room, host.id, { vantage: { x: 2, y: 2 }, intrinsics: sweep.intrinsics,
    frames: frames.map((f, i) => ({ ...f, pose: { ...f.pose, qw: i === 5 ? 'x' : f.pose.qw } })) }), 400, 'SCAN_UPLOAD_INVALID', 'a non-numeric pose is SCAN_UPLOAD_INVALID (400)');

  host.frames.length = 0;
  const s = await post('sweep', room, host.id, { vantage: { x: 2, y: 2 }, intrinsics: sweep.intrinsics, frames });
  check(s.status === 200 && s.json?.ok === true && Number.isInteger(s.json.notesFound) && Number.isInteger(s.json.stations) && Array.isArray(s.json.warnings),
    'sweep returns {ok, notesFound, stations, warnings}', JSON.stringify(s));
  await wait(500);
  const after = last(host, 'setup');
  check(Boolean(after), 'host receives setup after the sweep');
  if (after && s.json) {
    const g = after.grid, edge = new Set(g.edge.map((t) => `${t.x},${t.y}`));
    const tasks = after.stations.filter((x) => x.kind === 'task'), fixes = after.stations.filter((x) => x.kind === 'fix');
    check(tasks.length <= 3 && fixes.length <= 1, 'at most 3 task stations and 1 fix station', `${tasks.length}/${fixes.length}`);
    check(after.stations.length - 1 === s.json.stations, 'response station count matches setup (emergency not counted)', `${after.stations.length - 1} vs ${s.json.stations}`);
    check([...tasks, ...fixes].every((x) => edge.has(`${x.tile.x},${x.tile.y}`)), 'every task and fix station is on an edge tile');
    const spaced = [...tasks, ...fixes].every((a, i, all) => all.every((b, j) => i === j || Math.hypot(a.tile.x - b.tile.x, a.tile.y - b.tile.y) >= 2 - 1e-9));
    check(spaced, 'task and fix stations are at least 2 m apart');
    check(after.stations.filter((x) => x.kind === 'emergency').length === 1, 'the emergency station is still there');
    check(after.setupConfirmed === false, 'setup is still unconfirmed after the sweep');
    if (s.json.notesFound === 0) console.log('note  notesFound is 0: expected for the plain JPEG fixture unless YOLOE reads detections from the fixture (see tasks.md step 3)');
  }

  // --- locked after confirm ---
  send(host, { t: 'confirmSetup' });
  await wait(400);
  expectError(await post('perimeter', room, host.id, { poses }), 409, 'SETUP_LOCKED', 'perimeter after confirmSetup is SETUP_LOCKED (409)');

  host.ws.close(); joiner.ws.close();
  console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => { console.error('contract-check crashed:', e.message); process.exit(2); });
