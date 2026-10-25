const fs=require('node:fs');
const path=require('node:path');
const {connectClient}=require('./client');
async function main(){
  const args=process.argv.slice(2);let app,base=process.env.HTTP_URL || 'http://127.0.0.1:8080',perimeter,sweep;
  if(args[0]==='--fixture'){
    const fx=require('../../docs/fixtures/postit/sweep-observations.json');
    const jpeg=fs.readFileSync(path.join(__dirname,'../../docs/fixtures/postit/tiny-frame.jpg')).toString('base64');
    perimeter={poses:require('../../docs/fixtures/poses.json')};
    sweep={vantage:fx.vantage,intrinsics:fx.intrinsics,frames:fx.frames.map(({index,t,pose})=>({index,t,pose,jpeg}))};
    app=require('../index').createAppServer({sweepDetector:{async detect(frames){return frames.map(f=>({...f,detections:fx.frames.find(source=>source.index===f.index).detections}));}},
      ...(args.includes('--gemini')?{}:{stationPlanner:{async planCandidates(){throw new Error('Intentional fixture fallback test');}}})});
    const address=await app.listen(0,'127.0.0.1');base=`http://127.0.0.1:${address.port}`;
    console.log('SYNTHETIC fixture: injected detections, real HTTP/WebSocket; not live detector acceptance.');
  }else{
    if(args.length!==2)throw new Error('Usage: node tools/testSweep.js --fixture OR <perimeter.json> <sweep.json> (HTTP_URL optional)');
    const body=JSON.parse(fs.readFileSync(args[0],'utf8'));perimeter=Array.isArray(body)?{poses:body}:body;
    sweep=JSON.parse(fs.readFileSync(args[1],'utf8'));
  }
  let client;
  try{
    client=await connectClient(`${base.replace(/^http/,'ws')}/ws`);client.send({t:'create',name:'Sweep test host'});
    const joined=await client.waitFor(m=>m.t==='joined');
    const post=async(step,body)=>{
      const response=await fetch(`${base}/scan/${joined.room}/${step}`,{method:'POST',headers:{'content-type':'application/json','X-Player-Id':joined.playerId},
        body:JSON.stringify(body),signal:AbortSignal.timeout(660000)});
      const result=await response.json();if(!response.ok)throw new Error(`${response.status} ${result.code}: ${result.message}`);return result;
    };
    console.log('Perimeter:',JSON.stringify(await post('perimeter',perimeter)));
    const first=await client.waitFor(m=>m.t==='setup');console.log('Origin/emergency:',JSON.stringify({originX:first.grid.originX,originZ:first.grid.originZ,emergency:first.stations.find(s=>s.kind==='emergency').tile}));
    console.log('Sweep:',JSON.stringify(await post('sweep',sweep)));
    const setup=await client.waitFor(m=>m.t==='setup');console.log('Stations:',JSON.stringify(setup.stations));
  }finally{client?.socket.close();if(app)await app.close();}
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
