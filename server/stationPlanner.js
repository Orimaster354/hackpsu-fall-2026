const fs = require('node:fs');
const path = require('node:path');
const { RoomError, requireAction } = require('./errors');
const { DEFAULT_GEMINI_MODEL } = require('./gemini');
const { NOTE } = require('./yoloDetector');
const PROMPT = fs.readFileSync(path.join(__dirname, 'prompts/station-planning.md'), 'utf8');
const TASKS = ['hold', 'dial', 'shake', 'gesture', 'hammer'];

function planningCandidates(result) {
  return result.passes.flatMap((pass) => pass.detections.map((detection, index) => ({
    id: `${pass.pass}:${index}`, pass: pass.pass, label: detection.label,
    t: detection.t, box: detection.box, score: detection.confidence ?? null,
    context: (detection.context || []).map(({ label, box, confidence, imageGap }) => ({ label, box, confidence, imageGap })),
  })).filter((item) => item.label === NOTE && (item.score === null || item.score >= 0.50)));
}

function validatePlan(value, candidates) {
  requireAction(value && Array.isArray(value.suggestions) && value.suggestions.length <= 4
    && typeof value.summary === 'string' && value.summary.length <= 500,
  'PLANNER_INVALID_RESPONSE', 'Gemini returned an invalid station suggestion list.');
  const ids = new Set(); let tasks = 0; let fixes = 0;
  const suggestions = value.suggestions.map((item) => {
    const candidate = candidates.find((candidate) => candidate.id === item?.candidateId);
    requireAction(candidate?.label === NOTE && !ids.has(item.candidateId) && TASKS.includes(item.task)
      && ['task', 'fix'].includes(item.kind) && typeof item.reason === 'string'
      && item.reason.trim().length > 0 && item.reason.length <= 300,
    'PLANNER_INVALID_RESPONSE', 'Gemini suggested an unknown/duplicate candidate or invalid task.');
    requireAction(!Object.hasOwn(item, 'tile') && !Object.hasOwn(item, 'position'),
      'PLANNER_INVALID_RESPONSE', 'Physical tile placement is not available from detection metadata alone.');
    ids.add(item.candidateId);
    if (item.kind === 'task') tasks += 1; else fixes += 1;
    return { candidateId: candidate.id, label: candidate.label, pass: candidate.pass, t: candidate.t,
      task: item.task, kind: item.kind, reason: item.reason.trim() };
  });
  requireAction(tasks <= 3 && fixes <= 1, 'PLANNER_INVALID_RESPONSE', 'Choose at most three tasks and one fix candidate.');
  return { status: 'needs_geometry', summary: value.summary.trim(), suggestions,
    selectionPolicy: { minimumYoloScore: 0.50, candidateLabel: NOTE, maxPerPass: 8,
      contextMetric: 'same-frame box gap / image diagonal; not meters' },
    placementReady: false, placementNote: 'Landmark/task suggestions only. Pose/grid processing, edge placement, 2 m spacing and host review are still required.' };
}

function createStationPlanner({ apiKey = process.env.GEMINI_API_KEY,
  model = process.env.GEMINI_REASONING_MODEL || process.env.GEMINI_MODEL || DEFAULT_GEMINI_MODEL,
  fetchImpl = fetch } = {}) {
  async function planCandidates(candidates, { signal } = {}) {
    if (!candidates.length) return { status: 'no_candidates', summary: 'No sufficiently strong sticky-note candidates. Do not substitute furniture; record clearer views of wall notes or use manual placement.', suggestions: [], placementReady: false };
    requireAction(candidates.length <= 64 && apiKey && /^[a-zA-Z0-9._-]+$/.test(model),
      'PLANNER_NOT_CONFIGURED', 'Configure the server Gemini key and reasoning model.');
    let response;
    const thinkingConfig = /^gemini-3[.-]/.test(model) ? { thinkingLevel: 'LOW' }
      : /^gemini-2\.5-flash/.test(model) ? { thinkingBudget: 0 } : undefined;
    try {
      response = await fetchImpl(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey },
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(45000)]) : AbortSignal.timeout(45000),
        body: JSON.stringify({ systemInstruction: { parts: [{ text: PROMPT }] },
          contents: [{ role: 'user', parts: [{ text: JSON.stringify({ candidates, geometryAvailable: false }) }] }],
          generationConfig: { temperature: 0.2, maxOutputTokens: 2048, responseMimeType: 'application/json',
            ...(thinkingConfig ? { thinkingConfig } : {}), responseSchema: { type: 'OBJECT', required: ['summary', 'suggestions'],
              properties: { summary: { type: 'STRING' }, suggestions: { type: 'ARRAY', maxItems: 4,
                items: { type: 'OBJECT', required: ['candidateId', 'kind', 'task', 'reason'], properties: {
                  candidateId: { type: 'STRING' }, kind: { type: 'STRING', enum: ['task', 'fix'] },
                  task: { type: 'STRING', enum: TASKS }, reason: { type: 'STRING' },
                } } } } } },
        }),
      });
    } catch {
      throw new RoomError('PLANNER_UNAVAILABLE', 'Gemini station reasoning timed out or could not connect. Detections are retained.');
    }
    requireAction(response.ok, response.status === 429 ? 'PLANNER_QUOTA' : 'PLANNER_UNAVAILABLE',
      `Gemini station reasoning returned HTTP ${response.status}. Detections are retained.`);
    try {
      const body = await response.json(); const candidate = body.candidates?.[0];
      requireAction(candidate?.finishReason === 'STOP', 'PLANNER_INVALID_RESPONSE', 'Gemini did not finish the station plan.');
      const text = candidate.content?.parts?.filter((part) => !part.thought).map((part) => part.text || '').join('');
      requireAction(typeof text === 'string' && text.length <= 20000, 'PLANNER_INVALID_RESPONSE', 'Invalid planning response.');
      return { ...validatePlan(JSON.parse(text), candidates), model, usage: body.usageMetadata || null };
    } catch (error) {
      if (error instanceof RoomError) throw error;
      throw new RoomError('PLANNER_INVALID_RESPONSE', 'Gemini station reasoning returned invalid JSON. Detections are retained.');
    }
  }
  return {configured:Boolean(apiKey),model,planCandidates,
    plan:(detections,options)=>planCandidates(planningCandidates(detections),options)};
}

module.exports = { createStationPlanner, planningCandidates, validatePlan };
