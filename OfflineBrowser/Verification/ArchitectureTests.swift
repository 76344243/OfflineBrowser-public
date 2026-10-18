#if DEBUG
import Foundation
import WebKit

actor FixtureCounter { var count = 0; func add() { count += 1 }; func value() -> Int { count } }
@MainActor final class ArchitectureTests {
    let environment: AppEnvironment
    var results: [String: String] = [:]
    var viewer: WebsiteSession?
    init(environment: AppEnvironment) { self.environment = environment }
    func check(_ name: String, _ condition: Bool) throws { results[name] = condition ? "PASS" : "FAIL"; save(); if !condition { throw ArchiveError.unsupported("Test fehlgeschlagen: " + name) } }
    func run() async -> String {
        let e = environment; let counter = FixtureCounter()
        let remote = "http://127.0.0.1:19750"
        let documents: [String:(String,String)] = [
            "/index.html": ("text/html", """
            <!doctype html><html><head><link rel="stylesheet" href="/style.css"></head><body><main id="ok">Archiv</main><img src="/image.svg"><iframe src="/frame.html"></iframe>
            <script type="module" src="/module.js"></script><script>
            window.results={};
            fetch('/data.json').then(r=>r.json()).then(x=>results.relative=x.ok);
            fetch('\(remote)/absolute.json').then(r=>r.json()).then(x=>results.absolute=x.ok);
            const xhr=new XMLHttpRequest();xhr.open('GET','/data.json');xhr.onload=()=>results.xhr=JSON.parse(xhr.responseText).ok;xhr.send();
            localStorage.setItem('persist','yes');
            </script></body></html>
            """),
            "/style.css": ("text/css", "main{color:rgb(12,34,56)}"),
            "/module.js": ("text/javascript", "import {ok} from './part.js';window.results.module=ok;"),
            "/part.js": ("text/javascript", "export const ok=true;"),
            "/frame.html": ("text/html", "<p>Frame</p>"),
            "/data.json": ("application/json", "{\"ok\":true}"),
            "/absolute.json": ("application/json", "{\"ok\":true}"),
            "/image.svg": ("image/svg+xml", "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><circle cx='10' cy='10' r='8'/></svg>"),
            "/login": ("text/html", "<form action='/session' method='post'><input type='password' name='password'><button>OK</button></form>")]
        let origin = LocalContentServer(port:19750) { request in
            await counter.add()
            let path = request.target.components(separatedBy:"?")[0]
            if path == "/session" { return LocalResponse(status:303,headers:["Set-Cookie":"session=valid; Path=/; HttpOnly", "Location":"\(remote)/private.json"]) }
            if path == "/private.json" { return request.headers["cookie"]?.contains("session=valid") == true ? LocalResponse(headers:["Content-Type":"application/json"],data:Data("{\"private\":true}".utf8)) : LocalResponse(status:401) }
            if path == "/media.bin" { return LocalResponse(headers:["Content-Type":"application/octet-stream"],data:Data(repeating:97,count:8*1024*1024)) }
            guard let doc = documents[path] else { return LocalResponse(status:404) }
            return LocalResponse(headers:["Content-Type":doc.0],data:Data(doc.1.utf8))
        }
        do {
            e.policy.setOnline(true); e.store.online = true
            let cssTest=DocumentRewriter(mapper:URLMapper(port:25001,token:"test")).css(Data(#"p::before{content:"url(fake.svg)"}p{background:url(\69mage.svg)}"#.utf8),base:URL(string:remote+"/style.css")!)
            try check("CSS strings untouched escaped URLs resolved",String(decoding:cssTest.0,as:UTF8.self).contains("url(fake.svg)") && cssTest.1.map(\.path)==["/image.svg"])
            let moduleSource = #"const pattern=/import '.fake.js'/;const obj={import:'./string.js'};import {ok} from './part.js';"#
            let scanned=ModuleScanner.transform(moduleSource,base:URL(string:remote+"/module.js")!,mapper:URLMapper(port:25001,token:"test"))
            try check("JS regex and property strings preserved",scanned.0.contains("/import '.fake.js'/") && scanned.0.contains("import:'./string.js'") && scanned.1.map(\.path)==["/part.js"])
            try await origin.start()
            let id = e.store.add(ProbeResult(url:URL(string:remote+"/index.html")!))
            e.store.change(id) { $0.mode = .continuous }
            let entry = e.store.entry(id)!
            let session = WebsiteSession(entry:entry,store:e.store,broker:e.broker); viewer = session
            try await session.start(); try await session.load(entry.url)
            try await Task.sleep(for:.seconds(2))
            let js = try await session.webView.evaluateJavaScript("JSON.stringify({r:results,color:getComputedStyle(document.querySelector('main')).color, image:document.querySelector('img').complete})") as? String ?? ""
            try check("HTTP HTML CSS image fetch XHR ES-module", js.contains("\"relative\":true") && js.contains("\"absolute\":true") && js.contains("\"xhr\":true") && js.contains("\"module\":true") && js.contains("12, 34, 56") && js.contains("\"image\":true"))
            let media = URL(string:remote+"/media.bin")!
            _ = try await e.broker.obtain(id,url:media,generation:"runtime")
            var response = await e.broker.response(id,mapper:session.mapper,request:LocalRequest(method:"GET",target:session.mapper.local(media).path,headers:["range":"bytes=100-199"],body:Data()),localOnly:true)
            try check("media byte range",response.status == 206 && response.offset == 100 && response.length == 100 && response.file != nil)
            response = await e.broker.response(id,mapper:session.mapper,request:LocalRequest(method:"HEAD",target:session.mapper.local(media).path,headers:[:],body:Data()),localOnly:true)
            try check("HEAD streaming size",response.length == 8*1024*1024 && response.data == nil)
            var login = URLRequest(url:URL(string:remote+"/session")!); login.httpMethod="POST"; login.httpBody=Data("password=test".utf8)
            _ = try await e.broker.service(id).request(login)
            let privateResult = try await e.broker.raw(id,url:URL(string:remote+"/private.json")!)
            try check("cookie login redirect",privateResult.response.statusCode == 200); try await e.broker.service(id).dispose(privateResult)
            e.policy.setOnline(false); e.store.online = false
            let before = await counter.value()
            try await session.load(entry.url); try await Task.sleep(for:.seconds(1))
            try check("offline page and stored fetch",try await session.webView.evaluateJavaScript("results.relative===true && results.absolute===true && results.xhr===true") as? Bool == true)
            let escape = """
            (()=>{let blocked=0;for(const f of [()=>new Worker('\(remote)/escape-worker'),()=>new WebSocket('ws://127.0.0.1:19750/escape-ws'),()=>new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:19750'}]})]){try{f()}catch{blocked++}}navigator.sendBeacon('\(remote)/escape-beacon');const i=document.createElement('img');i.src='http://127.0.0.1:19750/escape-image';document.body.appendChild(i);return blocked;})()
            """
            try check("Worker WebSocket WebRTC blocked",try await session.webView.evaluateJavaScript(escape) as? Int == 3)
            let frameEscape="""
            (()=>{const iframe=document.createElement('iframe');document.body.appendChild(iframe);let count=0;for(const get of [()=>iframe.contentWindow,()=>iframe.contentDocument.defaultView,()=>window.frames[window.frames.length-1]]){try{new (get().RTCPeerConnection)({iceServers:[{urls:'stun:127.0.0.1:19750'}]})}catch{count++}}iframe.remove();return count})()
            """
            try check("fresh blank iframe WebRTC blocked",try await session.webView.evaluateJavaScript(frameEscape) as? Int==3)
            try await Task.sleep(for:.seconds(1))
            try check("offline zero original requests",await counter.value() == before)
            let contentBefore = try await session.webView.evaluateJavaScript("document.querySelector('main').textContent") as? String
            var missingRejected=false
            do { try await session.load(URL(string:remote+"/missing.html")!) } catch { missingRejected=true }
            try check("missing navigation rejected",missingRejected)
            try check("missing navigation preserves document",try await session.webView.evaluateJavaScript("document.querySelector('main').textContent") as? String == contentBefore)
            session.close(); viewer = nil
            let reopened = WebsiteSession(entry:entry,store:e.store,broker:e.broker,localOnly:true); viewer = reopened
            try await reopened.start(); try await reopened.load(entry.url)
            try check("profile localStorage persists",try await reopened.webView.evaluateJavaScript("localStorage.getItem('persist')") as? String == "yes")
            reopened.close(); viewer = nil
            let reopenedArchive = ArchiveStore(root:e.store.root)
            try check("archive reopen",try await reopenedArchive.record(id,url:entry.url,generations:["runtime"]) != nil)
            e.policy.setOnline(true); e.store.online = true
            let https = try await e.broker.raw(id,url:URL(string:"https://example.org/")!)
            try check("HTTPS system trust",https.response.statusCode == 200); try await e.broker.service(id).dispose(https)
            try await e.archive.erase(id); e.store.entries.removeAll { $0.id == id }; e.store.save()
            origin.stop(); save(); return "Technische Prüfungen bestanden"
        } catch {
            results["error"] = error.localizedDescription; viewer?.close(); origin.stop(); save(); return error.localizedDescription
        }
    }
    func save() {
        let path = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("architecture-results.json")
        try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic)
    }
}
#endif
