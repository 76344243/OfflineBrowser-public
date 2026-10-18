import Foundation
import SwiftSoup

struct SupportProbe {
    let broker: ResourceBroker
    func run(_ raw: String, id: UUID) async throws -> ProbeResult {
        let original = try URLMapper.address(raw)
        let download: DownloadedResponse
        do { download = try await broker.raw(id,url:original) }
        catch {
            if raw.contains("://") { throw error }
            var fallback = URLComponents(url:original,resolvingAgainstBaseURL:false)!; fallback.scheme = "http"
            download = try await broker.raw(id,url:fallback.url!)
        }
        let service = try await broker.service(id); defer { service.dispose(download) }
        let url = download.response.url ?? original
        if [401,403].contains(download.response.statusCode) { return ProbeResult(url:url,loginRequired:true) }
        guard (200..<300).contains(download.response.statusCode), download.response.mimeType == "text/html" else { throw ArchiveError.unsupported("Die Adresse liefert keine unterstützte HTML-Webseite.") }
        let data = try Data(contentsOf:download.file)
        if ResourceBroker.isLogin(data) { return ProbeResult(url:url,loginRequired:true) }
        let doc = try SwiftSoup.parse(String(decoding:data,as:UTF8.self),url.absoluteString)
        var candidates: [URL] = []
        if let link = try doc.select("link[rel=offline-kit]").first(), let u = URL(string:try link.attr("href"),relativeTo:url)?.absoluteURL { candidates.append(u) }
        if let u = URL(string:"/.well-known/offline-kit.json",relativeTo:url)?.absoluteURL { candidates.append(u) }
        for u in candidates {
            let result: DownloadedResponse
            do { result = try await broker.raw(id,url:u) } catch { continue }
            defer { service.dispose(result) }
            if result.response.statusCode == 200 {
                do {
                    let kit = try JSONDecoder().decode(OfflineKit.self,from:Data(contentsOf:result.file))
                    try Self.validate(kit,base:u)
                    return ProbeResult(url:url,kitURL:u,kit:kit)
                } catch { return ProbeResult(url:url,reason:"Kit nicht kompatibel: \(error.localizedDescription)") }
            }
        }
        return ProbeResult(url:url)
    }
    static func validate(_ kit: OfflineKit, base: URL) throws {
        guard kit.schemaVersion == 1, !kit.revision.isEmpty, !kit.resources.isEmpty else { throw ArchiveError.unsupported("Unbekannte Kit-Version oder leeres Inventar.") }
        let allowed = Set([URLMapper.origin(base)] + (kit.allowedResourceOrigins ?? []))
        var urls = Set<String>()
        for item in kit.resources {
            guard let u = URL(string:item.url,relativeTo:base)?.absoluteURL, ["http","https"].contains(u.scheme), allowed.contains(URLMapper.origin(u)), u.user == nil, u.password == nil,
                  let hash = item.sha256, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }), (item.bytes ?? 0) >= 0 else { throw ArchiveError.unsupported("Ungültiger Ressourcen-Eintrag oder nicht deklarierte Herkunft.") }
            guard urls.insert(URLMapper.key(u)).inserted else { throw ArchiveError.unsupported("Doppelte Ressourcen-Adresse im Kit.") }
        }
        guard let start = URL(string:kit.offlineEntry ?? kit.entry,relativeTo:base)?.absoluteURL, urls.contains(URLMapper.key(start)) else { throw ArchiveError.unsupported("Der Offline-Einstieg fehlt im Inventar.") }
    }
}
