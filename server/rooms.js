const { randomInt, randomUUID } = require('node:crypto');
const WebSocket = require('ws');
const { RoomError } = require('./errors');
const { Game } = require('./game');
const demoSetup = require('./fixtures/demo-setup.json');

const MAX_PLAYERS = 4;
const ROOM_CODE_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

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
  constructor(code, options = {}) {
    this.code = code;
    this.demo = options.demo === true;
    this.hostId = null;
    this.players = new Map();
    this.grid = null;
    this.setupConfirmed = false;
    this.scanBusy = false;
    this.scanGeometry = null;
    this.stations = [];
    this.hasMap = false;
    this.phase = 'lobby';
    this.game = new Game(this, options);
    if (this.demo) this.game.applySetup(demoSetup);
    else if (options.manualSetup) this.game.applySetup(options.manualSetup);
  }

  addPlayer(name, socket, playerId) {
    const safeName = cleanName(name);

    if (playerId !== undefined) {
      const existing = this.players.get(playerId);
      if (!existing || existing.name !== safeName) {
        throw new RoomError('PLAYER_NOT_FOUND', 'No matching player to reconnect.');
      }
      if (existing.socket && existing.socket !== socket) {
        if (existing.id === this.hostId) this.liveScan?.stop('host_reconnected');
        existing.socket.close(4000, 'Reconnected elsewhere');
      }
      existing.socket = socket;
      existing.ready = false;
      existing.pendingTile = null;
      return existing;
    }

    if (this.phase !== 'lobby') throw new RoomError('GAME_STARTED', 'New players cannot join after game start.');

    if (this.players.size >= MAX_PLAYERS) {
      throw new RoomError('ROOM_FULL', 'This room already has four players.');
    }

    const player = {
      id: randomUUID(),
      name: safeName,
      tile: null,
      alive: true,
      tileSource: 'manual',
      ready: false,
      socket,
    };
    this.players.set(player.id, player);
    if (this.hostId === null) this.hostId = player.id;
    return player;
  }

  detach(playerId, socket) {
    const player = this.players.get(playerId);
    if (player?.socket === socket) {
      if (player.id === this.hostId) this.liveScan?.stop('host_disconnected');
      player.socket = null;
      player.ready = false;
      player.pendingTile = null;
      if (this.phase === 'lobby') this.broadcastLobby();
      else this.game.publish();
    }
  }

  setReady(playerId, ready) {
    if (this.phase !== 'lobby') throw new RoomError('INVALID_PHASE', 'Ready status can only change in the lobby.');
    if (typeof ready !== 'boolean') throw new RoomError('INVALID_READY', 'Ready must be a boolean.');
    this.players.get(playerId).ready = ready;
    this.broadcastLobby();
  }

  publicPlayers() {
    return Array.from(this.players.values(), ({ id, name, tile, alive, tileSource, ready, socket }) => ({
        id, name, tile, alive, tileSource, ready,
        connected: socket?.readyState === WebSocket.OPEN,
      }));
  }

  lobbyMessage() {
    return {
      t: 'lobby',
      demo: this.demo,
      hostId: this.hostId,
      players: this.publicPlayers(),
      grid: this.grid,
      stations: this.stations,
      hasMap: this.hasMap,
      setupConfirmed: this.setupConfirmed,
    };
  }

  broadcastLobby() {
    this.broadcast(this.lobbyMessage());
  }

  setupMessage() {
    return { t: 'setup', grid: this.grid, stations: this.stations, setupConfirmed: this.setupConfirmed };
  }

  broadcastSetup() {
    this.broadcast(this.setupMessage());
    this.broadcastLobby();
  }

  sendTo(player, message) {
    send(player.socket, message);
  }

  broadcast(message) {
    for (const player of this.players.values()) send(player.socket, message);
  }
}

class RoomManager {
  constructor(options = {}) {
    this.rooms = new Map();
    this.options = options;
  }

  create(name, socket, demo = false) {
    if (typeof demo !== 'boolean') throw new RoomError('INVALID_DEMO', 'demo must be a boolean.');
    let code;
    do {
      code = roomCode();
    } while (this.rooms.has(code));
    const room = new Room(code, { ...this.options, demo });
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
