import Foundation
import WebKit
import Combine
import SwiftUI

@MainActor final class ReplaySession: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private var server: LocalContentServer?
    private let store: LibraryStore
    private let entry: WebsiteEntry
    private let file: URL
    @Published var error: String?
    private var closed=false
    init(entry:WebsiteEntry,file:URL,store:LibraryStore) {
        self.entry=entry; self.file=file; self.store=store
        let config=WKWebViewConfiguration()
        config.websiteDataStore=WKWebsiteDataStore(forIdentifier:entry.id)
        config.limitsNavigationsToAppBoundDomains=true
        config.allowsInlineMediaPlayback=true; config.mediaTypesRequiringUserActionForPlayback=[]
        webView=WKWebView(frame:.zero,configuration:config)
        super.init(); webView.navigationDelegate=self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }
    func start() async throws {
        let port=entry.port
        let rules:[[String:Any]]=[
            ["trigger":["url-filter":"^https?://"],"action":["type":"block"]],
            ["trigger":["url-filter":"^wss?://"],"action":["type":"block"]],
            ["trigger":["url-filter":"^http://127\\.0\\.0\\.1:\(port)/"],"action":["type":"ignore-previous-rules"]]
        ]
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:rules),as:UTF8.self)
        if let list=try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"replay-local-\(port)",encodedContentRuleList:encoded) { webView.configuration.userContentController.add(list) }
        guard !closed else { return }
        let archive=file
        let assets=Bundle.main.resourceURL!.appendingPathComponent("Replay")
        let original=entry.url.absoluteString
        let collection=entry.waczFile ?? entry.id.uuidString
        server=LocalContentServer(port:port) { request in
            let path=URLComponents(string:request.target)?.path ?? ""
            let csp="default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' data: blob:; connect-src 'self' blob:; frame-src 'self' data: blob:; worker-src 'self' blob:; object-src 'self' data: blob:"
            let headers=["Content-Security-Policy":csp,"X-Content-Type-Options":"nosniff"]
            if path=="/" {
                func attr(_ s:String)->String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"<",with:"&lt;") }
                let html="""
                <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden}replay-web-page{display:block;width:100%;height:100%}</style><script src="/ui.js"></script></head><body><replay-web-page source="/archive/\(attr(collection))" url="\(attr(original))" replayBase="/replay/" embed="replayonly" noCache config='{"liveRedirectOnNotFound":false}'></replay-web-page></body></html>
                """
                return LocalResponse(headers:headers.merging(["Content-Type":"text/html; charset=utf-8"],uniquingKeysWith:{$1}),data:Data(html.utf8))
            }
            if path=="/replay/" || path=="/replay/index.html" {
                let html="<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><script src=\"/ui.js\"></script></head><body><replay-app-main></replay-app-main></body></html>"
                return LocalResponse(headers:headers.merging(["Content-Type":"text/html; charset=utf-8"],uniquingKeysWith:{$1}),data:Data(html.utf8))
            }
            if path.hasPrefix("/archive/") {
                guard let size=(try? archive.resourceValues(forKeys:[.fileSizeKey]))?.fileSize else { return LocalResponse(status:404) }
                var start:Int64=0,end=Int64(size)-1,status=200
                if let range=request.headers["range"] {
                    guard range.hasPrefix("bytes="),!range.contains(",") else { return LocalResponse(status:416) }
                    let parts=range.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
                    guard parts.count==2 else { return LocalResponse(status:416) }
                    if parts[0].isEmpty,let suffix=Int64(parts[1]),suffix>0 { start=max(0,Int64(size)-suffix) }
                    else {
                        guard let n=Int64(parts[0]),n>=0 else { return LocalResponse(status:416) }; start=n
                        if !parts[1].isEmpty { guard let n=Int64(parts[1]) else { return LocalResponse(status:416) }; end=min(end,n) }
                    }
                    guard start<=end,start<Int64(size) else { return LocalResponse(status:416,headers:["Content-Range":"bytes */\(size)"]) }; status=206
                }
                var h=headers; h["Content-Type"]="application/wacz"; h["Accept-Ranges"]="bytes"
                if status==206 { h["Content-Range"]="bytes \(start)-\(end)/\(size)" }
                return LocalResponse(status:status,headers:h,file:archive,offset:UInt64(start),length:end-start+1)
            }
            let name=path=="/ui.js" ? "ui.js" : (path=="/replay/sw.js" || path=="/sw.js") ? "sw.js" : ""
            if !name.isEmpty,let data=try? Data(contentsOf:assets.appendingPathComponent(name)) {
                return LocalResponse(headers:["Content-Type":"application/javascript","Service-Worker-Allowed":"/","Content-Security-Policy":csp],data:data)
            }
            // The service worker serves all recorded URLs. Never fetch live data here.
            return LocalResponse(status:404,headers:headers)
        }
        try await server!.start()
        guard !closed else { server?.stop(); return }
        webView.load(URLRequest(url:URL(string:"http://127.0.0.1:\(port)/")!))
    }
    func close() { closed=true; webView.stopLoading(); webView.navigationDelegate=nil; server?.stop(); server=nil }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        let url=navigationAction.request.url
        if navigationAction.navigationType == .linkActivated, let requested=url?.absoluteString,
           let pages=entry.waczPages, !pages.isEmpty,
           let range=requested.range(of:"/https?://",options:.regularExpression) {
            let original=String(requested[requested.index(after:range.lowerBound)...]).components(separatedBy:"#")[0]
            if !pages.contains(original) {
                store.toast(store.online ? "Diese Seite ist im Archiv nicht gespeichert." : ArchiveError.offline.localizedDescription)
                decisionHandler(.cancel); return
            }
        }
        let allowed=url?.host=="127.0.0.1" && url?.port==Int(entry.port) || url?.scheme=="about" || url?.scheme=="blob"
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError e:Error) { if !closed { error=e.localizedDescription } }
}
struct ReplayScreen:View {
    @ObservedObject private var store:LibraryStore
    @StateObject private var session:ReplaySession
    let environment:AppEnvironment
    let onReturn:()->Void
    init(entry:WebsiteEntry,file:URL,environment:AppEnvironment,onReturn:@escaping ()->Void) { _session=StateObject(wrappedValue:ReplaySession(entry:entry,file:file,store:environment.store)); self.onReturn=onReturn; self.environment=environment; store=environment.store }
    var body:some View {
        ReplayContent(session:session,onReturn:onReturn).ignoresSafeArea(edges:.bottom)
            .overlay(alignment:.bottom) { if let error=session.error ?? store.notice { Text(error).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)).padding() } }
            .task { environment.replay=session; do { try await session.start() } catch { session.error=error.localizedDescription } }
            .onDisappear { session.close(); environment.replay=nil }
    }
}
struct ReplayContent:UIViewRepresentable {
    @ObservedObject var session:ReplaySession
    let onReturn:()->Void
    func makeUIView(context:Context)->NativeViewerContainer { NativeViewerContainer(webView:session.webView,onReturn:onReturn) }
    func updateUIView(_ view:NativeViewerContainer,context:Context) { view.onReturn=onReturn }
}
