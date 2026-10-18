import Foundation
import WebKit
import Combine

@MainActor final class WebsiteSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let entryID: UUID
    let store: LibraryStore
    let broker: ResourceBroker
    let mapper: URLMapper
    let webView: WKWebView
    var server: LocalContentServer?
    @Published var error: String?
    @Published var ready = false
    private var closed=false
    private let localOnly: Bool
    private let candidate: String?
    private let owner=UUID().uuidString
    private(set) var issues: [String] = []
    private var navigationContinuation: CheckedContinuation<Void,Error>?
    init(entry: WebsiteEntry, store: LibraryStore, broker: ResourceBroker, localOnly: Bool = false, candidate: String? = nil) {
        entryID = entry.id; self.store = store; self.broker = broker; self.localOnly = localOnly; self.candidate = candidate ?? entry.activeGeneration
        mapper = URLMapper(port:entry.port,token:UUID().uuidString)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier:entry.id)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let json = ["origin":mapper.localOrigin,"token":mapper.token,"originalOrigin":URLMapper.origin(entry.scope)]
        let serialized = String(decoding:try! JSONSerialization.data(withJSONObject:json),as:UTF8.self)
        let script = (try? String(contentsOf:Bundle.main.url(forResource:"controlled",withExtension:"js",subdirectory:"Bridge")!,encoding:.utf8)) ?? ""
        config.userContentController.addUserScript(WKUserScript(source:script.replacingOccurrences(of:"__OFFLINE_CONFIG__",with:serialized),injectionTime:.atDocumentStart,forMainFrameOnly:false))
        webView = WKWebView(frame:.zero,configuration:config)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        config.userContentController.add(self,name:"archiveEvents")
        webView.isInspectable = false
    }
    func start() async throws {
        guard !closed else { throw CancellationError() }; try Task.checkCancellation()
        let pattern = "^http://127\\.0\\.0\\.1:\(mapper.port)/t/\(mapper.token)/"
        let rules: [[String:Any]] = [["trigger":["url-filter":"^https?://"],"action":["type":"block"]], ["trigger":["url-filter":"^wss?://"],"action":["type":"block"]], ["trigger":["url-filter":pattern],"action":["type":"ignore-previous-rules"]]]
        let json = String(decoding:try JSONSerialization.data(withJSONObject:rules),as:UTF8.self)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"entry-\(entryID.uuidString)",encodedContentRuleList:json)
        guard !closed else { throw CancellationError() }; try Task.checkCancellation()
        if let list { webView.configuration.userContentController.add(list) }
        let broker = broker, id = entryID, mapper = mapper, candidate = candidate, localOnly = localOnly
        server = LocalContentServer(port:mapper.port) { request in await broker.response(id,mapper:mapper,request:request,candidate:candidate,localOnly:localOnly) }
        await broker.archive.pin(entryID,owner:owner,generation:candidate)
        guard !closed else { await broker.archive.unpin(entryID,owner:owner); throw CancellationError() }
        try await server!.start()
        guard !closed else { server?.stop(); await broker.archive.unpin(entryID,owner:owner); throw CancellationError() }; ready = true
    }
    func load(_ url: URL) async throws {
        guard !closed,ready else { throw CancellationError() }; try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation?.resume(throwing:CancellationError()); navigationContinuation = continuation
            webView.load(URLRequest(url:mapper.local(url)))
        }
    }
    func close() { closed=true; if let local=webView.url,let original=mapper.original(local),!localOnly { store.change(entryID) { $0.lastVisitedURL=original } }; webView.stopLoading(); webView.configuration.userContentController.removeScriptMessageHandler(forName:"archiveEvents"); server?.stop(); server = nil; navigationContinuation?.resume(throwing:CancellationError()); navigationContinuation = nil; let archive=broker.archive, id=entryID, owner=owner; Task { await archive.unpin(id,owner:owner) } }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let url = message.frameInfo.request.url, mapper.original(url) != nil, let body = message.body as? [String:String] else { return }
        if body["kind"] == "unsupported", let reason = body["reason"] { issues.append(reason); store.change(entryID) { $0.report = Array(Set($0.report + [reason])).sorted() } }
        if body["kind"] == "missing" { issues.append("Fehlende Ressource"); store.toast(store.online ? "Internet nicht verfügbar" : ArchiveError.offline.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let local = action.request.url, let original = mapper.original(local) else {
            store.toast("Diese Navigation gehört nicht zum gespeicherten Website-Bereich."); return .cancel
        }
        guard let entry = store.entry(entryID) else { return .cancel }
        let inScope = URLMapper.origin(original) == URLMapper.origin(entry.scope) && original.path.hasPrefix(entry.scope.path)
        if action.targetFrame?.isMainFrame == false, URLMapper.origin(original) != URLMapper.origin(entry.scope) { issues.append("Originübergreifende Frames werden nicht unterstützt."); store.change(entryID) { $0.report.append("Originübergreifende Frames werden nicht unterstützt.") }; return .cancel }
        if action.targetFrame?.isMainFrame != false, !inScope { store.toast("Externer Link. Legen Sie diese Website als eigenen Eintrag an."); return .cancel }
        if localOnly || !store.online {
            if !["GET","HEAD"].contains(action.request.httpMethod ?? "GET") { store.toast(ArchiveError.offline.localizedDescription); return .cancel }
            if (try? await broker.cached(entryID,url:original,candidate:candidate)) == nil { store.toast(ArchiveError.offline.localizedDescription); navigationContinuation?.resume(throwing:ArchiveError.missing); navigationContinuation = nil; return .cancel }
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navigationContinuation?.resume(); navigationContinuation = nil }
    func webView(_ webView:WKWebView,decidePolicyFor response:WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http=response.response as? HTTPURLResponse,http.statusCode>=400 {
            store.toast(store.online ? "Internet nicht verfügbar" : ArchiveError.offline.localizedDescription)
            navigationContinuation?.resume(throwing:ArchiveError.http(http.statusCode)); navigationContinuation=nil; return .cancel
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationContinuation?.resume(throwing:error); navigationContinuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationContinuation?.resume(throwing:error); navigationContinuation = nil }
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
}
