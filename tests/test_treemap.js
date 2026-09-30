const assert = require('node:assert/strict');
const {squarify} = require('../web/treemap.js');
for (let n of [1,2,3,10,100,1000]) {
  const input = Array.from({length:n},(_,i)=>({id:i,size:(i+1)*(i+1)}));
  const rects = squarify(input,1133,687), area=1133*687;
  const total=input.reduce((s,x)=>s+x.size,0);
  assert.equal(rects.length,n);
  assert.ok(Math.abs(rects.reduce((s,r)=>s+r.w*r.h,0)-area)<1e-6);
  for (const r of rects) {
    assert.ok(r.w>=0 && r.h>=0 && r.x>=-1e-9 && r.y>=-1e-9);
    assert.ok(r.x+r.w<=1133+1e-7 && r.y+r.h<=687+1e-7);
    assert.ok(Math.abs(r.w*r.h/area-r.size/total)<1e-9);
  }
  for(let i=0;i<rects.length;i++)for(let j=i+1;j<rects.length;j++){
    const a=rects[i],b=rects[j];
    const overlap=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x);
    const overlapY=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
    assert.ok(overlap<1e-7||overlapY<1e-7);
  }
}
assert.deepEqual(squarify([{size:0}],100,100),[]);
console.log('PASS: treemap area, bounds, proportions, non-overlap, empty data');
