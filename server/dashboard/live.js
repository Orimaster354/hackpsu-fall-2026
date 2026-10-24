const el = (id) => document.getElementById(id);
const video = el('video');
const capture = document.createElement('canvas');
const frames = new Map();
let socket;
let interval;
let drainTimer;
let objectUrl;
let active = false;
let sent = 0;
let analyzed = 0;
let lastTimestamp = -1;

function log(text) {
  const item = document.createElement('li');
  const time = document.createElement('time');
  time.textContent = new Date().toLocaleTimeString();
  item.append(time, document.createTextNode(text));
  el('events').prepend(item);
  while (el('events').children.length > 60) el('events').lastChild.remove();
}

function state(text, live = false) {
  el('status').textContent = text;
  el('status').className = live ? 'badge' : 'badge muted';
}

function stop(sendStop = true) {
  active = false;
  clearInterval(interval);
  clearTimeout(drainTimer);
  video.pause();
  video.controls = true;
  el('start').disabled = !video.src;
  el('file').disabled = false;
  el('server-clip').disabled = false;
  el('stop').disabled = true;
  if (socket) {
    if (sendStop && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ t: 'scan_stop' }));
    socket.close();
    socket = null;
  }
  frames.clear();
  state('STOPPED');
  if (el('message').textContent.startsWith('Video ended.')) el('message').textContent = 'Scan finished. Replay the video or select another clip.';
}

function sendFrame() {
  if (!active || !socket || socket.readyState !== WebSocket.OPEN || video.paused || video.ended || video.readyState < 2) return;
  const timestampMs = Math.round(video.currentTime * 1000);
  if (timestampMs <= lastTimestamp) return;
  const scale = Math.min(1, 768 / Math.max(video.videoWidth, video.videoHeight));
  capture.width = Math.max(1, Math.round(video.videoWidth * scale));
  capture.height = Math.max(1, Math.round(video.videoHeight * scale));
  capture.getContext('2d').drawImage(video, 0, 0, capture.width, capture.height);
  const jpeg = capture.toDataURL('image/jpeg', 0.7).split(',')[1];
  if (jpeg.length > Math.ceil(256 * 1024 / 3) * 4) { log('Frame is too large; use a lower-resolution video.'); return; }
  const frameId = `frame-${++sent}`;
  frames.set(frameId, { jpeg, timestampMs, sentAt: performance.now() });
  if (frames.size > 24) frames.delete(frames.keys().next().value);
  lastTimestamp = timestampMs;
  socket.send(JSON.stringify({ t: 'scan_frame', frameId, timestampMs, jpeg }));
  el('sent').textContent = sent;
}

async function showDetections(message) {
  analyzed += 1;
  el('analyzed').textContent = analyzed;
  el('objects').textContent = message.objects.length;
  const frame = frames.get(message.frameId);
  const labels = [...new Set(message.objects.map((object) => object.label))];
  el('labels').replaceChildren(...labels.map((label) => { const item = document.createElement('li'); item.textContent = label; return item; }));
  log(`${message.frameId} @ ${message.timestampMs} ms: ${labels.join(', ') || 'no identifiable objects'}`);
  el('frame-info').textContent = `Frame ${message.frameId} · video time ${(message.timestampMs / 1000).toFixed(2)} s`;
  if (!frame) return;
  el('latency').textContent = `${((performance.now() - frame.sentAt) / 1000).toFixed(1)}s`;
  const image = new Image();
  image.src = 'data:image/jpeg;base64,' + frame.jpeg;
  await image.decode();
  const canvas = el('result');
  canvas.width = image.width; canvas.height = image.height;
  const context = canvas.getContext('2d');
  context.drawImage(image, 0, 0);
  context.font = '13px sans-serif'; context.lineWidth = 2;
  for (const object of message.objects) {
    const [x, y, width, height] = object.box;
    context.strokeStyle = '#8ce9be';
    context.strokeRect(x * canvas.width, y * canvas.height, width * canvas.width, height * canvas.height);
    const textWidth = context.measureText(object.label).width + 10;
    const labelY = Math.max(17, y * canvas.height);
    context.fillStyle = '#10291f'; context.fillRect(x * canvas.width, labelY - 17, textWidth, 19);
    context.fillStyle = '#8ce9be'; context.fillText(object.label, x * canvas.width + 5, labelY - 3);
  }
}

el('file').addEventListener('change', () => {
  stop();
  if (objectUrl) URL.revokeObjectURL(objectUrl);
  const file = el('file').files[0];
  if (!file) return;
  objectUrl = URL.createObjectURL(file);
  video.src = objectUrl;
  state('VIDEO SELECTED');
  el('message').textContent = 'Ready. Starting will stream sampled video frames for Flash-Lite detection.';
});
video.addEventListener('loadeddata', () => { el('start').disabled = false; });
video.addEventListener('error', () => {
  el('message').textContent = 'Cannot load video. Choose an H.264 MP4 or configure LIVE_SCAN_TEST_VIDEO on the server.';
  el('start').disabled = true;
});
el('server-clip').addEventListener('click', () => {
  stop();
  video.src = '/dashboard/demo-video';
  state('LOADING TEST CLIP');
  el('message').textContent = 'Loading the server-configured local test MP4.';
});
video.addEventListener('ended', () => {
  clearInterval(interval);
  el('message').textContent = 'Video ended. Waiting for the last analyzed frame; you can stop at any time.';
  drainTimer = setTimeout(() => stop(), 21000);
});

el('start').addEventListener('click', () => {
  if (active) return;
  stop();
  sent = 0; analyzed = 0; lastTimestamp = -1;
  video.currentTime = 0;
  el('sent').textContent = '0'; el('analyzed').textContent = '0'; el('objects').textContent = '0'; el('latency').textContent = '—';
  el('start').disabled = true; el('file').disabled = true; el('server-clip').disabled = true; el('stop').disabled = false;
  active = true;
  state('CONNECTING');
  const connection = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  socket = connection;
  connection.addEventListener('open', () => connection.send(JSON.stringify({ t: 'create', name: 'Live scan test host' })));
  connection.addEventListener('message', async ({ data }) => {
    if (socket !== connection) return;
    const message = JSON.parse(data);
    if (message.t === 'joined') {
      el('room').textContent = `Host room ${message.room}`;
      connection.send(JSON.stringify({ t: 'scan_start' }));
    } else if (message.t === 'scan_status') {
      log(`Scan ${message.state}${message.reason ? ': ' + message.reason : ''}`);
      if (message.state === 'ready') {
        state('STREAMING', true);
        video.controls = false;
        try {
          await video.play();
          sendFrame();
          interval = setInterval(sendFrame, 1050);
          el('message').textContent = 'Streaming continuously. Only the newest waiting frame is retained.';
        } catch { log('Could not play this video. Try an H.264 MP4.'); stop(); }
      } else if (message.state === 'stopped') { el('message').textContent = `Scan stopped: ${message.reason}`; stop(false); }
    } else if (message.t === 'scan_detections') {
      try { await showDetections(message); } catch { log('Could not draw the matched frame. Labels are still available.'); }
    } else if (message.t === 'error') {
      log(`${message.code}: ${message.message}`);
      el('message').textContent = message.message;
    }
  });
  connection.addEventListener('error', () => { log('Backend connection failed.'); stop(false); });
  connection.addEventListener('close', () => { if (socket === connection) { log('Backend disconnected.'); stop(false); } });
});
el('stop').addEventListener('click', () => stop());
window.addEventListener('pagehide', () => stop());
