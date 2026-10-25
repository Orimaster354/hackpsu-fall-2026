const { requireAction } = require('./errors');
const fail = (ok, message) => requireAction(ok, 'SCAN_FAILED', message);
const distance = (a, b) => Math.hypot(a[0]-b[0], a[1]-b[1]);
const cross = (a, b, c) => (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);
function onSegment(a, b, p) {
  return Math.abs(cross(a, b, p)) < 1e-8 && p[0] >= Math.min(a[0], b[0])-1e-8
    && p[0] <= Math.max(a[0], b[0])+1e-8 && p[1] >= Math.min(a[1], b[1])-1e-8 && p[1] <= Math.max(a[1], b[1])+1e-8;
}
function intersects(a, b, c, d) {
  return (cross(a,b,c)*cross(a,b,d) < -1e-12 && cross(c,d,a)*cross(c,d,b) < -1e-12)
    || onSegment(a,b,c) || onSegment(a,b,d) || onSegment(c,d,a) || onSegment(c,d,b);
}
function simple(polygon) {
  for (let i=0; i<polygon.length; i++) for (let j=i+1; j<polygon.length; j++) {
    if (j===i+1 || (i===0 && j===polygon.length-1)) continue;
    if (intersects(polygon[i], polygon[(i+1)%polygon.length], polygon[j], polygon[(j+1)%polygon.length])) return false;
  }
  return true;
}
function simplify(points, epsilon=0.15) {
  if (points.length <= 2) return points;
  const a=points[0], b=points.at(-1), dx=b[0]-a[0], dy=b[1]-a[1], length2=dx*dx+dy*dy;
  let largest=0, index=0;
  for (let i=1; i<points.length-1; i++) {
    const t=length2 ? Math.max(0,Math.min(1,((points[i][0]-a[0])*dx+(points[i][1]-a[1])*dy)/length2)) : 0;
    const d=distance(points[i],[a[0]+t*dx,a[1]+t*dy]);
    if (d>largest) { largest=d; index=i; }
  }
  return largest>epsilon ? [...simplify(points.slice(0,index+1),epsilon).slice(0,-1),...simplify(points.slice(index),epsilon)] : [a,b];
}
function signedArea(p) { return p.reduce((sum,a,i)=>{const b=p[(i+1)%p.length];return sum+a[0]*b[1]-b[0]*a[1];},0)/2; }
function inside(point, polygon) {
  let result=false;
  for (let i=0,j=polygon.length-1;i<polygon.length;j=i++) {
    const a=polygon[i],b=polygon[j];
    if (onSegment(a,b,point)) return true;
    if ((a[1]>point[1]) !== (b[1]>point[1]) && point[0] < (b[0]-a[0])*(point[1]-a[1])/(b[1]-a[1])+a[0]) result=!result;
  }
  return result;
}
function offsetPolygon(p, amount=0.5) {
  const sign=Math.sign(signedArea(p));
  const lines=p.map((a,i)=>{const b=p[(i+1)%p.length],d=[b[0]-a[0],b[1]-a[1]],length=distance(a,b);
    fail(length>1e-8,'Perimeter contains a zero-length edge.');
    return {p:[a[0]+sign*amount*d[1]/length,a[1]-sign*amount*d[0]/length],d}; });
  const result=lines.map((line,i)=>{
    const previous=lines[(i+lines.length-1)%lines.length],denom=previous.d[0]*line.d[1]-previous.d[1]*line.d[0];
    if (Math.abs(denom)<1e-9) return line.p;
    const delta=[line.p[0]-previous.p[0],line.p[1]-previous.p[1]];
    const t=(delta[0]*line.d[1]-delta[1]*line.d[0])/denom;
    const point=[previous.p[0]+t*previous.d[0],previous.p[1]+t*previous.d[1]];
    fail(point.every(Number.isFinite) && distance(point,p[i])<=amount*10,'Perimeter has an unsupported sharp corner.');
    return point;
  });
  fail(simple(result) && Math.abs(signedArea(result))>=4,'Offset perimeter crosses itself.');
  return result;
}
function touchesTile(polygon,x,z) {
  const corners=[[x,z],[x+1,z],[x+1,z+1],[x,z+1]];
  return polygon.some((a,i)=>{
    const b=polygon[(i+1)%polygon.length];
    return (a[0]>=x && a[0]<=x+1 && a[1]>=z && a[1]<=z+1)
      || corners.some((c,j)=>intersects(a,b,c,corners[(j+1)%4]));
  });
}
function buildPerimeter(poses) {
  const path=poses.map(p=>[p.x,p.z]).filter((p,i,all)=>i===0 || distance(p,all[i-1])>1e-8);
  fail(path.length>=4 && distance(path[0],path.at(-1))<=0.75,'Walk must close within 0.75 m.');
  if (distance(path[0],path.at(-1))>1e-8) path.push(path[0]);
  const outline=simplify(path).slice(0,-1);
  fail(outline.length>=3 && simple(outline) && Math.abs(signedArea(outline))>=4,'Perimeter must be simple and cover at least 4 square meters.');
  const polygon=offsetPolygon(outline);
  const originX=Math.min(...polygon.map(p=>p[0])),originZ=Math.min(...polygon.map(p=>p[1]));
  const cols=Math.ceil(Math.max(...polygon.map(p=>p[0]))-originX-1e-9),rows=Math.ceil(Math.max(...polygon.map(p=>p[1]))-originZ-1e-9);
  fail(cols>0 && rows>0 && cols<=100 && rows<=100,'Room exceeds the supported grid size.');
  const playable=[];
  for(let y=0;y<rows;y++) for(let x=0;x<cols;x++) if(inside([originX+x+0.5,originZ+y+0.5],polygon)) playable.push({x,y});
  fail(playable.length>0,'No playable tiles were found.');
  const keys=new Set(playable.map(t=>`${t.x},${t.y}`));
  const edge=playable.filter(t=>[[1,0],[-1,0],[0,1],[0,-1]].some(([dx,dy])=>!keys.has(`${t.x+dx},${t.y+dy}`)) || touchesTile(polygon,originX+t.x,originZ+t.y));
  const area=signedArea(polygon); let cx=0,cz=0;
  polygon.forEach((a,i)=>{const b=polygon[(i+1)%polygon.length],c=a[0]*b[1]-b[0]*a[1];cx+=(a[0]+b[0])*c;cz+=(a[1]+b[1])*c;});
  cx/=6*area;cz/=6*area;
  const center=playable.reduce((best,t)=> Math.hypot(originX+t.x+0.5-cx,originZ+t.y+0.5-cz)<Math.hypot(originX+best.x+0.5-cx,originZ+best.y+0.5-cz)-1e-9 ? t : best);
  return {polygon,grid:{cols,rows,tileSize:1,originX,originZ,playable,edge},
    emergency:{id:'emergency',name:'EMERGENCY',tile:center,task:'hold',kind:'emergency'}};
}
module.exports={buildPerimeter,inside,simple};
