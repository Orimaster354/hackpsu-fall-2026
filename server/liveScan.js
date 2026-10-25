const { RoomError, requireAction } = require('./errors');
const { createGeminiClient, validatePhoto, DEFAULT_GEMINI_MODEL } = require('./gemini');

const MAX_FRAME_BYTES = 256 * 1024;
const MAX_SCAN_MS = 90000;

// Continuous client video, sampled at <=1 FPS; each AI request analyzes one exact frame.
// Only current + latest pending JPEGs are retained. No growing upload queue or video file.
class LiveScan {
  constructor({ notify, onStop, apiKey = process.env.GEMINI_API_KEY,
    model = process.env.GEMINI_MODEL || DEFAULT_GEMINI_MODEL,
    detect = createGeminiClient({ apiKey, model }), now = Date.now, sessionDurationMs = MAX_SCAN_MS } = {}) {
    Object.assign(this, { notify, onStop, apiKey, detect, now, sessionDurationMs });
    this.ready = false;
    this.closed = false;
    this.pending = null;
    this.current = null;
    this.lastReceivedAt = null;
    this.lastTimestamp = -1;
    this.lastSentAt = null;
    this.frameIds = new Set();
  }

  async start() {
    requireAction(this.apiKey, 'GEMINI_NOT_CONFIGURED', 'Configure the server Gemini key before scanning.');
    requireAction(!this.closed, 'SCAN_STOPPED', 'Start a new scan.');
    this.ready = true;
    this.sessionTimer = setTimeout(() => this.stop('duration_limit'), this.sessionDurationMs);
    this.sessionTimer.unref?.();
    this.notify({ t: 'scan_status', state: 'ready', maxFps: 1, maxFrameBytes: MAX_FRAME_BYTES, maxDurationMs: this.sessionDurationMs });
  }

  frame(message) {
    requireAction(this.ready && !this.closed, 'SCAN_NOT_READY', 'Wait for scan_status ready.');
    requireAction(typeof message.frameId === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(message.frameId)
      && !this.frameIds.has(message.frameId), 'INVALID_SCAN_FRAME', 'Use a unique frame ID (1–64 letters, digits, underscores or hyphens).');
    requireAction(Number.isSafeInteger(message.timestampMs) && message.timestampMs >= 0
      && message.timestampMs > this.lastTimestamp, 'INVALID_SCAN_FRAME', 'Capture timestamps must be nonnegative and strictly increasing.');
    requireAction(typeof message.jpeg === 'string' && message.jpeg.length <= Math.ceil(MAX_FRAME_BYTES / 3) * 4,
      'INVALID_SCAN_FRAME', 'Live JPEG frames are limited to 256 KiB.');
    validatePhoto([message.jpeg]);
    const now = this.now();
    requireAction(this.lastReceivedAt === null || now - this.lastReceivedAt >= 900,
      'SCAN_RATE_LIMIT', 'Send at most one camera frame per second.');
    this.lastReceivedAt = now;
    this.lastTimestamp = message.timestampMs;
    this.frameIds.add(message.frameId);
    this.pending = { frameId: message.frameId, timestampMs: message.timestampMs, jpeg: message.jpeg };
    this.pump();
  }

  pump() {
    if (this.closed || !this.ready || this.current || !this.pending || this.pumpTimer) return;
    const delay = this.lastSentAt === null ? 0 : Math.max(0, 1000 - (this.now() - this.lastSentAt));
    if (delay) {
      this.pumpTimer = setTimeout(() => { this.pumpTimer = null; this.pump(); }, delay);
      this.pumpTimer.unref?.();
      return;
    }
    const frame = this.pending;
    this.current = frame;
    this.pending = null;
    this.lastSentAt = this.now();
    this.controller = new AbortController();
    this.frameTimer = setTimeout(() => this.fail('SCAN_RESPONSE_TIMEOUT', 'Frame detection timed out. Restart scanning or place stations manually.'), 20000);
    this.frameTimer.unref?.();
    void this.analyze(frame, this.controller.signal);
  }

  async analyze(frame, signal) {
    try {
      const objects = await this.detect({ photos: [frame.jpeg] }, { signal });
      if (!this.closed && this.current === frame) {
        this.notify({ t: 'scan_detections', frameId: frame.frameId, timestampMs: frame.timestampMs, objects });
      }
    } catch (error) {
      if (!this.closed) this.fail(error instanceof RoomError ? error.code : 'SCAN_DETECTION_ERROR',
        error instanceof RoomError ? error.message : 'Frame detection failed. Restart scanning or place stations manually.');
    } finally {
      clearTimeout(this.frameTimer);
      if (this.current === frame) { this.current = null; this.controller = null; }
      this.pump();
    }
  }

  fail(code, message) {
    if (this.closed) return;
    this.notify({ t: 'error', code, message });
    this.stop('error');
  }

  stop(reason = 'host_stopped') {
    if (this.closed) return;
    this.closed = true;
    this.ready = false;
    for (const timer of [this.sessionTimer, this.frameTimer, this.pumpTimer]) clearTimeout(timer);
    this.controller?.abort();
    this.controller = null;
    this.pending = null;
    this.current = null;
    this.frameIds.clear();
    this.notify({ t: 'scan_status', state: 'stopped', reason });
    this.onStop?.();
  }
}

module.exports = { LiveScan, MAX_FRAME_BYTES, MAX_SCAN_MS };
