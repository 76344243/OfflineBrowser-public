#if DEBUG
import Foundation
import WebKit
@MainActor final class IntegrationTests {
    let environment:AppEnvironment
    var results:[String:String]=[:]
    init(environment:AppEnvironment) { self.environment=environment }
    func check(_ name:String,_ condition:Bool) throws { results[name]=condition ? "PASS" : "FAIL"; save(); if !condition { throw ArchiveError.unsupported(name) } }
    func run() async -> String {
        let e=environment; let url=URL(string:"http://127.0.0.1:19760/index.html")!
        var server:LocalContentServer?
        do {
            e.downloads.setOnline(true)
            let html=Data("<html><head><link rel='offline-kit' href='offline-kit.json'><link rel='stylesheet' href='style.css'></head><body><main>Offline-Kit</main><a href='javascript:void(0)'>Mehr anzeigen</a></body></html>".utf8)
            let rewriter=DocumentRewriter(mapper:URLMapper(port:25001,token:"test"))
            try check("no-op JavaScript link does not reject archive",try rewriter.html(html,base:url).2.isEmpty)
            let navigation=Data("<a href='javascript:location.href=\"/next\"'>Weiter</a>".utf8)
            try check("real JavaScript navigation still reported",try !rewriter.html(navigation,base:url).2.isEmpty)
            let css=Data("main{color:blue}".utf8)
            let files:[String:(String,Data)]=["/index.html":("text/html",html),"/style.css":("text/css",css),"/offline.js":("application/javascript",Data("window.offlineKitReady=true;".utf8))]
            try check("JavaScript MIME aliases accepted",ResourceBroker.mimeMatches("application/javascript",expected:"text/javascript; charset=utf-8") && ResourceBroker.mimeMatches("Text/JavaScript",expected:"application/javascript"))
            try check("unrelated MIME rejected",!ResourceBroker.mimeMatches("text/html",expected:"text/javascript") && !ResourceBroker.mimeMatches("text/css-extra",expected:"text/css"))
            let dir=e.store.root.appendingPathComponent("fixture-hashes"); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            var resources:[KitResource]=[]
            for (path,file) in files { let p=dir.appendingPathComponent(path.dropFirst().description); try file.1.write(to:p); let (hash,size)=try await e.archive.hash(p); resources.append(KitResource(url:String(path.dropFirst()),mime:path == "/offline.js" ? "text/javascript" : file.0,bytes:size,sha256:hash)) }
            let kit=OfflineKit(schemaVersion:1,revision:"1",scope:"./",entry:"index.html",resources:resources,offlineChecks:[OfflineCheck(path:"index.html",selector:"main",description:"Startseite")])
            var wrongVersion=kit; wrongVersion.schemaVersion=999
            var rejected=false
            do { try SupportProbe.validate(wrongVersion,base:url) } catch { rejected=true }; try check("foreign kit version rejected",rejected)
            var unsafe=kit; unsafe.resources[0].url="https://other.example/private.html"
            rejected=false
            do { try SupportProbe.validate(unsafe,base:url) } catch { rejected=true }; try check("undeclared kit origin rejected",rejected)
            let manifest=try JSONEncoder().encode(kit)
            let scenario=IntegrationScenario()
            let counter=FixtureCounter()
            server=LocalContentServer(port:19760) { req in
                await counter.add()
                if req.target=="/flaky.css" { let attempt=await scenario.flakyAttempt(); if attempt<3 { return LocalResponse(status:503,headers:["Retry-After":"1"]) }; return LocalResponse(headers:["Content-Type":"text/css"],data:css) }
                if req.target=="/bad.css" { return LocalResponse(headers:["Content-Type":"text/css"],data:Data("corrupted".utf8)) }
                if req.target=="/plain.html" { return LocalResponse(headers:["Content-Type":"text/html"],data:Data("<html><body><main id=plain>Ohne Kit</main><script src=assets.js></script></body></html>".utf8)) }
                if req.target=="/assets.js" { return LocalResponse(headers:["Content-Type":"application/javascript"],data:Data("window.asset=\"extra.json\";fetch(window.asset).then(r=>r.json()).then(v=>document.querySelector(\"main\").dataset.loaded=v.ok);".utf8)) }
                if req.target=="/extra.json" { return LocalResponse(headers:["Content-Type":"application/json"],data:Data("{\"ok\":true}".utf8)) }
                if req.target=="/offline-kit.json" { return LocalResponse(headers:["Content-Type":"application/json"],data:manifest) }
                if let file=files[req.target] { return LocalResponse(headers:["Content-Type":file.0],data:file.1) }
                return LocalResponse(status:404)
            }
            try await server!.start()
            let probe=try await SupportProbe(broker:e.broker).run(url.absoluteString,id:UUID())
            try check("kit detection",probe.kit?.revision=="1")
            let id=e.store.add(probe)
            e.downloads.start(id)
            for _ in 0..<150 { if e.store.entry(id)?.phase == .ready || e.store.entry(id)?.phase == .unsupported { break }; try await Task.sleep(for:.milliseconds(200)) }
            try check("full download and offline selectors",e.store.entry(id)?.phase == .ready && e.store.entry(id)?.verified == true)
            let original=e.store.entry(id)!.activeGeneration
            try check("kit counts",try await e.archive.records(id,generation:original!).count==3)
            e.downloads.setOnline(false); let before=await counter.value()
            let session=WebsiteSession(entry:e.store.entry(id)!,store:e.store,broker:e.broker)
            try await session.start(); try await session.load(url)
            let text=try await session.webView.evaluateJavaScript("document.querySelector('main').textContent") as? String
            results["offline rendered text"]=text ?? "nil"; save()
            try check("full archive offline",text == "Offline-Kit")
            session.close(); try check("offline no probes or requests",await counter.value()==before)
            e.downloads.setOnline(true)
            e.downloads.start(id,refresh:true); e.downloads.pause(id)
            try check("pause preserves complete version",e.store.entry(id)?.activeGeneration==original && e.store.entry(id)?.job != nil)
            await e.downloads.discard(id)
            try check("discard only unfinished",e.store.entry(id)?.activeGeneration==original && e.store.entry(id)?.job==nil)
            let other=e.store.add(ProbeResult(url:url))
            e.store.change(other) { $0.mode = .continuous }
            _=try await e.broker.obtain(other,url:url,generation:"runtime")
            await e.downloads.reset(id,mode:.idle)
            try check("entry isolation on reset",try await e.broker.cached(other,url:url) != nil && e.store.entry(id)?.activeGeneration==nil)
            await e.downloads.reset(other,mode:.idle,delete:true); await e.downloads.reset(id,mode:.idle,delete:true)
            try check("delete",e.store.entry(other)==nil && e.store.entry(id)==nil)
            // A transient bad resource must not stop unrelated transfers or end the job.
            let style=resources.first { $0.url=="style.css" }!
            var flaky=kit; flaky.resources.append(KitResource(url:"flaky.css",mime:style.mime,bytes:style.bytes,sha256:style.sha256))
            let flakyID=e.store.add(ProbeResult(url:url,kitURL:url.deletingLastPathComponent().appendingPathComponent("offline-kit.json"),kit:flaky))
            e.downloads.start(flakyID)
            try await wait(20) { e.store.entry(flakyID)?.phase == .ready }
            try check("retry while other files finish",await scenario.flakyCount>=3 && e.store.entry(flakyID)?.downloaded==0 && e.store.entry(flakyID)?.verified==true)
            await e.downloads.reset(flakyID,mode:.idle,delete:true)
            // Hash mismatch never promotes an archive; cancellation leaves the resumable job.
            var broken=kit; broken.resources.append(KitResource(url:"bad.css",mime:style.mime,bytes:style.bytes,sha256:style.sha256))
            let badID=e.store.add(ProbeResult(url:url,kitURL:url.deletingLastPathComponent().appendingPathComponent("offline-kit.json"),kit:broken))
            e.downloads.start(badID)
            try await wait(10) { e.store.entry(badID)?.job?.items.contains(where:{$0.lastError != nil})==true }
            e.downloads.pause(badID)
            try check("integrity failure resumable not ready",e.store.entry(badID)?.activeGeneration==nil && e.store.entry(badID)?.job != nil && e.store.entry(badID)?.phase == .pausedUser)
            await e.downloads.reset(badID,mode:.idle,delete:true)
            // Storage failure injection is scoped to archive writes, never fills the real disk.
            let diskID=e.store.add(probe)
            await e.archive.simulateFullDisk(diskID,enabled:true); e.downloads.start(diskID)
            try await wait(10) { e.store.entry(diskID)?.phase == .pausedStorage }
            try check("disk full pauses without ready",e.store.entry(diskID)?.activeGeneration==nil && e.store.entry(diskID)?.job != nil)
            await e.archive.simulateFullDisk(diskID,enabled:false)
            // Restart the persisted library and check that the job survives.
            let reopened=LibraryStore(root:e.store.root)
            try check("job survives reopened library",reopened.entry(diskID)?.job?.id==e.store.entry(diskID)?.job?.id)
            e.downloads.start(diskID); try await wait(20) { e.store.entry(diskID)?.phase == .ready }
            try check("resume after disk available",e.store.entry(diskID)?.verified==true)
            // Remove an actual blob, reconcile must withdraw the ready status and redownload it.
            let generation=e.store.entry(diskID)!.activeGeneration!
            let record=try await e.archive.records(diskID,generation:generation).first!
            try FileManager.default.removeItem(at:await e.archive.object(diskID,hash:record.hash))
            await e.reconcile()
            try check("missing blob withdraws ready",e.store.entry(diskID)?.verified==false && e.store.entry(diskID)?.job != nil)
            e.downloads.start(diskID); try await wait(20) { e.store.entry(diskID)?.phase == .ready }
            try check("missing blob restored",e.store.entry(diskID)?.verified==true)
            let restoredGeneration=e.store.entry(diskID)!.activeGeneration!
            let restoredRecord=try await e.archive.records(diskID,generation:restoredGeneration).first!
            let damagedFile=try await e.archive.object(diskID,hash:restoredRecord.hash)
            try Data("damaged".utf8).write(to:damagedFile)
            e.downloads.start(diskID,refresh:true)
            try await wait(20) { e.store.entry(diskID)?.phase == .ready && e.store.entry(diskID)?.job==nil }
            let repairedHash=try await e.archive.hash(damagedFile).0
            try check("corrupt existing blob repaired atomically",repairedHash==restoredRecord.hash)
            await e.downloads.reset(diskID,mode:.idle,delete:true)
            let plain=URL(string:"http://127.0.0.1:19760/plain.html")!
            let plainProbe=try await SupportProbe(broker:e.broker).run(plain.absoluteString,id:UUID())
            try check("no kit allows attempted download",plainProbe.kit==nil && !plainProbe.loginRequired)
            let plainID=e.store.add(plainProbe); e.downloads.start(plainID)
            try await wait(30) { e.store.entry(plainID)?.phase == .ready || e.store.entry(plainID)?.phase == .unsupported }
            try check("no kit HTML JS asset discovered and offline checked",e.store.entry(plainID)?.verified==true && e.store.entry(plainID)?.phase == .ready)
            e.downloads.setOnline(false); let plainBefore=await counter.value()
            let plainSession=WebsiteSession(entry:e.store.entry(plainID)!,store:e.store,broker:e.broker)
            try await plainSession.start(); try await plainSession.load(plain); try await Task.sleep(for:.seconds(1))
            let loaded=try await plainSession.webView.evaluateJavaScript("document.querySelector('main').dataset.loaded") as? String
            let plainAfter=await counter.value()
            try check("no kit dynamic data offline",loaded=="true" && plainBefore==plainAfter)
            plainSession.close(); await e.downloads.reset(plainID,mode:.idle,delete:true)
            e.downloads.setOnline(true)
            server?.stop(); save(); return "Integration bestanden"
        } catch { results["error"]=error.localizedDescription; server?.stop(); save(); return error.localizedDescription }
    }
    private func wait(_ seconds:Int,condition:()->Bool) async throws {
        for _ in 0..<(seconds*5) { if condition() { return }; try await Task.sleep(for:.milliseconds(200)) }
        throw ArchiveError.unsupported("Testbedingung nicht innerhalb von \(seconds) Sekunden erreicht")
    }
    private func save() { let p=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("integration-results.json"); try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:p,options:.atomic) }
}
actor IntegrationScenario { var flakyCount=0; func flakyAttempt()->Int { flakyCount+=1; return flakyCount } }
#endif
