import Foundation
import CryptoKit

enum CrawlerConfiguration {
    static let depthKey = "offlineBrowser.crawlDepth"
    static let defaultDepth = 2
}

struct CrawlerJob: Codable {
    var id: String
    var state = "queued"
    var done = 0
    var total = 0
    // Optional keeps jobs persisted by older builds decodable.
    var filesDone: Int? = nil
    var filesTotal: Int? = nil
}
struct CrawlerStatus: Decodable {
    var id: String
    var state: String
    var done: Int
    var total: Int
    var failed: Int?
    var filesDone: Int?
    var filesTotal: Int?
    var bytes: Int64?
    var sha256: String?
    var pages: [String]?
    var message: String?
}
@MainActor final class CrawlerCoordinator {
    let store: LibraryStore
    private let archive: ArchiveStore
    private var tasks: [UUID: Task<Void,Never>] = [:]
    private var runIDs: [UUID:UUID] = [:]
    private var stopping: [UUID: Task<Void,Never>] = [:]
    private let endpoint: URL?
    private let token: String
    var configured: Bool { endpoint != nil && !token.isEmpty }
    private var selectedDepth: Int {
        let value = UserDefaults.standard.object(forKey: CrawlerConfiguration.depthKey) as? Int ?? CrawlerConfiguration.defaultDepth
        return min(max(value, -1), 50)
    }
    init(store: LibraryStore, archive:ArchiveStore) {
        self.store=store; self.archive=archive
        let url=Bundle.main.url(forResource:"config",withExtension:"plist",subdirectory:"CrawlerConfig")
        let values=url.flatMap { try? Data(contentsOf:$0) }.flatMap { try? PropertyListSerialization.propertyList(from:$0,format:nil) as? [String:String] }
        endpoint=values?["endpoint"].flatMap(URL.init(string:)); token=values?["token"] ?? ""
    }
    func file(_ entry: WebsiteEntry) -> URL? {
        guard let name=entry.waczFile, name == URL(fileURLWithPath:name).lastPathComponent else { return nil }
        return store.root.appendingPathComponent("crawler/\(entry.id.uuidString)/\(name)")
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let endpoint, configured else { throw ArchiveError.unsupported("Crawler-Zugang ist nicht eingerichtet.") }
        var r=URLRequest(url:endpoint.appendingPathComponent(path)); r.httpMethod=method; r.httpBody=body
        r.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        if body != nil { r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        r.timeoutInterval=60; return r
    }
    func api(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard store.online else { throw ArchiveError.offline }
        let (data,response)=try await URLSession.shared.data(for:request(path,method:method,body:body))
        guard let response=response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ArchiveError.unsupported("Crawler nicht erreichbar oder Zugang abgelehnt.") }
        return data
    }
    func start(_ id: UUID, refresh: Bool = false) {
        guard tasks[id] == nil, let e=store.entry(id) else { return }
        guard store.online else { store.toast(ArchiveError.offline.localizedDescription); return }
        guard configured else { store.toast("Crawler-Zugang ist nicht eingerichtet."); return }
        if e.crawlerJob == nil { store.change(id) { $0.crawlerJob=CrawlerJob(id:UUID().uuidString.lowercased()); $0.job=nil } }
        store.change(id) { $0.phase = .downloading; $0.message="Crawler · Warteschlange" }
        let runID=UUID(); runIDs[id]=runID
        tasks[id]=Task { [weak self] in
            guard let self else { return }
            await stopping[id]?.value
            await run(id)
            if runIDs[id]==runID { tasks[id]=nil; runIDs[id]=nil }
        }
    }
    private func run(_ id: UUID) async {
        guard let e=store.entry(id), let job=e.crawlerJob else { return }
        while !Task.isCancelled {
            do {
                if !store.online { return }
                let body=try JSONSerialization.data(withJSONObject:["url":e.url.absoluteString,"id":job.id,"depth":selectedDepth])
                _=try await api("jobs",method:"POST",body:body)
                var status=try JSONDecoder().decode(CrawlerStatus.self,from:await api("jobs/"+job.id))
                if status.state == "paused" || status.state == "error" {
                    _=try await api("jobs/\(job.id)/resume",method:"POST")
                    status.state="queued"
                }
                try Task.checkCancellation()
                store.change(id) {
                    $0.crawlerJob?.state=status.state; $0.crawlerJob?.done=status.done; $0.crawlerJob?.total=status.total
                    $0.crawlerJob?.filesDone=status.filesDone; $0.crawlerJob?.filesTotal=status.filesTotal
                    $0.phase = .downloading
                    $0.message=status.state == "queued" ? "Crawler · Warteschlange" : "Crawler · Dateien geladen: \(status.filesDone ?? 0)"
                }
                store.capacity()
                if status.state == "ready" {
                    store.capacity()
                    if let available=store.availableBytes,let expected=status.bytes,available<expected {
                        store.change(id) { $0.phase = .pausedStorage; $0.message=ArchiveError.storage.localizedDescription }
                        return
                    }
                    store.change(id) { $0.message="Archiv wird auf dieses Gerät geladen" }
                    let (temp,response)=try await URLSession.shared.download(for:request("jobs/\(job.id)/archive"))
                    defer { try? FileManager.default.removeItem(at:temp) }
                    try Task.checkCancellation()
                    guard let response=response as? HTTPURLResponse,response.statusCode==200 else { throw ArchiveError.integrity }
                    let verified=try await Task.detached { () throws -> Bool in
                        let h=try FileHandle(forReadingFrom:temp); defer { try? h.close() }
                        var digest=SHA256(); var bytes:Int64=0
                        while let data=try h.read(upToCount:1024*1024),!data.isEmpty { digest.update(data:data); bytes += Int64(data.count) }
                        return bytes==status.bytes && digest.finalize().map { String(format:"%02x",$0) }.joined()==status.sha256
                    }.value
                    guard verified else { throw ArchiveError.integrity }
                    try Task.checkCancellation()
                    let dir=store.root.appendingPathComponent("crawler/\(id.uuidString)")
                    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                    let name=job.id+".wacz", destination=dir.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
                    try FileManager.default.moveItem(at:temp,to:destination)
                    let old=file(e)
                    store.change(id) {
                        $0.waczFile=name; $0.waczPages=status.pages; $0.crawlerJob=nil; $0.activeGeneration=nil; $0.job=nil
                        $0.mode = .full; $0.phase = .ready; $0.verified=true; $0.bytes=status.bytes ?? 0
                        $0.message="Browsertrix · auf diesem Gerät gesichert"; $0.lastUpdate=Date(); $0.updateAvailable=false
                        $0.report=["Browsertrix: \(status.done) Seiten, \(status.filesDone ?? 0) Dateien, \(status.failed ?? 0) fehlgeschlagene Seiten.","Originalantworten als WACZ gesichert. Interaktive Zustände sind nicht automatisch vollständig erfasst."]
                    }
                    if let old,old != destination { try? FileManager.default.removeItem(at:old) }
                    try? await archive.erase(id)
                    // App now owns a verified copy. Release remote disk space.
                    _=try? await api("jobs/"+job.id,method:"DELETE")
                    store.capacity(); return
                }
                try await Task.sleep(for:.seconds(2))
            } catch {
                if Task.isCancelled { return }
                store.change(id) { $0.phase = .retrying; $0.message="Es treten Probleme auf. Prüfen Sie Ihre Verbindung." }
                try? await Task.sleep(for:.seconds(5))
            }
        }
    }
    func pause(_ id: UUID, phase:JobPhase = .pausedUser) {
        runIDs[id]=nil
        let old=tasks.removeValue(forKey:id); old?.cancel()
        guard let job=store.entry(id)?.crawlerJob else { return }
        store.change(id) { $0.phase = phase; $0.message=phase == .pausedOffline ? "Offline · Fortsetzung möglich" : "Crawler · Fortsetzung möglich" }
        stopping[id]=Task { [weak self] in await old?.value; _=try? await self?.api("jobs/\(job.id)/pause",method:"POST") }
    }
    func discard(_ id: UUID, eraseArchive: Bool = false) async {
        let e=store.entry(id); pause(id); await stopping[id]?.value; stopping[id]=nil
        if let job=e?.crawlerJob { _=try? await api("jobs/"+job.id,method:"DELETE") }
        if eraseArchive { try? FileManager.default.removeItem(at:store.root.appendingPathComponent("crawler/\(id.uuidString)")) }
        store.change(id) { $0.crawlerJob=nil; if eraseArchive { $0.waczFile=nil; $0.waczPages=nil }; $0.phase = $0.waczFile == nil ? .none : .ready; $0.message=$0.waczFile == nil ? "Leerlauf" : "Browsertrix · auf diesem Gerät gesichert" }
    }
}

