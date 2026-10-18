import Foundation
import Combine
@MainActor final class AppEnvironment: ObservableObject {
    static let shared=AppEnvironment()
    let store: LibraryStore
    let archive: ArchiveStore
    let policy: NetworkPolicy
    let broker: ResourceBroker
    let downloads: DownloadCoordinator
    var viewer: WebsiteSession?
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
    }
    func reconcile() async {
        for entry in store.entries where entry.activeGeneration != nil {
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
