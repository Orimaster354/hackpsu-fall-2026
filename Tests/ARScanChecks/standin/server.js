'use strict';
// TEST STAND-IN for the scan endpoints the real server does not have yet (owner C):
//   POST /scan/:room/perimeter    POST /scan/:room/sweep
// It wraps the REAL server (lobby, host id, WebSocket, POST/GET /map/:room) and only adds those two routes, with the
// upload rules from docs/architecture.md. Processing is simplified: convex-room grid from the walk, a colour
// threshold instead of YOLOE, no Gemini, and the reference geometry from docs/fixtures/postit/postit-geometry.js.
// Every sweep is saved under captures/ with a report, so a physical test leaves evidence you can inspect.
//   node Tests/ARScanChecks/standin/server.js [--port 8080]
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const repo = path.resolve(__dirname, '../../..');
const { createAppServer } = require(path.join(repo, 'server/index.js'));
const geometry = require(path.join(repo, 'docs/fixtures/postit/postit-geometry.js'));
const { ContractError, validatePerimeter, validateSweep, MAX_PERIMETER_BYTES, MAX_SWEEP_BYTES } = require('./contract');
const { gridFromPerimeter } = require('./room');
const run = promisify(execFile);

const TASKS = ['hold', 'tilt', 'dial', 'shake'];

async function detectNotes(files) {
  const { stdout } = await run('python3', ['-I', path.join(__dirname, 'detect_notes.py'), ...files], { maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(stdout);
}

function readBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let failed = false;
    request.on('data', (chunk) => {
      if (failed) return;
      size += chunk.length;
      if (size > limit) { failed = true; chunks.length = 0; reject(new ContractError(413, 'SCAN_UPLOAD_TOO_LARGE', `Body exceeds ${limit} bytes.`)); }
      else chunks.push(chunk);
    });
    request.on('end', () => { if (!failed) resolve(Buffer.concat(chunks)); });
    request.on('error', reject);
    request.on('aborted', () => reject(new ContractError(400, 'UPLOAD_ABORTED', 'Upload was interrupted.')));
  });
}

function createStandIn(options = {}) {
  const outDir = options.outDir || path.join(__dirname, 'captures');
  const log = options.log || ((line) => console.log(line));
  const app = createAppServer(options.server || {});
  const scans = new Map(); // room code -> { polygon, grid, emergency }

  async function handle(request, response, code, kind) {
    try {
      const room = app.rooms.rooms.get(code);
      if (!room) throw new ContractError(404, 'ROOM_NOT_FOUND', 'Room does not exist.');
      if (request.method !== 'POST') { response.setHeader('Allow', 'POST'); throw new ContractError(405, 'METHOD_NOT_ALLOWED', 'Use POST.'); }
      if (request.headers['x-player-id'] !== room.hostId) throw new ContractError(403, 'HOST_ONLY', 'Only the host can upload a scan.');
      if (room.phase !== 'lobby') throw new ContractError(409, 'INVALID_PHASE', 'Scans are accepted in the lobby only.');
      if (room.setupConfirmed) throw new ContractError(409, 'SETUP_LOCKED', 'Confirmed setup cannot be replaced.');
      if (request.headers['content-type']?.split(';')[0] !== 'application/json') throw new ContractError(415, 'INVALID_CONTENT_TYPE', 'Send application/json.');
      const limit = kind === 'perimeter' ? MAX_PERIMETER_BYTES : MAX_SWEEP_BYTES;
      if (Number(request.headers['content-length']) > limit) throw new ContractError(413, 'SCAN_UPLOAD_TOO_LARGE', `Body exceeds ${limit} bytes.`);
      const raw = await readBody(request, limit);
      let body;
      try { body = JSON.parse(raw.toString('utf8')); } catch { throw new ContractError(400, 'SCAN_UPLOAD_INVALID', 'Body is not valid JSON.'); }
      const result = kind === 'perimeter' ? await perimeter(room, code, body, raw.length) : await sweep(room, code, body, raw.length);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify(result));
    } catch (error) {
      request.resume();
      if (!(error instanceof ContractError)) { log(`stand-in error: ${error.stack || error}`); }
      if (!response.destroyed) {
        response.writeHead(error.status || 500, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ t: 'error', code: error.code || 'SERVER_ERROR', message: error.status ? error.message : 'Unexpected stand-in error.' }));
      }
      log(`  ${kind} rejected: ${error.status || 500} ${error.code || ''} ${error.message}`);
    }
  }

  async function perimeter(room, code, body, bytes) {
    const poses = validatePerimeter(body);
    const lap = gridFromPerimeter(poses);
    room.broadcast({ t: 'processing', step: 'polygon' });
    const emergency = { id: 'emergency', name: 'Meeting spot', tile: lap.emergency, task: 'hold', kind: 'emergency' };
    room.game.applySetup({ grid: lap.grid, stations: [emergency] });
    scans.set(code, lap);
    log(`[${code}] perimeter: ${poses.length} poses, ${(bytes / 1024).toFixed(0)} KiB -> ${lap.grid.cols}x${lap.grid.rows} grid, ${lap.grid.edge.length} edge tiles, origin (${lap.grid.originX.toFixed(2)}, ${lap.grid.originZ.toFixed(2)}), emergency (${lap.emergency.x},${lap.emergency.y})`);
    return { ok: true, cols: lap.grid.cols, rows: lap.grid.rows, edgeTiles: lap.grid.edge.length };
  }

  async function sweep(room, code, body, bytes) {
    const lap = scans.get(code);
    if (!lap) throw new ContractError(409, 'SETUP_MISSING', 'Upload the perimeter walk first.');
    const { frames, warnings: inputWarnings } = validateSweep(body);
    const dir = path.join(outDir, `${code}-${new Date().toISOString().replace(/[:.]/g, '-')}`);
    fs.mkdirSync(dir, { recursive: true });
    const files = frames.map((f) => {
      const file = path.join(dir, `frame-${String(f.index).padStart(3, '0')}.jpg`);
      fs.writeFileSync(file, f.bytes);
      return file;
    });
    room.broadcast({ t: 'processing', step: 'gemini' });
    const found = await detectNotes(files);
    room.broadcast({ t: 'processing', step: 'placing' });

    const detections = frames.map((f, i) => ({
      index: f.index, t: f.t, pose: f.pose,
      detections: found[files[i]].map((d) => ({ label: 'sticky note', box: d.box, confidence: 0.9 })),
    }));
    const grid = lap.grid;
    const notes = geometry.placeNotes({
      frames: detections, intrinsics: body.intrinsics, polygon: lap.polygon,
      grid: { cols: grid.cols, rows: grid.rows, tileSize: 1, originX: grid.originX, originZ: grid.originZ, edge: grid.edge },
    });
    notes.sort((a, b) => b.observations.length - a.observations.length);
    const usable = notes.filter((n) => !(n.tile.x === lap.emergency.x && n.tile.y === lap.emergency.y));
    const picks = geometry.enforceSpacing(usable.map((n, i) => ({ id: `note-${i + 1}`, tile: n.tile })), 1, 2).slice(0, 4);
    const stations = picks.map((p, i) => ({
      id: p.id, name: 'Wall note', tile: p.tile, kind: i === 3 ? 'fix' : 'task', task: i === 3 ? 'hold' : TASKS[i % TASKS.length],
    }));
    const warnings = [...inputWarnings];
    if (notes.length < 4) warnings.push(`Only ${notes.length} notes found (goal 4 or more). Note size, distance and light matter; see the report in ${dir}.`);
    const emergency = { id: 'emergency', name: 'Meeting spot', tile: lap.emergency, task: 'hold', kind: 'emergency' };
    room.game.applySetup({ grid, stations: [emergency, ...stations] });

    const report = {
      room: code, vantage: body.vantage, intrinsics: body.intrinsics, bodyKiB: Math.round(bytes / 1024),
      frames: frames.map((f) => ({ index: f.index, t: f.t, kib: Math.round(f.bytes.length / 1024), size: `${f.width}x${f.height}`, notes: found[files[f.index]].length })),
      notes: notes.map((n) => ({ tile: n.tile, wall: n.hit.map((v) => +v.toFixed(2)), observations: n.observations.length })),
      stations, warnings,
    };
    fs.writeFileSync(path.join(dir, 'report.json'), JSON.stringify(report, null, 2));
    fs.writeFileSync(path.join(dir, 'upload-meta.json'), JSON.stringify({ vantage: body.vantage, intrinsics: body.intrinsics, frames: frames.map((f) => ({ index: f.index, t: f.t, pose: f.pose })) }, null, 2));
    log(`[${code}] sweep: ${frames.length} frames, ${(bytes / 1048576).toFixed(1)} MB, ${frames[0].width}x${frames[0].height}; ${found && Object.values(found).filter((b) => b.length).length} frames show a note -> ${notes.length} notes ${JSON.stringify(notes.map((n) => [n.tile.x, n.tile.y]))}; saved ${dir}`);
    return { ok: true, notesFound: notes.length, stations: stations.length, warnings };
  }

  const original = app.server.listeners('request');
  app.server.removeAllListeners('request');
  app.server.on('request', (request, response) => {
    let pathname = '';
    try { pathname = new URL(request.url, 'http://localhost').pathname; } catch { /* the original handler answers 400 */ }
    const match = /^\/scan\/([A-Z]{4})\/(perimeter|sweep)$/.exec(pathname);
    if (match) { void handle(request, response, match[1], match[2]); return; }
    for (const listener of original) listener.call(app.server, request, response);
  });
  return app;
}

if (require.main === module) {
  const portArg = process.argv.indexOf('--port');
  const port = portArg > 0 ? Number(process.argv[portArg + 1]) : 8080;
  createStandIn().listen(port).then((address) => {
    const lan = Object.values(os.networkInterfaces()).flat().filter((i) => i && i.family === 'IPv4' && !i.internal).map((i) => i.address);
    console.log(`SCAN STAND-IN (real lobby + map routes, simplified scan processing) on port ${address.port}`);
    console.log(`In the app's Settings, enter one of: ${lan.map((ip) => `${ip}:${address.port}`).join('   ') || `localhost:${address.port}`}`);
    console.log('Uploads are saved under Tests/ARScanChecks/standin/captures/');
  }).catch((error) => { console.error(error); process.exitCode = 1; });
}

module.exports = { createStandIn };
