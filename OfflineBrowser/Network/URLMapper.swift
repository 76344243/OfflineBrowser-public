import Foundation
struct URLMapper {
    let port: UInt16
    let token: String
    var localOrigin: String { "http://127.0.0.1:\(port)" }
    static func origin(_ url: URL) -> String {
        let scheme=url.scheme?.lowercased() ?? "https"
        let port=url.port.flatMap { ($0==80 && scheme=="http") || ($0==443 && scheme=="https") ? nil : $0 }
        return "\(scheme)://\(url.host?.lowercased() ?? "")\(port.map { ":\($0)" } ?? "")"
    }
    static func key(_ url: URL) -> String { var c = URLComponents(url: url, resolvingAgainstBaseURL: true)!; c.fragment = nil; if (c.scheme=="http" && c.port==80) || (c.scheme=="https" && c.port==443) { c.port=nil }; c.user = nil; c.password = nil; return c.url!.absoluteString }
    static func encode(_ text: String) -> String { Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ text: String) -> String? { let s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); return Data(base64Encoded: s + String(repeating: "=", count: (4-s.count%4)%4)).flatMap { String(data: $0, encoding: .utf8) } }
    func local(_ original: URL) -> URL {
        var c = URLComponents(url: original, resolvingAgainstBaseURL: true)!
        let path = "/t/\(token)/o/\(Self.encode(Self.origin(original)))" + (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath)
        c.scheme = "http"; c.host = "127.0.0.1"; c.port = Int(port); c.user = nil; c.password = nil; c.percentEncodedPath = path
        return c.url!
    }
    func original(_ local: URL) -> URL? {
        guard local.host == "127.0.0.1", local.port == Int(port), let c = URLComponents(url: local, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = "/t/\(token)/o/"; guard c.percentEncodedPath.hasPrefix(prefix) else { return nil }
        let rest = String(c.percentEncodedPath.dropFirst(prefix.count)); guard let slash = rest.firstIndex(of: "/"), let origin = Self.decode(String(rest[..<slash])) else { return nil }
        return URL(string: origin + rest[slash...] + (c.percentEncodedQuery.map { "?" + $0 } ?? "") + (c.percentEncodedFragment.map { "#" + $0 } ?? ""))
    }
    static func address(_ raw: String) throws -> URL {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s.contains("://") ? s : "https://" + s), ["http", "https"].contains(u.scheme), u.host != nil, u.user == nil, u.password == nil else { throw ArchiveError.invalidURL }
        return u
    }
}
