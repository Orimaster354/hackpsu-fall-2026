const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const WebSocket = require('ws');
const { RoomError, RoomManager, send } = require('./rooms');
const { handleMap } = require('./maps');
const { createGeminiClient } = require('./gemini');
const { LiveScan } = require('./liveScan');
const { createVideoTestHandler } = require('./videoLab');
const { createScanHandler } = require('./scans');

function createAppServer(options = {}) {
  const rooms = new RoomManager(options);
  const suggest = options.suggest || createGeminiClient();
  const startedAt = Date.now();
  const videoTest = createVideoTestHandler(options);
  const scan = createScanHandler(rooms,options);
  const dashboardAssets = new Map([
    ['/dashboard', ['index.html', 'text/html; charset=utf-8']],
    ['/dashboard/', ['index.html', 'text/html; charset=utf-8']],
    ['/dashboard/app.js', ['app.js', 'text/javascript; charset=utf-8']],
    ['/dashboard/style.css', ['style.css', 'text/css; charset=utf-8']],
    ['/dashboard/live', ['live.html', 'text/html; charset=utf-8']],
    ['/dashboard/live.js', ['live.js', 'text/javascript; charset=utf-8']],
    ['/dashboard/live.css', ['live.css', 'text/css; charset=utf-8']],
    ['/dashboard/videos', ['videos.html', 'text/html; charset=utf-8']],
    ['/dashboard/videos.js', ['videos.js', 'text/javascript; charset=utf-8']],
    ['/dashboard/videos.css', ['videos.css', 'text/css; charset=utf-8']],
  ].map(([route, [file, type]]) => [route, { type, body: fs.readFileSync(path.join(__dirname, 'dashboard', file)) }]));
  const testVideoPath = options.testVideoPath || process.env.LIVE_SCAN_TEST_VIDEO;
  if (testVideoPath) {
    const size = fs.statSync(testVideoPath).size;
    if (size > 10 * 1024 * 1024) throw new Error('Local test video must be at most 10 MiB.');
    dashboardAssets.set('/dashboard/demo-video', { type: 'video/mp4', body: fs.readFileSync(testVideoPath) });
  }
  const server = http.createServer((request, response) => {
    let route;
    try { route = new URL(request.url, 'http://localhost').pathname; }
    catch { response.writeHead(400); response.end(); return; }
    if (route === '/api/dashboard/video-test') {
      void videoTest(request, response);
      return;
    }
    const mapRoute = /^\/map\/([A-Z]{4})$/.exec(route);
    const scanRoute = /^\/scan\/([A-Z]{4})\/(perimeter|sweep)$/.exec(route);
    if (scanRoute) { void scan(request,response,scanRoute[1],scanRoute[2]); return; }
    if (mapRoute) {
      void handleMap(request, response, rooms, mapRoute[1], options.maxMapBytes);
      return;
    }
    if (request.method === 'GET' && (dashboardAssets.has(route) || route === '/api/dashboard')) {
      const address = request.socket.remoteAddress;
      if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address)) {
        response.writeHead(403);
        response.end('Dashboard is available on the server laptop only.');
        return;
      }
      response.setHeader('Cache-Control', 'no-store');
      response.setHeader('X-Content-Type-Options', 'nosniff');
      if (route === '/api/dashboard') {
        const roomList = Array.from(rooms.rooms.values(), (room) => ({
          code: room.code,
          phase: room.phase,
          grid: room.grid ? { cols: room.grid.cols, rows: room.grid.rows, tileSize: room.grid.tileSize,
            originX: room.grid.originX, originZ: room.grid.originZ } : null,
          setupConfirmed: room.setupConfirmed,
          stationCount: room.stations.length,
          hasMap: room.hasMap,
          players: room.lobbyMessage().players.map((player) => ({
            label: player.id.slice(0, 8), name: player.name,
            host: player.id === room.hostId, connected: player.connected,
            ready: player.ready, alive: player.alive, tile: player.tile, tileSource: player.tileSource,
          })),
        }));
        response.writeHead(200, { 'content-type': 'application/json' });
        const port = server.address().port;
        const addresses = [...new Set(Object.values(os.networkInterfaces()).flat()
          .filter((entry) => entry && entry.family === 'IPv4' && !entry.internal)
          .map((entry) => entry.address))];
        response.end(JSON.stringify({ startedAt, now: Date.now(), connections: sockets.clients.size,
          connectionUrls: addresses.map((address) => `ws://${address}:${port}/ws`), rooms: roomList }));
      } else {
        const asset = dashboardAssets.get(route);
        response.writeHead(200, { 'content-type': asset.type, 'content-length': asset.body.length });
        response.end(asset.body);
      }
      return;
    }
    if (request.method === 'GET' && request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: true }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  const sockets = new WebSocket.WebSocketServer({ noServer: true, maxPayload: 6 * 1024 * 1024 });

  server.on('upgrade', (request, socket, head) => {
    let route;
    try { route = new URL(request.url, 'http://localhost').pathname; }
    catch { socket.destroy(); return; }
    if (route !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }
    sockets.handleUpgrade(request, socket, head, (websocket) => {
      sockets.emit('connection', websocket);
    });
  });

  sockets.on('connection', (socket) => {
    let membership = null;

    socket.on('message', async (raw, isBinary) => {
      try {
        if (isBinary) throw new RoomError('INVALID_MESSAGE', 'Send a JSON text frame.');
        const message = JSON.parse(raw.toString('utf8'));
        if (!message || typeof message !== 'object' || Array.isArray(message)) {
          throw new RoomError('INVALID_MESSAGE', 'Message must be a JSON object.');
        }
        if (!['suggest', 'scan_frame'].includes(message.t) && raw.length > 64 * 1024) {
          throw new RoomError('MESSAGE_TOO_LARGE', 'Non-image events are limited to 64 KiB.');
        }

        if (message.t === 'create' || message.t === 'join') {
          if (membership) throw new RoomError('ALREADY_JOINED', 'This connection is already in a room.');
          membership = message.t === 'create'
            ? rooms.create(message.name, socket)
            : rooms.join(message.room, message.name, socket, message.playerId);
          send(socket, { t: 'joined', playerId: membership.player.id, room: membership.room.code });
          if (membership.room.grid) send(socket, membership.room.setupMessage());
          if (membership.room.phase === 'lobby') membership.room.broadcastLobby();
          else {
            send(socket, membership.room.lobbyMessage());
            send(socket, { t: 'role', role: membership.player.role });
            membership.room.game.publish();
            if (membership.room.game.winner) send(socket, {
              t: 'result', ejected: null, role: null, winner: membership.room.game.winner,
            });
          }
          return;
        }

        if (!membership) throw new RoomError('NOT_JOINED', 'Create or join a room first.');
        if (membership.player.socket !== socket) {
          throw new RoomError('CONNECTION_REPLACED', 'This player has reconnected on another connection.');
        }
        if (message.t === 'ready') {
          membership.room.setReady(membership.player.id, message.ready);
          return;
        }
        if (['scan_start', 'scan_frame', 'scan_stop'].includes(message.t)) {
          const { room, player } = membership;
          room.game.phase('lobby');
          room.game.host(player);
          if (message.t === 'scan_start') {
            if (room.liveScan) throw new RoomError('SCAN_ACTIVE', 'Stop the current scan before starting another.');
            const scan = new LiveScan({ ...(options.liveScanOptions || {}),
              notify: (event) => {
                if (player.socket === socket && (event.t !== 'scan_detections' || room.phase === 'lobby')) send(socket, event);
              }, onStop: () => { if (room.liveScan === scan) room.liveScan = null; },
            });
            room.liveScan = scan;
            send(socket, { t: 'scan_status', state: 'connecting' });
            try { await scan.start(); } catch (error) { scan.stop('error'); throw error; }
          } else if (message.t === 'scan_stop') {
            if (room.liveScan) room.liveScan.stop();
            else send(socket, { t: 'scan_status', state: 'stopped', reason: 'host_stopped' });
          } else {
            if (!room.liveScan) throw new RoomError('SCAN_NOT_READY', 'Start a scan first.');
            room.liveScan.frame(message);
          }
          return;
        }
        if (message.t === 'suggest') {
          const { room, player } = membership;
          room.game.phase('lobby');
          room.game.host(player);
          if (room.suggestionInFlight) throw new RoomError('SUGGEST_BUSY', 'A suggestion is already in progress.');
          room.suggestionInFlight = true;
          try {
            const objects = await suggest(message);
            room.game.phase('lobby');
            if (player.socket === socket) send(socket, { t: 'suggestions', objects });
          } finally {
            room.suggestionInFlight = false;
          }
          return;
        }
        membership.room.game.handle(membership.player, message);
        if (membership.room.phase !== 'lobby') membership.room.liveScan?.stop('game_started');
      } catch (error) {
        if (error instanceof SyntaxError) {
          send(socket, { t: 'error', code: 'INVALID_JSON', message: 'Message is not valid JSON.' });
        } else if (error instanceof RoomError) {
          send(socket, { t: 'error', code: error.code, message: error.message });
        } else {
          console.error(error);
          send(socket, { t: 'error', code: 'SERVER_ERROR', message: 'Unexpected server error.' });
        }
      }
    });

    socket.on('close', () => {
      if (membership) membership.room.detach(membership.player.id, socket);
    });
    socket.on('error', (error) => console.error('WebSocket error:', error.message));
  });

  return {
    server,
    rooms,
    listen(port = 8080, host = '0.0.0.0') {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.removeListener('error', reject);
          resolve(server.address());
        });
      });
    },
    close() {
      scan.close();
      for (const room of rooms.rooms.values()) room.game.dispose();
      for (const room of rooms.rooms.values()) room.liveScan?.stop('server_stopped');
      for (const socket of sockets.clients) socket.terminate();
      return new Promise((resolve, reject) => {
        sockets.close((socketError) => {
          if (socketError) return reject(socketError);
          server.close((serverError) => serverError ? reject(serverError) : resolve());
        });
      });
    },
  };
}

if (require.main === module) {
  const envPath = path.join(__dirname, '.env');
  if (fs.existsSync(envPath)) process.loadEnvFile(envPath);
  const port = Number(process.env.PORT || 8080);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    console.error('PORT must be an integer between 0 and 65535.');
    process.exitCode = 1;
  } else {
    const appOptions = process.argv.includes('--manual-fixture')
      ? { manualSetup: JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'manual-setup.json'), 'utf8')) } : {};
    createAppServer(appOptions).listen(port).then((address) => {
      console.log(`ROOMSHIFT server listening on 0.0.0.0:${address.port}`);
      if (appOptions.manualSetup) console.log('Developer manual fixture enabled; host must confirm setup.');
    }).catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
  }
}

module.exports = { createAppServer };
