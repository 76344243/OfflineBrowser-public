import Foundation

actor ResourceBroker {
    let store: LibraryStore
    let archive: ArchiveStore
    let policy: NetworkPolicy
    private var vaults: [UUID: CookieVault] = [:]
    private var transfers: [String:TransferService] = [:]
    init(store: LibraryStore, archive: ArchiveStore, policy: NetworkPolicy) { self.store = store; self.archive = archive; self.policy = policy }
    func vault(_ id: UUID) -> CookieVault { if let v = vaults[id] { return v }; let v = CookieVault(id:id); vaults[id] = v; return v }
    func service(_ id: UUID, background: Bool = false) throws -> TransferService {
        let key = id.uuidString + (background ? ".background" : ".viewer")
        if let t = transfers[key] { return t }
        let dir = try directory(id).appendingPathComponent(background ? "partials/background" : "partials/viewer")
        let t = TransferService(policy:policy,vault:vault(id),directory:dir,id:id,background:background)
        let store=store
        t.progress={ key,bytes in Task { @MainActor in guard store.entry(id) != nil, store.entry(id)?.phase != .resetting else { return }; if bytes==0 { store.transferBytes[id]?[key]=nil } else { store.transferBytes[id,default:[:]][key]=bytes } } }
        transfers[key] = t; return t
    }
    private func directory(_ id: UUID) throws -> URL {
        let p = archive.root.appendingPathComponent("entries/\(id.uuidString)")
        try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true); var folder=p; var values=URLResourceValues(); values.isExcludedFromBackup=true; try folder.setResourceValues(values); try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:p.path); return p
    }
    func cancel(_ id: UUID) { for (k,t) in transfers where k.hasPrefix(id.uuidString) { t.cancelAll() } }
    func clear(_ id: UUID) async {
        let owned=transfers.filter {$0.key.hasPrefix(id.uuidString)}.map(\.value)
        transfers=transfers.filter {!$0.key.hasPrefix(id.uuidString)}
        for transfer in owned { await transfer.shutdown() }
        await vault(id).clear(); vaults[id]=nil
    }
    func backgroundEvents(_ identifier: String, completion: @escaping () -> Void) async throws {
        guard let id = identifier.components(separatedBy:".").compactMap(UUID.init(uuidString:)).first else { completion(); return }
        let transfer = try service(id,background:true); transfer.backgroundCompletion = completion; _ = transfer.session
        await transfer.reconnectPolicy()
        if await store.entry(id)==nil { await transfer.shutdown(); completion(); try? await archive.erase(id) }
    }
    func generations(_ entry: WebsiteEntry, candidate: String? = nil) -> [String] { ([candidate, "runtime", entry.activeGeneration].compactMap { $0 }) }
    func cached(_ id: UUID, url: URL, candidate: String? = nil) async throws -> ResourceRecord? {
        guard let e = await store.entry(id) else { return nil }
        return try await archive.record(id,url:url,generations:generations(e,candidate:candidate))
    }
    func obtain(_ id: UUID, url: URL, generation: String, expected: DownloadItem? = nil, forceNetwork: Bool = false, background: Bool = false, requestHeaders: [String:String] = [:]) async throws -> ResourceRecord {
        guard ["http","https"].contains(url.scheme), await store.entry(id) != nil else { throw ArchiveError.invalidURL }
        if !forceNetwork, let r = try await archive.record(id,url:url,generations:[generation]), expected?.expectedHash == nil || expected?.expectedHash == r.hash {
            let file=try await archive.object(id,hash:r.hash)
            if (try? await archive.hash(file).0)==r.hash { return r }
        }
        guard policy.online else { if let r = try await cached(id,url:url), !forceNetwork { return r }; throw ArchiveError.offline }
        let archiveEpoch=await archive.epoch(id)
        let epoch = policy.epoch
        let service = try service(id,background:background)
        let result: DownloadedResponse
        do {
            var headers=requestHeaders
            if let old=try await cached(id,url:url) {
                if let etag=old.headers["etag"] { headers["If-None-Match"]=etag }
                else if let modified=old.headers["last-modified"] { headers["If-Modified-Since"]=modified }
            }
            result = try await service.download(url,headers:headers,context:generation)
        }
        catch {
            if !forceNetwork, let r = try await cached(id,url:url), expected?.expectedHash == nil || expected?.expectedHash?.lowercased()==r.hash {
                let file=try await archive.object(id,hash:r.hash)
                let response=HTTPURLResponse(url:url,statusCode:r.status,httpVersion:"HTTP/1.1",headerFields:r.headers)!
                return try await archive.put(id,generation:generation,url:url,file:file,response:response,expectedHash:expected?.expectedHash,expectedBytes:expected?.expectedBytes,expectedEpoch:archiveEpoch)
            }
            throw error
        }
        defer { service.dispose(result) }
        await vault(id).receive(result.response)
        guard policy.online, policy.epoch == epoch else { throw ArchiveError.offline }
        if result.response.statusCode==304, let old=try await cached(id,url:url) {
            let original=try await archive.object(id,hash:old.hash)
            let response=HTTPURLResponse(url:url,statusCode:old.status,httpVersion:"HTTP/1.1",headerFields:old.headers)!
            return try await archive.put(id,generation:generation,url:url,file:original,response:response,expectedHash:expected?.expectedHash,expectedBytes:expected?.expectedBytes,expectedEpoch:archiveEpoch)
        }
        if [401,403].contains(result.response.statusCode) { throw ArchiveError.login }
        guard (200..<300).contains(result.response.statusCode), result.response.statusCode != 206 else { throw ArchiveError.http(result.response.statusCode,retryAfter:Self.retryAfter(result.response.value(forHTTPHeaderField:"Retry-After"))) }
        let mime = result.response.mimeType ?? "application/octet-stream"
        if let expectedMime = expected?.mime, !Self.mimeMatches(mime, expected:expectedMime) { throw mime == "text/html" ? ArchiveError.login : ArchiveError.unsupported("Unerwarteter Dateityp: \(mime)") }
        if mime == "text/html" {
            let handle = try FileHandle(forReadingFrom:result.file); let prefix = try handle.read(upToCount:128*1024) ?? Data(); try? handle.close()
            if Self.isLogin(prefix) { throw ArchiveError.login }
        }
        let vary = result.response.value(forHTTPHeaderField:"Vary")?.lowercased() ?? ""
        if vary.contains("*") || vary.split(separator:",").contains(where: { !["accept-encoding","accept-language"].contains($0.trimmingCharacters(in:.whitespaces)) }) { throw ArchiveError.unsupported("Diese Antwort benötigt nicht reproduzierbare Varianten (Vary).") }
        return try await archive.put(id,generation:generation,url:url,file:result.file,response:result.response,expectedHash:expected?.expectedHash,expectedBytes:expected?.expectedBytes,expectedEpoch:archiveEpoch)
    }
    static func mimeMatches(_ actual: String, expected: String) -> Bool {
        func normalized(_ value: String) -> String {
            let type = value.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() ?? ""
            switch type {
            case "application/javascript", "application/x-javascript", "text/javascript": return "text/javascript"
            default: return type
            }
        }
        return normalized(actual) == normalized(expected)
    }
    static func isLogin(_ data: Data) -> Bool { let text = String(decoding:data,as:UTF8.self).lowercased(); return text.contains("type=\"password\"") || text.contains("type='password'") }
    func raw(_ id: UUID, url: URL) async throws -> DownloadedResponse { try await service(id).download(url) }
    func response(_ id: UUID, mapper: URLMapper, request: LocalRequest, candidate: String? = nil, localOnly: Bool = false) async -> LocalResponse {
        guard let local = URL(string:mapper.localOrigin + request.target), let original = mapper.original(local), await store.entry(id) != nil else { return LocalResponse(status:403) }
        do {
            if !["GET","HEAD"].contains(request.method) {
                guard policy.online, !localOnly else { throw ArchiveError.offline }
                var r = URLRequest(url:original); r.httpMethod = request.method; r.httpBody = request.body
                r.setValue(request.headers["content-type"],forHTTPHeaderField:"Content-Type")
                if let ref = request.headers["referer"].flatMap(URL.init(string:)).flatMap(mapper.original) { r.setValue(URLMapper.origin(ref),forHTTPHeaderField:"Origin"); r.setValue(ref.absoluteString,forHTTPHeaderField:"Referer") }
                let service = try service(id); let (data,http) = try await service.request(r)
                if let target = http.url, URLMapper.key(target) != URLMapper.key(original) { return LocalResponse(status:303,headers:["Location":mapper.local(target).absoluteString]) }
                if http.mimeType == "text/html" { let rewritten = try DocumentRewriter(mapper:mapper).html(data,base:original); return LocalResponse(status:http.statusCode,headers:headers(mapper:mapper,mime:"text/html"),data:rewritten.0) }
                return LocalResponse(status:http.statusCode,headers:headers(mapper:mapper,mime:http.mimeType ?? "application/octet-stream"),data:data)
            }
            let record: ResourceRecord
            if localOnly || !policy.online {
                guard let existing = try await cached(id,url:original,candidate:candidate) else { throw ArchiveError.missing }; record = existing
            } else {
                var originalHeaders:[String:String]=[:]
                if let entry=await store.entry(id), URLMapper.origin(entry.scope) != URLMapper.origin(original) { originalHeaders["Origin"]=URLMapper.origin(entry.scope) }
                do { record = try await obtain(id,url:original,generation:"runtime",forceNetwork:true,requestHeaders:originalHeaders) }
                catch ArchiveError.login {
                    // Login HTML is displayed, but never promoted into the archive.
                    let service = try service(id), result = try await service.download(original); defer { service.dispose(result) }
                    await vault(id).receive(result.response)
                    let data = try Data(contentsOf:result.file)
                    guard ResourceBroker.isLogin(data), result.response.mimeType == "text/html" else { throw ArchiveError.login }
                    let rewritten = try DocumentRewriter(mapper:mapper).html(data,base:original)
                    return LocalResponse(status:200,headers:headers(mapper:mapper,mime:"text/html"),data:rewritten.0)
                } catch {
                    if let fallback = try await cached(id,url:original,candidate:candidate), !(error is ArchiveError) { record = fallback }
                    else { throw error }
                }
            }
            if request.headers["sec-fetch-mode"]=="cors", let entry=await store.entry(id), URLMapper.origin(entry.scope) != URLMapper.origin(original) {
                let allowed=record.headers["access-control-allow-origin"]
                guard allowed=="*" || allowed==URLMapper.origin(entry.scope) else { throw ArchiveError.unsupported("Die Originalseite erlaubt diesen originübergreifenden Zugriff nicht (CORS).") }
            }
            let file = try await archive.object(id,hash:record.hash)
            var h = headers(mapper:mapper,mime:record.mime)
            if let csp = record.headers["content-security-policy"] { h["Content-Security-Policy"] = h["Content-Security-Policy"]! + ", " + csp }
            if record.mime == "text/html" {
                let (data,_,issues) = try DocumentRewriter(mapper:mapper).html(Data(contentsOf:file),base:original)
                if !issues.isEmpty { await store.change(id) { $0.report = Array(Set($0.report + issues)).sorted() } }
                return LocalResponse(headers:h,data:data)
            }
            if record.mime.contains("javascript") { let (source,_) = ModuleScanner.transform(String(decoding:try Data(contentsOf:file),as:UTF8.self),base:original,mapper:mapper); return LocalResponse(headers:h,data:Data(source.utf8)) }
            if record.mime == "text/css" { return LocalResponse(headers:h,data:DocumentRewriter(mapper:mapper).css(try Data(contentsOf:file),base:original).0) }
            h["Accept-Ranges"] = "bytes"
            if let range = request.headers["range"] {
                guard let interval = Self.range(range,size:record.size) else { h["Content-Range"] = "bytes */\(record.size)"; return LocalResponse(status:416,headers:h) }
                h["Content-Range"] = "bytes \(interval.0)-\(interval.1)/\(record.size)"
                return LocalResponse(status:206,headers:h,file:file,offset:UInt64(interval.0),length:interval.1-interval.0+1)
            }
            return LocalResponse(headers:h,file:file,length:record.size)
        } catch {
            await store.toast(error.localizedDescription == ArchiveError.offline.localizedDescription ? error.localizedDescription : (error is ArchiveError ? error.localizedDescription : "Internet nicht verfügbar"))
            return LocalResponse(status:503,headers:["Content-Type":"text/plain"],data:Data())
        }
    }
    private func headers(mapper: URLMapper, mime: String) -> [String:String] {
        ["Content-Type":mime + (["text/html","text/css"].contains(mime) ? "; charset=utf-8" : ""),
         "Content-Security-Policy":"default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; worker-src 'none'; object-src 'none'; frame-src 'self'; base-uri 'self'; form-action 'self'",
         "X-Content-Type-Options":"nosniff"]
    }
    static func retryAfter(_ value:String?) -> TimeInterval? {
        guard let value else { return nil }; if let seconds=Double(value),seconds>=0 { return seconds }
        let format=DateFormatter(); format.locale=Locale(identifier:"en_US_POSIX"); format.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from:value).map { max(0,$0.timeIntervalSinceNow) }
    }
    static func range(_ text: String, size: Int64) -> (Int64,Int64)? {
        guard text.hasPrefix("bytes="), !text.contains(","), size > 0 else { return nil }
        let parts = text.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false); guard parts.count == 2 else { return nil }
        if parts[0].isEmpty { guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }; return (max(0,size-suffix),size-1) }
        guard let start = Int64(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size-1 : (Int64(parts[1]) ?? -1)
        guard end >= start else { return nil }; return (start,min(end,size-1))
    }
}
