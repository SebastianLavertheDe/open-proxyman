#!/usr/bin/env node
// Portable behavioral checks for the exact JavaScript shipped in ScriptWorker.
// This does not replace the macOS process-isolation and loopback tests.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const runtime = fs.readFileSync(path.join(root, 'Sources/ProxyMirrorScriptWorker/ScriptingRuntime.swift'), 'utf8').split('#"""\n')[1].split('\n"""#')[0];
const vendored = fs.readFileSync(path.join(root, 'Sources/ProxyMirrorScriptWorker/BuiltInScriptModules.swift'), 'utf8');
const modules = {};
for (const [name, key] of [['Lodash','lodash'], ['Moment','moment'], ['Beautify','js-beautify']]) {
  modules[key] = vendored.split('let builtIn' + name + ' = #"""\n')[1].split('\n"""#')[0];
}
async function run(source, overrides = {}) {
  const context = vm.createContext({
    __pmOptions: JSON.stringify({source, message:{phase:'request',method:'GET',url:'https://example.test/api',headers:[],body:'abc'},sharedState:{},environment:{TOKEN:'local'},...overrides}),
    __pmModules: JSON.stringify({...modules,...overrides.modules}),
    __pmDigest: (algorithm,text,encoding) => crypto.createHash(algorithm).update(text).digest(encoding),
    __pmRandom: count => crypto.randomBytes(count).toString('hex'),
  });
  vm.runInContext(runtime, context, {timeout:1000});
  await new Promise(resolve => setImmediate(resolve));
  assert.notEqual(context.__pmResult, undefined, 'runtime must finish');
  return JSON.parse(context.__pmResult);
}
(async () => {
  let result = await run("message.body += '|mutated'; console.warn('warning'); console.error({reason:'test'});");
  assert.equal(result.message.body,'abc|mutated');
  assert.deepEqual(result.logs,['[warn] warning','[error] {"reason":"test"}']);
  result = await run("const _=require('lodash'); const moment=require('moment'); message.body=_.get({a:{b:3}},'a.b') + ':' + moment.utc('2026-11-23').format('YYYY-MM-DD');");
  assert.equal(result.message.body,'3:2026-11-23');
  result = await run("message.body=require('@users/example')(message.body);",{modules:{'@users/example/index.js':"const suffix=require('./suffix.json'); module.exports = value => value + suffix.text;",'@users/example/suffix.json':'{"text":"|addon"}'}});
  assert.equal(result.message.body,'abc|addon');
  result = await run("message.body=require('crypto').createHash('sha256').update(message.body).digest('hex');");
  assert.equal(result.message.body,crypto.createHash('sha256').update('abc').digest('hex'));
  result = await run("message.body = environment.TOKEN + ':' + process.env.TOKEN; sharedState.count=(sharedState.count||0)+1;",{sharedState:{count:4}});
  assert.equal(result.message.body,'local:local'); assert.equal(result.sharedState.count,5);
  result = await run("async function onRequest(message){ const value=await Promise.resolve('async'); message.body=value; }");
  assert.equal(result.message.body,'async');
  result = await run("return {status:201,headers:{'Content-Type':'text/plain'},body:'local'};",{mockMode:true});
  assert.equal(result.mock.status,201); assert.equal(result.message.body,'abc');
  result = await run("mockResponse({status:200,body:'{" + '"mock":true' + "}'});");
  assert.equal(result.mock.body,'{"mock":true}');
  result = await run("console.log(typeof fetch, typeof process.exit); require('fs');");
  assert.match(result.error,/找不到 addon/); assert.deepEqual(result.logs,['[log] undefined undefined']);
  result = await run("require('../../outside');"); assert.match(result.error,/路径超出/);
  result = await run("throw new Error('failed script');"); assert.match(result.error,/failed script/);
  assert.equal(result.sharedState,undefined,'errors must not return state to commit');
  result = await run("for(let i=0;i<300;i++) console.log(i);"); assert.equal(result.logs.length,256);
  result = await run("function preview(input){ return {method:input.method}; }",{operation:'preview',input:{method:'PATCH'}});
  assert.equal(result.preview,'{\n  "method": "PATCH"\n}');
  result = await run("const a={x:1};if(a.x){console.log(a.x)}",{operation:'beautify'});
  assert.match(result.source,/const a = \{/); assert.match(result.source,/\n  x: 1/);
  result = await run("function preview(input){ return '<script>alert(1)</script>'; }",{operation:'preview',input:{}});
  assert.equal(result.preview,'<script>alert(1)</script>','HTML remains a plain string');
  result = await run("async function preview(input){ return await Promise.resolve(input.value); }",{operation:'preview',input:{value:'async-preview'}});
  assert.equal(result.preview,'async-preview');
  result = await run("function preview(){ return 'x'.repeat(512*1024+1); }",{operation:'preview',input:{}});
  assert.match(result.error,/最大 512 KiB/);
  result = await run("const name='missing';",{operation:'preview',input:{}});
  assert.match(result.error,/请定义 function preview/);
  await assert.rejects(run("function preview(){ while(true){} }",{operation:'preview',input:{}}),/timed out/);
  result = await run("sharedState.self=sharedState; console.warn('before failure');");
  assert.match(result.error,/circular|cyclic/i); assert.equal(result.sharedState,undefined);
  assert.deepEqual(result.logs,['[warn] before failure']);
  result = await run("sharedState.large='x'.repeat(256*1024+1);");
  assert.match(result.error,/sharedState 超过/); assert.equal(result.sharedState,undefined);
  result = await run("console.log('missing response');",{mockMode:true});
  assert.match(result.error,/Mock API 脚本需要返回/);
  result = await run("mockResponse({status:200,body:'bad phase'});",{message:{phase:'response',headers:[]}});
  assert.match(result.error,/仅支持请求阶段/);
  console.log('PASS: 23 scripting runtime checks (CommonJS, upstream libraries, async hooks, shared state, Mock API, logs, preview, beautify)');
})().catch(error => {console.error(error);process.exitCode=1;});
