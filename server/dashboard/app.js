const $ = (id) => document.getElementById(id);
const escape = (value) => String(value).replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
let snapshot;
let selectedRoom;
let previous;
let loading = false;
let launching = false;
const bots = [];
const events = [];

function log(message) {
  events.unshift({ time: new Date().toLocaleTimeString(), message });
  events.splice(60);
  $('activity').innerHTML = events.map((event) => `<li><time>${escape(event.time)}</time>${escape(event.message)}</li>`).join('');
}

function observe(data) {
  if (!previous || previous.startedAt !== data.startedAt) {
    log(previous ? 'Server restarted. In-memory rooms have reset.' : 'Connected to the backend monitor.');
  } else {
    for (const room of data.rooms) {
      const oldRoom = previous.rooms.find((old) => old.code === room.code);
      if (!oldRoom) log(`Room ${room.code} created.`);
      for (const player of room.players) {
        const oldPlayer = oldRoom?.players.find((old) => old.label === player.label);
        if (!oldPlayer) log(`${player.name} joined ${room.code}.`);
        else if (oldPlayer.connected !== player.connected) log(`${player.name} ${player.connected ? 'reconnected to' : 'disconnected from'} ${room.code}.`);
        else if (oldPlayer.ready !== player.ready) log(`${player.name} is ${player.ready ? 'ready' : 'not ready'} in ${room.code}.`);
      }
    }
  }
  previous = data;
}

function render() {
  if (!snapshot) return;
  const players = snapshot.rooms.flatMap((room) => room.players);
  $('room-count').textContent = snapshot.rooms.length;
  $('room-badge').textContent = snapshot.rooms.length;
  $('connected-count').textContent = players.filter((player) => player.connected).length;
  $('ready-count').textContent = players.filter((player) => player.connected && player.ready).length;
  $('registered-count').textContent = `${players.length} registered across all rooms`;
  $('socket-count').textContent = snapshot.connections;
  const seconds = Math.floor((snapshot.now - snapshot.startedAt) / 1000);
  $('uptime').textContent = seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ${seconds % 60}s` : `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  if (!snapshot.rooms.some((room) => room.code === selectedRoom)) selectedRoom = snapshot.rooms.at(-1)?.code;
  $('room-tabs').innerHTML = snapshot.rooms.map((room) => `<button data-room="${escape(room.code)}" aria-pressed="${room.code === selectedRoom}">${escape(room.code)}</button>`).join('');
  const room = snapshot.rooms.find((room) => room.code === selectedRoom);
  if (!room) {
    $('room-content').innerHTML = '<div class="empty"><span class="empty-icon">⌘</span><h3>Waiting for your first crew</h3><p>Create a room from an iPhone or launch the test crew.</p></div>';
    return;
  }
  const ready = room.players.filter((player) => player.ready && player.connected).length;
  const connected = room.players.filter((player) => player.connected).length;
  $('room-content').innerHTML = `<div class="room-summary"><div><div class="room-code">${escape(room.code)}</div><div class="room-meta">${connected}/4 connected · ${ready}/4 ready · ${room.grid.cols} × ${room.grid.rows} grid</div></div><span class="badge">${escape(room.phase.toUpperCase())}</span></div><div class="progress" aria-label="${ready} of 4 players ready"><span style="width:${ready / 4 * 100}%"></span></div><table class="players"><thead><tr><th>PLAYER</th><th>CONNECTION</th><th>LOBBY STATUS</th><th>POSITION</th></tr></thead><tbody>${room.players.map((player) => `<tr><td><div class="identity"><span class="avatar">${escape(player.name.charAt(0).toUpperCase())}</span><div><div class="player-name">${escape(player.name)}${player.host ? '<span class="host">HOST</span>' : ''}</div><div class="player-id">${escape(player.label)}</div></div></div></td><td><span class="status ${player.connected ? 'online' : 'offline'}">${player.connected ? 'Connected' : 'Disconnected'}</span></td><td><span class="status ${player.ready ? 'online' : 'waiting'}">${player.ready ? 'Ready' : 'Not ready'}</span></td><td class="waiting">${player.tile ? `${player.tile.x}, ${player.tile.y}` : 'Awaiting tile'}</td></tr>`).join('')}</tbody></table><p class="footnote">${room.stationCount} stations · ${room.hasMap ? 'Room map available' : 'Room map pending'} · ${room.grid.tileSize} m tiles</p>`;
}

async function refresh() {
  if (loading) return;
  loading = true;
  try {
    const response = await fetch('/api/dashboard', { cache: 'no-store', signal: AbortSignal.timeout(4000) });
    if (!response.ok) throw new Error(`Server returned ${response.status}`);
    const data = await response.json();
    observe(data);
    snapshot = data;
    render();
    $('server-status').textContent = '● SERVER ONLINE';
    $('server-status').className = 'badge';
    $('updated').textContent = `Updated ${new Date().toLocaleTimeString()}`;
    $('error').hidden = true;
  } catch (error) {
    $('server-status').textContent = 'SERVER UNREACHABLE';
    $('server-status').className = 'badge offline';
    $('updated').textContent = 'Updates paused';
    $('error').textContent = `Cannot reach the backend. Showing the last received state. ${error.message}`;
    $('error').hidden = false;
  } finally {
    loading = false;
  }
}

function renderBots() {
  $('launch').disabled = launching || bots.length > 0;
  $('ready-all').disabled = !bots.some((bot) => bot.socket?.readyState === WebSocket.OPEN);
  $('disconnect-all').disabled = bots.length === 0;
  $('simulation').innerHTML = bots.map((bot, index) => `<div class="simulation-player"><div>${escape(bot.name)} <span>· ${bot.socket?.readyState === WebSocket.OPEN ? 'connected' : 'offline'}</span></div><button data-bot="${index}" ${bot.playerId ? '' : 'disabled'}>${bot.socket?.readyState === WebSocket.OPEN ? 'Disconnect' : 'Reconnect'}</button></div>`).join('');
}

function connectBot(bot, create = false) {
  return new Promise((resolve, reject) => {
    let joined = false;
    const socket = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
    bot.socket = socket;
    const timeout = setTimeout(() => { socket.close(); reject(new Error('Test player connection timed out.')); }, 5000);
    socket.addEventListener('open', () => socket.send(JSON.stringify(create
      ? { t: 'create', name: bot.name }
      : { t: 'join', name: bot.name, room: bot.room, ...(bot.playerId ? { playerId: bot.playerId } : {}) })));
    socket.addEventListener('message', ({ data }) => {
      const message = JSON.parse(data);
      if (message.t === 'joined') {
        joined = true;
        clearTimeout(timeout);
        bot.room = message.room;
        bot.playerId = message.playerId;
        selectedRoom = message.room;
        resolve();
        renderBots();
        refresh();
      } else if (message.t === 'error') {
        clearTimeout(timeout);
        socket.close();
        $('simulation-status').textContent = message.message;
        reject(new Error(message.message));
      }
    });
    socket.addEventListener('error', () => {
      clearTimeout(timeout);
      reject(new Error('Cannot connect the test player. Check the server.'));
    });
    socket.addEventListener('close', () => {
      clearTimeout(timeout);
      if (!joined) reject(new Error('Test player disconnected before joining.'));
      renderBots();
      refresh();
    });
  });
}

$('launch').addEventListener('click', async () => {
  launching = true;
  renderBots();
  $('simulation-status').textContent = 'Connecting test crew…';
  try {
    for (let i = 0; i < 4; i += 1) {
      const bot = { name: `Test Player ${i + 1}`, room: bots[0]?.room };
      bots.push(bot);
      await connectBot(bot, i === 0);
    }
    $('simulation-status').textContent = `Test crew joined ${bots[0].room}. Try readying or disconnecting a player.`;
  } catch (error) {
    $('simulation-status').textContent = error.message;
  } finally {
    launching = false;
    renderBots();
    refresh();
  }
});
$('ready-all').addEventListener('click', () => {
  for (const bot of bots) if (bot.socket?.readyState === WebSocket.OPEN) bot.socket.send(JSON.stringify({ t: 'ready', ready: true }));
});
$('disconnect-all').addEventListener('click', () => {
  for (const bot of bots) bot.socket?.close();
  bots.splice(0);
  renderBots();
  $('simulation-status').textContent = 'Test crew disconnected. Their room is retained for inspection.';
});
$('simulation').addEventListener('click', async (event) => {
  const button = event.target.closest('[data-bot]');
  if (!button) return;
  const bot = bots[Number(button.dataset.bot)];
  if (!bot) return;
  if (bot.socket?.readyState === WebSocket.OPEN) bot.socket.close();
  else {
    button.disabled = true;
    try { await connectBot(bot); } catch (error) { $('simulation-status').textContent = error.message; }
    renderBots();
  }
});
$('room-tabs').addEventListener('click', (event) => {
  const button = event.target.closest('[data-room]');
  if (button) { selectedRoom = button.dataset.room; render(); }
});
$('clear-log').addEventListener('click', () => { events.splice(0); $('activity').innerHTML = '<li class="quiet">Activity cleared.</li>'; });
$('refresh').addEventListener('click', refresh);
window.addEventListener('pagehide', () => bots.forEach((bot) => bot.socket?.close()));
refresh();
setInterval(refresh, 1000);
