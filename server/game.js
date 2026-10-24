const { randomInt } = require('node:crypto');
const { requireAction } = require('./errors');
const { sameTile, walkable, validateRoomSetup } = require('./contracts');

const IMPOSTORS = 1;
const KILL_COOLDOWN_MS = 25000;
const SABOTAGE_COOLDOWN_MS = 45000;
const MEETING_MS = 30000;

class Game {
  constructor(room, options = {}) {
    this.room = room;
    this.now = options.now || Date.now;
    this.randomIndex = options.randomIndex || randomInt;
    this.setTimer = options.setTimer || setTimeout;
    this.clearTimer = options.clearTimer || clearTimeout;
    this.killCooldownEndsAt = null;
    this.sabotageCooldownEndsAt = 0;
    this.lightsOut = false;
    this.meeting = null;
    this.meetingTimer = null;
    this.emergencies = 0;
    this.winner = null;
  }

  phase(phase) {
    requireAction(this.room.phase === phase, 'INVALID_PHASE', `Action requires phase '${phase}'.`);
  }

  host(player) {
    requireAction(player.id === this.room.hostId, 'HOST_ONLY', 'Only the host can do this.');
  }

  living(player) {
    requireAction(player.alive, 'PLAYER_DEAD', 'Eliminated players cannot perform this action.');
  }

  crew(player) {
    this.living(player);
    requireAction(player.role === 'crew', 'CREW_ONLY', 'Only living crew can do this.');
  }

  impostor(player) {
    this.living(player);
    requireAction(player.role === 'impostor', 'IMPOSTOR_ONLY', 'Only the living impostor can do this.');
  }

  counts() {
    const crew = [...this.room.players.values()].filter((player) => player.alive && player.role === 'crew');
    const stationCount = this.room.stations.filter((station) => station.kind === 'task').length;
    return { tasksDone: crew.reduce((total, player) => total + (player.completedTasks?.size || 0), 0),
      tasksTotal: crew.length * stationCount };
  }

  state() {
    return { phase: this.room.phase, players: this.room.publicPlayers(), ...this.counts(),
      lightsOut: this.lightsOut, killCooldownEndsAt: this.killCooldownEndsAt,
      meeting: this.meeting ? { ...this.meeting, votes: { ...this.meeting.votes } } : null };
  }

  publish() {
    this.room.broadcast({ t: 'state', ...this.state() });
  }

  setup(player, message) {
    this.phase('lobby');
    this.host(player);
    const setup = validateRoomSetup(message.grid, message.stations);
    this.room.grid = setup.grid;
    this.room.stations = setup.stations;
    for (const member of this.room.players.values()) { member.tile = null; member.pendingTile = null; }
    this.room.broadcastLobby();
  }

  start(player) {
    this.phase('lobby');
    this.host(player);
    const players = [...this.room.players.values()];
    requireAction(players.length === 4 && this.room.publicPlayers().every((member) => member.connected),
      'NEED_FOUR_PLAYERS', 'Four connected players are required.');
    const impostorIndex = this.randomIndex(players.length);
    players.forEach((member, index) => {
      member.role = index === impostorIndex ? 'impostor' : 'crew';
      member.alive = true;
      member.completedTasks = new Set();
      member.usedEmergency = false;
      member.reportable = false;
      member.pendingTile = null;
      this.room.sendTo(member, { t: 'role', role: member.role });
    });
    this.room.phase = 'playing';
    this.killCooldownEndsAt = this.now() + KILL_COOLDOWN_MS;
    this.publish();
  }

  tile(player, message) {
    requireAction(['lobby', 'playing'].includes(this.room.phase), 'INVALID_PHASE', 'Tiles are frozen during meetings and after the game.');
    this.living(player);
    if (!walkable(message.tile, this.room.grid) || !['ar', 'manual'].includes(message.source)) {
      player.pendingTile = null;
      requireAction(false, 'INVALID_TILE', 'Send an accessible integer tile and ar/manual source.');
    }
    const tile = { x: message.tile.x, y: message.tile.y };
    if (sameTile(player.tile, tile) && player.tileSource === message.source) {
      player.pendingTile = null;
      return;
    }
    if (!sameTile(player.pendingTile?.tile, tile) || player.pendingTile?.source !== message.source) {
      player.pendingTile = { tile, source: message.source };
      return;
    }
    player.tile = tile;
    player.tileSource = message.source;
    player.pendingTile = null;
    if (this.room.phase === 'lobby') this.room.broadcastLobby();
    else this.publish();
  }

  taskDone(player, message) {
    this.phase('playing');
    this.crew(player);
    const station = this.room.stations.find((item) => item.id === message.stationId && item.kind === 'task');
    requireAction(station && sameTile(player.tile, station.tile), 'INVALID_STATION', 'Be on the task station tile.');
    requireAction(!this.lightsOut, 'LIGHTS_OUT', 'Fix lights before completing tasks.');
    requireAction(!player.completedTasks.has(station.id), 'TASK_ALREADY_DONE', 'You already completed this station.');
    player.completedTasks.add(station.id);
    this.checkWin();
    this.publish();
  }

  kill(player, message) {
    this.phase('playing');
    this.impostor(player);
    const target = this.room.players.get(message.targetId);
    requireAction(target && target.alive && target.role === 'crew' && sameTile(player.tile, target.tile),
      'INVALID_TARGET', 'A living crew target must be on the same tile.');
    requireAction(this.now() >= this.killCooldownEndsAt, 'KILL_COOLDOWN', 'Kill cooldown has not elapsed.');
    target.alive = false;
    target.reportable = true;
    target.pendingTile = null;
    this.killCooldownEndsAt = this.now() + KILL_COOLDOWN_MS;
    this.room.sendTo(target, { t: 'killed' });
    this.checkWin();
    this.publish();
  }

  beginMeeting(reason, bodyOf = null) {
    this.room.phase = 'meeting';
    this.meeting = { reason, bodyOf, endsAt: this.now() + MEETING_MS, votes: {} };
    for (const player of this.room.players.values()) player.pendingTile = null;
    this.meetingTimer = this.setTimer(() => this.finishMeeting(), MEETING_MS);
    this.meetingTimer?.unref?.();
    this.room.broadcast({ t: 'meeting', ...this.meeting });
    this.publish();
  }

  report(player, message) {
    this.phase('playing');
    this.living(player);
    const body = this.room.players.get(message.bodyId);
    requireAction(body && !body.alive && body.reportable && sameTile(player.tile, body.tile),
      'INVALID_BODY', 'Be on the tile of an unreported body.');
    this.beginMeeting('report', body.id);
  }

  emergency(player) {
    this.phase('playing');
    this.living(player);
    requireAction(sameTile(player.tile, { x: 0, y: 0 }), 'EMERGENCY_TILE', 'Go to emergency tile (0,0).');
    requireAction(!player.usedEmergency && this.emergencies < 3, 'EMERGENCY_USED', 'Emergency meeting allowance used.');
    player.usedEmergency = true;
    this.emergencies += 1;
    this.beginMeeting('emergency');
  }

  vote(player, message) {
    this.phase('meeting');
    this.living(player);
    const target = this.room.players.get(message.target);
    requireAction(message.target === 'skip' || target?.alive, 'INVALID_VOTE', 'Vote for a living player or skip.');
    requireAction(!Object.hasOwn(this.meeting.votes, player.id), 'ALREADY_VOTED', 'One vote per living player.');
    this.meeting.votes[player.id] = message.target;
    const living = [...this.room.players.values()].filter((member) => member.alive);
    if (living.every((member) => Object.hasOwn(this.meeting.votes, member.id))) this.finishMeeting();
    else this.publish();
  }

  finishMeeting() {
    if (this.room.phase !== 'meeting') return;
    this.clearTimer(this.meetingTimer);
    this.meetingTimer = null;
    const living = [...this.room.players.values()].filter((player) => player.alive);
    const votes = Object.values(this.meeting.votes);
    const ejected = living.find((player) => votes.filter((id) => id === player.id).length > living.length / 2);
    if (ejected) ejected.alive = false;
    for (const player of this.room.players.values()) player.reportable = false;
    this.meeting = null;
    this.room.phase = 'playing';
    this.checkWin(false);
    this.room.broadcast({ t: 'result', ejected: ejected?.id || null, role: ejected?.role || null, winner: this.winner });
    this.publish();
  }

  sabotage(player) {
    this.phase('playing');
    this.impostor(player);
    requireAction(!this.lightsOut, 'LIGHTS_ALREADY_OUT', 'Lights are already out.');
    requireAction(this.now() >= this.sabotageCooldownEndsAt, 'SABOTAGE_COOLDOWN', 'Sabotage cooldown has not elapsed.');
    this.lightsOut = true;
    this.sabotageCooldownEndsAt = this.now() + SABOTAGE_COOLDOWN_MS;
    this.publish();
  }

  fix(player, message) {
    this.phase('playing');
    this.crew(player);
    const station = this.room.stations.find((item) => item.id === message.stationId && item.kind === 'fix');
    requireAction(this.lightsOut && station && sameTile(player.tile, station.tile), 'INVALID_FIX', 'Fix lights on a fix station tile.');
    this.lightsOut = false;
    this.publish();
  }

  checkWin(announce = true) {
    const players = [...this.room.players.values()];
    const crew = players.filter((player) => player.alive && player.role === 'crew').length;
    const impostors = players.filter((player) => player.alive && player.role === 'impostor').length;
    const { tasksDone, tasksTotal } = this.counts();
    if (impostors === 0 || (tasksTotal > 0 && tasksDone >= tasksTotal)) this.winner = 'crew';
    else if (crew <= impostors) this.winner = 'impostor';
    if (this.winner) {
      this.room.phase = 'ended';
      if (announce) this.room.broadcast({ t: 'result', ejected: null, role: null, winner: this.winner });
    }
  }

  handle(player, message) {
    const actions = { setRoom: 'setup', start: 'start', tile: 'tile', taskDone: 'taskDone', kill: 'kill',
      report: 'report', emergency: 'emergency', vote: 'vote', sabotage: 'sabotage', fix: 'fix' };
    const action = Object.hasOwn(actions, message.t) && actions[message.t];
    requireAction(action, 'UNKNOWN_EVENT', 'Unknown game event.');
    this[action](player, message);
  }

  dispose() {
    if (this.meetingTimer) this.clearTimer(this.meetingTimer);
  }
}

module.exports = { Game, IMPOSTORS, KILL_COOLDOWN_MS, SABOTAGE_COOLDOWN_MS, MEETING_MS };
