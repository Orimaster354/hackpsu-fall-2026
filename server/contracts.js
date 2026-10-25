const { requireAction } = require('./errors');

const TASK_TYPES = new Set(['shake', 'tilt', 'dial', 'hold', 'gesture']);
const sameTile = (a, b) => Boolean(a && b && a.x === b.x && a.y === b.y);

function validTile(tile, grid) {
  return tile && Number.isInteger(tile.x) && Number.isInteger(tile.y)
    && tile.x >= 0 && tile.y >= 0 && tile.x < grid.cols && tile.y < grid.rows;
}

function walkable(tile, grid) {
  return validTile(tile, grid) && !grid.blocked.some((blocked) => sameTile(blocked, tile));
}

function validateRoomSetup(grid, stations) {
  requireAction(grid && Number.isInteger(grid.cols) && Number.isInteger(grid.rows)
    && grid.cols > 0 && grid.cols <= 100 && grid.rows > 0 && grid.rows <= 100
    && grid.tileSize === 1 && Array.isArray(grid.blocked) && grid.blocked.length <= 10000,
  'INVALID_GRID', 'Grid needs 1–100 rows/columns, 1 m tiles, and a blocked tile array.');
  requireAction(grid.blocked.every((tile) => validTile(tile, grid)), 'INVALID_GRID', 'Blocked tiles must be inside the grid.');
  const safeGrid = { cols: grid.cols, rows: grid.rows, tileSize: 1,
    blocked: grid.blocked.map(({ x, y }) => ({ x, y })) };
  requireAction(walkable({ x: 0, y: 0 }, safeGrid), 'INVALID_GRID', 'The emergency tile (0,0) must be accessible.');
  requireAction(Array.isArray(stations) && stations.length <= 100, 'INVALID_STATIONS', 'Provide at most 100 stations.');
  const ids = new Set();
  const safeStations = stations.map((station) => {
    requireAction(station && typeof station.id === 'string' && station.id.length > 0 && station.id.length <= 64
      && !ids.has(station.id) && typeof station.name === 'string' && station.name.trim().length > 0
      && station.name.length <= 80 && walkable(station.tile, safeGrid) && TASK_TYPES.has(station.task)
      && ['task', 'fix'].includes(station.kind), 'INVALID_STATIONS', 'Station IDs, types, and accessible tiles must be valid.');
    ids.add(station.id);
    return { id: station.id, name: station.name.trim(), tile: { x: station.tile.x, y: station.tile.y },
      task: station.task, kind: station.kind };
  });
  return { grid: safeGrid, stations: safeStations };
}

module.exports = { sameTile, walkable, validateRoomSetup };
