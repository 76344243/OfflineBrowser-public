(function(config){
'use strict';
const prefix='/t/'+config.token+'/o/';
function report(reason){try{window.webkit.messageHandlers.archiveEvents.postMessage({kind:'unsupported',reason});}catch{}}
function original(value){
  const u=new URL(value,location.href);
  if(u.origin!==config.origin)return u;
  if(!u.pathname.startsWith(prefix))return new URL(config.originalOrigin+u.pathname+u.search+u.hash);
  const tail=u.pathname.slice(prefix.length), slash=tail.indexOf('/');
  if(slash<0)return u;
  const text=tail.slice(0,slash).replace(/-/g,'+').replace(/_/g,'/');
  return new URL(atob(text)+tail.slice(slash)+u.search+u.hash);
}
function mapped(value){
  if(value==null)return value;
  const s=String(value); if(s.startsWith('#'))return s;
  const u=original(new URL(s,original(document.baseURI)).href);
  if(!['http:','https:'].includes(u.protocol))return s;
  const encoded=btoa(u.origin).replace(/\+/g,'-').replace(/\//g,'_').replace(/=/g,'');
  return config.origin+prefix+encoded+u.pathname+u.search+u.hash;
}
const nativeFetch=window.fetch.bind(window);
function checkedResponse(response){if(response.status>=400){try{window.webkit.messageHandlers.archiveEvents.postMessage({kind:'missing',reason:'Eine angeforderte Ressource fehlt.'});}catch{}}return response;}
Object.defineProperty(window,'fetch',{value:function(input,init){
  if(input instanceof Request){return nativeFetch(new Request(mapped(input.url),input),init).then(checkedResponse);}
  return nativeFetch(mapped(input),init).then(checkedResponse);
},writable:false,configurable:false});
const nativeOpen=XMLHttpRequest.prototype.open;
XMLHttpRequest.prototype.open=function(method,url,...args){return nativeOpen.call(this,method,mapped(url),...args);};
const nativeSet=Element.prototype.setAttribute;
const attributes=new Set(['src','href','action','poster','data']);
Element.prototype.setAttribute=function(key,value){
  const name=String(key).toLowerCase();
  if(attributes.has(name))value=mapped(value);
  else if(name==='srcset' && !String(value).includes('data:'))value=String(value).split(',').map(p=>{const [u,...rest]=p.trim().split(/\s+/);return [mapped(u),...rest].join(' ');}).join(',');
  return nativeSet.call(this,key,value);
};
for(const [name,property] of [['HTMLImageElement','src'],['HTMLScriptElement','src'],['HTMLLinkElement','href'],['HTMLMediaElement','src'],['HTMLSourceElement','src'],['HTMLIFrameElement','src'],['HTMLAnchorElement','href'],['HTMLFormElement','action']]){
 const proto=window[name]?.prototype, descriptor=proto&&Object.getOwnPropertyDescriptor(proto,property);
 if(descriptor?.set)Object.defineProperty(proto,property,{...descriptor,set(v){descriptor.set.call(this,mapped(v));}});
}
function deny(name){
 const value=function(){report(name+' wird nicht unterstützt.');throw new DOMException(name+' ist in diesem Archiv-Browser gesperrt.','NotSupportedError');};
 try{Object.defineProperty(window,name,{value,writable:false,configurable:false});}catch{}
}
// Initial about:blank frames inherit origin and can expose fresh constructors.
const guarded=new WeakSet();
function guardWindow(win){
 try{if(!win||guarded.has(win))return;guarded.add(win);
  for(const name of ['WebSocket','EventSource','Worker','SharedWorker','RTCPeerConnection','webkitRTCPeerConnection']){
   if(Object.getOwnPropertyDescriptor(win,name)?.configurable===false)continue;
   Object.defineProperty(win,name,{value:function(){report(name+' ist gesperrt.');throw new DOMException('Gesperrt','NotSupportedError');},configurable:false,writable:false});
  }
  try{Object.defineProperty(win.navigator,'sendBeacon',{value:()=>{report('Beacon ist gesperrt.');return false;},configurable:false});}catch{}
  const proto=win.HTMLIFrameElement?.prototype;
  for(const name of ['contentWindow','contentDocument']){
   const descriptor=proto&&Object.getOwnPropertyDescriptor(proto,name);
   if(descriptor?.get&&descriptor.configurable)Object.defineProperty(proto,name,{...descriptor,configurable:false,get(){const value=descriptor.get.call(this);guardWindow(name==='contentDocument'?value?.defaultView:value);return value;}});
  }
  function inspect(){for(const frame of win.document.querySelectorAll('iframe')){try{guardWindow(frame.contentWindow);}catch{}}}
  for(const name of ['appendChild','insertBefore','replaceChild']){const native=win.Node.prototype[name];win.Node.prototype[name]=function(...args){const result=native.apply(this,args);inspect();return result;};}
  for(const proto of [win.Element.prototype,win.DocumentFragment.prototype,win.Document.prototype])for(const name of ['append','prepend','replaceChildren']){const native=proto[name];if(native)proto[name]=function(...args){const result=native.apply(this,args);inspect();return result;};}
  const inner=Object.getOwnPropertyDescriptor(win.Element.prototype,'innerHTML');
  if(inner?.set)Object.defineProperty(win.Element.prototype,'innerHTML',{...inner,set(value){inner.set.call(this,value);inspect();}});
  const adjacent=win.Element.prototype.insertAdjacentHTML;if(adjacent)win.Element.prototype.insertAdjacentHTML=function(...args){const result=adjacent.apply(this,args);inspect();return result;};
  new win.MutationObserver(inspect).observe(win.document,{childList:true,subtree:true});
 }catch{}
}
guardWindow(window);
for(const name of ['WebSocket' ,'EventSource','Worker','SharedWorker','RTCPeerConnection','webkitRTCPeerConnection'])deny(name);
try{Object.defineProperty(navigator,'sendBeacon',{value:()=>{report('Beacon wird nicht unterstützt.');return false;},configurable:false});}catch{}
try{if(navigator.serviceWorker)Object.defineProperty(Object.getPrototypeOf(navigator.serviceWorker),'register',{value:()=>Promise.reject(new DOMException('Service Worker sind gesperrt.','NotSupportedError')),configurable:false});}catch{}
window.open=function(url){location.href=mapped(url);return null;};
document.addEventListener('click',function(e){const a=e.target.closest?.('a[href]');if(a){const target=mapped(a.getAttribute('href')); if(target!==a.href)nativeSet.call(a,'href',target);}},true);
document.addEventListener('submit',function(e){if(e.target instanceof HTMLFormElement)nativeSet.call(e.target,'action',mapped(e.target.getAttribute('action')||location.href));},true);
window.addEventListener('error',e=>{if(e.target?.src||e.target?.href)try{window.webkit.messageHandlers.archiveEvents.postMessage({kind:'missing',reason:'Eine benötigte Ressource ist nicht verfügbar.'});}catch{}},true);
Object.defineProperty(window,'__offlineOriginalURL',{value:()=>original(location.href).href});
})(__OFFLINE_CONFIG__);
