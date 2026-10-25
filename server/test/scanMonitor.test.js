const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {ScanMonitor}=require('../scanMonitor');
const {createAppServer}=require('../index');
const poses=require('../../docs/fixtures/poses.json');
const fx=require('../../docs/fixtures/postit/sweep-observations.json');
const bytes=fs.readFileSync(path.join(__dirname,'../../docs/fixtures/postit/tiny-frame.jpg'));

test('monitor bounds scan/image history and exposes neither raw JPEGs nor player identities',()=>{
  const monitor=new ScanMonitor({maxRuns:2,maxPreviews:2});
  const run=monitor.begin({code:'ABCD',hostId:'private-host-id'},'sweep',123);
  monitor.update(run,{hostId:'private-host-id',pose:{qx:1},jpeg:'private-jpeg'});
  for(let index=0;index<3;index++)monitor.frame(run,{index,t:index,detections:[]},{bytes},{width:320,height:240});
  const snapshot=monitor.snapshot();
  assert.deepEqual(snapshot.runs[0].previews.map(p=>p.index),[1,2]);
  assert.equal(monitor.preview(run.id,0),undefined);assert.deepEqual(monitor.preview(run.id,2),bytes);
  const json=JSON.stringify(snapshot);assert.ok(!json.includes('private-host-id'));assert.ok(!json.includes('private-jpeg'));assert.ok(!json.includes('qx'));
  monitor.begin({code:'EFGH'},'perimeter');monitor.begin({code:'IJKL'},'perimeter');
  assert.equal(monitor.snapshot().runs.length,2);assert.equal(monitor.preview(run.id,2),undefined);
});

test('app uploads appear live, stream frame progress/previews, and finish with merged notes and stations',async t=>{
  let entered,release;const ready=new Promise(r=>{entered=r;}),gate=new Promise(r=>{release=r;});
  const app=createAppServer({sweepDetector:{async detect(frames,k,{onFrame}){
    const result=frames.map(frame=>({...frame,detections:fx.frames.find(f=>f.index===frame.index).detections}));
    onFrame(result[0]);entered();await gate;return result;
  }},stationPlanner:{async planCandidates(){throw new Error('Intentional fallback');}}});
  const socket={readyState:1,send(){}};const {room,player:host}=app.rooms.create('Host',socket);
  const address=await app.listen(0,'127.0.0.1');t.after(()=>app.close());
  const base=`http://127.0.0.1:${address.port}`;
  const post=async(kind,body)=>{
    const response=await fetch(`${base}/scan/${room.code}/${kind}`,{method:'POST',headers:{'Content-Type':'application/json','X-Player-Id':host.id},body:JSON.stringify(body)});
    return {status:response.status,body:await response.json()};
  };
  const snapshot=async()=> (await fetch(`${base}/api/dashboard/scans`)).json();
  assert.equal((await snapshot()).runs.length,0);
  await post('perimeter',{poses});
  const perimeter=(await snapshot()).runs[0];assert.equal(perimeter.status,'completed');assert.equal(perimeter.grid.originX,-.5);
  const body={vantage:fx.vantage,intrinsics:fx.intrinsics,frames:fx.frames.map(({index,t,pose})=>({index,t,pose,jpeg:bytes.toString('base64')}))};
  const pending=post('sweep',body);await ready;
  const during=(await snapshot()).runs[0];assert.equal(during.status,'processing');assert.equal(during.step,'detecting');
  assert.equal(during.frames.length,1);assert.equal(during.totalFrames,36);assert.equal(during.previews.length,1);
  const preview=await fetch(base+during.previews[0].url);assert.equal(preview.headers.get('content-type'),'image/jpeg');
  assert.deepEqual(Buffer.from(await preview.arrayBuffer()),bytes);
  release();assert.equal((await pending).status,200);
  const completed=(await snapshot()).runs[0];assert.equal(completed.id,during.id);assert.equal(completed.status,'completed');
  assert.equal(completed.frames.length,36);assert.equal(completed.notesFound,6);assert.equal(completed.notes.length,6);
  assert.equal(completed.stations.length,5);assert.equal(completed.result.stations,4);assert.ok(completed.result.warnings.length);
  assert.ok(completed.previews.length<=6);assert.equal(completed.notes.filter(n=>n.station).length,4);
  assert.ok(!JSON.stringify(completed).includes(host.id));assert.ok(!JSON.stringify(completed).includes('"pose"'));
  const failed=await post('perimeter',{poses:poses.slice(0,10)});assert.equal(failed.status,400);
  const error=(await snapshot()).runs[0];assert.equal(error.status,'failed');assert.equal(error.error.code,'SCAN_UPLOAD_INVALID');
  const missing=await fetch(`${base}/api/dashboard/scans/${during.id}/frames/9999`);assert.equal(missing.status,404);
});
