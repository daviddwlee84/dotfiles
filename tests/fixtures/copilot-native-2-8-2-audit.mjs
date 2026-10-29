// Manual, zero-quota audit of the installed 2.8.2 backend against a loopback fake.
// No stored credentials are read; private config and SQLite are removed afterward.
// Run: bun tests/fixtures/copilot-native-2-8-2-audit.mjs [absolute-package-dir]
import {mkdtempSync, readFileSync, writeFileSync, readdirSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const root=mkdtempSync(join(tmpdir(),'copilot-native-audit-'));
process.env.COPILOT_API_HOME=root;
process.env.COPILOT_API_SQLITE_DB_PATH=join(root,'usage.sqlite');
delete process.env.COPILOT_API_GITHUB_TOKEN;
writeFileSync(join(root,'config.json'),JSON.stringify({auth:{apiKeys:[],adminApiKey:'fixture-only'},useResponsesApiWebSocket:false}),{mode:0o600});
const packageRoot=process.argv[2] || join(process.env.HOME,'.local/share/copilot-api/pkg/node_modules/@jeffreycao/copilot-api');
const dir=join(packageRoot,'dist');
const require=createRequire(join(packageRoot,'package.json'));
const {getGlobalDispatcher,setGlobalDispatcher}=require('undici');
const previousDispatcher=getGlobalDispatcher();
let externalDispatches=0;
setGlobalDispatcher({dispatch(options,handler){
  if(new URL(options.origin).hostname!=='127.0.0.1'){
    externalDispatches++;
    throw new Error('Native audit refuses non-loopback upstream traffic');
  }
  return previousDispatcher.dispatch(options,handler);
}});
const configName=readdirSync(dir).find(x=>x.startsWith('config-store-')&&x.endsWith('.js'));
const serverName=readdirSync(dir).find(x=>x.startsWith('server-')&&x.endsWith('.js'));
const {D:state}=await import(join(dir,configName));
const {createServer}=await import(join(dir,serverName));
assert.equal(JSON.parse(readFileSync(join(dir,'../package.json'))).version,'2.8.2');
let captured=null, delay=0, failed=false, inflight=0, peak=0;
const upstream=Bun.serve({hostname:'127.0.0.1',port:0,async fetch(req){
  assert.equal(new URL(req.url).pathname,'/responses');
  captured=await req.json();inflight++;peak=Math.max(peak,inflight);
  if(delay)await new Promise(r=>setTimeout(r,delay));
  inflight--;
  if(captured.stream){
    const event=failed?{type:'response.failed',response:{id:'resp_fixture',status:'failed',error:{code:'fixture_failure',message:'fixture'}}}:{type:'response.completed',response:{id:'resp_fixture',status:'completed',output:[],usage:{input_tokens:0,output_tokens:0,total_tokens:0}}};
    return new Response(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`,{headers:{'content-type':'text/event-stream'}});
  }
  return Response.json({id:'resp_fixture',object:'response',status:'completed',model:captured.model,output:[],usage:{input_tokens:0,output_tokens:0,total_tokens:0}});
}});
state.copilotToken='fixture-not-a-real-token';state.githubToken='fixture-not-a-real-token';
state.copilotApiUrl=`http://127.0.0.1:${upstream.port}`;
state.models={data:[{id:'gpt-6-luna',supported_endpoints:['/responses'],capabilities:{type:'chat',limits:{max_prompt_tokens:32000,max_output_tokens:1000}}}]};
const events=[];
const app=createServer({plugins:{enabled:true,publish:(name,data)=>events.push({name,data})}});
const results={version:'2.8.2',external_dispatches:0};
const base=()=>({model:'gpt-6-luna',stream:false,max_output_tokens:32,input:[{role:'user',content:'fixture'}]});
async function request(body,zstd=false){
  const bytes=new TextEncoder().encode(JSON.stringify(body));
  const response=await app.request('/v1/responses',{method:'POST',headers:{'content-type':'application/json',...(zstd?{'content-encoding':'zstd'}:{})},body:zstd?Bun.zstdCompressSync(bytes):bytes});
  const text=await response.text();assert.equal(response.status,200,text.slice(0,400));return text;
}
try{
  let body=base();body.input.unshift({type:'mcp_list_tools',server_label:'fixture',tools:[{name:'fixture_tool',description:'',input_schema:{type:'object',properties:{}}}]});
  await request(body);assert.equal(captured.input[0].tools[0].description,'');results.mcp_blank_description_preserved=true;
  body=base();body.tools=[{type:'namespace',name:'fixture',description:'',tools:[]}];
  await request(body);assert.equal(captured.tools[0].description,'fixture');results.namespace_blank_description_repaired=true;
  await request(base(),true);assert.equal(captured.model,'gpt-6-luna');results.native_zstd_decoded=true;
  body=base();body.service_tier='fast';await request(body);assert.equal(captured.model,'gpt-6-luna');assert.equal(captured.service_tier,undefined);results.fast_tier_stripped_without_model_rewrite=true;
  delay=200;body=base();body.stream=true;
  const started=performance.now();
  const response=await app.request('/v1/responses',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
  results.headers_wait_for_upstream_ms=Math.round(performance.now()-started);assert.ok(results.headers_wait_for_upstream_ms>=180);await response.text();delay=0;
  events.length=0;failed=true;body=base();body.stream=true;await request(body);failed=false;
  await new Promise(r=>setTimeout(r,20));
  const end=events.findLast(e=>e.name==='request.end');assert.ok(end);results.native_failed_sse_request_outcome=end.data.outcome;assert.equal(end.data.outcome,'completed');
  delay=100;peak=0;await Promise.all([request(base()),request(base()),request(base())]);results.peak_concurrent_upstream_fixture_calls=peak;assert.equal(peak,3);delay=0;
  assert.equal(externalDispatches,0);
  console.log('AUDIT_RESULT '+JSON.stringify(results));
}finally{
  upstream.stop(true);
  setGlobalDispatcher(previousDispatcher);
  rmSync(root,{recursive:true,force:true});
}
