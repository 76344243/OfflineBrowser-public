#!/usr/bin/env python3
"""Add Kit v1 to static Jimdo exports; normal pages receive only a discovery link.

Offline pages use the existing rendered document, not the online Jimdo runtime.
Requires beautifulsoup4. Regenerate after every public content change.
"""
import argparse
import hashlib
import json
import mimetypes
import re
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen
from bs4 import BeautifulSoup

STYLE = """
.offline-menu { position:absolute; right:16px; top:16px; z-index:10; border:0; border-radius:8px; padding:10px 14px; background:#fff; color:#142b57; cursor:pointer; font:inherit; }
header .DyyGf { padding-right:110px; box-sizing:border-box; }
header .G4Yk_ { height:auto!important; }
header .G4Yk_.offline-open { display:block!important; position:relative!important; opacity:1!important; visibility:visible!important; transform:none!important; }
header .G4Yk_.offline-open ul { display:flex!important; flex-wrap:wrap; gap:14px; padding:16px; }
.offline-notice { position:fixed; bottom:20px; left:50%; transform:translateX(-50%); max-width:85vw; padding:12px 18px; background:#182535; color:white; border-radius:12px; z-index:10000; }
dialog.offline-image { border:0; padding:12px; max-width:95vw; max-height:95vh; }
dialog.offline-image img { max-width:85vw; max-height:80vh; object-fit:contain; }
"""
SCRIPT = """'use strict';
(() => {
 const english=document.documentElement.lang.startsWith('en');
 const say=text=>{document.querySelector('.offline-notice')?.remove();const n=document.createElement('div');n.className='offline-notice';n.setAttribute('role','status');n.textContent=text;document.body.append(n);setTimeout(()=>n.remove(),6000);};
 document.querySelector('.offline-menu')?.addEventListener('click',function(){const menu=document.querySelector('header .G4Yk_');const open=menu?.classList.toggle('offline-open');this.setAttribute('aria-expanded',String(!!open));});
 document.addEventListener('click',event=>{
  const a=event.target.closest('a[href]');
  if(a?.dataset.offlineExternal){event.preventDefault();say(english?'This link needs an internet connection and opens outside this archive.':'Dieser Link benötigt Internet und führt außerhalb des Archivs.');return;}
  const img=event.target.closest('[data-offline-gallery]');
  if(img&&!img.closest('dialog')){event.preventDefault();const d=document.createElement('dialog');d.className='offline-image';const close=document.createElement('button');close.textContent=english?'Close':'Schließen';close.addEventListener('click',()=>{d.close();d.remove();});const copy=img.cloneNode();copy.removeAttribute('srcset');d.append(close,copy);document.body.append(d);d.showModal();}
 });
 document.querySelectorAll('form').forEach(form=>form.addEventListener('submit',event=>{event.preventDefault();say(english?'Sending messages requires an internet connection. Please use the original website.':'Der Nachrichtenversand benötigt Internet. Bitte verwenden Sie die normale Webseite.');}));
})();
"""

def digest(data):
    return hashlib.sha256(data).hexdigest()

def prepare(root):
    root = root.resolve()
    pages = sorted(p for p in root.rglob('*.html')
                   if not any(x.startswith('.') or x in {'offline', 'node_modules', 'build'}
                              for x in p.relative_to(root).parts))
    assert root / 'index.html' in pages
    backups = root / '.offline-kit-backup'
    backups.mkdir(exist_ok=True)
    out = root / 'offline'
    out.mkdir(exist_ok=True)
    (out / 'offline.js').write_text(SCRIPT)
    (out / 'offline.css').write_text(STYLE)
    resources = {}
    mapping = {}
    for page in pages:
        rel = page.relative_to(root).as_posix()
        mapping['/' + rel] = '/offline/' + rel
        if rel.endswith('index.html'):
            mapping['/' + rel[:-len('index.html')]] = '/offline/' + rel
    remote_files = {}

    def asset_url(value, base):
        if value.startswith(('data:', '#', 'mailto:', 'tel:')):
            return value
        parsed = urlsplit(urljoin('https://' + root.name + '/' + base, value))
        if parsed.hostname == root.name:
            file = root / parsed.path.lstrip('/')
            if file.is_file():
                if file.suffix == '.css':
                    return css_file(file)
                resources['/' + file.relative_to(root).as_posix()] = file
                return parsed.path + (('?' + parsed.query) if parsed.query else '')
            if parsed.path.startswith('/renderer/static/'):
                return asset_url('https://static-assets.jimstatic.com'+parsed.path, base)
            raise ValueError('Missing local resource: ' + str(file))
        if parsed.scheme not in {'http', 'https'}:
            return value
        if value not in remote_files:
            extension = Path(parsed.path).suffix
            dest = out / 'remote' / (digest(value.encode())[:20] + extension)
            dest.parent.mkdir(exist_ok=True)
            if not dest.exists():
                with urlopen(Request(value, headers={'User-Agent':'Mozilla/5.0'}), timeout=30) as response:
                    dest.write_bytes(response.read())
            remote_files[value] = '/' + dest.relative_to(root).as_posix()
            resources[remote_files[value]] = dest
        return remote_files[value]

    css_processing = set()
    def css_file(file):
        rel = file.relative_to(root).as_posix()
        path = '/offline/' + rel
        if path in resources:
            return path
        if file in css_processing:
            return path
        css_processing.add(file)
        text = file.read_text()
        def replace(match):
            raw = match.group(1).strip().strip('\"\'')
            return 'url("' + asset_url(raw, rel) + '")'
        text = re.sub(r'url\(([^)]+)\)', replace, text)
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        resources[path] = dest
        return path

    for page in pages:
        rel = page.relative_to(root).as_posix()
        original = page.read_text()
        backup = backups / rel
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            backup.write_bytes(page.read_bytes())
        soup = BeautifulSoup(original, 'html.parser')
        for script in soup.find_all('script'):
            script.decompose()
        for node in soup.select('#codex-browser-sidebar-comments-root, .qXb2G'):
            node.decompose()
        # Retain rendered main/footer but remove the online cookie overlays.
        main = soup.find('main')
        if not main:
            raise ValueError('No rendered main: ' + rel)
        for node in list(soup.select('#root > div > div')):
            node.decompose()
        for node in soup.select('link[rel="preconnect"], link[rel="dns-prefetch"], link[rel="preload"], link[rel="prefetch"], link[rel="offline-kit"]'):
            node.decompose()
        for element in soup.find_all(True):
            for key in list(element.attrs):
                if key.lower().startswith('on'):
                    del element[key]
            for key in ('src', 'poster'):
                if element.has_attr(key):
                    element[key] = asset_url(element[key], rel)
            if element.has_attr('srcset'):
                element['srcset'] = ', '.join(asset_url(words[0], rel) + (' ' + ' '.join(words[1:]) if len(words)>1 else '')
                                            for part in element['srcset'].split(',') if (words:=part.strip().split()))
                if element.name == 'img' and not element.get('src'):
                    element['src'] = element['srcset'].split(',')[0].strip().split()[0]
            if element.name == 'link' and element.has_attr('href'):
                element['href'] = asset_url(element['href'], rel)
            if element.name == 'a' and element.has_attr('href'):
                value = element['href']
                if value.startswith('javascript:'):
                    element['href'] = '#'
                elif not value.startswith(('#', 'mailto:', 'tel:')):
                    u = urlsplit(urljoin('https://' + root.name + '/' + rel, value))
                    if u.hostname == root.name and u.path in mapping:
                        element['href'] = mapping[u.path] + (('#'+u.fragment) if u.fragment else '')
                    elif u.hostname == root.name and (root/u.path.lstrip('/')).is_file():
                        element['href'] = asset_url(value, rel)
                    else:
                        element['data-offline-external'] = 'true'
            if element.has_attr('style'):
                element['style'] = re.sub(r'url\(([^)]+)\)', lambda m:'url("'+asset_url(m.group(1).strip().strip('\"\''),rel)+'")', element['style'])
        for style in soup.find_all('style'):
            # Some existing PhotoSwipe export rules lost their closing url()/brace.
            text = re.sub(r'url\((/assets/[^\s)]+)\s+(?=\.pswp)',r'url(\1)} ',style.get_text())
            style.string = re.sub(r'url\(([^)]+)\)', lambda m:'url("'+asset_url(m.group(1).strip().strip('\"\''),rel)+'")',text)
        english = soup.html.get('lang','').startswith('en')
        header = soup.find('header')
        if header and header.select_one('.G4Yk_'):
            button = soup.new_tag('button', attrs={'class':'offline-menu', 'type':'button','aria-expanded':'false'})
            button.string = 'Menu' if english else 'Menü'
            header.append(button)
        placeholders = soup.select('[data-testid="static-form-element"]')
        if rel in {'contact/index.html','kontakt/index.html'}:
            placeholders.append(main)
        for placeholder in placeholders:
            note = soup.new_tag('p'); note.string = 'Sending messages requires internet. Please use the original website.' if english else 'Der Nachrichtenversand benötigt Internet. Bitte verwenden Sie die normale Webseite.'
            placeholder.append(note)
        if rel in {'gallery/index.html','galerie/index.html','portfolio/index.html'}:
            for image in main.select('img'):
                image['data-offline-gallery'] = 'true'
        style = soup.new_tag('link', attrs={'rel':'stylesheet','href':'/offline/offline.css'})
        soup.head.append(style)
        script = soup.new_tag('script', attrs={'src':'/offline/offline.js','defer':''})
        soup.head.append(script)
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(str(soup))
        resources['/' + dest.relative_to(root).as_posix()] = dest
        # Make only an additive edit to the normal website; don't reserialize it.
        if 'rel="offline-kit"' not in original:
            page.write_text(original.replace('</head>', '<link rel="offline-kit" href="/offline-kit.json">\n</head>', 1))
    for name in ('offline.js','offline.css'):
        resources['/offline/'+name] = out/name
    items = []
    for url, file in sorted(resources.items()):
        data = file.read_bytes()
        item = {'url':url, 'bytes':len(data),'sha256':digest(data)}
        # Exported images sometimes have a PNG name but JPEG contents. Let the
        # server/WebKit infer their real MIME type; Kit v1 allows mime omission.
        if file.suffix in {'.html','.css','.js'}:
            item['mime'] = mimetypes.guess_type(file.name)[0]
        items.append(item)
    kit = {'schemaVersion':1,'revision':'2026-10-06.'+digest(json.dumps(items).encode())[:12],
           'scope':'/','entry':'/index.html','offlineEntry':'/offline/index.html','resources':items,
           'allowedResourceOrigins':[], 'offlineChecks':[{'path':mapping['/'+p.relative_to(root).as_posix()],
                 'selector':'main[data-testid="static-page-main"]','description':p.relative_to(root).as_posix()} for p in pages]}
    (root/'offline-kit.json').write_text(json.dumps(kit,ensure_ascii=False,indent=2)+'\n')
    print(root.name, len(pages),'pages',len(items),'resources',sum(x['bytes'] for x in items),'bytes')

def verify(root):
    """Check every hash, resource reference and the additive online-page edit."""
    root = root.resolve()
    kit = json.loads((root/'offline-kit.json').read_text())
    assert kit['schemaVersion'] == 1 and kit['allowedResourceOrigins'] == []
    urls = {r['url'] for r in kit['resources']}
    assert len(urls) == len(kit['resources']) and kit['offlineEntry'] in urls
    assert not any(x in url for url in urls for x in ['.git/','.php','.bak','._','contact-form.js'])
    for item in kit['resources']:
        data = (root/item['url'].lstrip('/')).read_bytes()
        assert len(data) == item['bytes'] and digest(data) == item['sha256'], item['url']
        if item['url'].endswith('.css'):
            for raw in re.findall(r'url\(([^)]+)\)',data.decode()):
                path = raw.strip().strip('\"\'')
                assert path.startswith('data:') or path in urls, path
        if not item['url'].endswith('.html'):
            continue
        soup = BeautifulSoup(data.decode(),'html.parser')
        assert soup.find('main') and soup.select_one('.offline-menu')
        assert not soup.select('a[href^="javascript:"], iframe, object, embed')
        for element in soup.select('img[src],script[src],link[href]'):
            value = element.get('src',element.get('href'))
            assert not urlsplit(value).netloc and urlsplit(value).path in urls, value
        for a in soup.select('a[href]'):
            if a['href'].startswith('/offline/'):
                assert urlsplit(a['href']).path in urls,a['href']
    for backup in (root/'.offline-kit-backup').rglob('*.html'):
        if backup.name.startswith('._'):
            continue
        original = backup.read_bytes()
        rel = backup.relative_to(root/'.offline-kit-backup')
        current = (root/rel).read_bytes()
        assert current.replace(b'<link rel="offline-kit" href="/offline-kit.json">\n',b'') == original,rel
    print(root.name,'PASS: hashes, local references, navigation, public inventory, additive online changes')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('sites',type=Path,nargs='+'); parser.add_argument('--verify',action='store_true')
    args = parser.parse_args()
    for site in args.sites:
        (verify if args.verify else prepare)(site)
