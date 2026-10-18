import Foundation
import WebKit

@MainActor final class DownloadCoordinator {
    let store: LibraryStore
    let broker: ResourceBroker
    let archive: ArchiveStore
    let policy: NetworkPolicy
    private var tasks: [UUID:Task<Void,Never>] = [:]
    private var verifiers: [UUID:WebsiteSession] = [:]
    private var lastChecks = Date.distantPast
    private var runs: [UUID:UUID] = [:]
    init(store:LibraryStore,broker:ResourceBroker,archive:ArchiveStore,policy:NetworkPolicy) { self.store=store; self.broker=broker; self.archive=archive; self.policy=policy }
    func start(_ id:UUID, refresh:Bool=false, nextKit:OfflineKit? = nil) {
        guard tasks[id]==nil, let e=store.entry(id) else { return }
        guard store.online else { store.toast(ArchiveError.offline.localizedDescription); return }
        if e.job==nil {
            var items:[DownloadItem]=[]
            if let kit=nextKit ?? e.kit, let base=e.kitURL {
                items=kit.resources.compactMap { item in guard let u=URL(string:item.url,relativeTo:base)?.absoluteURL else { return nil }; return DownloadItem(url:u,expectedHash:item.sha256,expectedBytes:item.bytes,mime:item.mime) }
            } else { items=[DownloadItem(url:e.startURL)] }
            store.change(id) { $0.job=DownloadJob(items:items,refreshing:refresh,previousMode:e.mode,previousKit:e.kit); if let nextKit { $0.kit=nextKit }; $0.phase = .discovering; $0.verified=false }
        }
        store.change(id) { $0.phase = .downloading; $0.message="Elemente werden geladen" }
        let runID=UUID(); runs[id]=runID
        tasks[id]=Task { [weak self] in await self?.run(id); if self?.runs[id]==runID { self?.tasks[id]=nil; self?.runs[id]=nil } }
    }
    func pause(_ id:UUID, phase:JobPhase = .pausedUser) {
        runs[id]=nil; tasks.removeValue(forKey:id)?.cancel(); verifiers.removeValue(forKey:id)?.close()
        Task { await broker.cancel(id) }
        store.change(id) { $0.phase=phase; $0.message=phase == .pausedOffline ? "Offline · Fortsetzung möglich" : "Fortsetzung möglich" }
    }
    func discard(_ id:UUID) async {
        pause(id); guard let e=store.entry(id), let job=e.job else { return }
        try? await archive.removeGeneration(id,job.id)
        store.change(id) { $0.job=nil; $0.phase = e.activeGeneration == nil ? .none : .ready; $0.message=e.activeGeneration == nil ? (e.mode == .continuous ? "Laufend sichern · aktiv" : "Leerlauf") : "Gesicherte Version verfügbar"; $0.verified=e.activeGeneration != nil; if job.refreshing { $0.kit=job.previousKit ?? e.kit } }
        try? await archive.prune(id,keeping:[e.activeGeneration,"runtime"].compactMap{$0})
        await updateBytes(id)
    }
    func setOnline(_ value:Bool) {
        policy.setOnline(value); store.online=value; store.save()
        if !value { for e in store.entries where e.busy { pause(e.id,phase:.pausedOffline) } }
        else { for e in store.entries where e.phase == .pausedOffline { start(e.id) } }
    }
    private func run(_ id:UUID) async {
        // Resume checks the actual archive, not persisted done flags.
        if let job=store.entry(id)?.job {
            for item in job.items where item.done {
                let record=try? await archive.record(id,url:item.url,generations:[job.id])
                let valid:Bool
                if let record,let file=try? await archive.object(id,hash:record.hash),let digest=try? await archive.hash(file) { valid=digest.0==record.hash } else { valid=false }
                if !valid { store.change(id) { e in if let i=e.job?.items.firstIndex(where:{$0.id==item.id}) { e.job?.items[i].done=false; e.job?.items[i].retryAt=nil } } }
            }
        }
        while !Task.isCancelled {
            guard let e=store.entry(id), let job=e.job else { return }
            if !policy.online { store.change(id) { $0.phase = .pausedOffline }; return }
            let pending=job.items.filter { !$0.done && ($0.retryAt ?? .distantPast)<=Date() }
            if pending.isEmpty {
                if job.items.allSatisfy(\.done) {
                    do {
                        let finished=try await verify(id,generation:job.id)
                        if finished {
                            // A manifest that changes mid-download is not promoted.
                            if let old=e.kit, let url=e.kitURL {
                                let response=try await broker.raw(id,url:url); let service=try await broker.service(id); defer { service.dispose(response) }
                                let newest=try JSONDecoder().decode(OfflineKit.self,from:Data(contentsOf:response.file))
                                guard newest.revision==old.revision else { throw ArchiveError.unsupported("Manifest während des Downloads geändert. Starten Sie Refresh erneut.") }
                            }
                            store.change(id) { $0.activeGeneration=job.id; $0.mode = .full; $0.phase = .ready; $0.job=nil; $0.verified=true; $0.updateAvailable=false; $0.lastUpdate=Date(); $0.message=$0.kit == nil ? "Versuchter Download · Offline geprüft" : "Vollständig gesichert · \($0.kit!.revision)" }
                            try? await archive.removeGeneration(id,"runtime")
                            try? await archive.prune(id,keeping:[job.id])
                            await updateBytes(id); return
                        }
                    } catch {
                        if Task.isCancelled { return }
                        if case ArchiveError.unsupported = error {
                            store.change(id) { $0.phase = .unsupported; $0.message=error.localizedDescription; $0.report.append(error.localizedDescription) }; return
                        }
                        store.change(id) { $0.phase = .retrying; $0.message="Es treten Probleme auf. Prüfen Sie Ihre Verbindung." }
                        try? await Task.sleep(for:.seconds(5))
                    }
                } else { store.change(id) { $0.phase = .retrying; $0.message="Es treten Probleme auf. Prüfen Sie Ihre Verbindung." }; try? await Task.sleep(for:.seconds(1)) }
                continue
            }
            let batch=Array(pending.prefix(3))
            await withTaskGroup(of:(String, Result<ResourceRecord,Error>).self) { group in
                for item in batch {
                    let broker=broker
                    group.addTask { do { return (item.id,.success(try await broker.obtain(id,url:item.url,generation:job.id,expected:item,forceNetwork:job.refreshing,background:true))) } catch { return (item.id,.failure(error)) } }
                }
                for await (key,result) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    switch result {
                    case .success(let record):
                        store.change(id) { entry in if let i=entry.job?.items.firstIndex(where:{$0.id==key}) { entry.job?.items[i].done=true; entry.job?.items[i].lastError=nil } }
                        if e.kit==nil { await discover(id,record:record,generation:job.id) }
                    case .failure(let error):
                        if error is CancellationError || !policy.online { continue }
                        if case ArchiveError.storage = error {
                            pauseForStorage(id); group.cancelAll(); return
                        }
                        if (error as NSError).code == NSFileWriteOutOfSpaceError || (error as NSError).code == 28 {
                            pauseForStorage(id); group.cancelAll(); return
                        }
                        if case ArchiveError.login = error { store.change(id) { $0.phase = .needsLogin; $0.message=ArchiveError.login.localizedDescription }; group.cancelAll(); return }
                        store.change(id) { entry in
                            if let i=entry.job?.items.firstIndex(where:{$0.id==key}) {
                                let attempt=(entry.job?.items[i].attempts ?? 0)+1
                                entry.job?.items[i].attempts=attempt; entry.job?.items[i].lastError=error.localizedDescription
                                let serverDelay:TimeInterval
                                if case ArchiveError.http(_,let delay)=error { serverDelay=delay ?? 0 } else { serverDelay=0 }
                                entry.job?.items[i].retryAt=Date().addingTimeInterval(max(serverDelay,min(60,pow(2,Double(min(attempt,6)))))+Double.random(in:0...1))
                            }
                            entry.phase = .retrying; entry.message="Es treten Probleme auf. Prüfen Sie Ihre Verbindung."
                        }
                    }
                    await updateBytes(id)
                }
            }
            if store.entry(id)?.phase == .pausedStorage || store.entry(id)?.phase == .needsLogin { return }
        }
    }
    private func discover(_ id:UUID,record:ResourceRecord,generation:String) async {
        guard let e=store.entry(id), let base=URL(string:record.url), let file=try? await archive.object(id,hash:record.hash), let data=try? Data(contentsOf:file) else { return }
        let mapper=URLMapper(port:e.port,token:"discovery")
        var urls:[URL]=[]
        if record.mime=="text/html" { urls=(try? DocumentRewriter(mapper:mapper).links(data,base:base)) ?? [] }
        else if record.mime=="text/css" { urls=DocumentRewriter(mapper:mapper).css(data,base:base).1 }
        else if record.mime.contains("javascript") { urls=ModuleScanner.transform(String(decoding:data,as:UTF8.self),base:base,mapper:mapper).1 + AssetStrings.urls(String(decoding:data,as:UTF8.self),document:e.startURL) }
        // HTML links are scoped; embedded cross-origin URLs need an explicit declaration to be crawled.
        append(id,urls:urls.filter { URLMapper.origin($0)==URLMapper.origin(e.scope) && $0.path.hasPrefix(e.scope.path) })
    }
    private func append(_ id:UUID,urls:[URL]) {
        store.change(id) { e in
            var known=Set(e.job?.items.map(\.id) ?? [])
            for url in urls where ["http","https"].contains(url.scheme) { if known.insert(URLMapper.key(url)).inserted { e.job?.items.append(DownloadItem(url:url)) } }
            let paths=Dictionary(grouping:e.job?.items ?? [],by:{$0.url.path})
            if paths.contains(where:{$0.value.count>25}) { e.message="Die Seite erzeugt fortlaufend neue Adressen; ein vollständiger Abschluss ist nicht nachweisbar." }
        }
    }
    private func verify(_ id:UUID,generation:String) async throws -> Bool {
        guard let entry=store.entry(id) else { throw CancellationError() }
        store.change(id) { $0.phase = .verifying; $0.message="Offline-Funktionen werden geprüft" }
        for item in entry.job?.items ?? [] { guard let r=try await archive.record(id,url:item.url,generations:[generation]), let file=try? await archive.object(id,hash:r.hash), (try await archive.hash(file)).0==r.hash else { throw ArchiveError.integrity } }
        if entry.kit==nil {
            let capture=WebsiteSession(entry:entry,store:store,broker:broker,candidate:generation)
            verifiers[id]=capture
            do { try await capture.start(); try await capture.load(entry.startURL); try await Task.sleep(for:.seconds(2)) } catch { capture.close(); throw error }
            let newRecords=try await archive.records(id,generation:"runtime")
            let known=Set(entry.job?.items.map(\.id) ?? [])
            let more=newRecords.compactMap { r in !known.contains(r.url) ? URL(string:r.url) : nil }
            capture.close(); verifiers[id]=nil
            if !more.isEmpty { append(id,urls:more); return false }
        }
        let session=WebsiteSession(entry:entry,store:store,broker:broker,localOnly:true,candidate:generation); verifiers[id]=session
        defer { session.close(); verifiers[id]=nil }
        try await session.start(); try await session.load(entry.startURL); try await Task.sleep(for:.seconds(2))
        for item in entry.job?.items ?? [] {
            if let record=try await archive.record(id,url:item.url,generations:[generation]),record.mime=="text/html" {
                let file=try await archive.object(id,hash:record.hash)
                let issues=try DocumentRewriter(mapper:session.mapper).html(Data(contentsOf:file),base:item.url).2
                if !issues.isEmpty { throw ArchiveError.unsupported("Nicht unterstützt: "+issues.joined(separator:"; ")) }
            }
        }
        if let checks=entry.kit?.offlineChecks {
            for check in checks {
                guard let url=URL(string:check.path,relativeTo:entry.kitURL)?.absoluteURL else { throw ArchiveError.invalidURL }
                try await session.load(url)
                let literal=String(decoding:try JSONSerialization.data(withJSONObject:[check.selector]),as:UTF8.self)
                guard try await session.webView.evaluateJavaScript("document.querySelector(\(literal)[0]) !== null") as? Bool == true else { throw ArchiveError.unsupported("Offline-Prüfung fehlgeschlagen: \(check.description ?? check.selector)") }
            }
        }
        if !session.issues.isEmpty { throw ArchiveError.unsupported("Nicht unterstützt: " + session.issues.joined(separator:"; ")) }
        let records=try await archive.records(id,generation:"runtime")
        if entry.kit==nil {
            let known=Set(entry.job?.items.map(\.id) ?? [])
            let more=records.compactMap { r in !known.contains(r.url) ? URL(string:r.url) : nil }
            if !more.isEmpty { append(id,urls:more); return false }
        }
        store.change(id) { $0.report.append("Offline geprüft: \(Date().formatted()) · \($0.job?.items.count ?? 0) Elemente") }
        return true
    }
    private func pauseForStorage(_ id:UUID) {
        store.capacity(); let available=store.availableBytes
        store.change(id) { $0.phase = .pausedStorage; $0.message=ArchiveError.storage.localizedDescription; $0.job?.storageCapacityAtPause=available }
    }
    func updateBytes(_ id:UUID) async { if let bytes=try? await archive.bytes(id) { store.change(id) { $0.bytes=bytes } }; store.capacity() }
    func tick(checkUpdates: Bool = true) async {
        store.capacity()
        for e in store.entries where e.phase != .resetting { if !e.busy { try? await archive.prune(e.id,keeping:["runtime",e.activeGeneration,e.job?.id].compactMap{$0}) }; await updateBytes(e.id); if e.phase == .pausedStorage, let now=store.availableBytes, let before=e.job?.storageCapacityAtPause, now>before+1024*1024 { start(e.id) } }
        guard checkUpdates, store.online, Date().timeIntervalSince(lastChecks)>300 else { return }; lastChecks=Date()
        for e in store.entries where e.mode != .idle && !e.busy {
            do {
                let target=e.kitURL ?? e.startURL
                let response=try await broker.raw(e.id,url:target); let service=try await broker.service(e.id); defer { service.dispose(response) }
                if let kit=e.kit { let new=try JSONDecoder().decode(OfflineKit.self,from:Data(contentsOf:response.file)); if new.revision != kit.revision { store.change(e.id) { $0.updateAvailable=true } } }
                else if let old=try await broker.cached(e.id,url:target) { let hash=(try await archive.hash(response.file)).0; if hash != old.hash { store.change(e.id) { $0.updateAvailable=true } } }
            } catch { /* An unavailable probe does not declare the page current. */ }
        }
    }
    func refresh(_ id:UUID) async {
        guard let e=store.entry(id), store.online else { store.toast(ArchiveError.offline.localizedDescription); return }
        if e.mode == .full {
            if let url=e.kitURL {
                do { let response=try await broker.raw(id,url:url); let service=try await broker.service(id); defer { service.dispose(response) }; let kit=try JSONDecoder().decode(OfflineKit.self,from:Data(contentsOf:response.file)); try SupportProbe.validate(kit,base:url); if e.job != nil { store.toast("Setzen Sie zuerst den bestehenden Download fort oder verwerfen Sie ihn."); return }; start(id,refresh:true,nextKit:kit); return } catch { store.toast(error.localizedDescription); return }
            }
            if e.job != nil { store.toast("Setzen Sie zuerst den bestehenden Download fort oder verwerfen Sie ihn."); return }
            start(id,refresh:true)
        } else if e.mode == .continuous {
            let urls=(try? await archive.records(id,generation:"runtime"))?.compactMap { URL(string:$0.url) } ?? [e.startURL]
            var success=true
            for url in Set(urls+[e.startURL]) { do { _ = try await broker.obtain(id,url:url,generation:"runtime",forceNetwork:true) } catch { success=false; store.toast(error.localizedDescription) } }
            if success { store.change(id) { $0.lastUpdate=Date(); $0.updateAvailable=false } }; await updateBytes(id)
        }
    }
    private static func clearWebsiteData(_ id:UUID) {
        // Removing the complete named WKWebsiteDataStore can crash the iOS
        // simulator while a WebView still owns its configuration. Clear the
        // data in that store instead; WebKit performs this asynchronously and
        // retains the store until the completion handler has run.
        let dataStore = WKWebsiteDataStore(forIdentifier:id)
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince:.distantPast) { }
    }
    func reset(_ id:UUID, mode:StorageMode, delete:Bool=false) async {
        pause(id); store.change(id) { $0.phase = .resetting; $0.message="Webseitendaten werden gelöscht" }
        Self.clearWebsiteData(id)
        await broker.clear(id); try? await archive.erase(id)
        if delete { store.entries.removeAll { $0.id==id }; store.save() }
        else { store.change(id) { $0.mode=mode; $0.job=nil; $0.activeGeneration=nil; $0.phase = .none; $0.bytes=0; $0.verified=false; $0.message=mode == .idle ? "Leerlauf" : "Laufend sichern · aktiv"; $0.report=[]; $0.lastVisitedURL=nil } }
    }
}
