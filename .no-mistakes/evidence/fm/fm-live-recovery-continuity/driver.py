import os,json,subprocess,time,threading,shutil
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
root=Path.cwd(); home=root/'.l'; ev=Path('/home/local/.no-mistakes/evidence/01M4DVV8KZKGKXJKB3N6XH3F6Q')
phase='compat'; counts={}; requests=[]; captures=[]
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length']))); branch=any(t['function']['name']=='fm_branch_report' for t in data.get('tools',[]))
  key=(phase,branch); n=counts.get(key,0); counts[key]=n+1
  requests.append({'phase':phase,'branch':branch,'ordinal':n,'request':data})
  call=None; text='PRIMARY RESPONSE: context acknowledged.'
  if branch:
   if phase=='compat' and n==0: call=('antigravity',{'probe':'compatibility'})
   elif phase=='stall' and n==0: call=('bash',{'command':'sleep 12; printf "read-only probe complete\\n"'})
   elif (phase=='compat' and n==1) or (phase=='recovery' and n%2==0): call=('fm_branch_report',{'task':'fleet','verdict':'routine','summary':phase+' monitoring cycle completed','silent':True})
   text='Monitoring complete.'
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
  def send(delta,finish=None):
   msg={'id':'lab-response','object':'chat.completion.chunk','created':int(time.time()),'model':data['model'],'choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
   self.wfile.write(('data: '+json.dumps(msg)+'\n\n').encode()); self.wfile.flush()
  send({'role':'assistant','content':''})
  if call:
   send({'tool_calls':[{'index':0,'id':'call-'+str(len(requests)),'type':'function','function':{'name':call[0],'arguments':json.dumps(call[1])}}]}); send({},'tool_calls')
  else: send({'content':text}); send({},'stop')
  self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
server=ThreadingHTTPServer(('127.0.0.1',0),Handler); threading.Thread(target=server.serve_forever,daemon=True).start()
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
env['TMUX_TMPDIR']=str(home/'tmux')
def tm(*args): return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=True).stdout
def send(s): tm('send-keys','-t','primary','-l',s); tm('send-keys','-t','primary','Enter'); time.sleep(.5)
def capture(label): captures.append({'label':label,'pane':tm('capture-pane','-p','-S','-200','-t','primary')})
def wait(pred,label,seconds=30):
 end=time.time()+seconds
 while time.time()<end:
  if pred(): return
  time.sleep(.1)
 capture('timeout '+label); raise RuntimeError('timeout '+label)
def log():
 p=home/'driver.jsonl'; return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
def queue(seq): (home/'state/.wake-queue').write_text(f'{int(time.time())}\t{seq}\theartbeat\tfleet\theartbeat\n')
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True)
 (home/'tmux').mkdir(); (home/'agent').mkdir(); (home/'config/supervision-host').touch()
 (home/'agent/models.json').write_text(json.dumps({'providers':{'lab':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'disposable-local-endpoint','models':[{'id':'probe'},{'id':'recovery'}]}}}))
 tm('new-session','-d','-s','primary','-x','120','-y','35','-c',str(root),'-e','FM_HOME='+str(home),'-e','PI_CODING_AGENT_DIR='+str(home/'agent'),'-e','FM_BRANCH_DELIVERY_TIMEOUT_MS=3000','pi --offline --approve --no-extensions --no-skills --no-context-files --no-mcp -e .pi/extensions/fm-branch-supervision.ts -e .lab-driver/drive.ts --model lab/probe')
 wait(lambda:any('started' in x for x in log()),'primary startup')
 send('Captain baseline context ALPHA'); wait(lambda:counts.get(('compat',False),0)>0,'main response'); time.sleep(1)
 queue(1); send('/lab-wake'); wait(lambda:any(x.get('settled')=='ok' for x in log()),'compatibility cycle'); capture('Compatibility cycle')
 phase='stall'; queue(2); send('/lab-wake'); wait(lambda:counts.get(('stall',True),0)>0,'read-only shell probe')
 send('Captain request BETA while the branch is stalled'); wait(lambda:counts.get(('stall',False),0)>0,'concurrent main dialog')
 send('/lab-wake')
 send('/lab-recover'); wait(lambda:sum('settled' in x for x in log())>=3,'timeout and queued retirement'); capture('Timeout and corrected selection')
 grant_exists=(home/'state/.branch-eligible-rows').exists()
 drained=subprocess.run(['bash','bin/fm-wake-drain.sh'],env={**env,'FM_HOME':str(home),'FM_SUPERVISION_ACTOR':'main'},text=True,capture_output=True)
 (ev/'main-drain.txt').write_text(drained.stdout+'\n'+drained.stderr)
 phase='recovery'; queue(3); send('/lab-wake'); wait(lambda:sum(x.get('settled')=='ok' for x in log())>=2,'replacement cycle'); capture('Recovered monitoring cycle')
 # A second real branch cycle proves the replacement is not merely manually started.
 queue(4); send('/lab-wake'); wait(lambda:sum(x.get('settled')=='ok' for x in log())>=3,'successor cycle'); capture('Successor cycle')
 assert not grant_exists, 'timed-out row grant remains stranded'
 results=[x['settled'] for x in log() if 'settled' in x]
 assert results==['ok','supervision branch delivery timeout','supervision session was replaced before handling the accepted wake','ok','ok'], results
 recovery=next(x['request'] for x in requests if x['phase']=='recovery' and x['branch'])
 mirror=[m['content'][0]['text'] for m in recovery['messages'] if m['role']=='user' and isinstance(m.get('content'),list) and m['content'][0]['text'].startswith(('[captain]','[main]'))]
 assert mirror==['[captain] Captain baseline context ALPHA','[main] PRIMARY RESPONSE: context acknowledged.','[captain] Captain request BETA while the branch is stalled','[main] PRIMARY RESPONSE: context acknowledged.'], mirror
 assert any(m.get('role')=='tool' and m.get('content')=='ok' for x in requests if x['phase']=='compat' and x['branch'] for m in x['request']['messages']), 'compatibility tool did not execute'
 assert drained.returncode==0 and '\t2\theartbeat\t' in drained.stdout, 'main could not reclaim timed-out row'
 (ev/'live-primary.json').write_text(json.dumps({'driver':log(),'grantAfterTimeout':grant_exists,'captures':captures,'requests':requests},indent=2))
 for p in (home/'state/branch-session').glob('*.jsonl'): shutil.copyfile(p,ev/('branch-'+p.name))
 print(json.dumps({'driver':log(),'grantAfterTimeout':grant_exists,'requestCounts':{str(k):v for k,v in counts.items()}},indent=2))
except Exception as e:
 print('LIVE SETUP/DRIVE ERROR:',repr(e)); (ev/'live-primary.json').write_text(json.dumps({'error':repr(e),'driver':log(),'captures':captures,'requests':requests},indent=2)); raise
finally:
 try: tm('kill-server')
 except Exception: pass
 server.shutdown(); shutil.rmtree(home,ignore_errors=True)
