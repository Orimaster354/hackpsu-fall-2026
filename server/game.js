const { randomInt } = require('node:crypto');
const { requireAction } = require('./errors');
const { sameTile, walkable, validateRoomSetup } = require('./contracts');
const zones = require('./zones');

const MIN_PLAYERS = 4;
const MAX_PLAYERS = 10;
/** One impostor up to six players, two from seven. */
const impostorCount = (players) => (players >= 7 ? 2 : 1);
const KILL_COOLDOWN_MS = 25000;
const SABOTAGE_COOLDOWN_MS = 45000;
const MEETING_MS = 30000;
/** How long the crew have to repair a meltdown before the impostors win. */
const MELTDOWN_MS = 60000;
/** Two crew must finish holding the repair within this long of each other to stop a meltdown. */
const FIX_PAIR_WINDOW_MS = 4000;
const SCOUT_USES = 2;
const SCOUT_COOLDOWN_MS = 40000;

/**
 * The impostors' three sabotages. Only one can be active at a time, they share one cooldown, and each is
 * repaired at a fix station (the server picks which one when the sabotage starts).
 *  - lights: tasks are off until one crew member holds the fix.
 *  - jammer: no reports or emergency meetings, and phones lose the map, until one crew member holds the fix.
 *  - meltdown: reports and meetings are off and a timer runs. Two crew must hold the fix together, or the
 *    impostors win when the timer ends.
 */
const SABOTAGES = ['lights', 'jammer', 'meltdown'];
/** The special crew roles. Each is held by exactly one crew member in every game. */
const POWERS = ['medic', 'scout'];

class Game {
  constructor(room, options = {}) {
    this.room = room;
    this.now = options.now || Date.now;
    this.randomIndex = options.randomIndex || randomInt;
    this.setTimer = options.setTimer || setTimeout;
    this.clearTimer = options.clearTimer || clearTimeout;
    this.killCooldownEndsAt = null;
    this.sabotageCooldownEndsAt = 0;
    this.activeSabotage = null;
    this.fixHolds = new Map();
    this.meltdownTimer = null;
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
    requireAction(player.role === 'impostor', 'IMPOSTOR_ONLY', 'Only a living impostor can do this.');
  }

  /** Kept for older code and tests: true while the lights sabotage is active. */
  get lightsOut() {
    return this.activeSabotage?.kind === 'lights';
  }

  /** True while a sabotage stops reports and emergency meetings. */
  meetingsBlocked() {
    return this.activeSabotage?.kind === 'jammer' || this.activeSabotage?.kind === 'meltdown';
  }

  counts() {
    const crew = [...this.room.players.values()].filter((player) => player.alive && player.role === 'crew');
    const stationCount = this.room.stations.filter((station) => station.kind === 'task').length;
    return { tasksDone: crew.reduce((total, player) => total + (player.completedTasks?.size || 0), 0),
      tasksTotal: crew.length * stationCount };
  }

  sabotageState() {
    if (!this.activeSabotage) return null;
    const { kind, fixStationId, endsAt } = this.activeSabotage;
    const fresh = [...this.fixHolds.values()].filter((at) => this.now() - at <= FIX_PAIR_WINDOW_MS).length;
    return { kind, fixStationId, endsAt, holders: kind === 'meltdown' ? fresh : 0 };
  }

  state() {
    return { phase: this.room.phase, players: this.room.publicPlayers(), ...this.counts(),
      lightsOut: this.activeSabotage?.kind === 'lights', sabotage: this.sabotageState(),
      killCooldownEndsAt: this.killCooldownEndsAt,
      meeting: this.meeting ? { ...this.meeting, votes: { ...this.meeting.votes } } : null };
  }

  publish() {
    this.room.broadcast({ t: 'state', ...this.state() });
  }

  /** What a player is told privately about their role: crew or impostor, a special power, and who their partners are. */
  roleMessage(player) {
    const partners = player.role === 'impostor'
      ? [...this.room.players.values()].filter((other) => other !== player && other.role === 'impostor').map((other) => other.id)
      : [];
    return { t: 'role', role: player.role, power: player.power || null, partners };
  }

  // Internal producer API for scan processing and explicit developer fixtures.
  // Clients cannot supply room geometry through a WebSocket event.
  applySetup(message) {
    this.phase('lobby');
    requireAction(!this.room.setupConfirmed, 'SETUP_LOCKED', 'Confirmed setup cannot be replaced.');
    const setup = validateRoomSetup(message.grid, message.stations);
    this.room.grid = setup.grid;
    this.room.stations = setup.stations;
    for (const member of this.room.players.values()) { member.tile = null; member.pendingTile = null; }
    this.room.setupConfirmed = false;
    this.room.broadcastSetup();
  }

  editStation(player, message) {
    requireAction(!this.room.scanBusy,'SCAN_BUSY','Wait for scan processing before editing setup.');
    this.phase('lobby');
    this.host(player);
    requireAction(this.room.grid, 'SETUP_MISSING', 'Wait for a server-generated setup.');
    requireAction(!this.room.setupConfirmed, 'SETUP_LOCKED', 'Confirmed stations cannot be edited.');
    const station = message.station || (message.delete === true ? { id: message.id, delete: true } : null);
    requireAction(station && typeof station.id === 'string', 'INVALID_STATION', 'Provide a station object or deletion.');
    const existing = this.room.stations.find((item) => item.id === station.id);
    requireAction(existing?.kind !== 'emergency' && station.kind !== 'emergency', 'EMERGENCY_LOCKED', 'The emergency station is server-controlled.');
    let stations;
    if (station.delete === true) {
      requireAction(existing, 'INVALID_STATION', 'Station does not exist.');
      stations = this.room.stations.filter((item) => item.id !== station.id);
    } else {
      stations = existing ? this.room.stations.map((item) => item.id === station.id ? station : item)
        : [...this.room.stations, station];
    }
    this.room.stations = validateRoomSetup(this.room.grid, stations).stations;
    this.room.broadcastSetup();
  }

  /** Host: choose which doors join which rooms. Replaces the whole list. */
  setDoors(player, message) {
    requireAction(!this.room.scanBusy, 'SCAN_BUSY', 'Wait for scan processing before editing doors.');
    this.phase('lobby');
    this.host(player);
    requireAction(!this.room.setupConfirmed, 'SETUP_LOCKED', 'Confirmed setup cannot be edited.');
    this.room.doors = zones.validateDoors(this.room, message.doors);
    this.room.broadcastSetup();
  }

  /** Host: drop one scanned room. The remaining rooms are laid out and allocated again. */
  removeZone(player, message) {
    requireAction(!this.room.scanBusy, 'SCAN_BUSY', 'Wait for scan processing before removing a room.');
    this.phase('lobby');
    this.host(player);
    requireAction(!this.room.setupConfirmed, 'SETUP_LOCKED', 'Confirmed setup cannot be edited.');
    const id = zones.zoneId(message.zone);
    requireAction(this.room.zones.has(id), 'INVALID_ZONE', 'That room does not exist.');
    this.room.zones.delete(id);
    zones.resetZone(this.room, id);
    if (zones.scannedZones(this.room).length) zones.recompose(this.room);
    else {
      this.room.grid = null;
      this.room.stations = [];
      for (const member of this.room.players.values()) { member.tile = null; member.pendingTile = null; }
      this.room.broadcastSetup();
    }
  }

  confirmSetup(player) {
    requireAction(!this.room.scanBusy,'SCAN_BUSY','Wait for scan processing before confirming setup.');
    this.phase('lobby');
    this.host(player);
    requireAction(this.room.grid, 'SETUP_MISSING', 'Wait for a server-generated setup.');
    validateRoomSetup(this.room.grid, this.room.stations);
    requireAction(zones.zonesConnected(this.room), 'ZONES_NOT_CONNECTED', 'Join every room to the others with doors first.');
    this.room.setupConfirmed = true;
    this.room.broadcastSetup();
  }

  start(player) {
    requireAction(!this.room.scanBusy,'SCAN_BUSY','Wait for scan processing before starting.');
    this.phase('lobby');
    this.host(player);
    requireAction(this.room.setupConfirmed, 'SETUP_NOT_CONFIRMED', 'The host must confirm setup before starting.');
    const players = [...this.room.players.values()];
    requireAction(players.length >= MIN_PLAYERS && players.length <= MAX_PLAYERS
      && this.room.publicPlayers().every((member) => member.connected),
    'NEED_FOUR_PLAYERS', `${MIN_PLAYERS} to ${MAX_PLAYERS} connected players are required.`);
    const candidates = [...players];
    const impostors = new Set();
    for (let index = 0; index < impostorCount(players.length); index += 1) {
      impostors.add(candidates.splice(this.randomIndex(candidates.length), 1)[0]);
    }
    // Each special power goes to a different crew member. `candidates` is now the crew.
    const holders = new Map();
    for (const power of POWERS) {
      if (candidates.length) holders.set(candidates.splice(this.randomIndex(candidates.length), 1)[0], power);
    }
    players.forEach((member) => {
      member.role = impostors.has(member) ? 'impostor' : 'crew';
      member.power = holders.get(member) || null;
      member.abilityUses = 0;
      member.abilityCooldownEndsAt = 0;
      member.alive = true;
      member.completedTasks = new Set();
      member.usedEmergency = false;
      member.reportable = false;
      member.pendingTile = null;
    });
    players.forEach((member) => this.room.sendTo(member, this.roleMessage(member)));
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
    requireAction(this.activeSabotage?.kind !== 'lights', 'LIGHTS_OUT', 'Fix lights before completing tasks.');
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

  /**
   * The special crew powers. Medic: bring back a freshly killed player, once, by standing on their body before it
   * is reported. Scout: see where everyone else is standing (tiles and head counts, never names), twice, with a
   * cooldown.
   */
  ability(player, message) {
    this.phase('playing');
    this.crew(player);
    requireAction(player.power, 'NO_ABILITY', 'You have no special ability.');
    if (player.power === 'medic') {
      requireAction(!player.abilityUses, 'ABILITY_USED', 'The Medic can revive only once.');
      const body = this.room.players.get(message.targetId);
      requireAction(body && !body.alive && body.reportable && sameTile(player.tile, body.tile),
        'INVALID_BODY', 'Stand on the tile of an unreported body to revive it.');
      body.alive = true;
      body.reportable = false;
      body.pendingTile = null;
      player.abilityUses = 1;
      this.room.sendTo(body, { t: 'revived' });
      this.publish();
      return;
    }
    requireAction((player.abilityUses || 0) < SCOUT_USES, 'ABILITY_USED', 'No scout pings left.');
    requireAction(this.now() >= (player.abilityCooldownEndsAt || 0), 'ABILITY_COOLDOWN', 'The scout is recharging.');
    const counts = new Map();
    for (const other of this.room.players.values()) {
      if (other === player || !other.alive || !other.tile) continue;
      const key = `${other.tile.x},${other.tile.y}`;
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    player.abilityUses = (player.abilityUses || 0) + 1;
    player.abilityCooldownEndsAt = this.now() + SCOUT_COOLDOWN_MS;
    this.room.sendTo(player, { t: 'scout',
      tiles: [...counts].map(([key, count]) => { const [x, y] = key.split(',').map(Number); return { x, y, count }; }),
      usesLeft: SCOUT_USES - player.abilityUses, cooldownEndsAt: player.abilityCooldownEndsAt });
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
    requireAction(!this.meetingsBlocked(), 'SABOTAGE_BLOCKS_MEETING', 'Repair the sabotage before reporting.');
    const body = this.room.players.get(message.bodyId);
    requireAction(body && !body.alive && body.reportable && sameTile(player.tile, body.tile),
      'INVALID_BODY', 'Be on the tile of an unreported body.');
    this.beginMeeting('report', body.id);
  }

  emergency(player) {
    this.phase('playing');
    this.living(player);
    requireAction(!this.meetingsBlocked(), 'SABOTAGE_BLOCKS_MEETING', 'Repair the sabotage before calling a meeting.');
    const station = this.room.stations.find((item) => item.kind === 'emergency' && sameTile(player.tile, item.tile));
    requireAction(station, 'EMERGENCY_TILE', 'Go to an emergency station.');
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

  sabotage(player, message = {}) {
    this.phase('playing');
    this.impostor(player);
    const kind = message.kind === undefined ? 'lights' : message.kind;
    requireAction(SABOTAGES.includes(kind), 'INVALID_SABOTAGE', `Sabotage must be one of ${SABOTAGES.join(', ')}.`);
    if (this.activeSabotage) {
      requireAction(false, this.activeSabotage.kind === 'lights' ? 'LIGHTS_ALREADY_OUT' : 'SABOTAGE_ACTIVE',
        'A sabotage is already active.');
    }
    requireAction(this.now() >= this.sabotageCooldownEndsAt, 'SABOTAGE_COOLDOWN', 'Sabotage cooldown has not elapsed.');
    const fixes = this.room.stations.filter((station) => station.kind === 'fix');
    // Lights stay usable without a fix station (as before); the new sabotages need somewhere to be repaired.
    requireAction(kind === 'lights' || fixes.length > 0, 'NO_FIX_STATION', 'This sabotage needs a fix station.');
    const target = fixes.length ? fixes[this.randomIndex(fixes.length)] : null;
    this.activeSabotage = { kind, fixStationId: target?.id || null, endsAt: kind === 'meltdown' ? this.now() + MELTDOWN_MS : null };
    this.fixHolds = new Map();
    this.sabotageCooldownEndsAt = this.now() + SABOTAGE_COOLDOWN_MS;
    if (kind === 'meltdown') {
      this.meltdownTimer = this.setTimer(() => this.meltdownExpired(), MELTDOWN_MS);
      this.meltdownTimer?.unref?.();
    }
    this.publish();
  }

  /** Crew repair the active sabotage at its fix station. A meltdown needs two crew finishing together. */
  fix(player, message) {
    this.phase('playing');
    this.crew(player);
    const station = this.room.stations.find((item) => item.id === message.stationId && item.kind === 'fix');
    requireAction(this.activeSabotage && station && sameTile(player.tile, station.tile)
      && (!this.activeSabotage.fixStationId || station.id === this.activeSabotage.fixStationId),
    'INVALID_FIX', 'Repair the sabotage at its fix station.');
    if (this.activeSabotage.kind !== 'meltdown') {
      this.clearSabotage();
      return;
    }
    const now = this.now();
    this.fixHolds.set(player.id, now);
    const partner = [...this.fixHolds].find(([id, at]) => {
      const other = this.room.players.get(id);
      return id !== player.id && now - at <= FIX_PAIR_WINDOW_MS && other?.alive && other.role === 'crew'
        && sameTile(other.tile, station.tile);
    });
    if (partner) this.clearSabotage();
    else this.publish();
  }

  clearSabotage() {
    if (this.meltdownTimer) this.clearTimer(this.meltdownTimer);
    this.meltdownTimer = null;
    this.activeSabotage = null;
    this.fixHolds = new Map();
    this.publish();
  }

  meltdownExpired() {
    this.meltdownTimer = null;
    if (this.activeSabotage?.kind !== 'meltdown' || ['ended'].includes(this.room.phase)) return;
    this.winner = 'impostor';
    this.room.phase = 'ended';
    this.room.broadcast({ t: 'result', ejected: null, role: null, winner: 'impostor' });
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
      if (this.meltdownTimer) this.clearTimer(this.meltdownTimer);
      this.meltdownTimer = null;
      if (announce) this.room.broadcast({ t: 'result', ejected: null, role: null, winner: this.winner });
    }
  }

  handle(player, message) {
    const actions = { editStation: 'editStation', setDoors: 'setDoors', removeZone: 'removeZone', confirmSetup: 'confirmSetup',
      start: 'start', tile: 'tile', taskDone: 'taskDone', kill: 'kill', ability: 'ability', report: 'report',
      emergency: 'emergency', vote: 'vote', sabotage: 'sabotage', fix: 'fix' };
    const action = Object.hasOwn(actions, message.t) && actions[message.t];
    requireAction(action, 'UNKNOWN_EVENT', 'Unknown game event.');
    this[action](player, message);
  }

  dispose() {
    if (this.meetingTimer) this.clearTimer(this.meetingTimer);
    if (this.meltdownTimer) this.clearTimer(this.meltdownTimer);
  }
}

module.exports = { Game, MIN_PLAYERS, MAX_PLAYERS, impostorCount, KILL_COOLDOWN_MS, SABOTAGE_COOLDOWN_MS, MEETING_MS,
  MELTDOWN_MS, FIX_PAIR_WINDOW_MS, SCOUT_USES, SCOUT_COOLDOWN_MS, SABOTAGES, POWERS };
