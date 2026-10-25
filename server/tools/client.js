const WebSocket = require('ws');

function connectClient(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { handshakeTimeout: 5000 });
    const inbox = [];
    const waiters = [];
    let failure;
    function fail(error) {
      failure = error;
      for (const waiter of waiters.splice(0)) { clearTimeout(waiter.timer); waiter.reject(error); }
      reject(error);
    }
    socket.on('message', (raw) => {
      const message = JSON.parse(raw.toString());
      const index = waiters.findIndex((waiter) => waiter.predicate(message));
      if (message.t === 'error' && index < 0 && waiters.length) {
        for (const waiter of waiters.splice(0)) {
          clearTimeout(waiter.timer);
          waiter.reject(new Error(`${message.code}: ${message.message}`));
        }
        return;
      }
      if (index < 0) {
        inbox.push(message);
        if (inbox.length > 500) inbox.shift();
      } else {
        const [waiter] = waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      }
    });
    socket.on('error', fail);
    socket.on('close', () => fail(new Error('Client disconnected.')));
    socket.once('open', () => resolve({
      socket,
      send: (message) => socket.send(JSON.stringify(message)),
      waitFor(predicate, timeout = 5000) {
        if (failure) return Promise.reject(failure);
        const index = inbox.findIndex(predicate);
        if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
        const errorIndex = inbox.findIndex((message) => message.t === 'error');
        if (errorIndex >= 0) {
          const [error] = inbox.splice(errorIndex, 1);
          return Promise.reject(new Error(`${error.code}: ${error.message}`));
        }
        return new Promise((done, failed) => {
          const waiter = { predicate, resolve: done, reject: failed };
          waiter.timer = setTimeout(() => {
            waiters.splice(waiters.indexOf(waiter), 1);
            failed(new Error('Timed out waiting for a server event.'));
          }, timeout);
          waiters.push(waiter);
        });
      },
    }));
  });
}

module.exports = { connectClient };
