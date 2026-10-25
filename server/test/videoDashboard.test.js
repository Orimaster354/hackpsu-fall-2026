const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

test('MOV selection enables Analyze even when the browser cannot preview the codec', async () => {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      listeners: {}, files: [], disabled: false, textContent: '', clientWidth: 640, clientHeight: 360,
      addEventListener(type, callback) { this.listeners[type] = callback; },
      removeAttribute(name) { delete this[name]; }, load() {}, replaceChildren() {},
      getContext() { return { scale() {} }; },
    });
    return elements.get(id);
  }
  let urlCount = 0;
  const context = {
    document: { getElementById: element }, window: { addEventListener() {} }, devicePixelRatio: 1,
    URL: { createObjectURL() { return `blob:test-${++urlCount}`; }, revokeObjectURL() {} },
    fetch: async () => ({ ok: true, json: async () => ({ configured: true, model: 'test-model' }) }),
  };
  await vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../dashboard/videos.js'), 'utf8'), context);
  const select = (pass, name) => {
    element(pass).files = [{ name, size: 1024 }];
    element(pass).listeners.change();
  };
  assert.equal(element('start').disabled, true);
  select('overview', 'overview.MOV');
  assert.equal(element('start').disabled, false);
  assert.match(element('start-reason').textContent, /second video.*optional/);
  select('edge', 'edge.mov');
  assert.equal(element('start').disabled, false);
  for (const pass of ['overview', 'edge']) element(`${pass}-video`).listeners.error();
  assert.equal(element('start').disabled, false);
  assert.match(element('edge-info').textContent, /preview unavailable/);
  assert.match(element('start-reason').textContent, /Ready to analyze/);
  const edge = element('edge-video'); edge.currentSrc = edge.src; edge.duration = 121;
  edge.listeners.loadedmetadata();
  assert.equal(element('start').disabled, true);
  assert.match(element('edge-info').textContent, /no longer than 120 seconds/);
  select('edge', 'valid.mp4');
  assert.equal(element('start').disabled, false);
  select('edge', 'wrong.txt');
  assert.equal(element('start').disabled, true);
  assert.match(element('edge-info').textContent, /MP4 or MOV/);
  element('edge').files = []; element('edge').listeners.change();
  assert.equal(element('start').disabled, false);
});
