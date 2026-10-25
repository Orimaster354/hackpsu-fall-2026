const { requireAction } = require('./errors');

const TASK_TYPES = new Set(['shake', 'tilt', 'dial', 'hold', 'gesture']);
const sameTile = (a, b) => Boolean(a && b && a.x === b.x && a.y === b.y);
const tileKey = (tile) => `${tile.x},${tile.y}`;

function validTile(tile, grid) {
  return Boolean(grid && tile && Number.isInteger(tile.x) && Number.isInteger(tile.y)
    && tile.x >= 0 && tile.y >= 0 && tile.x < grid.cols && tile.y < grid.rows);
}

function walkable(tile, grid) {
  return Boolean(validTile(tile, grid) && grid.playable.some((cell) => sameTile(cell, tile)));
}

function validateRoomSetup(grid, stations) {
  requireAction(grid && Number.isInteger(grid.cols) && Number.isInteger(grid.rows)
    && grid.cols > 0 && grid.cols <= 100 && grid.rows > 0 && grid.rows <= 100 && grid.tileSize === 1
    && Number.isFinite(grid.originX) && Number.isFinite(grid.originZ)
    && Array.isArray(grid.playable) && grid.playable.length > 0 && grid.playable.length <= grid.cols * grid.rows
    && Array.isArray(grid.edge) && grid.edge.length > 0 && grid.edge.length <= grid.playable.length,
  'INVALID_GRID', 'Grid needs finite origins, 1 m tiles, and playable/edge tile arrays.');
  requireAction(grid.playable.every((tile) => validTile(tile, grid)) && grid.edge.every((tile) => validTile(tile, grid)),
    'INVALID_GRID', 'Grid tiles must be in bounds.');
  const playable = new Set(grid.playable.map(tileKey));
  const edge = new Set(grid.edge.map(tileKey));
  requireAction(playable.size === grid.playable.length && edge.size === grid.edge.length
    && [...edge].every((key) => playable.has(key)), 'INVALID_GRID', 'Tiles must be unique; edge tiles must also be playable.');
  const safeGrid = { cols: grid.cols, rows: grid.rows, tileSize: 1, originX: grid.originX, originZ: grid.originZ,
    playable: grid.playable.map(({ x, y }) => ({ x, y })), edge: grid.edge.map(({ x, y }) => ({ x, y })) };
  requireAction(Array.isArray(stations) && stations.length <= 100, 'INVALID_STATIONS', 'Provide at most 100 stations.');
  const ids = new Set();
  const safeStations = stations.map((station) => {
    requireAction(station && typeof station.id === 'string' && station.id.length > 0 && station.id.length <= 64
      && !ids.has(station.id) && typeof station.name === 'string' && station.name.trim().length > 0
      && station.name.length <= 80 && walkable(station.tile, safeGrid) && TASK_TYPES.has(station.task)
      && ['task', 'fix', 'emergency'].includes(station.kind), 'INVALID_STATIONS', 'Station IDs, types, and playable tiles must be valid.');
    requireAction(station.kind === 'emergency' || edge.has(tileKey(station.tile)), 'STATION_NOT_EDGE', 'Task/fix stations must be on edge tiles.');
    ids.add(station.id);
    return { id: station.id, name: station.name.trim(), tile: { x: station.tile.x, y: station.tile.y }, task: station.task, kind: station.kind };
  });
  const emergency = safeStations.filter((station) => station.kind === 'emergency');
  requireAction(emergency.length === 1, 'INVALID_EMERGENCY', 'Setup needs exactly one server-placed emergency station.');
  const edgeStations = safeStations.filter((station) => station.kind !== 'emergency');
  for (let index = 0; index < edgeStations.length; index += 1) {
    const tile = edgeStations[index].tile;
    requireAction(!sameTile(tile, emergency[0].tile), 'STATION_OVERLAP', 'A task/fix station cannot occupy the emergency tile.');
    for (const other of edgeStations.slice(index + 1)) {
      const dx = tile.x - other.tile.x; const dy = tile.y - other.tile.y;
      requireAction(dx * dx + dy * dy >= 4, 'STATIONS_TOO_CLOSE', 'Task/fix tile centers must be at least 2 m apart.');
    }
  }
  return { grid: safeGrid, stations: safeStations };
}

module.exports = { sameTile, walkable, validateRoomSetup };
