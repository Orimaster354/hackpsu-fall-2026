// Several scanned rooms ("zones") in one game.
//
// Every room is scanned on its own: its own perimeter walk, grid, sticky-note sweep and ARWorldMap, because each
// ARKit session has its own world frame. The game rules (same tile, stations, kills) work on ONE shared grid, so
// the server lays the rooms out side by side in a combined tile space and keeps each room's local grid next to it.
//
//   combined tile = local tile + zone.offset
//
// Clients report combined tiles. A phone converts with the offset of the room it is standing in, using that
// room's local grid (origin in that room's ARKit frame). With a single room the offset is (0,0) and the combined
// grid is the room's own grid, so a one-room game looks exactly like before zones existed.
//
// Doors link two rooms. They tell a phone which room's map to load when its player walks through, and let the
// host check that every room can be reached. They do not change the game rules.

const { requireAction } = require('./errors');
const { MAX_TASK_STATIONS, MAX_ZONES } = require('./contracts');

const FIRST_ZONE = 'z1';
const ZONE_ID = /^z[1-6]$/;
const SHELF_WIDTH = 60; // combined tile columns before the next room starts a new row
const GAP = 1; // empty tiles between rooms so they never touch
const TASK_ORDER = ['hold', 'dial', 'shake', 'gesture', 'hammer', 'orbs', 'signal'];

function zoneId(value) {
  const id = value === undefined ? FIRST_ZONE : value;
  requireAction(typeof id === 'string' && ZONE_ID.test(id), 'INVALID_ZONE', 'Room id must be z1 to z6.');
  return id;
}

function zoneName(value) {
  if (value === undefined) return undefined;
  requireAction(typeof value === 'string' && value.trim().length > 0 && value.trim().length <= 24,
    'INVALID_ZONE', 'Room name must be 1 to 24 characters.');
  return value.trim();
}

/** Returns the zone, creating it (up to MAX_ZONES) when it does not exist yet. */
function ensureZone(room, id, name) {
  let zone = room.zones.get(id);
  if (!zone) {
    requireAction(room.zones.size < MAX_ZONES, 'TOO_MANY_ZONES', `A game has at most ${MAX_ZONES} rooms.`);
    zone = { id, name: name || `Room ${room.zones.size + 1}`, geometry: null, ranked: [] };
    room.zones.set(id, zone);
  } else if (name) {
    zone.name = name;
  }
  return zone;
}

function scannedZones(room) {
  return [...room.zones.values()].filter((zone) => zone.geometry);
}

/** Lays rooms out left to right, wrapping to a new row at SHELF_WIDTH columns. */
function layout(zones) {
  let x = 0; let y = 0; let shelf = 0;
  return zones.map((zone) => {
    const { cols, rows } = zone.geometry.grid;
    if (x > 0 && x + cols > SHELF_WIDTH) { x = 0; y += shelf + GAP; shelf = 0; }
    const placed = { zone, offset: { x, y } };
    x += cols + GAP;
    shelf = Math.max(shelf, rows);
    return placed;
  });
}

function combine(room) {
  const placed = layout(scannedZones(room));
  requireAction(placed.length > 0, 'SETUP_MISSING', 'Scan a room first.');
  let cols = 0; let rows = 0;
  for (const { zone, offset } of placed) {
    cols = Math.max(cols, offset.x + zone.geometry.grid.cols);
    rows = Math.max(rows, offset.y + zone.geometry.grid.rows);
  }
  requireAction(cols <= 100 && rows <= 100, 'ZONES_TOO_LARGE', 'The rooms together exceed the 100 x 100 tile limit.');
  const single = placed.length === 1;
  const first = placed[0].zone.geometry.grid;
  const grid = { cols, rows, tileSize: 1, originX: single ? first.originX : 0, originZ: single ? first.originZ : 0, playable: [], edge: [] };
  for (const { zone, offset } of placed) {
    for (const tile of zone.geometry.grid.playable) grid.playable.push({ x: tile.x + offset.x, y: tile.y + offset.y });
    for (const tile of zone.geometry.grid.edge) grid.edge.push({ x: tile.x + offset.x, y: tile.y + offset.y });
  }
  return { grid, placed };
}

const stationId = (zone, localId) => (zone.id === FIRST_ZONE ? localId : `${zone.id}-${localId}`);

/**
 * Turns every room's ranked candidates into the game's stations.
 * - At most MAX_TASK_STATIONS task stations in the whole game, taken round-robin across rooms in rank order, so
 *   each room gets a share before any room gets a second.
 * - No two task stations share a task type: a repeat takes the first type nobody has used yet.
 * - One emergency station per room, and one fix station per room when it has a candidate.
 */
function allocate(placed) {
  const queues = placed.map(({ zone }) => zone.ranked.filter((pick) => pick.kind === 'task'));
  const tasks = placed.map(() => []);
  let count = 0;
  for (let round = 0; count < MAX_TASK_STATIONS; round += 1) {
    let progressed = false;
    queues.forEach((queue, index) => {
      if (queue[round] && count < MAX_TASK_STATIONS) { tasks[index].push({ ...queue[round] }); count += 1; progressed = true; }
    });
    if (!progressed) break;
  }
  const used = new Set();
  for (const pick of tasks.flat()) {
    if (!TASK_ORDER.includes(pick.task) || used.has(pick.task)) {
      const free = TASK_ORDER.find((type) => !used.has(type));
      if (free) pick.task = free;
    }
    used.add(pick.task);
  }
  const stations = [];
  placed.forEach(({ zone, offset }, index) => {
    const at = (tile) => ({ x: tile.x + offset.x, y: tile.y + offset.y });
    const emergency = zone.geometry.emergency;
    stations.push({ id: stationId(zone, emergency.id), name: 'EMERGENCY', tile: at(emergency.tile), task: 'hold', kind: 'emergency' });
    for (const pick of tasks[index]) {
      stations.push({ id: stationId(zone, pick.id), name: pick.name, tile: at(pick.tile), task: pick.task, kind: 'task' });
    }
    const fix = zone.ranked.find((pick) => pick.kind === 'fix');
    if (fix) stations.push({ id: stationId(zone, fix.id), name: fix.name, tile: at(fix.tile), task: 'hold', kind: 'fix' });
  });
  return stations;
}

/** Rebuilds the combined grid and stations from the rooms and applies them to the game (lobby only). */
function recompose(room) {
  const { grid, placed } = combine(room);
  room.game.applySetup({ grid, stations: allocate(placed) });
  return placed;
}

/** What a client needs to know about each room. Empty for a setup that did not come from a scan. */
function zonesInfo(room) {
  const placed = layout(scannedZones(room));
  return placed.map(({ zone, offset }) => ({
    id: zone.id,
    name: zone.name,
    offset,
    grid: zone.geometry.grid,
    hasMap: room.maps.has(zone.id),
    doors: room.doors.flatMap((door) => {
      if (door.a.zone === zone.id) return [{ tile: door.a.tile, toZone: door.b.zone, toTile: door.b.tile }];
      if (door.b.zone === zone.id) return [{ tile: door.b.tile, toZone: door.a.zone, toTile: door.a.tile }];
      return [];
    }),
  }));
}

const isEdge = (zone, tile) => Boolean(zone?.geometry && tile && Number.isInteger(tile.x) && Number.isInteger(tile.y)
  && zone.geometry.grid.edge.some((cell) => cell.x === tile.x && cell.y === tile.y));

/** Replaces the door list. Each door joins an edge tile of one room to an edge tile of another, one per pair. */
function validateDoors(room, doors) {
  requireAction(Array.isArray(doors) && doors.length <= 15, 'INVALID_DOORS', 'Provide a list of doors.');
  const pairs = new Set();
  return doors.map((door) => {
    const zoneA = room.zones.get(door?.a?.zone);
    const zoneB = room.zones.get(door?.b?.zone);
    requireAction(zoneA && zoneB && zoneA !== zoneB, 'INVALID_DOORS', 'A door joins two different scanned rooms.');
    requireAction(isEdge(zoneA, door.a.tile) && isEdge(zoneB, door.b.tile), 'INVALID_DOORS', 'Doors must be on edge tiles of their rooms.');
    const key = [zoneA.id, zoneB.id].sort().join('|');
    requireAction(!pairs.has(key), 'INVALID_DOORS', 'Only one door per pair of rooms.');
    pairs.add(key);
    return { a: { zone: zoneA.id, tile: { x: door.a.tile.x, y: door.a.tile.y } }, b: { zone: zoneB.id, tile: { x: door.b.tile.x, y: door.b.tile.y } } };
  });
}

/** True when every scanned room can be reached from the first one through doors. */
function zonesConnected(room) {
  const ids = scannedZones(room).map((zone) => zone.id);
  if (ids.length <= 1) return true;
  const seen = new Set([ids[0]]);
  const queue = [ids[0]];
  while (queue.length) {
    const here = queue.shift();
    for (const door of room.doors) {
      const next = door.a.zone === here ? door.b.zone : door.b.zone === here ? door.a.zone : null;
      if (next && !seen.has(next)) { seen.add(next); queue.push(next); }
    }
  }
  return ids.every((id) => seen.has(id));
}

/** Forget a room's geometry-dependent data after it is rescanned or removed. */
function resetZone(room, id) {
  room.maps.delete(id);
  room.doors = room.doors.filter((door) => door.a.zone !== id && door.b.zone !== id);
}

module.exports = { FIRST_ZONE, zoneId, zoneName, ensureZone, scannedZones, combine, allocate, recompose, zonesInfo,
  validateDoors, zonesConnected, resetZone, layout };
