const { requireAction } = require('./errors');

// MP4 and QuickTime share atom headers. Read movie duration without decoding frames,
// so an iPhone codec unsupported by the browser does not block a Gemini upload.
function movieMetadata(bytes, filename) {
  const extension = /\.(mp4|mov)$/i.exec(filename || '')?.[1].toLowerCase();
  requireAction(extension && Buffer.isBuffer(bytes) && bytes.length >= 16, 'INVALID_VIDEO', 'Choose an MP4 or MOV video.');
  let duration; let hasFileType = false; let quickTime = extension === 'mov';
  function atoms(start, end, inMovie = false) {
    let offset = start; let count = 0;
    while (offset < end) {
      requireAction(++count <= 10000 && end - offset >= 8, 'INVALID_VIDEO', 'Invalid MP4/MOV container.');
      let size = bytes.readUInt32BE(offset); const type = bytes.toString('ascii', offset + 4, offset + 8);
      let header = 8;
      if (size === 1) {
        requireAction(end - offset >= 16, 'INVALID_VIDEO', 'Invalid video atom.');
        const large = bytes.readBigUInt64BE(offset + 8);
        requireAction(large <= BigInt(Number.MAX_SAFE_INTEGER), 'INVALID_VIDEO', 'Invalid video atom size.');
        size = Number(large); header = 16;
      } else if (size === 0) size = end - offset;
      requireAction(size >= header && size <= end - offset, 'INVALID_VIDEO', 'Video appears truncated or corrupt.');
      const payload = offset + header; const limit = offset + size;
      if (!inMovie && type === 'ftyp') {
        requireAction(limit - payload >= 8, 'INVALID_VIDEO', 'Invalid video file type.');
        hasFileType = true;
        if (bytes.toString('ascii', payload, payload + 4) === 'qt  ') quickTime = true;
      }
      if (!inMovie && type === 'moov') atoms(payload, limit, true);
      if (inMovie && type === 'mvhd') {
        const version = bytes[payload];
        requireAction((version === 0 && limit - payload >= 20) || (version === 1 && limit - payload >= 32),
          'INVALID_VIDEO', 'Invalid movie duration metadata.');
        const timescale = bytes.readUInt32BE(payload + (version === 1 ? 20 : 12));
        const ticks = version === 1 ? Number(bytes.readBigUInt64BE(payload + 24)) : bytes.readUInt32BE(payload + 16);
        requireAction(timescale > 0 && Number.isSafeInteger(ticks), 'INVALID_VIDEO', 'Invalid movie time scale.');
        duration = ticks / timescale;
      }
      offset = limit;
    }
  }
  atoms(0, bytes.length);
  requireAction((hasFileType || quickTime) && Number.isFinite(duration) && duration > 0 && duration <= 120,
    'INVALID_VIDEO', 'Video must have readable movie metadata and be no longer than 120 seconds. Export a complete MP4/MOV if this file is incomplete.');
  return { mimeType: quickTime ? 'video/quicktime' : 'video/mp4', duration };
}

module.exports = { movieMetadata };
