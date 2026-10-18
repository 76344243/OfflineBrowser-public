import Foundation

enum StorageMode: String, Codable { case idle, full, continuous }
enum JobPhase: String, Codable { case resetting, none, discovering, downloading, retrying, pausedUser, pausedStorage, pausedOffline, needsLogin, verifying, ready, unsupported }
struct KitResource: Codable { var url: String; var mime: String?; var bytes: Int64?; var sha256: String? }
struct OfflineCheck: Codable { var path: String; var selector: String; var description: String? }
struct OfflineKit: Codable {
    var schemaVersion: Int
    var revision: String
    var scope: String
    var entry: String
    var offlineEntry: String?
    var resources: [KitResource]
    var allowedResourceOrigins: [String]?
    var offlineChecks: [OfflineCheck]?
}
struct WebsiteEntry: Codable, Identifiable {
    var id = UUID()
    var url: URL
    var scope: URL
    var port: UInt16
    var mode: StorageMode = .idle
    var phase: JobPhase = .none
    var kitURL: URL?
    var kit: OfflineKit?
    var activeGeneration: String?
    var job: DownloadJob?
    // Optional Browsertrix/WACZ state. Optional fields keep libraries created
    // by earlier app versions decodable without a migration step.
    var waczPages: [String]?
    var waczFile: String?
    var crawlerJob: CrawlerJob?
    var bytes: Int64 = 0
    var updateAvailable = false
    var lastUpdate: Date?
    var lastVisitedURL:URL?
    var message = "Leerlauf"
    var report: [String] = []
    var verified = false
    var allowedOrigins: [String] = []
    var startURL: URL { guard let kit, let kitURL else { return url }; return URL(string: kit.offlineEntry ?? kit.entry, relativeTo: kitURL)?.absoluteURL ?? url }
    var busy: Bool { [.discovering, .downloading, .retrying, .verifying].contains(phase) || crawlerJob != nil }
    var downloaded: Int { job?.items.filter { $0.done }.count ?? 0 }
    var total: Int { job?.items.count ?? 0 }
}
struct DownloadItem: Codable, Identifiable {
    var url: URL
    var expectedHash: String?
    var expectedBytes: Int64?
    var mime: String?
    var done = false
    var attempts = 0
    var retryAt: Date?
    var lastError: String?
    var id: String { URLMapper.key(url) }
}
struct DownloadJob: Codable {
    var id = UUID().uuidString
    var items: [DownloadItem] = []
    var refreshing = false
    var previousMode: StorageMode = .idle
    var previousKit: OfflineKit?
    var failures: [String] = []
    var storageCapacityAtPause: Int64?
}
struct ResourceRecord: Codable {
    var url: String
    var generation: String
    var hash: String
    var size: Int64
    var mime: String
    var status: Int
    var headers: [String: String]
    var saved = Date()
}
struct ProbeResult {
    var url: URL
    var kitURL: URL?
    var kit: OfflineKit?
    var loginRequired = false
    var reason: String?
}
enum ArchiveError: LocalizedError {
    case offline, missing, login, unsupported(String), http(Int, retryAfter: TimeInterval? = nil), storage, integrity, invalidURL
    var errorDescription: String? {
        switch self {
        case .offline, .missing: return "Im offline Modus werden keine Daten aus dem Internet geladen."
        case .login: return "Anmeldung erforderlich. Öffnen Sie die Seite und melden Sie sich an."
        case .unsupported(let s): return s
        case .http(let status,_): return "Serverantwort \(status)."
        case .storage: return "Nicht genügend freier Speicher. Geben Sie Speicher frei, um fortzusetzen."
        case .integrity: return "Die Datei stimmt nicht mit dem Manifest überein."
        case .invalidURL: return "Bitte eine gültige HTTP- oder HTTPS-Adresse eingeben."
        }
    }
}
