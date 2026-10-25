const fs=require('node:fs');
const fsp=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const {spawn}=require('node:child_process');
const {RoomError,requireAction}=require('./errors');
const {CLASSES,NOTE,validBox}=require('./yoloDetector');
const {selectModel,modelReady}=require('./yoloConfig');
function validateSweepResult(result,frames,intrinsics){
  requireAction(Array.isArray(result?.frames) && result.frames.length===frames.length,'SCAN_FAILED','Detector omitted sweep frames.');
  const seen=new Set();
  return result.frames.map(frame=>{
    const source=frames.find(f=>f.index===frame?.index);
    requireAction(source && !seen.has(frame.index) && Array.isArray(frame.detections) && frame.detections.length<=64,'SCAN_FAILED','Invalid detector frame results.');
    seen.add(frame.index);
    if(frame.detections.length)requireAction(frame.width===intrinsics.width && frame.height===intrinsics.height,'SCAN_UPLOAD_INVALID','JPEG dimensions do not match camera intrinsics.');
    const pixelBox=box=>box.map((v,i)=>v*(i%2===0?intrinsics.width:intrinsics.height));
    const detections=frame.detections.map(d=>{
      requireAction(d.label===NOTE && Number.isFinite(d.confidence) && d.confidence>=0.55 && d.confidence<=1 && validBox(d.box)
        && Array.isArray(d.context) && d.context.length<=6,'SCAN_FAILED','Invalid detector note observations.');
      const context=d.context.map(c=>{
        requireAction(CLASSES.includes(c.label) && c.label!==NOTE && validBox(c.box)
          && Number.isFinite(c.confidence) && c.confidence>=0.35 && c.confidence<=1
          && Number.isFinite(c.imageGap) && c.imageGap>=0 && c.imageGap<=0.200001,'SCAN_FAILED','Invalid same-frame context.');
        return {label:c.label,confidence:c.confidence,imageGap:c.imageGap,box:pixelBox(c.box)};
      });
      return {label:NOTE,confidence:d.confidence,box:pixelBox(d.box),context};
    });
    return {index:source.index,t:source.t,pose:source.pose,detections};
  });
}
function createSweepDetector({model=selectModel(),pythonPath=process.env.YOLOE_PYTHON || path.join(__dirname,'.venv-yolo',process.platform==='win32'?'Scripts/python.exe':'bin/python'),
  ready=modelReady(model),spawnImpl=spawn,timeoutMs=600000}={}){
  selectModel(model);
  return {model,async detect(frames,intrinsics,{signal,onFrame=()=>{}}={}){
    requireAction(ready && fs.existsSync(pythonPath),'SCAN_FAILED','YOLOE is not ready; install and warm up the local detector.');
    signal?.throwIfAborted();
    const directory=await fsp.mkdtemp(path.join(os.tmpdir(),'blindspot-sweep-'));
    try{
      const specs=[];
      for(const [i,frame] of frames.entries()){
        const filename=path.join(directory,`${i}.jpg`);await fsp.writeFile(filename,frame.bytes);specs.push({path:filename,index:frame.index});
      }
      return await new Promise((resolve,reject)=>{
        const env={...process.env,YOLOE_MODEL:model,PYTHONUNBUFFERED:'1',PYTHONUTF8:'1'};delete env.GEMINI_API_KEY;
        const child=spawnImpl(pythonPath,[path.join(__dirname,'tools/yoloe_worker.py')],{cwd:__dirname,env,windowsHide:true,stdio:['pipe','pipe','pipe']});
        let pending='',stderr='',total=0,output,failure;
        const abort=()=>{failure=new RoomError('SCAN_FAILED','Sweep detection cancelled.');child.kill();};
        const timer=setTimeout(()=>{failure=new RoomError('SCAN_FAILED','Sweep detection exceeded ten minutes.');child.kill();},timeoutMs);timer.unref();
        const cleanup=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);};
        signal?.addEventListener('abort',abort,{once:true});if(signal?.aborted)abort();
        child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');
        child.stderr.on('data',s=>{stderr=(stderr+s).slice(-3000);});
        child.stdout.on('data',s=>{
          total+=Buffer.byteLength(s);if(total>16*1024*1024){failure=new RoomError('SCAN_FAILED','Detector output exceeded its limit.');child.kill();return;}
          pending+=s;const lines=pending.split('\n');pending=lines.pop();
          for(const line of lines){if(!line.trim())continue;try{
            const event=JSON.parse(line);
            if(event.type==='sweep_frame'){
              const source=frames.find(f=>f.index===event.frame?.index);
              requireAction(source,'SCAN_FAILED','Detector reported an unknown frame.');
              onFrame(validateSweepResult({frames:[event.frame]},[source],intrinsics)[0]);
            }
            if(event.type==='sweep_result')output=validateSweepResult(event,frames,intrinsics);
            if(event.type==='error')failure=new RoomError('SCAN_FAILED','YOLOE could not decode or analyze the sweep.');
          }catch(e){failure=e instanceof RoomError?e:new RoomError('SCAN_FAILED','Invalid detector response.');child.kill();}}
        });
        child.once('error',()=>{cleanup();reject(new RoomError('SCAN_FAILED','Cannot start the YOLOE runtime.'));});
        child.once('close',code=>{cleanup();if(failure || code!==0 || !output){if(stderr)console.error(`Sweep worker: ${stderr}`);reject(failure||new RoomError('SCAN_FAILED','Sweep detector returned no results.'));}else resolve(output);});
        child.stdin.on('error',()=>{});child.stdin.end(JSON.stringify({frames:specs}));
      });
    }finally{await fsp.rm(directory,{recursive:true,force:true});}
  }};
}
module.exports={createSweepDetector,validateSweepResult};
