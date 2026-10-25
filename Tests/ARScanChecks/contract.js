'use strict';
// Upload rules for POST /scan/:room/perimeter and /sweep, written from docs/architecture.md ("Upload formats").
// Used by check_uploads.js and by the stand-in server. This is a test tool, not the real server's validator.

const MAX_PERIMETER_BYTES = 2 * 1024 * 1024;
const MAX_SWEEP_BYTES = 64 * 1024 * 1024;
const MAX_JPEG_BYTES = 600 * 1024;

class ContractError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const invalid = (message) => new ContractError(400, 'SCAN_UPLOAD_INVALID', message);
const finite = (v) => typeof v === 'number' && Number.isFinite(v);

function checkPose(pose, where, { needT = false } = {}) {
  for (const key of ['x', 'y', 'z', 'qx', 'qy', 'qz', 'qw']) {
    if (!finite(pose?.[key])) throw invalid(`${where}: ${key} must be a finite number`);
  }
  if (needT && !finite(pose.t)) throw invalid(`${where}: t must be a finite number`);
  const norm = Math.hypot(pose.qx, pose.qy, pose.qz, pose.qw);
  if (Math.abs(norm - 1) > 0.02) throw invalid(`${where}: quaternion is not unit length (${norm.toFixed(4)})`);
}

function validatePerimeter(body) {
  const poses = body?.poses;
  if (!Array.isArray(poses)) throw invalid('poses must be an array');
  if (poses.length < 100 || poses.length > 3000) throw invalid(`poses must have 100 to 3000 samples, got ${poses.length}`);
  poses.forEach((pose, i) => checkPose(pose, `poses[${i}]`, { needT: true }));
  for (let i = 1; i < poses.length; i++) {
    if (!(poses[i].t > poses[i - 1].t)) throw invalid(`poses[${i}]: t must be strictly increasing`);
  }
  return poses;
}

// Minimal JPEG reader: size from the start-of-frame marker, and the EXIF orientation tag if present.
function inspectJpeg(buffer) {
  if (buffer.length < 4 || buffer[0] !== 0xff || buffer[1] !== 0xd8) throw invalid('frame is not a JPEG');
  let width = null, height = null, orientation = null;
  let i = 2;
  while (i + 4 <= buffer.length) {
    if (buffer[i] !== 0xff) { i++; continue; }
    const marker = buffer[i + 1];
    if (marker === 0xff) { i++; continue; }
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) { i += 2; continue; }
    if (marker === 0xd9 || marker === 0xda) break;
    const length = buffer.readUInt16BE(i + 2);
    const start = i + 4;
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
      height = buffer.readUInt16BE(start + 1);
      width = buffer.readUInt16BE(start + 3);
    } else if (marker === 0xe1 && buffer.toString('latin1', start, start + 6) === 'Exif\0\0') {
      const tiff = start + 6;
      const little = buffer.toString('latin1', tiff, tiff + 2) === 'II';
      const u16 = (o) => (little ? buffer.readUInt16LE(o) : buffer.readUInt16BE(o));
      const u32 = (o) => (little ? buffer.readUInt32LE(o) : buffer.readUInt32BE(o));
      const ifd = tiff + u32(tiff + 4);
      const count = u16(ifd);
      for (let n = 0; n < count; n++) {
        const entry = ifd + 2 + n * 12;
        if (u16(entry) === 0x0112) orientation = u16(entry + 8);
      }
    }
    i = start + length - 2;
  }
  if (width === null) throw invalid('could not read the JPEG size');
  return { width, height, orientation };
}

function validateSweep(body) {
  const warnings = [];
  const v = body?.vantage;
  if (!Number.isInteger(v?.x) || !Number.isInteger(v?.y)) throw invalid('vantage must be a tile {x, y}');
  const k = body.intrinsics;
  for (const key of ['fx', 'fy', 'cx', 'cy']) if (!finite(k?.[key]) || k[key] <= 0) throw invalid(`intrinsics.${key} must be positive`);
  for (const key of ['width', 'height']) if (!Number.isInteger(k?.[key]) || k[key] <= 0) throw invalid(`intrinsics.${key} must be a positive integer`);
  if (k.cx < k.width * 0.3 || k.cx > k.width * 0.7 || k.cy < k.height * 0.3 || k.cy > k.height * 0.7) {
    throw invalid(`principal point (${k.cx}, ${k.cy}) is far from the center of a ${k.width}x${k.height} image`);
  }
  if (Math.abs(k.fx - k.fy) > 0.05 * k.fx) throw invalid(`fx ${k.fx} and fy ${k.fy} differ by more than 5%`);
  if (k.fx < k.width * 0.5 || k.fx > k.width * 3) throw invalid(`fx ${k.fx} is implausible for width ${k.width}`);
  if (k.width < k.height) warnings.push('image is portrait; ARKit captures landscape. Was it rotated?');

  const frames = body.frames;
  if (!Array.isArray(frames)) throw invalid('frames must be an array');
  if (frames.length < 8 || frames.length > 60) throw invalid(`frames must have 8 to 60 entries, got ${frames.length}`);
  const decoded = [];
  frames.forEach((frame, i) => {
    const where = `frames[${i}]`;
    if (frame.index !== i) throw invalid(`${where}: index must be ${i}`);
    if (!finite(frame.t)) throw invalid(`${where}: t must be a number`);
    if (i > 0 && !(frame.t > frames[i - 1].t)) throw invalid(`${where}: t must be strictly increasing`);
    checkPose(frame.pose, `${where}.pose`);
    if (typeof frame.jpeg !== 'string' || !frame.jpeg.length) throw invalid(`${where}: jpeg must be base64`);
    const bytes = Buffer.from(frame.jpeg, 'base64');
    if (bytes.length > MAX_JPEG_BYTES) throw invalid(`${where}: JPEG is ${bytes.length} bytes, over 600 KiB`);
    const info = inspectJpeg(bytes);
    if (info.width !== k.width || info.height !== k.height) {
      throw invalid(`${where}: JPEG is ${info.width}x${info.height} but intrinsics describe ${k.width}x${k.height}`);
    }
    if (info.orientation !== null && info.orientation !== 1) throw invalid(`${where}: EXIF orientation ${info.orientation} would rotate the image`);
    decoded.push({ index: frame.index, t: frame.t, pose: frame.pose, bytes, ...info });
  });
  return { frames: decoded, warnings };
}

module.exports = { ContractError, validatePerimeter, validateSweep, inspectJpeg, MAX_PERIMETER_BYTES, MAX_SWEEP_BYTES, MAX_JPEG_BYTES };
