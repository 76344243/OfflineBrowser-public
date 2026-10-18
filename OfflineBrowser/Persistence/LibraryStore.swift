import Foundation
import Combine

@MainActor final class LibraryStore: ObservableObject {
    @Published var entries: [WebsiteEntry] = []
    @Published var online = true
    @Published var checkingLibrary=true
    @Published var transferBytes:[UUID:[String:Int64]]=[:]
    private(set) var readFailure=false
    @Published var notice: String?
    @Published var availableBytes: Int64?
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineBrowser")
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: self.root.appendingPathComponent("library.json")) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard snapshot.version==1 else { throw ArchiveError.unsupported("Unbekannte Bibliotheksversion. Die Datei wird nicht überschrieben.") }
                entries = snapshot.entries; online = snapshot.online
            }
            for i in entries.indices where entries[i].busy { entries[i].phase = .pausedUser; entries[i].message = "Fortsetzung möglich" }
            // A terminated app may leave a reset in progress. Do not keep the
            // card permanently disabled; the next launch must allow retrying it.
            for i in entries.indices where entries[i].phase == .resetting {
                entries[i].phase = .none
                entries[i].message = "Löschung wurde unterbrochen · erneut möglich"
            }
        } catch { readFailure=true; notice = "Bibliothek konnte nicht gelesen werden: \(error.localizedDescription)" }
        capacity()
    }
    private struct Snapshot: Codable { var version = 1; var entries: [WebsiteEntry]; var online: Bool }
    func save() {
        guard !readFailure else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Snapshot(entries: entries, online: online)).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        } catch { notice = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }
    func entry(_ id: UUID) -> WebsiteEntry? { entries.first { $0.id == id } }
    func change(_ id: UUID, _ edit: (inout WebsiteEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        edit(&entries[i]); save()
    }
    func add(_ result: ProbeResult) -> UUID {
        let used = Set(entries.map(\.port))
        let port = (21000...59000).map { UInt16($0) }.first { !used.contains($0) }!
        var e = WebsiteEntry(url: result.url, scope: result.url.deletingLastPathComponent(), port: port)
        if result.url.path.isEmpty || result.url.path == "/" { e.scope = result.url }
        e.kit = result.kit; e.kitURL = result.kitURL
        e.allowedOrigins = [URLMapper.origin(result.url)] + (result.kit?.allowedResourceOrigins ?? [])
        if let kit = result.kit, let base = result.kitURL { e.scope = URL(string: kit.scope, relativeTo: base)?.absoluteURL ?? e.scope }
        if result.loginRequired { e.phase = .needsLogin }
        e.message = result.loginRequired ? "Anmeldung erforderlich" : (result.kit == nil ? "Versuchter Download · Leerlauf" : "Kit unterstützt · Leerlauf")
        entries.append(e); save(); return e.id
    }
    func capacity() { availableBytes = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }
    func toast(_ message: String) {
        notice = message
        Task { try? await Task.sleep(for: .seconds(6)); if notice == message { notice = nil } }
    }
}
