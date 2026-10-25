(() => {
  const $=id=>document.getElementById(id);
  let history=[],selectedId,follow=true,preview,selectedNote,selectedFrame,timer,closed=false,renderedRevision=-1;
  const stages={uploading:'Receiving upload',detecting:'Detecting notes',polygon:'Building grid',placing:'Placing stations',ranking:'Gemini ranking',completed:'Completed',error:'Failed'};
  function drawFrame(){
    const image=$('app-scan-image'),canvas=$('app-scan-boxes'),ctx=canvas.getContext('2d');
    canvas.width=image.naturalWidth||1;canvas.height=image.naturalHeight||1;
    ctx.clearRect(0,0,canvas.width,canvas.height);
    for(const item of selectedNote?[selectedNote]:(preview?.detections||[])){
      const [x,y,w,h]=item.box;ctx.strokeStyle='#8ce9be';ctx.lineWidth=Math.max(2,canvas.width/320);
      ctx.strokeRect(x*canvas.width,y*canvas.height,w*canvas.width,h*canvas.height);
      ctx.fillStyle='#8ce9be';ctx.font=`${Math.max(14,canvas.width/45)}px sans-serif`;
      ctx.fillText(`${item.id||'note'} ${Number(item.confidence??item.score).toFixed(2)}`,x*canvas.width,Math.max(22,y*canvas.height-5));
    }
  }
  function drawGrid(run){
    const canvas=$('app-scan-grid'),ctx=canvas.getContext('2d'),grid=run.grid;
    ctx.clearRect(0,0,canvas.width,canvas.height);if(!grid)return;
    const size=Math.min((canvas.width-30)/grid.cols,(canvas.height-30)/grid.rows),edge=new Set(grid.edge.map(t=>`${t.x},${t.y}`));
    for(const tile of grid.playable){
      ctx.fillStyle=edge.has(`${tile.x},${tile.y}`)?'#20374a':'#15212d';ctx.strokeStyle='#344858';
      ctx.fillRect(15+tile.x*size,15+tile.y*size,size,size);ctx.strokeRect(15+tile.x*size,15+tile.y*size,size,size);
    }
    for(const [i,station] of (run.stations||[]).entries()){
      const x=15+(station.tile.x+.5)*size,y=15+(station.tile.y+.5)*size;
      ctx.fillStyle=station.kind==='emergency'?'#f28b82':station.kind==='fix'?'#f3cf72':'#8ce9be';
      ctx.beginPath();ctx.arc(x,y,Math.max(3,size*.22),0,Math.PI*2);ctx.fill();
      ctx.fillStyle='#07101a';ctx.font=`bold ${Math.min(15,Math.max(8,size*.22))}px sans-serif`;ctx.textAlign='center';ctx.textBaseline='middle';
      ctx.fillText(station.kind==='emergency'?'E':station.kind==='fix'?'F':String(i),x,y);
    }
  }
  function showPreview(run,index,note=null){
    preview=run.previews.find(p=>p.index===index);selectedFrame=index;selectedNote=note;
    $('app-scan-preview-empty').hidden=Boolean(preview);$('app-scan-frame').hidden=!preview;
    if(!preview)return;
    $('app-scan-frame-caption').textContent=`Frame ${preview.index} · ${preview.t.toFixed(2)}s · ${note?note.id:'all detected note boxes'}`;
    $('app-scan-frame-select').value=String(index);
    const image=$('app-scan-image');if(image.getAttribute('src')!==preview.url)image.src=preview.url;else drawFrame();
  }
  function render(){
    const run=history.find(r=>r.id===selectedId);
    $('app-scan-details').hidden=!run;
    $('app-scan-status').textContent=run?(run.status==='cancelled'?'Cancelled':stages[run.step]||run.status):'WAITING FOR APP';
    $('app-scan-info').textContent=run?`Room ${run.room} · ${run.kind} · ${new Date(run.startedAt).toLocaleTimeString()} · ${(((run.endedAt??Date.now())-run.startedAt)/1000).toFixed(0)}s elapsed`:'Scan a room in the iPhone app. New uploads appear automatically.';
    if(!run)return;
    const bytes=run.receivedBytes/1048576,total=run.totalBytes/1048576;
    $('app-scan-metrics').textContent=`Upload ${bytes.toFixed(1)}${total?` / ${total.toFixed(1)}`:''} MiB · Frames ${run.frames.length}/${run.totalFrames} · Raw note observations ${run.frames.reduce((sum,f)=>sum+f.notes,0)} · Merged notes ${run.notesFound??'—'} · Task/fix stations ${run.result?.stations??'—'}`;
    $('app-scan-upload').value=run.totalBytes?Math.min(100,run.receivedBytes/run.totalBytes*100):0;
    $('app-scan-error').hidden=!run.error;
    $('app-scan-error').textContent=run.error?`${run.error.code}: ${run.error.message}`:'';
    const warningList=$('app-scan-warnings');warningList.replaceChildren();
    for(const message of run.result?.warnings||[]){const li=document.createElement('li');li.textContent=message;warningList.append(li);}
    const options=$('app-scan-frame-select');options.replaceChildren();
    for(const item of run.previews){const option=document.createElement('option');option.value=item.index;option.textContent=`Frame ${item.index} · ${item.t.toFixed(2)}s`;options.append(option);}
    if(!run.previews.some(p=>p.index===selectedFrame)){selectedFrame=run.previews.at(-1)?.index;selectedNote=null;}
    showPreview(run,selectedFrame,selectedNote);
    const notes=$('app-scan-notes');notes.replaceChildren();
    for(const note of run.notes){
      const button=document.createElement('button');button.type='button';button.className='app-note';
      const reason=run.planning?.suggestions?.find(s=>s.candidateId===note.id)?.reason;
      button.textContent=`${note.id} · score ${note.score.toFixed(2)} · ${note.observationCount} observations · ${note.station?`${note.station.kind}/${note.station.task} at (${note.station.tile.x},${note.station.tile.y})`:'candidate not selected'}${reason?` · ${reason}`:''}`;
      button.disabled=!run.previews.some(p=>p.index===note.frameIndex);
      button.title=button.disabled?'Preview not retained in bounded history':'Inspect this note';
      button.addEventListener('click',()=>showPreview(run,note.frameIndex,note));notes.append(button);
    }
    if(!run.notes.length)notes.textContent=run.status==='completed'?'No merged note candidates in this scan.':'Merged candidates appear after frame detection.';
    if(run.notesFound>run.notes.length){const p=document.createElement('p');p.textContent=`Showing ${run.notes.length} of ${run.notesFound} candidates, with selected stations first.`;notes.append(p);}
    drawGrid(run);
    const stations=$('app-scan-stations');stations.replaceChildren();
    for(const station of run.stations){const li=document.createElement('li');li.textContent=`${station.kind} · ${station.name} · tile (${station.tile.x},${station.tile.y}) · ${station.task}`;stations.append(li);}
    const events=$('app-scan-events');events.replaceChildren();
    for(const event of [...run.events].reverse()){const li=document.createElement('li');li.textContent=`${new Date(event.at).toLocaleTimeString()} · ${event.message}`;events.append(li);}
  }
  async function poll(){
    try{
      const response=await fetch('/api/dashboard/scans',{cache:'no-store'});if(!response.ok)throw new Error('Scan monitor unavailable.');
      const data=await response.json();history=data.runs;
      const previousId=selectedId;
      if(follow || !history.some(r=>r.id===selectedId))selectedId=history[0]?.id;
      if(previousId!==selectedId){selectedFrame=undefined;selectedNote=null;}
      const select=$('app-scan-select'),signature=history.map(r=>r.id).join(',');
      if(select.dataset.signature!==signature){
        select.replaceChildren();select.dataset.signature=signature;
        for(const run of history){const option=document.createElement('option');option.value=run.id;option.textContent=`${run.room} · ${run.kind} · ${new Date(run.startedAt).toLocaleTimeString()}`;select.append(option);}
      }
      select.value=selectedId||'';$('app-scan-connection').textContent=`Live · updates every second · ${history.length} recent scans`;
      if(renderedRevision!==data.revision){renderedRevision=data.revision;render();}
    }catch(error){$('app-scan-connection').textContent=error.message;}
    if(!closed)timer=setTimeout(poll,1000);
  }
  $('app-scan-image').addEventListener('load',drawFrame);
  $('app-scan-select').addEventListener('change',()=>{follow=false;selectedId=$('app-scan-select').value;selectedFrame=undefined;selectedNote=null;render();});
  $('app-scan-follow').addEventListener('click',()=>{follow=true;selectedId=history[0]?.id;selectedFrame=undefined;selectedNote=null;render();});
  $('app-scan-frame-select').addEventListener('change',()=>{const run=history.find(r=>r.id===selectedId);if(run)showPreview(run,Number($('app-scan-frame-select').value));});
  window.addEventListener('pagehide',()=>{closed=true;clearTimeout(timer);});
  render();void poll();
})();
