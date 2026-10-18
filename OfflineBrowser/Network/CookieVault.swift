import Foundation
import Security
actor CookieVault {
    let id: UUID
    private var cookies: [HTTPCookie] = []
    private var active=true
    init(id: UUID) {
        self.id = id
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"OfflineBrowser.cookies", kSecAttrAccount as String:id.uuidString, kSecReturnData as String:true]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String:Any]] {
            cookies = list.compactMap { dict in var props: [HTTPCookiePropertyKey:Any] = [:]; for (k,v) in dict { props[HTTPCookiePropertyKey(k)] = v }; if let expires = dict["Expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: expires) }; return HTTPCookie(properties: props) }
        }
    }
    func header(_ url: URL) -> String? {
        guard active else { return nil }
        let host = url.host?.lowercased() ?? "", path = url.path.isEmpty ? "/" : url.path
        let valid = cookies.filter { c in
            let domain = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let match = c.domain.hasPrefix(".") ? (host == domain || host.hasSuffix("." + domain)) : host == domain
            return match && (path==c.path || (path.hasPrefix(c.path) && (c.path.hasSuffix("/") || path.dropFirst(c.path.count).hasPrefix("/")))) && (!c.isSecure || url.scheme == "https") && (c.expiresDate == nil || c.expiresDate! > Date())
        }.sorted { $0.path.count > $1.path.count }
        return valid.isEmpty ? nil : valid.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    func receive(_ response: HTTPURLResponse) {
        guard active, let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String:String]()) { $0[String(describing:$1.key)] = String(describing:$1.value) }
        for c in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            cookies.removeAll { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            cookies.append(c)
        }
        persist()
    }
    func clear() {
        active=false; cookies = []; SecItemDelete([kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"OfflineBrowser.cookies", kSecAttrAccount as String:id.uuidString] as CFDictionary)
    }
    private func persist() {
        let list = cookies.map { c -> [String:Any] in var props: [String:Any] = [:]; for (k,v) in c.properties ?? [:] { if let d = v as? Date { props[k.rawValue] = d.timeIntervalSince1970 } else if JSONSerialization.isValidJSONObject(["v":v]) { props[k.rawValue] = v } }; return props }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        let key: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"OfflineBrowser.cookies", kSecAttrAccount as String:id.uuidString]
        if SecItemUpdate(key as CFDictionary, [kSecValueData as String:data] as CFDictionary) == errSecItemNotFound { var q = key; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; SecItemAdd(q as CFDictionary, nil) }
    }
}
