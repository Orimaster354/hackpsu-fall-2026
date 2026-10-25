const $ = (id) => document.getElementById(id);
const passes = ['overview', 'edge'];
const clips = {};
let configured = false;
let controller;
let result;
let timer;

function log(message) {
  const li = document.createElement('li');
  li.textContent = `${new Date().toLocaleTimeString()}  ${message}`;
  $('events').prepend(li);
}
function controls() {
  $('start').disabled = !configured || Boolean(controller) || !passes.every((pass) => clips[pass]?.ready);
  $('cancel').disabled = !controller;
  for (const pass of passes) $(pass).disabled = Boolean(controller);
}
function draw(pass) {
  const canvas = $(`${pass}-box`); const video = $(`${pass}-video`);
  const ctx = canvas.getContext('2d');
  canvas.width = canvas.clientWidth * devicePixelRatio;
  canvas.height = canvas.clientHeight * devicePixelRatio;
  ctx.scale(devicePixelRatio, devicePixelRatio);
  const detection = clips[pass]?.selected;
  if (!detection || Math.abs(video.currentTime - detection.t) > 0.25 || !video.videoWidth) return;
  const scale = Math.min(canvas.clientWidth / video.videoWidth, canvas.clientHeight / video.videoHeight);
  const width = video.videoWidth * scale; const height = video.videoHeight * scale;
  const [x, y, w, h] = detection.box;
  ctx.strokeStyle = '#8ce9be'; ctx.lineWidth = 3;
  ctx.strokeRect((canvas.clientWidth - width) / 2 + x * width, (canvas.clientHeight - height) / 2 + y * height, w * width, h * height);
}

for (const pass of passes) {
  const video = $(`${pass}-video`);
  $(pass).addEventListener('change', () => {
    const file = $(pass).files[0];
    if (clips[pass]?.url) URL.revokeObjectURL(clips[pass].url);
    clips[pass] = { file, ready: false };
    result = null; $('download').disabled = true;
    for (const name of passes) { $(`${name}-detections`).replaceChildren(); if (clips[name]) clips[name].selected = null; draw(name); }
    $('error').hidden = true;
    if (!file) { video.removeAttribute('src'); video.load(); $(`${pass}-info`).textContent = 'No video selected'; controls(); return; }
    if (!file.name.toLowerCase().endsWith('.mp4') || file.size > 64 * 1024 * 1024 || file.size < 13) {
      $(`${pass}-info`).textContent = 'Choose an MP4 no larger than 64 MiB.'; controls(); return;
    }
    clips[pass].url = URL.createObjectURL(file);
    video.src = clips[pass].url;
    $(`${pass}-info`).textContent = 'Reading video…'; controls();
  });
  video.addEventListener('loadedmetadata', () => {
    const clip = clips[pass];
    clip.ready = Number.isFinite(video.duration) && video.duration > 0 && video.duration <= 120;
    clip.duration = video.duration;
    $(`${pass}-info`).textContent = clip.ready
      ? `${clip.file.name} · ${video.duration.toFixed(1)}s · ${(clip.file.size / 1024 / 1024).toFixed(1)} MiB`
      : 'Use a readable video no longer than 120 seconds.';
    controls(); draw(pass);
  });
  video.addEventListener('error', () => { if (clips[pass]) clips[pass].ready = false; $(`${pass}-info`).textContent = 'Browser cannot play this video. Try an H.264 MP4.'; controls(); });
  for (const event of ['seeked', 'timeupdate', 'loadeddata']) video.addEventListener(event, () => draw(pass));
}
window.addEventListener('resize', () => passes.forEach(draw));

function showResult(data) {
  result = data;
  let total = 0;
  for (const passResult of data.passes) {
    const list = $(`${passResult.pass}-detections`); list.replaceChildren();
    total += passResult.detections.length;
    if (!passResult.detections.length) { const p = document.createElement('p'); p.className = 'helper'; p.textContent = 'No usable objects detected in this pass.'; list.append(p); }
    for (const detection of passResult.detections) {
      const button = document.createElement('button'); button.type = 'button'; button.setAttribute('aria-pressed', 'false');
      button.textContent = `${detection.t.toFixed(2)}s · ${detection.label}`;
      button.addEventListener('click', () => {
        for (const other of list.querySelectorAll('button')) other.setAttribute('aria-pressed', 'false');
        button.setAttribute('aria-pressed', 'true');
        clips[passResult.pass].selected = detection;
        const video = $(`${passResult.pass}-video`); video.pause(); video.currentTime = detection.t; draw(passResult.pass);
      });
      list.append(button);
    }
  }
  $('summary').textContent = `${total} detections across both videos · ${(data.elapsedMs / 1000).toFixed(1)}s analysis`;
  $('download').disabled = false;
  for (const warning of data.cleanupWarnings || []) log(warning);
  log('Complete. Click a detection to seek and view its box.');
  $('status').textContent = 'COMPLETE';
}

$('test-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if ($('start').disabled) return;
  controller = new AbortController(); result = null; $('download').disabled = true; controls();
  for (const pass of passes) { $(`${pass}-detections`).replaceChildren(); clips[pass].selected = null; draw(pass); }
  $('events').replaceChildren(); $('error').hidden = true; $('status').textContent = 'ANALYZING';
  $('summary').textContent = 'Uploading both videos…';
  const started = Date.now();
  timer = setInterval(() => { $('elapsed').textContent = `${Math.floor((Date.now() - started) / 1000)}s elapsed`; }, 1000);
  log('Sending both complete MP4 files to the backend.');
  let gotResult = false;
  try {
    const form = new FormData();
    for (const pass of passes) { form.append(pass, clips[pass].file); form.append(`${pass}Duration`, String(clips[pass].duration)); }
    const response = await fetch('/api/dashboard/video-test', { method: 'POST', headers: { 'X-Roomshift-Video-Test': '1' }, body: form, signal: controller.signal });
    const reader = response.body.getReader(); const decoder = new TextDecoder(); let pending = '';
    const consume = (line) => {
      if (!line.trim()) return;
      const data = JSON.parse(line);
      if (data.type === 'error') throw new Error(`${data.code}: ${data.message}`);
      if (data.type === 'progress') { log(data.message); $('summary').textContent = data.message; }
      if (data.type === 'result') { showResult(data); gotResult = true; }
    };
    while (true) {
      const { done, value } = await reader.read();
      pending += decoder.decode(value, { stream: !done });
      const lines = pending.split('\n'); pending = lines.pop();
      for (const line of lines) consume(line);
      if (done) break;
    }
    if (pending) consume(pending);
    if (!gotResult) throw new Error('The server closed before returning results.');
  } catch (error) {
    $('status').textContent = 'STOPPED'; $('summary').textContent = 'Test did not complete.';
    $('error').textContent = error.name === 'AbortError' ? 'Test cancelled. The server will attempt to remove temporary Gemini uploads.' : error.message;
    $('error').hidden = false; log($('error').textContent);
  } finally { clearInterval(timer); controller = null; controls(); }
});
$('cancel').addEventListener('click', () => controller?.abort());
$('download').addEventListener('click', () => {
  const url = URL.createObjectURL(new Blob([JSON.stringify(result, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = 'roomshift-video-detections.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
window.addEventListener('pagehide', () => { controller?.abort(); for (const clip of Object.values(clips)) if (clip.url) URL.revokeObjectURL(clip.url); });
(async () => {
  try {
    const response = await fetch('/api/dashboard/video-test', { cache: 'no-store' });
    if (!response.ok) throw new Error('Cannot read video test configuration.');
    const config = await response.json(); configured = config.configured;
    $('configuration').textContent = `Model: ${config.model} · ${configured ? 'Server API key configured' : 'Set GEMINI_API_KEY in server/.env and restart'}${config.busy ? ' · Another test is running' : ''}`;
    $('status').textContent = configured ? 'READY' : 'KEY REQUIRED'; controls();
  } catch (error) { $('configuration').textContent = error.message; $('status').textContent = 'SERVER UNREACHABLE'; }
})();
