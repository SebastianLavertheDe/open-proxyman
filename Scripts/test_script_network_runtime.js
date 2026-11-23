#!/usr/bin/env node
// Exercises the shipped JavaScript API against real localhost HTTP traffic.
// The transport shim speaks the native bridge wire protocol. Native Swift I/O is
// validated separately by test_script_network.py --swift /path/to/swiftc.
'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),http=require('node:http'),assert=require('node:assert/strict');
const NativeAbortController=globalThis.AbortController;
const runtime=fs.readFileSync(path.join(__dirname,'../Sources/ProxyMirrorScriptWorker/ScriptingRuntime.swift'),'utf8').split('#"""\n')[1].split('\n"""#')[0];
const server=http.createServer((request,response)=>{
  const chunks=[];request.on('data',data=>chunks.push(data));request.on('end',()=>{
    const reply=()=>{response.setHeader('X-Network-Test','real-localhost');
      if(request.url==='/binary'){response.end(Buffer.from([0,1,128,255]));return;}
      response.setHeader('Content-Type','application/json');response.end(JSON.stringify({method:request.method,url:request.url,headers:request.headers,body:Buffer.concat(chunks).toString('utf8')}));};
    if(request.url==='/slow')setTimeout(reply,300);else reply();
  });
});
async function run(source,base){
  const tasks=new Map();
  let context;
  const finish=value=>context.__pmNetworkComplete(JSON.stringify(value));
  context=vm.createContext({
    __pmOptions:JSON.stringify({source,message:{phase:'request',method:'GET',url:base,headers:[],body:'original'},environment:{},sharedState:{},networkEnabled:true}),
    __pmModules:'{}',
    __pmFetchNative:serialized=>{
      const value=JSON.parse(serialized),controller=new NativeAbortController();tasks.set(value.id,controller);
      const timer=setTimeout(()=>controller.abort(new Error('timeout')),value.timeoutMs||2000);
      fetch(value.url,{method:value.method,headers:value.headers,body:value.body??(value.bodyBase64?Buffer.from(value.bodyBase64,'base64'):undefined),redirect:value.redirect,signal:controller.signal})
        .then(async response=>({id:value.id,status:response.status,statusText:response.statusText,url:response.url,headers:Array.from(response.headers),bodyBase64:Buffer.from(await response.arrayBuffer()).toString('base64')}))
        .then(finish,error=>finish({id:value.id,error:error.message,name:controller.signal.reason?.message==='timeout'?'TimeoutError':error.name}))
        .finally(()=>{clearTimeout(timer);tasks.delete(value.id);});
    },
    __pmAbortNative:id=>tasks.get(id)?.abort(),
  });
  vm.runInContext(runtime,context,{timeout:1000});
  const deadline=Date.now()+3000;
  while(context.__pmResult===undefined&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,5));
  for(const task of tasks.values())task.abort();
  assert.notEqual(context.__pmResult,undefined,'network API did not finish');
  return JSON.parse(context.__pmResult);
}
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base='http://127.0.0.1:'+server.address().port;
  let value=await run(`async function onRequest(message){const r=await fetch(${JSON.stringify(base+'/echo')},{headers:{'X-Script':'bridge'}});const d=await r.json();message.body=JSON.stringify({status:r.status,header:r.headers.get('X-Network-Test'),data:d});return message;}`,base);
  let body=JSON.parse(value.message.body);assert.equal(body.status,200);assert.equal(body.header,'real-localhost');assert.equal(body.data.headers['x-script'],'bridge');
  value=await run(`async function onRequest(message){const r=await require('@proxymirror/http').post(${JSON.stringify(base+'/echo')},'hello π',{headers:{'Content-Type':'text/plain'}});message.body=(await r.json()).body;return message;}`,base);
  assert.equal(value.message.body,'hello π');
  value=await run(`async function onRequest(message){const axios=require('axios').create({baseURL:${JSON.stringify(base)}});const r=await axios.post('/echo',{actual:true},{params:{q:'π'},headers:{'X-Axios':'subset'}});message.body=JSON.stringify(r.data);return message;}`,base);
  body=JSON.parse(value.message.body);assert.deepEqual(JSON.parse(body.body),{actual:true});assert.equal(body.method,'POST');assert.equal(body.url,'/echo?q=%CF%80');assert.equal(body.headers['x-axios'],'subset');
  value=await run(`async function onRequest(message){const r=await fetch(${JSON.stringify(base+'/binary')});message.body=String(Array.from(new Uint8Array(await r.arrayBuffer())));return message;}`,base);
  assert.equal(value.message.body,'0,1,128,255');
  value=await run(`async function onRequest(message){const r=await fetch(${JSON.stringify(base+'/binary')});message.body=await r.text();return message;}`,base);
  assert.equal(value.message.body,'\u0000\u0001\uFFFD\uFFFD');
  value=await run(`async function onRequest(message){const c=new AbortController();const pending=fetch(${JSON.stringify(base+'/slow')},{signal:c.signal});c.abort();await pending;return message;}`,base);
  assert.match(value.error,/已取消/);assert.equal(value.sharedState,undefined);
  value=await run(`async function onRequest(message){sharedState.fail=1;await fetch(${JSON.stringify(base+'/slow')},{timeoutMs:30});return message;}`,base);
  assert.match(value.error,/timeout/i);assert.equal(value.sharedState,undefined);
  value=await run(`async function onRequest(message){const r=await fetch(${JSON.stringify(base+'/echo')});const clone=r.clone();await r.text();message.body=(await clone.json()).method;return message;}`,base);
  assert.equal(value.message.body,'GET');
  console.log('PASS: shipped JS network API with real localhost HTTP (fetch/Headers/JSON/text/binary/http module/axios subset/AbortController/timeout/clone). Native URLSession has a separate Swift harness.');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>{server.closeAllConnections();server.close();});
