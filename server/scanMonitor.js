const {randomUUID}=require('node:crypto');

// Bounded, laptop-only diagnostics. No disk persistence or player identities.
class ScanMonitor {
  constructor({maxRuns=6,maxPreviews=6,now=Date.now}={}){
    this.runs=[];this.revision=0;this.maxRuns=maxRuns;this.maxPreviews=maxPreviews;this.now=now;
  }
  begin(room,kind,totalBytes){
    const run={id:randomUUID(),room:room.code,kind,status:'uploading',step:'uploading',startedAt:this.now(),updatedAt:this.now(),
      totalBytes:Number.isFinite(totalBytes)?totalBytes:0,receivedBytes:0,totalFrames:0,frames:[],notes:[],stations:[],events:[],previews:new Map()};
    this.runs.unshift(run);this.runs.length=Math.min(this.runs.length,this.maxRuns);
    this.event(run,'Receiving app scan upload.');return run;
  }
  update(run,patch){if(!run)return;Object.assign(run,patch);run.updatedAt=this.now();this.revision++;}
  event(run,message){if(!run)return;run.events.push({at:this.now(),message:message.slice(0,300)});run.events=run.events.slice(-30);this.update(run,{});}
  frame(run,frame,source,intrinsics){
    if(!run)return;
    const detections=frame.detections.slice(0,20).map(d=>({label:d.label,confidence:d.confidence,
      box:d.box.map((v,i)=>v/(i%2===0?intrinsics.width:intrinsics.height))}));
    const summary={index:frame.index,t:frame.t,notes:frame.detections.length};
    const index=run.frames.findIndex(f=>f.index===frame.index);
    if(index<0)run.frames.push(summary);else run.frames[index]=summary;
    if(source?.bytes && source.bytes.length<=600*1024){
      run.previews.delete(frame.index);run.previews.set(frame.index,{bytes:source.bytes,t:frame.t,detections});
      while(run.previews.size>this.maxPreviews)run.previews.delete(run.previews.keys().next().value);
    }
    this.update(run,{latestFrame:frame.index,step:'detecting',status:'processing'});
  }
  retain(run,notes,frames,input){
    if(!run)return;
    // Retain selected representatives rather than all uploaded camera images.
    run.previews.clear();
    const indices=[...new Set(notes.map(n=>n.best.frameIndex))].slice(0,this.maxPreviews);
    if(!indices.length && frames.length)indices.push(frames.at(-1).index);
    for(const index of indices){
      const frame=frames.find(f=>f.index===index),source=input.frames.find(f=>f.index===index);
      if(frame && source)this.frame(run,frame,source,input.intrinsics);
    }
  }
  snapshot(){
    return {revision:this.revision,runs:this.runs.map(run=>({
      id:run.id,room:run.room,kind:run.kind,status:run.status,step:run.step,startedAt:run.startedAt,updatedAt:run.updatedAt,endedAt:run.endedAt,
      totalBytes:run.totalBytes,receivedBytes:run.receivedBytes,totalFrames:run.totalFrames,frames:run.frames,latestFrame:run.latestFrame,
      detectorModel:run.detectorModel,notesFound:run.notesFound,notes:run.notes,stations:run.stations,grid:run.grid,result:run.result,planning:run.planning,error:run.error,events:run.events,
      previews:[...run.previews].map(([index,frame])=>({index,t:frame.t,detections:frame.detections,url:`/api/dashboard/scans/${run.id}/frames/${index}`})),
    }))};
  }
  preview(id,index){return this.runs.find(r=>r.id===id)?.previews.get(index)?.bytes;}
}
module.exports={ScanMonitor};
