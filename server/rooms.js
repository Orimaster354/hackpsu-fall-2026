const { randomInt, randomUUID } = require('node:crypto');
const WebSocket = require('ws');

const MAX_PLAYERS = 4;
const DEFAULT_GRID = Object.freeze({ cols: 5, rows: 5, tileSize: 1.0, blocked: [] });
const ROOM_CODE_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

class RoomError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function roomCode() {
  return Array.from({ length: 4 }, () => ROOM_CODE_ALPHABET[randomInt(ROOM_CODE_ALPHABET.length)]).join('');
}

function cleanName(name) {
  if (typeof name !== 'string' || !name.trim() || name.trim().length > 24) {
    throw new RoomError('INVALID_NAME', 'Name must be 1–24 characters.');
  }
  return name.trim();
}

function send(socket, message) {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(message));
  }
}

class Room {
  constructor(code) {
    this.code = code;
    this.hostId = null;
    this.players = new Map();
    this.grid = { ...DEFAULT_GRID, blocked: [] };
    this.stations = [];
    this.hasMap = false;
  }

  addPlayer(name, socket, playerId) {
    const safeName = cleanName(name);

    if (playerId !== undefined) {
      const existing = this.players.get(playerId);
      if (!existing || existing.name !== safeName) {
        throw new RoomError('PLAYER_NOT_FOUND', 'No matching player to reconnect.');
      }
      if (existing.socket && existing.socket !== socket) {
        existing.socket.close(4000, 'Reconnected elsewhere');
      }
      existing.socket = socket;
      return existing;
    }

    if (this.players.size >= MAX_PLAYERS) {
      throw new RoomError('ROOM_FULL', 'This room already has four players.');
    }

    const player = {
      id: randomUUID(),
      name: safeName,
      tile: null,
      alive: true,
      tileSource: 'manual',
      socket,
    };
    this.players.set(player.id, player);
    if (this.hostId === null) this.hostId = player.id;
    return player;
  }

  detach(playerId, socket) {
    const player = this.players.get(playerId);
    if (player?.socket === socket) player.socket = null;
  }

  lobbyMessage() {
    return {
      t: 'lobby',
      players: Array.from(this.players.values(), ({ id, name, tile, alive, tileSource }) => ({
        id, name, tile, alive, tileSource,
      })),
      grid: this.grid,
      stations: this.stations,
      hasMap: this.hasMap,
    };
  }

  broadcastLobby() {
    const message = this.lobbyMessage();
    for (const player of this.players.values()) send(player.socket, message);
  }
}

class RoomManager {
  constructor() {
    this.rooms = new Map();
  }

  create(name, socket) {
    let code;
    do {
      code = roomCode();
    } while (this.rooms.has(code));
    const room = new Room(code);
    const player = room.addPlayer(name, socket);
    this.rooms.set(code, room);
    return { room, player };
  }

  join(code, name, socket, playerId) {
    if (typeof code !== 'string' || !/^[A-Z]{4}$/.test(code)) {
      throw new RoomError('INVALID_ROOM', 'Room code must be four letters.');
    }
    const room = this.rooms.get(code);
    if (!room) throw new RoomError('ROOM_NOT_FOUND', 'Room does not exist.');
    const player = room.addPlayer(name, socket, playerId);
    return { room, player };
  }
}

module.exports = { RoomError, RoomManager, send };
