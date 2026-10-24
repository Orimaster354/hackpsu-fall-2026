const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const WebSocket = require('ws');
const { RoomError, RoomManager, send } = require('./rooms');

function createAppServer() {
  const rooms = new RoomManager();
  const server = http.createServer((request, response) => {
    if (request.method === 'GET' && request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: true }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  const sockets = new WebSocket.WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });

  server.on('upgrade', (request, socket, head) => {
    if (new URL(request.url, 'http://localhost').pathname !== '/ws') {
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

    socket.on('message', (raw, isBinary) => {
      try {
        if (isBinary) throw new RoomError('INVALID_MESSAGE', 'Send a JSON text frame.');
        const message = JSON.parse(raw.toString('utf8'));
        if (!message || typeof message !== 'object' || Array.isArray(message)) {
          throw new RoomError('INVALID_MESSAGE', 'Message must be a JSON object.');
        }

        if (message.t === 'create' || message.t === 'join') {
          if (membership) throw new RoomError('ALREADY_JOINED', 'This connection is already in a room.');
          membership = message.t === 'create'
            ? rooms.create(message.name, socket)
            : rooms.join(message.room, message.name, socket, message.playerId);
          send(socket, { t: 'joined', playerId: membership.player.id, room: membership.room.code });
          membership.room.broadcastLobby();
          return;
        }

        if (!membership) throw new RoomError('NOT_JOINED', 'Create or join a room first.');
        throw new RoomError('NOT_IMPLEMENTED', `Event '${message.t}' is not part of the lobby skeleton.`);
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
    createAppServer().listen(port).then((address) => {
      console.log(`ROOMSHIFT server listening on 0.0.0.0:${address.port}`);
    }).catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
  }
}

module.exports = { createAppServer };
