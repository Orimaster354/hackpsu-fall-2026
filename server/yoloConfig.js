const fs=require('node:fs');
const path=require('node:path');
const {requireAction}=require('./errors');
const config=require('./yolo-models.json');
const MODEL=config.defaultModel;
function selectModel(value=process.env.YOLOE_MODEL || MODEL){
  requireAction(config.allowedModels.includes(value),'YOLOE_NOT_READY','Choose a supported YOLOE-26 text-prompt checkpoint in YOLOE_MODEL.');
  return value;
}
function modelReady(model){
  if(!config.allowedModels.includes(model))return false;
  const cache=path.join(__dirname,'.cache/yoloe');
  if(!fs.existsSync(path.join(cache,model)))return false;
  return [`ready-${model.slice(0,-3)}.json`,'ready.json'].some(file=>{
    try{return JSON.parse(fs.readFileSync(path.join(cache,file),'utf8')).model===model;}catch{return false;}
  });
}
module.exports={MODEL,selectModel,modelReady};
