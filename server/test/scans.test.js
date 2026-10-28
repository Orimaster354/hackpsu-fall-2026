const test=require('node:test');
const assert=require('node:assert/strict');
const {createAppServer}=require('../index');
const {buildPerimeter}=require('../perimeter');
const poses=require('../../docs/fixtures/poses.json');
async function roomServer(t,options={}){
  const app=createAppServer(options);const messages=[];
  const socket=()=>({readyState:1,send:raw=>messages.push(JSON.parse(raw))});
  const {room,player:host}=app.rooms.create('Host',socket());
  const guest=app.rooms.join(room.code,'Guest',socket()).player;
  const address=await app.listen(0,'127.0.0.1');t.after(()=>app.close());
  const post=async(step,body,id=host.id)=>{
    const response=await fetch(`http://127.0.0.1:${address.port}/scan/${room.code}/${step}`,{method:'POST',
      headers:{'content-type':'application/json','X-Player-Id':id},body:typeof body==='string'?body:JSON.stringify(body)});
    return {status:response.status,body:await response.json()};
  };
  return {app,room,host,guest,messages,post};
}
test('perimeter fixture produces the expected grid, center and broadcast order',async t=>{
  const {room,messages,post}=await roomServer(t);
  const response=await post('perimeter',{poses});
  assert.equal(response.status,200);assert.deepEqual(response.body,{ok:true,zone:'z1',cols:5,rows:5,edgeTiles:16});
  assert.equal(room.grid.originX,-0.5);assert.equal(room.grid.originZ,-0.5);assert.equal(room.grid.playable.length,25);
  assert.deepEqual(room.stations[0].tile,{x:2,y:2});assert.equal(room.stations[0].kind,'emergency');
  assert.deepEqual(messages.filter((_,i)=>i%2===0).map(m=>m.t),['processing','setup','lobby']);
  assert.equal(room.setupConfirmed,false);
});
test('retrying identical perimeter poses succeeds and broadcasts a fresh equal setup',async t=>{
  const {post,room,messages}=await roomServer(t);
  await post('perimeter',{poses});const previous=structuredClone(room.grid);messages.length=0;
  const retry=await post('perimeter',{poses});
  assert.equal(retry.status,200);assert.deepEqual(room.grid,previous);
  assert.equal(messages.filter(m=>m.t==='setup').length,2); // Both connected recipients receive the new acknowledgement.
  assert.ok(messages.filter(m=>m.t==='setup').every(m=>JSON.stringify(m.grid)===JSON.stringify(previous)));
});
test('perimeter rejects non-host, malformed poses, open/small paths, and locked/playing setup atomically',async t=>{
  const {room,host,guest,post}=await roomServer(t);
  assert.equal((await post('perimeter',{poses},guest.id)).status,403);
  for(const body of ['{broken',{poses:poses.slice(0,10)},{poses:poses.map((p,i)=>({...p,t:i===5?0:p.t}))},
    {poses:poses.map(p=>({...p,qw:0,qx:0,qy:0,qz:0}))}]){
    const response=await post('perimeter',body);assert.equal(response.status,400);assert.equal(response.body.code,'SCAN_UPLOAD_INVALID');
  }
  await post('perimeter',{poses});const grid=room.grid;
  for(const path of [poses.slice(0,120),poses.map(p=>({...p,x:p.x*.2,z:p.z*.2}))]){
    const response=await post('perimeter',{poses:path});assert.equal(response.status,422);assert.equal(response.body.code,'SCAN_FAILED');assert.equal(room.grid,grid);
  }
  room.game.confirmSetup(host);
  assert.equal((await post('perimeter',{poses})).body.code,'SETUP_LOCKED');
  room.phase='playing';assert.equal((await post('perimeter',{poses})).body.code,'INVALID_PHASE');
});
test('clockwise perimeter is equivalent and self-crossing paths are rejected',()=>{
  assert.deepEqual(buildPerimeter([...poses].reverse()).grid,buildPerimeter(poses).grid);
  const path=[[0,0],[4,4],[0,4],[4,0],[0,0]].map(([x,z])=>({x,z}));
  assert.throws(()=>buildPerimeter(path),{code:'SCAN_FAILED'});
});
module.exports={roomServer};

const fs=require('node:fs');
const path=require('node:path');
const fx=require('../../docs/fixtures/postit/sweep-observations.json');
const {placeNotes}=require('../postitGeometry');
const {locatedNotes,selectStations}=require('../sweep');
const jpeg=fs.readFileSync(path.join(__dirname,'../../docs/fixtures/postit/tiny-frame.jpg')).toString('base64');
const sweepBody=()=>structuredClone({vantage:fx.vantage,intrinsics:fx.intrinsics,frames:fx.frames.map(({index,t,pose})=>({index,t,pose,jpeg}))});
const fixtureDetector={async detect(frames){return frames.map(f=>({...f,detections:fx.frames.find(item=>item.index===f.index).detections}));}};
const unavailablePlanner={async planCandidates(){throw new Error('Gemini unavailable');}};
test('ported geometry matches all six fixture notes, tiles and merged observations',()=>{
  const notes=placeNotes(fx);
  assert.equal(notes.length,6);
  for(const expected of fx.expectedNotes){
    const found=notes.find(n=>fx.frames[n.best.frameIndex].detections[n.best.detection].noteId===expected.noteId);
    assert.deepEqual(found.tile,expected.tile);
    assert.ok(Math.hypot(found.hit[0]-expected.wall[0],found.hit[1]-expected.wall[1])<0.05);
    assert.equal(found.observations.length,fx.frames.filter(f=>f.detections.some(d=>d.noteId===expected.noteId)).length);
  }
});
test('fixture sweep places 3 tasks and 1 fix despite Gemini failure, with 2 m spacing',async t=>{
  const {room,post,messages}=await roomServer(t,{sweepDetector:fixtureDetector,stationPlanner:unavailablePlanner});
  assert.equal((await post('sweep',sweepBody())).body.code,'SETUP_MISSING');
  await post('perimeter',{poses});messages.length=0;
  const result=await post('sweep',sweepBody());
  assert.equal(result.status,200);assert.equal(result.body.notesFound,6);assert.equal(result.body.stations,4);
  assert.match(result.body.warnings.join(' '),/Gemini/);
  assert.equal(room.stations.filter(s=>s.kind==='task').length,3);assert.equal(room.stations.filter(s=>s.kind==='fix').length,1);
  assert.deepEqual(room.stations.find(s=>s.kind==='emergency').tile,{x:2,y:2});
  for(const a of room.stations.filter(s=>s.kind!=='emergency')){
    assert.ok(room.grid.edge.some(e=>e.x===a.tile.x && e.y===a.tile.y));
    for(const b of room.stations.filter(s=>s.kind!=='emergency' && s.id!==a.id))assert.ok(Math.hypot(a.tile.x-b.tile.x,a.tile.y-b.tile.y)>=2);
  }
  assert.deepEqual(messages.slice(-4).map(m=>m.t),['setup','setup','lobby','lobby']);
  assert.equal(room.setupConfirmed,false);
});
test('station selection respects Gemini order, skips close/emergency tiles and backfills by score',()=>{
  const notes=[{id:'sweep:0',tile:{x:0,y:0},confidence:.8},{id:'sweep:1',tile:{x:1,y:0},confidence:.99},
    {id:'sweep:2',tile:{x:4,y:0},confidence:.7},{id:'sweep:3',tile:{x:4,y:4},confidence:.6},
    {id:'sweep:4',tile:{x:0,y:4},confidence:.5},{id:'sweep:5',tile:{x:2,y:2},confidence:1}];
  const stations=selectStations(notes,[{candidateId:'sweep:0',kind:'task',task:'dial'},
    {candidateId:'sweep:1',kind:'task',task:'shake'}],{tile:{x:2,y:2}});
  assert.equal(stations[0].id,'note-0');assert.equal(stations[0].task,'dial');assert.equal(stations.length,4);
  assert.ok(!stations.some(s=>s.id==='note-1' || s.id==='note-5'));assert.equal(stations.at(-1).kind,'fix');
});
test('empty sweep succeeds with emergency-only setup; client detections never bypass the detector',async t=>{
  const detector={async detect(frames){return frames.map(f=>({...f,detections:[]}));}};
  const {room,post}=await roomServer(t,{sweepDetector:detector,stationPlanner:unavailablePlanner});
  await post('perimeter',{poses});const body=sweepBody();body.frames[0].detections=fx.frames[0].detections;
  const result=await post('sweep',body);
  assert.equal(result.status,200);assert.equal(result.body.notesFound,0);assert.equal(result.body.stations,0);assert.equal(room.stations.length,1);
  assert.ok(result.body.warnings.length);
});
test('sweep validates frames, poses, intrinsics, host and setup lock before detection',async t=>{
  let calls=0;
  const {host,guest,room,post}=await roomServer(t,{sweepDetector:{async detect(...args){calls++;return fixtureDetector.detect(...args);}},stationPlanner:unavailablePlanner});
  await post('perimeter',{poses});
  assert.equal((await post('sweep',sweepBody(),guest.id)).status,403);
  const changes=[b=>{b.frames=b.frames.slice(0,3);},b=>{b.frames[1].index=0;},b=>{b.frames[1].t=0;},
    b=>{b.frames[0].pose.qw='x';},b=>{b.frames[0].jpeg='bogus';},b=>{b.intrinsics.fx=0;},b=>{b.vantage={x:99,y:99};}];
  for(const change of changes){const body=sweepBody();change(body);assert.equal((await post('sweep',body)).body.code,'SCAN_UPLOAD_INVALID');}
  assert.equal(calls,0);room.game.confirmSetup(host);assert.equal((await post('sweep',sweepBody())).body.code,'SETUP_LOCKED');
});
test('pending sweep locks concurrent setup mutations and releases its slot',async t=>{
  let release,entered;const ready=new Promise(r=>{entered=r;});const gate=new Promise(r=>{release=r;});
  const {room,host,post}=await roomServer(t,{sweepDetector:{async detect(frames){entered();await gate;return fixtureDetector.detect(frames);}},stationPlanner:unavailablePlanner});
  await post('perimeter',{poses});const pending=post('sweep',sweepBody());await ready;
  assert.throws(()=>room.game.confirmSetup(host),{code:'SCAN_BUSY'});assert.throws(()=>room.game.editStation(host,{}),{code:'SCAN_BUSY'});
  assert.equal((await post('perimeter',{poses})).body.code,'SCAN_BUSY');release();assert.equal((await pending).status,200);assert.equal(room.scanBusy,false);
});
test('Gemini sees only deduplicated metadata, and invalid selections fall back instead of failing setup',async t=>{
  let invalid=false;
  const planner={async planCandidates(candidates){
    assert.equal(candidates.length,6);assert.ok(candidates.every(c=>c.id.startsWith('sweep:') && !c.tile && !c.hit && !c.pose && !c.jpeg));
    return {summary:'Fixture ranking',suggestions:[{candidateId:invalid?'invented:0':candidates[2].id,kind:'fix',task:'hold',reason:'A valid metadata choice.'}]};
  }};
  const {post,room}=await roomServer(t,{sweepDetector:fixtureDetector,stationPlanner:planner});
  await post('perimeter',{poses});const first=await post('sweep',sweepBody());assert.equal(first.status,200);
  const fix=room.stations.find(s=>s.kind==='fix');assert.equal(fix.id,'note-2');assert.equal(first.body.warnings.length,0);
  invalid=true;const second=await post('sweep',sweepBody());assert.equal(second.status,200);assert.equal(second.body.stations,4);
  assert.match(second.body.warnings.join(' '),/invalid/);
});
test('scan body and per-frame size limits fail before inference',async t=>{
  const {post}=await roomServer(t,{sweepDetector:fixtureDetector,stationPlanner:unavailablePlanner});
  assert.equal((await post('perimeter',' '.repeat(2*1024*1024+1))).status,413);
  await post('perimeter',{poses});const body=sweepBody();body.frames[0].jpeg='A'.repeat(819204);
  assert.equal((await post('sweep',body)).body.code,'SCAN_UPLOAD_TOO_LARGE');
});

test('geometry keeps 0.50-confidence notes through to edge placement',()=>{
  const observations=structuredClone(fx);
  for(const frame of observations.frames)for(const detection of frame.detections)detection.confidence=.50;
  const notes=placeNotes(observations);
  assert.equal(notes.length,6);
  assert.ok(notes.every(note=>note.confidence===.50));
  for(const frame of observations.frames)for(const detection of frame.detections)detection.confidence=.499;
  assert.deepEqual(placeNotes(observations),[]);
});
