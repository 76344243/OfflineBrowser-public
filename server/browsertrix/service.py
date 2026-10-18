"""Single-worker Browsertrix API for the optional OfflineBrowser backend."""
import gzip, hashlib, hmac, ipaddress, json, os, re, shutil, socket, subprocess, threading, time, uuid, zipfile
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
ROOT=Path(os.environ.get('CRAWLER_ROOT','/opt/offline-browser'))
TOKEN=os.environ['CRAWLER_TOKEN']
IMAGE=os.environ.get('CRAWLER_IMAGE','webrecorder/browsertrix-crawler:1.15.0@sha256:9a0df32c1a61eb12de5d0faa19a63fbef8924257a5e4e1496803594527a69a31')
BEHAVIORS=ROOT/'behaviors'
LOCK=threading.RLock()
JOBS=ROOT/'jobs'; JOBS.mkdir(parents=True,exist_ok=True)
def read(j): return json.loads((JOBS/(j+'.json')).read_text())
def save(d):
 p=JOBS/(d['id']+'.json'); tmp=p.with_suffix('.tmp'); tmp.write_text(json.dumps(d)); tmp.replace(p)
def command(*args): return subprocess.run(args,capture_output=True,text=True,timeout=90)
def valid_url(u):
 p=urlsplit(u)
 if p.scheme not in ('http','https') or not p.hostname or p.username or p.password: raise ValueError('HTTP/HTTPS-Adresse erforderlich')
 for a in socket.getaddrinfo(p.hostname,p.port or (443 if p.scheme=='https' else 80),type=socket.SOCK_STREAM):
  if not ipaddress.ip_address(a[4][0]).is_global: raise ValueError('Nur öffentliche Webseiten werden unterstützt')
 return u

def crawl_depth(value):
 if isinstance(value,bool) or not isinstance(value,int) or value < -1 or value > 50:
  raise ValueError('Ungültige Crawltiefe')
 return value

def resource_count(collection):
 """Count unique recorded response URLs from the live CDX index.

 The crawler writes this index while a crawl is running. It therefore gives
 the app a useful live resource count before the final WACZ is assembled.
 """
 root=ROOT/'crawls'/'collections'/collection/'warc-cdx'
 urls=set()
 if not root.is_dir(): return 0
 for path in root.iterdir():
  if not path.is_file() or not (path.name.endswith('.cdx') or path.name.endswith('.cdxj') or path.name.endswith('.cdx.gz') or path.name.endswith('.cdxj.gz')): continue
  try:
   opener=gzip.open if path.name.endswith('.gz') else open
   with opener(path,'rt',encoding='utf-8',errors='replace') as f:
    for line in f:
     line=line.strip()
     if line and not line.startswith('!'):
      urls.add(line.split(' ',1)[0])
  except (OSError,EOFError):
   continue
 return len(urls)

def update_resource_progress(d):
 done=resource_count(d['id'])
 d['filesDone']=done
 d['filesTotal']=max(int(d.get('filesTotal',0)),done)
 return done

def launch(d):
 if d.get('container'): command('docker','rm',d['container'])
 name='ob-'+d['id']+'-'+str(int(time.time()))
 args=['docker','run','-d','--name',name,'--shm-size=1g','--memory=2300m','--cpus=1.5','-v',str(ROOT/'crawls')+':/crawls','-v',str(BEHAVIORS)+':/behaviors:ro',IMAGE,'crawl']
 states=sorted((ROOT/'crawls'/'collections'/d['id']/'crawls').glob('*.yaml'))
 if d.get('resume') and states: args+=['--config','/crawls/collections/'+d['id']+'/crawls/'+states[-1].name]
 args+=['--url',d['url'],'--scopeType','host','--depth',str(crawl_depth(d.get('depth',2))),'--workers','1','--collection',d['id'],'--generateWACZ','--behaviors','autoscroll','autofetch','siteSpecific','--selectLinks','a[href]','iframe[src]->@src','frame[src]->@src','embed[src]->@src','--customBehaviors','/behaviors/collect-embedded-frames.js','--saveState','always','--saveStateInterval','30','--lang','de']
 r=command(*args)
 if r.returncode: d.update(state='error',message='Crawler konnte nicht gestartet werden'); save(d); return
 d.update(state='running',container=name,resume=False); save(d)

def worker():
 while True:
  try:
   with LOCK:
    ds=[json.loads(p.read_text()) for p in JOBS.glob('*.json')]
    active=next((d for d in ds if d['state'] in ('running','pausing')),None)
    if active:
     d=active; r=command('docker','inspect','--format','{{.State.Running}} {{.State.ExitCode}}',d['container'])
     update_resource_progress(d)
     logs=command('docker','logs','--tail','100',d['container']).stdout
     for l in logs.splitlines():
      try:
       m=json.loads(l)
       if m.get('context')=='crawlStatus':
        s=m['details']; d.update(done=s.get('crawled',0),total=s.get('total',0),failed=s.get('failed',0))
       if m.get('context')=='behaviorScriptCustom':
        details=m.get('details',{}); message=m.get('message','') or details.get('message','')
        match=re.search(r'Deferred media planned:\s*(\d+)',message)
        if match:
         plans=d.setdefault('mediaPlans',{})
         page=details.get('page') or str(len(plans))
         plans[page]=int(match.group(1))
         d['filesTotal']=max(int(d.get('filesTotal',0)),sum(plans.values()))
      except (ValueError,KeyError): pass
     update_resource_progress(d)
     plans=d.get('mediaPlans',{})
     if plans:
      d['filesTotal']=max(int(d.get('filesTotal',0)),sum(plans.values()))
     if r.stdout.startswith('false'):
      if d['state']=='pausing': d.update(state='paused',message='Fortsetzung möglich')
      else:
       file=ROOT/'crawls'/'collections'/d['id']/(d['id']+'.wacz')
       if r.stdout.strip()=='false 0' and file.is_file():
        with zipfile.ZipFile(file) as z:
         if z.testzip(): raise ValueError('Invalid archive')
         pages=[]
         for name in z.namelist():
          if name.startswith('pages/') and name.endswith('.jsonl'):
           for line in z.read(name).decode().splitlines():
            item=json.loads(line)
            if item.get('url'): pages.append(item['url'])
         d['pages']=sorted(set(pages))
        h=hashlib.sha256()
        with file.open('rb') as f:
         for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
        final_files=resource_count(d['id'])
        d.update(state='ready',bytes=file.stat().st_size,sha256=h.hexdigest(),filesDone=final_files,filesTotal=final_files,message='Archiv bereit')
       else: d.update(state='error',message='Es treten Probleme auf. Prüfen Sie Ihre Verbindung.')
     save(d)
    else:
     queued=sorted((d for d in ds if d['state']=='queued'),key=lambda d:d['created'])
     if queued: launch(queued[0])
  except Exception as e: print('Worker error:',type(e).__name__,flush=True)
  time.sleep(2)

class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def reply(self,status,value):
  b=json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
 def authorized(self):
  return hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+TOKEN)
 def route(self):
  if not self.authorized(): self.reply(401,{'error':'Nicht autorisiert'}); return
  parts=urlsplit(self.path).path.strip('/').split('/')
  try:
   if self.command=='POST' and parts==['jobs']:
    n=int(self.headers.get('Content-Length','0'))
    if n>4096: raise ValueError('Anfrage zu groß')
    body=json.loads(self.rfile.read(n)); url=valid_url(body['url']); depth=crawl_depth(body.get('depth',2))
    with LOCK:
     # Client identifier makes retries idempotent after a lost response.
     j=body.get('id') or str(uuid.uuid4()); uuid.UUID(j)
     if (JOBS/(j+'.json')).exists(): d=read(j)
     else:
      d=dict(id=j,url=url,depth=depth,state='queued',created=time.time(),done=0,total=0,failed=0,filesDone=0,filesTotal=0,message='Warteschlange'); save(d)
    self.reply(201,d); return
   if len(parts)<2 or parts[0]!='jobs': self.reply(404,{}); return
   j=parts[1]; uuid.UUID(j)
   with LOCK:
    d=read(j)
    if self.command=='POST' and len(parts)==3:
     if parts[2]=='pause':
      if d['state']=='running':
       command('docker','kill','--signal=SIGINT',d['container']); d['state']='pausing'
      elif d['state']=='queued': d['state']='paused'
     elif parts[2]=='resume':
      if d['state'] in ('paused','error'): d.update(state='queued',resume=True)
     else: self.reply(404,{}); return
     save(d); self.reply(200,d); return
    if self.command=='DELETE':
     if d.get('container'): command('docker','rm','-f',d['container'])
     shutil.rmtree(ROOT/'crawls'/'collections'/j,ignore_errors=True); (JOBS/(j+'.json')).unlink(); self.reply(200,{}); return
   if self.command=='GET' and len(parts)==3 and parts[2]=='archive':
    if d['state']!='ready': self.reply(409,{}); return
    file=ROOT/'crawls'/'collections'/j/(j+'.wacz')
    self.send_response(200); self.send_header('Content-Type','application/wacz'); self.send_header('Content-Length',str(file.stat().st_size)); self.end_headers()
    with file.open('rb') as f: shutil.copyfileobj(f,self.wfile,1024*1024)
    return
   self.reply(200,d)
  except FileNotFoundError: self.reply(404,{'error':'Auftrag nicht vorhanden'})
  except (ValueError,KeyError,TypeError,socket.gaierror): self.reply(400,{'error':'Ungültige Anfrage oder Adresse'})
  except (BrokenPipeError,ConnectionResetError): pass
 def do_GET(self): self.route()
 def do_POST(self): self.route()
 def do_DELETE(self): self.route()
if __name__=='__main__':
 threading.Thread(target=worker,daemon=True).start()
 ThreadingHTTPServer(('127.0.0.1',5112),Handler).serve_forever()
