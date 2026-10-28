const { zoneId, scannedZones } = require('./zones');

const MAX_MAP_BYTES = 64 * 1024 * 1024;

class MapError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}

function readBinary(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let failed = false;
    request.on('data', (chunk) => {
      if (failed) return;
      size += chunk.length;
      if (size > limit) {
        failed = true;
        chunks.length = 0;
        reject(new MapError(413, 'MAP_TOO_LARGE', 'Map exceeds the upload limit.'));
      } else chunks.push(chunk);
    });
    request.on('end', () => { if (!failed) resolve(Buffer.concat(chunks)); });
    request.on('error', reject);
    request.on('aborted', () => reject(new MapError(400, 'UPLOAD_ABORTED', 'Map upload was interrupted.')));
  });
}

async function handleMap(request, response, manager, code, maxBytes = MAX_MAP_BYTES) {
  try {
    const room = manager.rooms.get(code);
    if (!room) throw new MapError(404, 'ROOM_NOT_FOUND', 'Room does not exist.');
    response.setHeader('Cache-Control', 'no-store');
    // Each scanned room has its own ARWorldMap, because each AR session has its own world frame. `?zone=z2`
    // picks the room; without it the first room (z1), so a one-room game is unchanged.
    let zone;
    try { zone = zoneId(new URL(request.url, 'http://localhost').searchParams.get('zone') ?? undefined); }
    catch { throw new MapError(400, 'INVALID_ZONE', 'Room id must be z1 to z6.'); }
    if (request.method === 'GET') {
      const map = room.maps.get(zone);
      if (!map) throw new MapError(404, 'MAP_NOT_FOUND', 'No map uploaded yet.');
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': map.length });
      response.end(map);
      return;
    }
    if (request.method !== 'POST') {
      response.setHeader('Allow', 'GET, POST');
      throw new MapError(405, 'METHOD_NOT_ALLOWED', 'Use GET or POST.');
    }
    if (request.headers['x-player-id'] !== room.hostId) throw new MapError(403, 'HOST_ONLY', 'Only the host can upload a map.');
    if (room.phase !== 'lobby') throw new MapError(409, 'INVALID_PHASE', 'Upload maps in the lobby.');
    if (scannedZones(room).length && !room.zones.get(zone)?.geometry) throw new MapError(404, 'INVALID_ZONE', 'That room has not been scanned.');
    const contentType = request.headers['content-type']?.split(';')[0];
    if (contentType !== 'application/octet-stream') throw new MapError(415, 'INVALID_CONTENT_TYPE', 'Send application/octet-stream.');
    if (Number(request.headers['content-length']) > maxBytes) throw new MapError(413, 'MAP_TOO_LARGE', 'Map exceeds the upload limit.');
    const body = await readBinary(request, maxBytes);
    if (body.length === 0) throw new MapError(400, 'EMPTY_MAP', 'Map must not be empty.');
    // The game may have started while the asynchronous upload was in flight.
    if (room.phase !== 'lobby') throw new MapError(409, 'INVALID_PHASE', 'Game started before upload completed.');
    room.maps.set(zone, body);
    room.broadcastLobby();
    response.writeHead(204);
    response.end();
  } catch (error) {
    request.resume();
    if (!response.destroyed) {
      response.writeHead(error.status || 500, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ t: 'error', code: error.code || 'MAP_ERROR', message: error.status ? error.message : 'Map upload failed.' }));
    }
  }
}

module.exports = { handleMap, MAX_MAP_BYTES };
