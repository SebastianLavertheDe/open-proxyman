// The host runs this JavaScript in a short-lived JavaScriptCore process. Tests execute
// the exact same source in Node's vm; no filesystem or network bridge is exposed.
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
