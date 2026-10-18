#!/usr/bin/env python3
"""Explicit public-file inventory. PHP, hidden files, credentials and build artifacts are excluded."""
import argparse,hashlib,json,mimetypes
from pathlib import Path
PUBLIC={'.html','.htm','.js','.css','.json','.mp3','.m4a','.mp4','.ogg','.wav','.jpg','.jpeg','.png','.webp','.gif','.svg','.ico','.woff','.woff2','.ttf','.wasm','.pdf'}
SKIP={'.git','build','verification','scripts','node_modules','private','.private','__pycache__'}
def generate(root,revision,entry='index.html'):
 root=root.resolve(); resources=[]
 for path in sorted(root.rglob('*')):
  rel=path.relative_to(root)
  if not path.is_file() or path.is_symlink() or any(p.startswith('.') or p in SKIP for p in rel.parts):continue
  if path.suffix.lower() not in PUBLIC or path.name=='offline-kit.json' or path.name.endswith('.mp3.js'):continue
  if any(x in path.name.lower() for x in ['password','credential','secret','auth-config','download-manifest','data.txt']):continue
  hasher=hashlib.sha256()
  with path.open('rb') as f:
   while chunk:=f.read(1024*1024):hasher.update(chunk)
  mime=mimetypes.guess_type(path.name)[0] or 'application/octet-stream'
  if path.suffix=='.js':mime='text/javascript'
  resources.append({'url':rel.as_posix(),'mime':mime,'bytes':path.stat().st_size,'sha256':hasher.hexdigest()})
 if entry not in {r['url'] for r in resources}:raise ValueError('Offline entry missing from public inventory')
 kit={'schemaVersion':1,'revision':revision,'scope':'./','entry':entry,'offlineEntry':entry,'resources':resources,'allowedResourceOrigins':[],'offlineChecks':[{'path':entry,'selector':'main','description':'Startseite sichtbar'}]}
 (root/'offline-kit.json').write_text(json.dumps(kit,ensure_ascii=False,indent=2)+'\n')
 return kit
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('--revision',required=True);p.add_argument('--entry',default='index.html');a=p.parse_args()
 kit=generate(a.directory,a.revision,a.entry);print('Manifest geschrieben:',a.directory/'offline-kit.json','Elemente:',len(kit['resources']),'Bytes:',sum(x['bytes'] for x in kit['resources']))
