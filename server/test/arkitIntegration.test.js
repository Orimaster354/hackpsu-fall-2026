const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {createAppServer}=require('../index');
const {connectClient}=require('../tools/client');
const poses=require('../../docs/fixtures/poses.json');
const fx=require('../../docs/fixtures/postit/sweep-observations.json');

test('scan upload shapes used by ARKit continue through map, confirmation, four-player start and AR tile actions',async t=>{
  const app=createAppServer({sweepDetector:{async detect(frames){return frames.map(frame=>({...frame,detections:fx.frames.find(f=>f.index===frame.index).detections}));}},
    stationPlanner:{async planCandidates(){throw new Error('Fixture score fallback');}}});
  const address=await app.listen(0,'127.0.0.1');const base=`http://127.0.0.1:${address.port}`;
  const clients=[];t.after(async()=>{for(const client of clients)client.socket.terminate();await app.close();});
  for(let i=0;i<4;i++)clients.push(await connectClient(`ws://127.0.0.1:${address.port}/ws`));
  clients[0].send({t:'create',name:'Host'});const joined=await clients[0].waitFor(m=>m.t==='joined');
  for(let i=1;i<4;i++){clients[i].send({t:'join',room:joined.room,name:`Guest ${i}`});await clients[i].waitFor(m=>m.t==='joined');}
  const post=async(step,body)=>{
    const response=await fetch(`${base}/scan/${joined.room}/${step}`,{method:'POST',headers:{'Content-Type':'application/json','X-Player-Id':joined.playerId},body:JSON.stringify(body)});
    assert.equal(response.status,200);return response.json();
  };
  assert.equal((await post('perimeter',{poses})).cols,5);
  const jpeg=fs.readFileSync(path.join(__dirname,'../../docs/fixtures/postit/tiny-frame.jpg')).toString('base64');
  const sweep=await post('sweep',{vantage:fx.vantage,intrinsics:fx.intrinsics,frames:fx.frames.map(({index,t,pose})=>({index,t,pose,jpeg}))});
  assert.equal(sweep.notesFound,6);assert.equal(sweep.stations,4);
  const setups=await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='setup' && m.stations.length===5)));
  assert.ok(setups.every(s=>s.grid.originX===-.5 && s.grid.originZ===-.5 && s.setupConfirmed===false));
  // Opaque synthetic bytes verify map transport only, not ARKit world-map validity/relocalization.
  const bytes=Buffer.from('synthetic-world-map-transport-fixture');
  const upload=await fetch(`${base}/map/${joined.room}`,{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Player-Id':joined.playerId},body:bytes});
  assert.equal(upload.status,204);
  await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='lobby' && m.hasMap)));
  assert.deepEqual(Buffer.from(await (await fetch(`${base}/map/${joined.room}`)).arrayBuffer()),bytes);
  clients[0].send({t:'confirmSetup'});
  await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='lobby' && m.setupConfirmed)));
  clients[0].send({t:'start'});
  const roles=await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='role')));
  assert.equal(roles.filter(r=>r.role==='impostor').length,1);
  const states=await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='state' && m.phase==='playing')));
  assert.ok(states.every(s=>s.players.length===4 && s.players.every(p=>!Object.hasOwn(p,'role'))));
  for(const client of clients)for(let i=0;i<2;i++)client.send({t:'tile',source:'ar',tile:{x:2,y:2}});
  await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='state' && m.players.every(p=>p.tile?.x===2 && p.tile?.y===2 && p.tileSource==='ar'))));
  const crew=clients[roles.findIndex(r=>r.role==='crew')],station=setups[0].stations.find(s=>s.kind==='task');
  crew.send({t:'tile',source:'ar',tile:station.tile});crew.send({t:'tile',source:'ar',tile:station.tile});crew.send({t:'taskDone',stationId:station.id});
  await Promise.all(clients.map(c=>c.waitFor(m=>m.t==='state' && m.tasksDone===1)));
});
