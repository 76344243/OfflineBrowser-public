import Foundation
import Combine
@MainActor final class AppEnvironment: ObservableObject {
    static let shared=AppEnvironment()
    let store: LibraryStore
    let archive: ArchiveStore
    let policy: NetworkPolicy
    let broker: ResourceBroker
    let downloads: DownloadCoordinator
    let crawler: CrawlerCoordinator
    var viewer: WebsiteSession?
    var replay: ReplaySession?
    init() {
        #if DEBUG
        let testFlag=CommandLine.arguments.first { $0.hasSuffix("-test") }
        let testRoot=testFlag.map { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("OfflineBrowserTests/"+$0) }
        if CommandLine.arguments.contains("--ui-reset"), let testRoot { try? FileManager.default.removeItem(at:testRoot) }
        store = LibraryStore(root:testRoot)
        #else
        store = LibraryStore()
        #endif
         archive = ArchiveStore(root:store.root); policy = NetworkPolicy()
        policy.setOnline(store.online); broker = ResourceBroker(store:store,archive:archive,policy:policy)
        downloads = DownloadCoordinator(store:store,broker:broker,archive:archive,policy:policy)
        crawler = CrawlerCoordinator(store:store,archive:archive)
        downloads.crawler = crawler
        downloads.isViewing = { [weak self] in self?.viewer != nil || self?.replay != nil }
    }
    func reconcile() async {
        for entry in store.entries where entry.waczFile != nil {
            guard let file = crawler.file(entry), FileManager.default.fileExists(atPath:file.path) else {
                store.change(entry.id) { e in
                    e.waczFile = nil; e.waczPages = nil; e.crawlerJob = nil
                    e.phase = .none; e.verified = false; e.bytes = 0
                    e.message = "Browsertrix-Archiv fehlt · erneut möglich"
                }
                continue
            }
        }
        for entry in store.entries where entry.activeGeneration != nil && entry.waczFile == nil && entry.crawlerJob == nil {
            let generation=entry.activeGeneration!
            let records=(try? await archive.records(entry.id,generation:generation)) ?? []
            var missing=records.isEmpty
            for record in records {
                if (try? await archive.record(entry.id,url:URL(string:record.url)!,generations:[generation])) == nil { missing=true }
            }
            if missing {
                let items=entry.kit?.resources.compactMap { resource -> DownloadItem? in
                    guard let u=URL(string:resource.url,relativeTo:entry.kitURL)?.absoluteURL else { return nil }
                    return DownloadItem(url:u,expectedHash:resource.sha256,expectedBytes:resource.bytes,mime:resource.mime)
                } ?? [DownloadItem(url:entry.startURL)]
                store.change(entry.id) { e in e.verified=false; e.phase = .pausedUser; e.message="Archivdateien fehlen · Fortsetzung möglich"; e.job=DownloadJob(id:generation,items:items,refreshing:true,previousMode:entry.mode) }
            }
        }
        store.checkingLibrary=false
    }
}
