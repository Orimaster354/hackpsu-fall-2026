const {requireAction}=require('./errors');
const {pose}=require('./scans');
const {inside}=require('./perimeter');
const {placeNotes}=require('./postitGeometry');
const {sameTile,walkable}=require('./contracts');
const {createStationPlanner,validatePlan}=require('./stationPlanner');
const valid=(ok,message)=>requireAction(ok,'SCAN_UPLOAD_INVALID',message);
function sweepInput(body,grid){
  valid(walkable(body?.vantage,grid),'Vantage must be a playable tile (a hint, not the camera pose).');
  const k=body.intrinsics;
  valid(k && ['fx','fy','cx','cy','width','height'].every(key=>Number.isFinite(k[key])) && k.fx>0 && k.fy>0
    && Number.isInteger(k.width) && Number.isInteger(k.height) && k.width>0 && k.width<=8192 && k.height>0 && k.height<=8192
    && k.cx>=0 && k.cx<=k.width && k.cy>=0 && k.cy<=k.height,'Provide valid JPEG camera intrinsics.');
  valid(Array.isArray(body.frames) && body.frames.length>=8 && body.frames.length<=60,'Provide 8-60 sweep frames.');
  let last=-1;const indices=new Set();
  const frames=body.frames.map(frame=>{
    valid(Number.isInteger(frame?.index) && frame.index>=0 && !indices.has(frame.index)
      && Number.isFinite(frame.t) && frame.t>=0 && frame.t>last,'Frame indices must be unique and timestamps strictly increasing.');
    indices.add(frame.index);last=frame.t;
    const p=pose(frame.pose),jpeg=frame.jpeg;
    valid(typeof jpeg==='string' && jpeg.length%4===0 && /^[A-Za-z0-9+/]+={0,2}$/.test(jpeg),'Each JPEG must be base64.');
    requireAction(jpeg.length<=819200,'SCAN_UPLOAD_TOO_LARGE','Each JPEG must be at most 600 KiB decoded.');
    const bytes=Buffer.from(jpeg,'base64');
    valid(bytes.length>=4 && bytes.length<=600*1024 && bytes[0]===255 && bytes[1]===216 && bytes.at(-2)===255 && bytes.at(-1)===217,'Invalid JPEG frame.');
    return {index:frame.index,t:frame.t,pose:p,bytes};
  });
  return {frames,intrinsics:Object.fromEntries(['fx','fy','cx','cy','width','height'].map(key=>[key,k[key]]))};
}
const spacing=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y)>=2-1e-9;
const TASKS=['hold','tilt','dial','shake','gesture','hammer'];
// No two task stations get the same task. The first station keeps its type; a later duplicate takes the first type
// nobody has used, in TASKS order. Six types cover the three task stations. The fix station is not a motion task.
function uniqueTaskTypes(picks){
  const used=new Set();
  for(const pick of picks){
    if(pick.kind!=='task')continue;
    if(used.has(pick.task)){const free=TASKS.find(type=>!used.has(type));if(free)pick.task=free;}
    used.add(pick.task);
  }
  return picks;
}
function selectStations(notes,suggestions,emergency){
  const picks=[];const used=new Set();
  const add=(note,kind,task)=>{
    if(!note || used.has(note.id) || sameTile(note.tile,emergency.tile) || picks.some(p=>!spacing(p.tile,note.tile)))return false;
    if(picks.filter(p=>p.kind===kind).length>=(kind==='fix'?1:3))return false;
    used.add(note.id);picks.push({...note,kind,task:kind==='fix'?'hold':task});return true;
  };
  for(const suggestion of suggestions) add(notes.find(n=>n.id===suggestion.candidateId),suggestion.kind,suggestion.task);
  for(const note of [...notes].sort((a,b)=>b.confidence-a.confidence)){
    const kind=picks.filter(p=>p.kind==='task').length<3?'task':'fix';
    add(note,kind,kind==='fix'?'hold':TASKS[picks.length%TASKS.length]);
    if(picks.length===4)break;
  }
  if(picks.length && !picks.some(p=>p.kind==='fix')){picks.at(-1).kind='fix';picks.at(-1).task='hold';}
  uniqueTaskTypes(picks);
  return picks.map(note=>({id:`note-${note.id.split(':')[1]}`,name:note.context?.[0]?.label?`Note by ${note.context[0].label}`:'Wall note',
    tile:note.tile,kind:note.kind,task:note.task}));
}
function locatedNotes(frames,intrinsics,geometry){
  const notes=placeNotes({frames:frames.filter(f=>inside([f.pose.x,f.pose.z],geometry.polygon)),intrinsics,polygon:geometry.polygon,grid:geometry.grid});
  return notes.map((note,i)=>{
    const frame=frames.find(f=>f.index===note.best.frameIndex),d=frame.detections[note.best.detection];
    return {...note,id:`sweep:${i}`,t:frame.t,box:d.box,context:d.context||[]};
  });
}
async function processSweep(room,body,{sweepDetector,stationPlanner,signal,beforeCommit,scanMonitor,monitorRun}={}){
  const input=sweepInput(body,room.grid);
  const geometry=room.scanGeometry;
  scanMonitor?.update(monitorRun,{status:'processing',step:'detecting',totalFrames:input.frames.length,grid:room.grid});
  scanMonitor?.event(monitorRun,`Analyzing ${input.frames.length} app JPEG frames with YOLOE.`);
  room.broadcast({t:'processing',step:'gemini'});
  const detector=sweepDetector || require('./sweepDetector').createSweepDetector();
  scanMonitor?.update(monitorRun,{detectorModel:detector.model});
  const reportFrame=frame=>scanMonitor?.frame(monitorRun,frame,input.frames.find(f=>f.index===frame.index),input.intrinsics);
  const frames=await detector.detect(input.frames,input.intrinsics,{signal,onFrame:reportFrame});
  for(const frame of frames)reportFrame(frame);
  signal?.throwIfAborted();
  room.broadcast({t:'processing',step:'placing'});
  const notes=locatedNotes(frames,input.intrinsics,geometry),warnings=[];
  scanMonitor?.update(monitorRun,{step:'placing',notesFound:notes.length});
  scanMonitor?.event(monitorRun,`${notes.length} wall-note candidates after geometric merging.`);
  const candidates=notes.map(n=>({id:n.id,pass:'sweep',label:'sticky note',t:n.t,score:n.confidence,
    box:n.box.map((v,i)=>v/(i%2===0?input.intrinsics.width:input.intrinsics.height)),
    context:n.context.map(c=>({...c,box:c.box?.map((v,i)=>v/(i%2===0?input.intrinsics.width:input.intrinsics.height))})),
    conflictsWith:notes.filter(other=>other.id!==n.id && !spacing(n.tile,other.tile)).map(other=>other.id)}));
  let suggestions=[];
  if(notes.length){
    try{
      room.broadcast({t:'processing',step:'gemini'});
      const planner=stationPlanner || createStationPlanner();
      scanMonitor?.update(monitorRun,{step:'ranking'});scanMonitor?.event(monitorRun,'Gemini ranking note metadata.');
      const plan=await planner.planCandidates(candidates,{signal});
      suggestions=validatePlan(plan,candidates).suggestions;
    }catch{signal?.throwIfAborted();warnings.push('Gemini ranking unavailable or invalid; stations ranked by detector score.');}
  }else warnings.push('No usable wall notes found. Add stations manually or rescan.');
  const stations=selectStations(notes,suggestions,geometry.emergency);
  if(stations.length<4)warnings.push(`Only ${stations.length} spaced task/fix stations could be placed; host review is required.`);
  beforeCommit?.();
  room.broadcast({t:'processing',step:'placing'});
  room.game.applySetup({grid:geometry.grid,stations:[geometry.emergency,...stations]});
  const ordered=[...notes].sort((a,b)=>Number(stations.some(s=>s.id===`note-${b.id.split(':')[1]}`))-Number(stations.some(s=>s.id===`note-${a.id.split(':')[1]}`)));
  scanMonitor?.retain(monitorRun,ordered,frames,input);
  scanMonitor?.update(monitorRun,{step:'placing',grid:room.grid,stations:room.stations,
    notes:ordered.slice(0,64).map(n=>({...candidates.find(c=>c.id===n.id),frameIndex:n.best.frameIndex,
      observationCount:n.observations.length,station:stations.find(s=>s.id===`note-${n.id.split(':')[1]}`)||null})),
    planning:{suggestions},warnings});
  return {ok:true,notesFound:notes.length,stations:stations.length,warnings};
}
module.exports={sweepInput,locatedNotes,selectStations,processSweep};
