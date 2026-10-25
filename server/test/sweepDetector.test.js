const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {EventEmitter}=require('node:events');
const {PassThrough,Writable}=require('node:stream');
const {createSweepDetector,validateSweepResult}=require('../sweepDetector');
const input=[{index:7,t:0,pose:{x:2,y:1.4,z:2,qx:0,qy:0,qz:0,qw:1},bytes:Buffer.from('fixture JPEG')}];
const k={width:1920,height:1080};
const result=()=>({frames:[{index:7,width:1920,height:1080,detections:[{label:'sticky note',confidence:.8,box:[.4,.3,.02,.03],
  context:[{label:'television',confidence:.9,box:[.5,.2,.3,.4],imageGap:.05}]}]}]});
test('sweep adapter associates uploaded poses and converts boxes to pixels without trusting worker poses',()=>{
  const raw=result();raw.frames[0].pose={x:999};
  const frames=validateSweepResult(raw,input,k);
  assert.equal(frames[0].index,7);assert.deepEqual(frames[0].pose,input[0].pose);
  assert.deepEqual(frames[0].detections[0].box,[768,324,38.4,32.4]);
  for(const mutate of [r=>{r.frames[0].index=0;},r=>{r.frames[0].detections[0].confidence=.54;},
    r=>{r.frames[0].detections[0].box=[.9,.9,.5,.5];},r=>{r.frames[0].width=320;}]){
    const bad=result();mutate(bad);assert.throws(()=>validateSweepResult(bad,input,k));
  }
});
test('sweep worker uses temporary JPEGs, strips the API key and cleans up after success/invalid output/cancel',async()=>{
  for(const mode of ['success','broken','cancel']){
    let specs,entered;const started=new Promise(r=>{entered=r;});
    const spawnImpl=(program,args,options)=>{
      assert.equal(program,process.execPath);assert.equal(options.windowsHide,true);assert.ok(!options.env.GEMINI_API_KEY);
      const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();child.kill=()=>process.nextTick(()=>child.emit('close',null));
      child.stdin=new Writable({write(chunk,encoding,done){specs=JSON.parse(chunk).frames;assert.ok(specs.every(f=>fs.existsSync(f.path)));done();entered();
        process.nextTick(()=>{if(mode==='cancel')return;
          if(mode==='success')child.stdout.write(`${JSON.stringify({type:'sweep_frame',frame:result().frames[0]})}\n`);
          child.stdout.write(mode==='broken'?'bad-json\n':`${JSON.stringify({type:'sweep_result',...result()})}\n`);if(mode==='success')child.emit('close',0);});}});
      return child;
    };
    const detector=createSweepDetector({pythonPath:process.execPath,ready:true,spawnImpl});const controller=new AbortController();
    const progress=[];
    const pending=detector.detect(input,k,{signal:controller.signal,onFrame:frame=>progress.push(frame)});
    const checked=mode==='success'?pending:assert.rejects(pending,{code:'SCAN_FAILED'});
    await started;if(mode==='cancel')controller.abort();await checked;
    if(mode==='success'){assert.equal(progress.length,1);assert.equal(progress[0].index,7);}
    assert.ok(specs.every(f=>!fs.existsSync(f.path)));
  }
});
