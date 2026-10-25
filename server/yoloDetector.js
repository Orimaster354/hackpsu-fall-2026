const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { RoomError, requireAction } = require('./errors');

const MODEL = 'yoloe-26s-seg.pt';
const NOTE = 'sticky note';
const CLASSES = [NOTE, 'door', 'window', 'whiteboard', 'light switch', 'electrical outlet', 'clock', 'poster', 'fire extinguisher', 'air vent'];
function validBox(box) {
  return Array.isArray(box) && box.length === 4 && box.every((v) => Number.isFinite(v) && v >= 0 && v <= 1)
    && box[2] > 0 && box[3] > 0 && box[0] + box[2] <= 1.000001 && box[1] + box[3] <= 1.000001;
}

function validateYoloResult(result, videos) {
  requireAction(result?.model === MODEL && Array.isArray(result.passes) && result.passes.length === videos.length,
    'YOLOE_INVALID_RESPONSE', 'YOLOE returned an invalid result.');
  const seen = new Set();
  const passes = result.passes.map((pass) => {
    const video = videos.find((video) => video.pass === pass?.pass);
    requireAction(video && !seen.has(pass.pass) && Array.isArray(pass.detections) && pass.detections.length <= 8,
      'YOLOE_INVALID_RESPONSE', 'YOLOE returned invalid pass data.');
    seen.add(pass.pass);
    const detections = pass.detections.map((item) => {
      const box = item?.box;
      requireAction(item?.label === NOTE && Number.isFinite(item.t) && item.t >= 0 && item.t < video.duration
        && Number.isFinite(item.confidence) && item.confidence >= 0.35 && item.confidence <= 1
        && Number.isInteger(item.frameIndex) && item.frameIndex >= 0
        && validBox(box),
      'YOLOE_INVALID_RESPONSE', 'YOLOE returned invalid labels, timestamps or boxes.');
      const safe = { label: item.label, t: item.t, box, confidence: item.confidence, frameIndex: item.frameIndex };
      requireAction(item.observationCount === undefined || (Number.isInteger(item.observationCount)
        && item.observationCount >= 1 && item.observationCount <= 120), 'YOLOE_INVALID_RESPONSE', 'Invalid observation count.');
      safe.observationCount = item.observationCount ?? 1;
      requireAction(Array.isArray(item.context) && item.context.length <= 6, 'YOLOE_INVALID_RESPONSE', 'Missing or oversized same-frame wall context.');
      safe.context = item.context.map((element) => {
        requireAction(CLASSES.includes(element?.label) && element.label !== NOTE && validBox(element.box)
          && Number.isFinite(element.confidence) && element.confidence >= 0.35 && element.confidence <= 1
          && Number.isFinite(element.imageGap) && element.imageGap >= 0 && element.imageGap <= 0.200001,
        'YOLOE_INVALID_RESPONSE', 'Invalid wall-context evidence.');
        return { label: element.label, box: element.box, confidence: element.confidence, imageGap: element.imageGap };
      });
      if (item.frameJpeg !== undefined) {
        requireAction(typeof item.frameJpeg === 'string' && item.frameJpeg.length <= 350000
          && /^[A-Za-z0-9+/]+={0,2}$/.test(item.frameJpeg), 'YOLOE_INVALID_RESPONSE', 'Invalid detection frame preview.');
        const jpeg = Buffer.from(item.frameJpeg, 'base64');
        requireAction(jpeg.length <= 256 * 1024 && jpeg[0] === 255 && jpeg[1] === 216
          && jpeg.at(-2) === 255 && jpeg.at(-1) === 217, 'YOLOE_INVALID_RESPONSE', 'Invalid detection frame JPEG.');
        safe.frameJpeg = item.frameJpeg;
      }
      return safe;
    });
    return { pass: pass.pass, duration: video.duration, detections,
      diagnostics: pass.diagnostics ? Object.fromEntries(['proposalsByClass', 'belowThresholdByClass', 'areaRejectedByClass', 'acceptedByClass', 'selectedByClass']
        .map((group) => [group, Object.fromEntries(CLASSES.filter((label) => Number.isInteger(pass.diagnostics[group]?.[label])
          && pass.diagnostics[group][label] >= 0 && pass.diagnostics[group][label] <= 100000)
          .map((label) => [label, pass.diagnostics[group][label]]))])) : null,
      framesAnalyzed: Number.isInteger(pass.framesAnalyzed) ? pass.framesAnalyzed : null,
      timestampSource: pass.timestampSource === 'decoder presentation time' ? pass.timestampSource : 'frame-index/fps fallback' };
  });
  return { model: MODEL, passes, analysis: { engine: 'yoloe', device: 'cpu', fps: 1, confidenceThreshold: 0.35,
    classes: CLASSES, maxObjectsPerPass: 8, maxCandidatesPerClass: 8, imageSize: 960, candidateLabel: NOTE,
    contextMetric: 'same-frame box gap / image diagonal; not meters',
    deduplication: 'short image-space overlap tracks; not persistent world identities' },
    primaryDetector: 'yoloe',
    usage: null, cleanupWarnings: [] };
}

function createYoloDetector({ pythonPath = process.env.YOLOE_PYTHON || path.join(__dirname, '.venv-yolo',
  process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python'), spawnImpl = spawn,
  ready = fs.existsSync(path.join(__dirname, '.cache/yoloe/ready.json')), timeoutMs = 600000 } = {}) {
  return { model: MODEL, configured: Boolean(ready && fs.existsSync(pythonPath)),
    quality: { fps: 1, maxObjectsPerPass: 8, device: 'cpu', confidenceThreshold: 0.35, imageSize: 960, candidateLabel: NOTE },
    async detect(videos, { signal, notify = () => {} } = {}) {
      requireAction(ready && fs.existsSync(pythonPath), 'YOLOE_NOT_READY', 'Install requirements-yoloe.txt and run tools/yoloe_worker.py --warmup with the isolated Python runtime.');
      signal?.throwIfAborted();
      const started = Date.now();
      const directory = await fsp.mkdtemp(path.join(os.tmpdir(), 'roomshift-yoloe-'));
      try {
        const specs = [];
        for (const video of videos) {
          const file = path.join(directory, `${video.pass}${video.mimeType === 'video/quicktime' ? '.mov' : '.mp4'}`);
          await fsp.writeFile(file, video.bytes);
          specs.push({ pass: video.pass, path: file, duration: video.duration });
        }
        const result = await new Promise((resolve, reject) => {
          const environment = { ...process.env, PYTHONUNBUFFERED: '1', PYTHONUTF8: '1' };
          delete environment.GEMINI_API_KEY;
          const child = spawnImpl(pythonPath, [path.join(__dirname, 'tools/yoloe_worker.py')],
            { cwd: __dirname, windowsHide: true, env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
          let pending = ''; let stderr = ''; let outputBytes = 0; let final; let failure;
          const abort = () => { failure = new RoomError('YOLOE_CANCELLED', 'Local YOLOE analysis cancelled.'); child.kill(); };
          const timer = setTimeout(() => { failure = new RoomError('YOLOE_TIMEOUT', 'Local YOLOE exceeded ten minutes. Try shorter clips.'); child.kill(); }, timeoutMs);
          timer.unref();
          const cleanup = () => { clearTimeout(timer); signal?.removeEventListener('abort', abort); };
          signal?.addEventListener('abort', abort, { once: true });
          if (signal?.aborted) abort();
          child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
          child.stderr.on('data', (text) => { stderr = (stderr + text).slice(-4000); });
          child.stdout.on('data', (text) => {
            outputBytes += Buffer.byteLength(text);
            if (outputBytes > 8 * 1024 * 1024) { failure = new RoomError('YOLOE_INVALID_RESPONSE', 'Local detector output exceeded its limit.'); child.kill(); return; }
            pending += text;
            const lines = pending.split('\n'); pending = lines.pop();
            for (const line of lines) {
              if (!line.trim()) continue;
              try {
                const event = JSON.parse(line);
                if (event.type === 'progress' && typeof event.message === 'string') notify(event.message.slice(0, 300));
                else if (event.type === 'result') final = validateYoloResult(event, videos);
                else if (event.type === 'error') failure = new RoomError('YOLOE_FAILED', 'Local YOLOE could not analyze the videos. Check the backend log.');
              } catch (error) { failure = error instanceof RoomError ? error : new RoomError('YOLOE_INVALID_RESPONSE', 'Invalid output from local detector.'); child.kill(); }
            }
          });
          child.once('error', () => { cleanup(); reject(new RoomError('YOLOE_NOT_READY', 'Cannot start the isolated YOLOE Python runtime.')); });
          child.once('close', (code) => {
            cleanup();
            if (failure || code !== 0 || !final) {
              if (stderr) console.error(`YOLOE worker: ${stderr}`);
              reject(failure || new RoomError('YOLOE_FAILED', 'Local YOLOE did not return results.'));
            } else resolve(final);
          });
          child.stdin.on('error', () => {}); // A failed/aborted worker may close stdin early.
          child.stdin.end(JSON.stringify({ videos: specs }));
        });
        return { ...result, elapsedMs: Date.now() - started };
      } finally {
        // Only remove this process-created temporary directory, never a client-selected path.
        await fsp.rm(directory, { recursive: true, force: true });
      }
    } };
}

module.exports = { createYoloDetector, validateYoloResult, MODEL, CLASSES, NOTE };
