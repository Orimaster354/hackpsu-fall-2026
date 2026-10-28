const { RoomError, requireAction } = require('./errors');
const { buildPerimeter } = require('./perimeter');
const { zoneId, zoneName, ensureZone, scannedZones, recompose, resetZone } = require('./zones');
const LIMITS={perimeter:2*1024*1024,sweep:64*1024*1024};
const statusFor={ROOM_NOT_FOUND:404,HOST_ONLY:403,INVALID_PHASE:409,SETUP_LOCKED:409,SETUP_MISSING:409,
  SCAN_BUSY:409,SCAN_UPLOAD_TOO_LARGE:413,SCAN_FAILED:422,SCAN_UPLOAD_INVALID:400,INVALID_ZONE:400,TOO_MANY_ZONES:409,ZONES_TOO_LARGE:422};
function valid(ok,message) {requireAction(ok,'SCAN_UPLOAD_INVALID',message);}
function pose(value) {
  valid(value && ['x','y','z','qx','qy','qz','qw'].every(k=>Number.isFinite(value[k])),'Pose needs finite position and quaternion fields.');
  const norm=Math.hypot(value.qx,value.qy,value.qz,value.qw);
  valid(Math.abs(norm-1)<=0.05,'Pose quaternion must be approximately unit length.');
  return {x:value.x,y:value.y,z:value.z,qx:value.qx/norm,qy:value.qy/norm,qz:value.qz/norm,qw:value.qw/norm};
}
function perimeterInput(body) {
  valid(Array.isArray(body?.poses) && body.poses.length>=100 && body.poses.length<=3000,'Provide 100-3000 perimeter poses.');
  let last=-1;
  return body.poses.map(p=>{valid(Number.isFinite(p?.t) && p.t>=0 && p.t>last,'Pose timestamps must strictly increase.');last=p.t;return {...pose(p),t:p.t};});
}
function readJson(request,limit,onBytes=()=>{}) {
  return new Promise((resolve,reject)=>{
    let size=0,failed=false;const chunks=[];
    request.on('data',chunk=>{if(failed)return;size+=chunk.length;onBytes(size);if(size>limit){failed=true;chunks.length=0;reject(new RoomError('SCAN_UPLOAD_TOO_LARGE','Scan exceeds the upload limit.'));}else chunks.push(chunk);});
    request.on('end',()=>{if(failed)return;try{resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));}catch{reject(new RoomError('SCAN_UPLOAD_INVALID','Send a valid JSON scan body.'));}});
    request.on('error',()=>reject(new RoomError('SCAN_UPLOAD_INVALID','Scan upload interrupted.')));
    request.on('aborted',()=>reject(new RoomError('SCAN_UPLOAD_INVALID','Scan upload interrupted.')));
  });
}
function authorize(room,request) {
  requireAction(room,'ROOM_NOT_FOUND','Room does not exist.');
  requireAction(request.headers['x-player-id']===room.hostId,'HOST_ONLY','Only the host may upload a scan.');
  requireAction(room.phase==='lobby','INVALID_PHASE','Scan uploads are lobby only.');
  requireAction(!room.setupConfirmed,'SETUP_LOCKED','Confirmed setup cannot be replaced.');
}
function createScanHandler(manager,options={}) {
  const active=new Set();
  const handler=async(request,response,code,step)=>{
    let room,run,ownsSlot=false;const controller=new AbortController();const monitor=options.scanMonitor;
    const abort=()=>{if(!response.writableEnded)controller.abort();};response.on('close',abort);
    try{
      room=manager.rooms.get(code);authorize(room,request);
      valid(request.method==='POST','Use POST for scan uploads.');
      requireAction(!room.scanBusy,'SCAN_BUSY','This room is already processing a scan.');
      if(step==='sweep')requireAction(scannedZones(room).length && room.grid,'SETUP_MISSING','Upload a perimeter first.');
      valid(request.headers['content-type']?.split(';')[0].trim()==='application/json','Send application/json.');
      requireAction(Number(request.headers['content-length']||0)<=LIMITS[step],'SCAN_UPLOAD_TOO_LARGE','Scan exceeds the upload limit.');
      room.scanBusy=true;ownsSlot=true;active.add(controller);
      run=monitor?.begin(room,step,Number(request.headers['content-length']||0));
      const body=await readJson(request,LIMITS[step],receivedBytes=>monitor?.update(run,{receivedBytes}));authorize(room,request);controller.signal.throwIfAborted();
      let result;
      // Every scan names the room it belongs to (default z1, so a one-room game is unchanged).
      const zid=zoneId(body?.zone),name=zoneName(body?.name);
      if(step==='sweep')requireAction(room.zones.get(zid)?.geometry,'SETUP_MISSING','Upload this room\'s perimeter first.');
      if(step==='perimeter'){
        const poses=perimeterInput(body);
        monitor?.update(run,{status:'processing',step:'polygon'});monitor?.event(run,`Building grid from ${poses.length} poses.`);
        room.broadcast({t:'processing',step:'polygon'});
        const geometry=buildPerimeter(poses);
        // Rescanning a room starts it over: its old map and doors no longer match the new world frame.
        const existed=room.zones.has(zid),zone=ensureZone(room,zid,name);
        const before={geometry:zone.geometry,ranked:zone.ranked,maps:new Map(room.maps),doors:room.doors};
        zone.geometry=geometry;zone.ranked=[];resetZone(room,zid);
        try{recompose(room);}catch(error){
          if(existed){zone.geometry=before.geometry;zone.ranked=before.ranked;}else room.zones.delete(zid);
          room.maps=before.maps;room.doors=before.doors;throw error;
        }
        monitor?.update(run,{grid:room.grid,stations:room.stations});
        result={ok:true,zone:zid,cols:geometry.grid.cols,rows:geometry.grid.rows,edgeTiles:geometry.grid.edge.length};
      }else{
        const {processSweep}=require('./sweep');
        result=await processSweep(room,body,{...options,monitorRun:run,signal:controller.signal,
          beforeCommit:()=>{authorize(room,request);controller.signal.throwIfAborted();}});
      }
      monitor?.update(run,{status:'completed',step:'completed',endedAt:Date.now(),result});monitor?.event(run,'Scan completed; setup broadcast to app.');
      response.writeHead(200,{'content-type':'application/json','Cache-Control':'no-store'});response.end(JSON.stringify(result));
    }catch(error){
      monitor?.update(run,{status:controller.signal.aborted?'cancelled':'failed',step:'error',endedAt:Date.now(),
        error:{code:error instanceof RoomError?error.code:'SERVER_ERROR',message:error instanceof RoomError?error.message:'Scan processing failed.'}});
      request.resume();if(!response.destroyed){response.writeHead(statusFor[error.code]||500,{'content-type':'application/json'});
        response.end(JSON.stringify({t:'error',code:error instanceof RoomError ? error.code:'SERVER_ERROR',message:error instanceof RoomError ? error.message:'Scan processing failed.'}));}
    }finally{if(ownsSlot){room.scanBusy=false;active.delete(controller);}response.removeListener('close',abort);}
  };
  handler.close=()=>{for(const controller of active)controller.abort();};
  return handler;
}
module.exports={createScanHandler,perimeterInput,pose,LIMITS};
