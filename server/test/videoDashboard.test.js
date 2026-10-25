const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

test('same-timestamp notes render separate close-ups and grouped observation counts', async () => {
  const elements = new Map(); const crops = [];
  const make = () => ({ children: [], dataset: {}, textContent: '', addEventListener() {}, setAttribute() {},
    replaceChildren() { this.children = []; }, append(item) { this.children.push(item); },
    prepend(item) { this.children.unshift(item); },
    getContext() { return { fillRect() {}, drawImage(...args) { crops.push(args.slice(1, 5)); } }; } });
  const element = (id) => { if (!elements.has(id)) elements.set(id, make()); return elements.get(id); };
  const context = { document: { getElementById: element, createElement: make },
    window: { addEventListener() {} },
    Image: class { constructor() { this.width = 1000; this.height = 1000; } set src(value) { this.onload(); } },
    fetch: async () => ({ ok: true, json: async () => ({ configured: true, model: 'test-model' }) }),
    testResult: { passes: [{ pass: 'overview', detections: [0.2, 0.5, 0.8].map((x) => ({
      label: 'sticky note', t: 10, box: [x, 0.3, 0.03, 0.03], confidence: 0.8, frameJpeg: 'fixture', observationCount: 2,
    })) }], model: 'test-model', elapsedMs: 1 },
  };
  vm.createContext(context);
  await vm.runInContext(fs.readFileSync(path.join(__dirname, '../dashboard/videos.js'), 'utf8'), context);
  vm.runInContext('showResult(testResult)', context);
  const buttons = element('overview-detections').children;
  assert.equal(buttons.length, 3); assert.equal(crops.length, 3);
  assert.equal(new Set(crops.map((crop) => crop[0])).size, 3);
  assert.ok(buttons.every((button) => button.children[0].className === 'note-crop'));
  assert.ok(buttons.every((button) => button.textContent.includes('seen in 2 sampled frame(s)')));
});

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
