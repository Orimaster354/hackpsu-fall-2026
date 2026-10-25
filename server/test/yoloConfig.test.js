const test=require('node:test');
const assert=require('node:assert/strict');
const {MODEL,selectModel,modelReady}=require('../yoloConfig');
const {createYoloDetector,validateYoloResult}=require('../yoloDetector');
const {createSweepDetector}=require('../sweepDetector');
test('Larger YOLOE selection is shared by video/sweep and explicit Small remains available',()=>{
  assert.equal(MODEL,'yoloe-26l-seg.pt');
  for(const model of ['yoloe-26s-seg.pt','yoloe-26m-seg.pt','yoloe-26l-seg.pt']){
    assert.equal(selectModel(model),model);
    assert.equal(createYoloDetector({model,ready:true,pythonPath:process.execPath}).model,model);
    assert.equal(createSweepDetector({model,ready:true,pythonPath:process.execPath}).model,model);
  }
  assert.throws(()=>selectModel('../untrusted.pt'),{code:'YOLOE_NOT_READY'});
  assert.equal(modelReady('../untrusted.pt'),false);
});
test('video adapter rejects results from a different model instead of silently misreporting it',()=>{
  const videos=[{pass:'overview',duration:3}],result={model:'yoloe-26s-seg.pt',passes:[{pass:'overview',detections:[]}]};
  assert.throws(()=>validateYoloResult(result,videos),{code:'YOLOE_INVALID_RESPONSE'});
  assert.equal(validateYoloResult(result,videos,'yoloe-26s-seg.pt').model,'yoloe-26s-seg.pt');
});
