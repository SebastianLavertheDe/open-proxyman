// The host runs this JavaScript in a short-lived JavaScriptCore process. Tests execute
// the exact same source in Node's vm; the native network bridge uses a bounded, direct URLSession.
let scriptingRuntime = #"""
(() => {
    "use strict";
    const options = JSON.parse(__pmOptions);
    const modules = JSON.parse(__pmModules);
    const cache = Object.create(null);
    const logs = [];
    const asText = value => {
        if (typeof value === "string") return value.slice(0, 2000);
        try { return (JSON.stringify(value) ?? String(value)).slice(0, 2000); }
        catch { return "[无法显示的值]"; }
    };
    const writeLog = level => (...values) => {
        if (logs.length < 256) logs.push("[" + level + "] " + values.slice(0, 12).map(asText).join(" ").slice(0, 4000));
    };
    const console = Object.freeze({log:writeLog("log"), info:writeLog("info"), debug:writeLog("debug"),
        warn:writeLog("warn"), error:writeLog("error"), assert:(condition,...args)=>{if(!condition)writeLog("error")("Assertion failed",...args);}});
    const environment = Object.freeze(Object.assign(Object.create(null), options.environment || {}));
    const process = Object.freeze({env:environment});
    let state = options.sharedState || {};
    let mock;
    const mockResponse = value => {
        if (options.message?.phase !== "request") throw new Error("Mock API 仅支持请求阶段");
        if (!value || typeof value !== "object") throw new Error("mockResponse 需要响应对象");
        mock = value;
        return value;
    };
    const pendingNetwork = new Map();
    let nextRequestID = 0;
    class PMHeaders {
        constructor(values = []) {
            this.values = new Map();
            if(values instanceof PMHeaders) values = Array.from(values.entries());
            if(!Array.isArray(values)) values = Object.entries(values);
            for(const [name, value] of values) this.append(name, value);
        }
        append(name, value) {
            name = String(name).toLowerCase(); value = String(value);
            this.values.set(name,this.values.has(name) ? this.values.get(name)+", "+value : value);
        }
        set(name,value) {this.values.set(String(name).toLowerCase(),String(value));}
        get(name) {return this.values.get(String(name).toLowerCase()) ?? null;}
        has(name) {return this.values.has(String(name).toLowerCase());}
        delete(name) {this.values.delete(String(name).toLowerCase());}
        entries() {return this.values.entries();}
        keys() {return this.values.keys();}
        forEach(callback,thisArg) {this.values.forEach((value,key)=>callback.call(thisArg,value,key,this));}
        [Symbol.iterator]() {return this.entries();}
    }
    class PMAbortSignal {
        constructor(){this.aborted=false;this.listeners=new Set();}
        addEventListener(event,callback){if(event==='abort')this.listeners.add(callback);}
        removeEventListener(event,callback){if(event==='abort')this.listeners.delete(callback);}
        throwIfAborted(){if(this.aborted){const error=new Error('网络请求已取消');error.name='AbortError';throw error;}}
    }
    class PMAbortController {
        constructor(){this.signal=new PMAbortSignal();}
        abort(){if(this.signal.aborted)return;this.signal.aborted=true;for(const callback of this.signal.listeners)callback();}
    }
    const fromBase64 = text => {
        const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        let bits=0,value=0;const bytes=[];
        for(const character of text){const digit=alphabet.indexOf(character);if(digit<0)continue;value=(value<<6)|digit;bits+=6;if(bits>=8){bits-=8;bytes.push((value>>bits)&255);}}
        return new Uint8Array(bytes);
    };
    const toBase64 = bytes => {
        const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';let result='';
        for(let i=0;i<bytes.length;i+=3){const a=bytes[i],b=bytes[i+1],c=bytes[i+2];result+=alphabet[a>>2]+alphabet[((a&3)<<4)|((b||0)>>4)]+(b===undefined?'=':alphabet[((b&15)<<2)|((c||0)>>6)])+(c===undefined?'=':alphabet[c&63]);}
        return result;
    };
    const decodeUTF8 = bytes => {
        let output='';
        for(let index=0;index<bytes.length;){
            const first=bytes[index];
            if(first<128){output+=String.fromCharCode(first);index++;continue;}
            const length=first>=0xC2&&first<=0xDF?2:first>=0xE0&&first<=0xEF?3:first>=0xF0&&first<=0xF4?4:0;
            let value=length===2?first&31:length===3?first&15:first&7, valid=length!==0&&index+length<=bytes.length;
            for(let offset=1;valid&&offset<length;offset++){const next=bytes[index+offset];if((next&0xC0)!==0x80)valid=false;else value=(value<<6)|(next&63);}
            if(!valid||(length===2&&value<128)||(length===3&&value<2048)||(length===4&&value<65536)||(value>=0xD800&&value<=0xDFFF)||value>0x10FFFF){output+='\uFFFD';index++;}
            else {output+=String.fromCodePoint(value);index+=length;}
        }
        return output;
    };
    class PMResponse {
        constructor(value){
            this.status=value.status;this.statusText=value.statusText;this.ok=this.status>=200&&this.status<300;
            this.url=value.url;this.headers=new PMHeaders(value.headers);this.bodyUsed=false;this._value=value;
        }
        async text(){if(this.bodyUsed)throw new TypeError('Response body already used');this.bodyUsed=true;return decodeUTF8(fromBase64(this._value.bodyBase64));}
        async json(){return JSON.parse(await this.text());}
        async arrayBuffer(){if(this.bodyUsed)throw new TypeError('Response body already used');this.bodyUsed=true;return fromBase64(this._value.bodyBase64).buffer;}
        clone(){if(this.bodyUsed)throw new TypeError('Response body already used');return new PMResponse(this._value);}
    }
    globalThis.__pmHasPendingNetwork = () => pendingNetwork.size > 0;
    globalThis.__pmNetworkComplete = serialized => {
        const value=JSON.parse(serialized),entry=pendingNetwork.get(value.id);
        if(!entry)return;
        pendingNetwork.delete(value.id);entry.cleanup();
        if(value.error){const error=new Error(value.error);error.name=value.name||'TypeError';entry.reject(error);}
        else entry.resolve(new PMResponse(value));
    };
    const fetch = (address, init={}) => new Promise((resolve,reject)=>{
        try {
            if(options.networkEnabled!==true || typeof __pmFetchNative!=='function')throw new Error('此 worker 模式未启用网络 API');
            const signal=init.signal;
            signal?.throwIfAborted?.();
            if(signal?.aborted){const error=new Error('网络请求已取消');error.name='AbortError';throw error;}
            const id='request-'+(++nextRequestID);
            const request={id,url:String(address),method:String(init.method||'GET').toUpperCase(),headers:Array.from(new PMHeaders(init.headers).entries()),redirect:init.redirect||'follow'};
            if(init.timeoutMs!==undefined || init.timeout!==undefined)request.timeoutMs=Number(init.timeoutMs??init.timeout);
            if(init.body!==undefined&&init.body!==null){
                if(typeof init.body==='string')request.body=init.body;
                else if(init.body instanceof ArrayBuffer)request.bodyBase64=toBase64(new Uint8Array(init.body));
                else if(ArrayBuffer.isView(init.body))request.bodyBase64=toBase64(new Uint8Array(init.body.buffer,init.body.byteOffset,init.body.byteLength));
                else throw new TypeError('fetch body 支持字符串、ArrayBuffer 或 TypedArray');
            }
            const abort=()=>{const entry=pendingNetwork.get(id);if(!entry)return;pendingNetwork.delete(id);entry.cleanup();__pmAbortNative(id);const error=new Error('网络请求已取消');error.name='AbortError';reject(error);};
            pendingNetwork.set(id,{resolve,reject,cleanup:()=>signal?.removeEventListener?.('abort',abort)});
            signal?.addEventListener?.('abort',abort);
            try {__pmFetchNative(JSON.stringify(request));}
            catch(error){pendingNetwork.delete(id);signal?.removeEventListener?.('abort',abort);reject(error);}
        }catch(error){reject(error);}
    });
    const http = Object.freeze({fetch,request:fetch,get:(url,options={})=>fetch(url,{...options,method:'GET'}),
        post:(url,body,options={})=>fetch(url,{...options,method:'POST',body})});
    const makeAxios = defaults => {
        const axios = async (address, options={})=>{
            const config=typeof address==='string'?{...defaults,...options,url:address}:{...defaults,...address};
            let url=String(config.url||'');
            if(config.baseURL&&!/^https?:\/\//i.test(url))url=String(config.baseURL).replace(/\/$/,'')+'/'+url.replace(/^\//,'');
            if(config.params){const query=Object.entries(config.params).flatMap(([key,value])=>(Array.isArray(value)?value:[value]).filter(v=>v!==null&&v!==undefined).map(value=>encodeURIComponent(key)+'='+encodeURIComponent(String(value)))).join('&');if(query)url+=(url.includes('?')?'&':'?')+query;}
            const headers=new PMHeaders({...defaults.headers,...config.headers});
            let body=config.data;
            if(body!==undefined&&body!==null&&typeof body==='object'&&!(body instanceof ArrayBuffer)&&!ArrayBuffer.isView(body)){
                body=JSON.stringify(body);if(!headers.has('content-type'))headers.set('Content-Type','application/json');
            }
            try {
                const response=await fetch(url,{method:config.method||'GET',headers,body,timeoutMs:config.timeout,signal:config.signal,redirect:config.maxRedirects===0?'manual':'follow'});
                let data;
                if(config.responseType==='arraybuffer')data=await response.arrayBuffer();
                else {const text=await response.text();if(config.responseType==='text')data=text;else {try{data=JSON.parse(text);}catch{data=text;}}}
                const result={data,status:response.status,statusText:response.statusText,headers:Object.fromEntries(response.headers),config};
                const valid=typeof config.validateStatus==='function'?config.validateStatus(response.status):response.ok;
                if(!valid){const error=new Error('Request failed with status code '+response.status);error.response=result;error.isAxiosError=true;throw error;}
                return result;
            }catch(error){error.isAxiosError=true;error.config=config;throw error;}
        };
        axios.request=axios;axios.get=(url,config={})=>axios(url,{...config,method:'GET'});
        axios.post=(url,data,config={})=>axios(url,{...config,method:'POST',data});
        axios.put=(url,data,config={})=>axios(url,{...config,method:'PUT',data});
        axios.delete=(url,config={})=>axios(url,{...config,method:'DELETE'});
        axios.create=config=>makeAxios({...defaults,...config,headers:{...defaults.headers,...config.headers}});
        axios.isAxiosError=error=>error?.isAxiosError===true;
        return axios;
    };
    const axios = makeAxios({});
    globalThis.fetch=fetch;globalThis.Headers=PMHeaders;globalThis.AbortController=PMAbortController;
    const normalize = path => {
        const parts = [];
        for (const part of path.split("/")) {
            if (!part || part === ".") continue;
            if (part === "..") { if (!parts.length) throw new Error("Addon 路径超出目录"); parts.pop(); }
            else parts.push(part);
        }
        return parts.join("/");
    };
    const crypto = Object.freeze({
        createHash: algorithm => {
            let data = "";
            const hash = {update(value, encoding="utf8") {
                if (encoding !== "utf8" && encoding !== "utf-8") throw new Error("update 仅支持 UTF-8 文本");
                data += String(value); return hash;
            }, digest(format="hex") {return __pmDigest(String(algorithm),data,format);}};
            return hash;
        },
        randomBytes: count => {
            const hex = __pmRandom(Number(count));
            return Object.freeze({toString:(encoding="hex") => {
                if(encoding === "hex") return hex;
                throw new Error("randomBytes.toString 仅支持 hex");
            }});
        }
    });
    const load = (name, parent="") => {
        if(typeof name!=="string" || !name.length || name.length>256) throw new Error("无效的模块名");
        if(name === "crypto" || name === "node:crypto") return crypto;
        if(name === "@proxymirror/http") return http;
        if(name === "axios") return axios;
        if(name === "@proxymirror/json") return Object.freeze({parse:JSON.parse, stringify:JSON.stringify,
            pretty:value=>JSON.stringify(typeof value === "string" ? JSON.parse(value):value,null,2)});
        if (/^(node:|\/|[a-zA-Z]:)/.test(name)) throw new Error("不支持的模块：" + name);
        const normalized = normalize(name.startsWith(".") ? parent + "/" + name : name);
        const key = [normalized, normalized+".js", normalized+".json", normalized+"/index.js",normalized+"/index.json"]
            .find(candidate => Object.prototype.hasOwnProperty.call(modules,candidate));
        if(!key) throw new Error("找不到 addon："+name+"；将 CommonJS 文件放入 Addons 目录");
        if(cache[key]) return cache[key].exports;
        const module = {exports:{}};
        cache[key] = module;
        if(key.endsWith(".json")) module.exports = JSON.parse(modules[key]);
        else {
            const localRequire = path=>load(path,key.split("/").slice(0,-1).join("/"));
            new Function("module","exports","require","console","process",modules[key])
                (module,module.exports,localRequire,console,process);
        }
        return module.exports;
    };
    const finish = result => { globalThis.__pmResult = JSON.stringify(result); };
    const failure = error => finish({error:String(error?.stack || error).slice(0,4000), logs});
    try {
        if(options.operation === "beautify") {
            finish({source:load("js-beautify").js_beautify(options.source,{indent_size:2,preserve_newlines:true,end_with_newline:false})});
            return;
        }
        if(options.operation === "preview") {
            const render = new Function("input","console","require","process", options.source+
                "\n; if(typeof preview !== 'function') throw new Error('请定义 function preview(input)'); return preview(input);");
            Promise.resolve(render(options.input,console,load,process)).then(value=>{
                const preview = typeof value === "string" ? value : JSON.stringify(value,null,2);
                if(typeof preview !== "string" || preview.length>512*1024) throw new Error("Preview 需要返回文本或 JSON，最大 512 KiB");
                finish({preview,logs});
            }).catch(failure);
            return;
        }
        const message = options.message;
        const phase = message.phase === "request" ? "onRequest" : message.phase === "response" ? "onResponse" : "onWebSocket";
        const script = new Function("message","console","require","sharedState","environment","process","mockResponse",
            options.source+"\n; if(typeof "+phase+" === 'function') return "+phase+"(message);");
        Promise.resolve(script(message,console,load,state,environment,process,mockResponse)).then(value=>{
            if(options.mockMode && value !== undefined && !mock) mockResponse(value);
            if(options.mockMode && !mock) throw new Error("Mock API 脚本需要返回响应对象，或调用 mockResponse");
            const stateJSON = JSON.stringify(state);
            if(stateJSON.length>256*1024) throw new Error("sharedState 超过 256 KiB");
            finish({message:mock ? message : value === undefined ? message : value,logs,sharedState:state,mock});
        }).catch(failure);
    } catch(error) {failure(error);}
})()
"""#
