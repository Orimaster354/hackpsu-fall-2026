const $ = (id) => document.getElementById(id);
const passes = ['overview', 'edge'];
const clips = {};
let configured = false;
let controller;
let result;
let timer;
let detectorConfig;

function engine() { return $('detector').value || 'yoloe'; }
function selectDetector() {
  if (!detectorConfig) return;
  const selected = detectorConfig.detectors?.[engine()] || detectorConfig;
  configured = selected.configured;
  $('configuration').textContent = engine() === 'yoloe'
    ? `Model: ${selected.model} · Local CPU · wall sticky notes + context · 1 FPS · score threshold 0.35 · ${configured ? 'Ready' : 'Install and warm up the YOLOE runtime, then restart'}`
    : `Model: ${selected.model} · ${configured ? 'Server API key configured' : 'Set GEMINI_API_KEY in server/.env and restart'}${selected.quality ? ` · High detail, ${selected.quality.fps} FPS · Videos analyzed separately` : ''}`;
  $('upload-notice').textContent = engine() === 'yoloe'
    ? 'YOLOE processes videos locally. If station reasoning is checked, only detection labels/scores/boxes/IDs go to Gemini; no videos or frame images are sent. Temporary local copies are removed after the run.'
    : 'Gemini mode sends selected complete videos to Google using the server API key. Temporary provider uploads are deleted after the attempt when possible.';
  $('reasoning').disabled = !detectorConfig.reasoning?.configured || Boolean(controller);
  $('reasoning-status').textContent = detectorConfig.reasoning?.configured
    ? `Reasoning model: ${detectorConfig.reasoning.model}. Suggestions still require physical placement and review.`
    : 'Gemini reasoning is unavailable. Set GEMINI_API_KEY in server/.env and restart; local detection remains available.';
  $('status').textContent = configured ? 'READY' : 'SETUP REQUIRED';
  controls();
}

function log(message) {
  const li = document.createElement('li');
  li.textContent = `${new Date().toLocaleTimeString()}  ${message}`;
  $('events').prepend(li);
}
function controls() {
  const selected = passes.filter((pass) => clips[pass]?.file);
  $('start').disabled = !configured || Boolean(controller) || !clips.overview?.ready || selected.some((pass) => !clips[pass].ready);
  $('cancel').disabled = !controller;
  for (const pass of passes) $(pass).disabled = Boolean(controller);
  $('detector').disabled = Boolean(controller);
  $('reasoning').disabled = !detectorConfig?.reasoning?.configured || Boolean(controller);
  $('edge-clear').disabled = Boolean(controller) || !clips.edge?.file;
  const waiting = ['overview', ...selected.filter((pass) => pass !== 'overview')].filter((pass) => !clips[pass]?.ready);
  $('start-reason').textContent = controller ? 'Analysis is running. Progress appears below.'
    : !configured ? 'The selected detector is not configured. See the model status above.'
      : waiting.length ? `Choose a valid ${waiting.join(' and ')} video to enable analysis. Check the message below each picker.`
        : `${selected.length} video(s) selected. Ready to analyze; a second video and browser preview are optional.`;
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
    clips[pass] = { file, valid: false, ready: false };
    video.removeAttribute('src'); video.load();
    result = null; $('download').disabled = true;
    $('planning').hidden = true;
    for (const name of passes) $(`${name}-stats`).textContent = '';
    for (const name of passes) { $(`${name}-detections`).replaceChildren(); $(`${name}-snapshot`).hidden = true; if (clips[name]) clips[name].selected = null; draw(name); }
    $('error').hidden = true;
    if (!file) { video.removeAttribute('src'); video.load(); $(`${pass}-info`).textContent = 'No video selected'; controls(); return; }
    if (!/\.(mp4|mov)$/i.test(file.name) || file.size > 512 * 1024 * 1024 || file.size < 13) {
      $(`${pass}-info`).textContent = 'Choose an MP4 or MOV no larger than 512 MiB.'; controls(); return;
    }
    clips[pass].valid = true; clips[pass].ready = true;
    clips[pass].url = URL.createObjectURL(file);
    video.src = clips[pass].url;
    $(`${pass}-info`).textContent = `${file.name} · ${(file.size / 1024 / 1024).toFixed(1)} MiB · Selected. Server will check duration.`; controls();
  });
  video.addEventListener('loadedmetadata', () => {
    const clip = clips[pass];
    if (!clip?.valid || video.currentSrc !== clip.url) return;
    clip.duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : undefined;
    clip.ready = clip.duration === undefined || clip.duration <= 120;
    $(`${pass}-info`).textContent = clip.ready
      ? `${clip.file.name} · ${clip.duration === undefined ? 'Duration checked by server' : `${clip.duration.toFixed(1)}s`} · ${(clip.file.size / 1024 / 1024).toFixed(1)} MiB`
      : `${clip.file.name} is ${clip.duration.toFixed(1)} seconds. Use a video no longer than 120 seconds.`;
    controls(); draw(pass);
  });
  video.addEventListener('error', () => {
    const clip = clips[pass]; if (!clip?.valid) return;
    if (clip.duration !== undefined && clip.duration > 120) return;
    clip.ready = true;
    $(`${pass}-info`).textContent = `${clip.file.name} · Browser preview unavailable. You can still analyze it; the server checks duration and the selected detector decodes the original file.`;
    controls();
  });
  for (const event of ['seeked', 'timeupdate', 'loadeddata']) video.addEventListener(event, () => draw(pass));
}
window.addEventListener('resize', () => passes.forEach(draw));

function showResult(data) {
  result = data;
  let total = 0;
  for (const passResult of data.passes) {
    const list = $(`${passResult.pass}-detections`); list.replaceChildren();
    const stats = passResult.diagnostics;
    $(`${passResult.pass}-stats`).textContent = stats ?
      ['proposalsByClass', 'belowThresholdByClass', 'areaRejectedByClass', 'selectedByClass'].map((group) =>
        `${({ proposalsByClass: 'Proposals', belowThresholdByClass: 'Below score threshold', areaRejectedByClass: 'Size filtered', selectedByClass: 'Shown' })[group]}: ${Object.entries(stats[group] || {}).map(([name, count]) => `${name} ${count}`).join(', ') || 'none'}`).join(' · ') : '';
    total += passResult.detections.length;
    if (!passResult.detections.length) { const p = document.createElement('p'); p.className = 'helper'; p.textContent = 'No usable objects detected in this pass.'; list.append(p); }
    for (const [index, detection] of passResult.detections.entries()) {
      const button = document.createElement('button'); button.type = 'button'; button.setAttribute('aria-pressed', 'false');
      button.dataset.candidateId = `${passResult.pass}:${index}`;
      const context = detection.context || [];
      button.textContent = `${passResult.pass}:${index} · ${detection.t.toFixed(2)}s · ${detection.label}${Number.isFinite(detection.confidence) ? ` · score ${detection.confidence.toFixed(2)}` : ''} · ${context.length ? context.map((item) => `near ${item.label} (image gap ${item.imageGap.toFixed(3)})`).join(', ') : 'wall context unknown'}`;
      button.addEventListener('click', () => {
        for (const other of list.querySelectorAll('button')) other.setAttribute('aria-pressed', 'false');
        button.setAttribute('aria-pressed', 'true');
        clips[passResult.pass].selected = detection;
        const snapshot = $(`${passResult.pass}-snapshot`);
        snapshot.hidden = !detection.frameJpeg;
        if (detection.frameJpeg) snapshot.src = `data:image/jpeg;base64,${detection.frameJpeg}`;
        const video = $(`${passResult.pass}-video`);
        if (video.readyState < 1) { log(detection.frameJpeg ? 'Showing the exact decoded detection frame below the video.' : `Preview unavailable here. Inspect ${detection.t.toFixed(2)}s in an external player or download the JSON.`); return; }
        video.pause(); video.currentTime = detection.t; draw(passResult.pass);
      });
      list.append(button);
    }
  }
  $('summary').textContent = `${total} detections · ${data.model} · ${(data.elapsedMs / 1000).toFixed(1)}s analysis`;
  $('download').disabled = false;
  $('planning').hidden = !data.planning;
  $('station-plan').replaceChildren();
  if (data.planning) {
    $('planning-summary').textContent = data.planning.summary;
    for (const suggestion of data.planning.suggestions) {
      const item = document.createElement('li');
        item.textContent = `${suggestion.candidateId} · ${suggestion.label} · ${suggestion.pass} ${suggestion.t.toFixed(2)}s · ${suggestion.kind}/${suggestion.task}: ${suggestion.reason} `;
      const inspect = document.createElement('button'); inspect.type = 'button'; inspect.textContent = 'Inspect frame';
      inspect.addEventListener('click', () => {
        const target = document.querySelector(`[data-candidate-id="${suggestion.candidateId}"]`); target?.click();
      });
      item.append(inspect); $('station-plan').append(item);
    }
    if (data.planning.status === 'unavailable') log(`Reasoning unavailable: ${data.planning.summary}`);
  }
  for (const warning of data.cleanupWarnings || []) log(warning);
  log('Complete. Click a detection to seek and view its box.');
  $('status').textContent = 'COMPLETE';
}

$('test-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if ($('start').disabled) return;
  controller = new AbortController(); result = null; $('download').disabled = true; controls();
  for (const pass of passes) $(`${pass}-stats`).textContent = '';
  for (const pass of passes) { $(`${pass}-detections`).replaceChildren(); $(`${pass}-snapshot`).hidden = true; if (clips[pass]) clips[pass].selected = null; draw(pass); }
  $('events').replaceChildren(); $('error').hidden = true; $('status').textContent = 'ANALYZING';
  $('planning').hidden = true;
  $('summary').textContent = 'Uploading selected videos…';
  const started = Date.now();
  timer = setInterval(() => { $('elapsed').textContent = `${Math.floor((Date.now() - started) / 1000)}s elapsed`; }, 1000);
  log(`Sending selected video files to the backend for ${engine() === 'yoloe' ? 'local YOLOE' : 'Gemini'} analysis.`);
  let gotResult = false;
  try {
    const form = new FormData();
    form.append('detector', engine());
    form.append('reasoning', $('reasoning').checked && detectorConfig.reasoning?.configured ? '1' : '0');
    for (const pass of passes) if (clips[pass]?.file) form.append(pass, clips[pass].file);
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
$('edge-clear').addEventListener('click', () => { $('edge').value = ''; $('edge').dispatchEvent(new Event('change')); });
$('detector').addEventListener('change', () => { result = null; $('download').disabled = true; selectDetector(); });
$('download').addEventListener('click', () => {
  const url = URL.createObjectURL(new Blob([JSON.stringify(result, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = 'roomshift-video-detections.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
window.addEventListener('pagehide', () => { controller?.abort(); for (const clip of Object.values(clips)) if (clip.url) URL.revokeObjectURL(clip.url); });
(async () => {
  try {
    const response = await fetch('/api/dashboard/video-test', { cache: 'no-store' });
    if (!response.ok) throw new Error('Cannot read video test configuration.');
    detectorConfig = await response.json();
    if (detectorConfig.defaultDetector) $('detector').value = detectorConfig.defaultDetector;
    else if (detectorConfig.detectors?.yoloe?.configured) $('detector').value = 'yoloe';
    selectDetector();
  } catch (error) { $('configuration').textContent = error.message; $('status').textContent = 'SERVER UNREACHABLE'; }
})();
