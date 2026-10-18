import SwiftUI
import WebKit

struct LibraryView: View {
    let environment: AppEnvironment
    @ObservedObject var store: LibraryStore
    @State private var address=""
    @State private var probing=false
    @State private var probe:ProbeResult?
    @State private var probeID:UUID?
    @State private var presented:WebsiteEntry?
    @State private var confirmation:Confirmation?
    @State private var showingReport:WebsiteEntry?
    @AppStorage(CrawlerConfiguration.depthKey) private var crawlDepth = CrawlerConfiguration.defaultDepth
    @FocusState private var addressFocused:Bool
    @Environment(\.scenePhase) private var scene
    init(environment:AppEnvironment) { self.environment=environment; store=environment.store }
    private struct Confirmation:Identifiable { let id=UUID(); var text:String; var actions:[Action]; var onCancel:(()->Void)? = nil }
    private struct Action:Identifiable { let id=UUID(); var title:String; var destructive=false; var run:()->Void }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:6) { Text("Ihre Webseiten.\nAuch ohne Internet.").font(.largeTitle.bold()); Text("Dauerhaft auf diesem Gerät gespeichert").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName:"externaldrive.badge.wifi").font(.system(size:32)).foregroundStyle(.teal).accessibilityHidden(true)
                    }
                    Picker("Internetzugriff",selection:Binding(get:{store.online},set:{environment.downloads.setOnline($0)})) { Label("Online",systemImage:"wifi").tag(true); Label("Offline",systemImage:"wifi.slash").tag(false) }.pickerStyle(.segmented).accessibilityIdentifier("networkMode")
                    HStack { Image(systemName:"internaldrive"); Text(store.availableBytes.map { "Verfügbarer Speicher: " + Self.bytes($0) } ?? "Verfügbarer Speicher unbekannt"); Spacer() }.font(.footnote).foregroundStyle(.secondary)
                    if let capacity=store.availableBytes, capacity<500*1024*1024 { Label("Nur noch wenig Speicher verfügbar.",systemImage:"exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                    GroupBox {
                        VStack(alignment:.leading,spacing:10) {
                            Label("Lokale Archivierung",systemImage:"internaldrive").font(.subheadline.weight(.semibold))
                            Text("Die Standardfunktion arbeitet vollständig auf diesem Gerät und benötigt keinen eigenen Server.").font(.footnote).foregroundStyle(.secondary)
                            Label("Browsertrix für komplexe Webseiten",systemImage:"server.rack").font(.subheadline.weight(.semibold))
                            Text("Optional kann ein eigener Browsertrix-Dienst JavaScript-lastige Seiten serverseitig erfassen. Das Ergebnis wird als WACZ-Datei lokal gespeichert und offline wiedergegeben.").font(.footnote).foregroundStyle(.secondary)
                            if environment.crawler.configured {
                                HStack {
                                    Text("Erfassungstiefe")
                                    Spacer()
                                    Picker("Erfassungstiefe",selection:$crawlDepth) {
                                        Text("Nur Startseite").tag(0)
                                        Text("2 Ebenen").tag(2)
                                        Text("3 Ebenen").tag(3)
                                        Text("5 Ebenen").tag(5)
                                        Text("Ohne Begrenzung").tag(-1)
                                    }.pickerStyle(.menu)
                                }.font(.footnote)
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    } label: { Text("ARCHIVIERUNGSOPTIONEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    VStack(alignment:.leading,spacing:10) {
                        Text("WEBSEITE HINZUFÜGEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing:10) {
                            TextField("https://beispiel.de",text:$address).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().focused($addressFocused).submitLabel(.go).onSubmit { checkAddress() }.accessibilityIdentifier("address")
                            Button(action:checkAddress) { if probing { ProgressView() } else { Image(systemName:"arrow.right").font(.headline) } }.buttonStyle(.borderedProminent).disabled(probing || address.isEmpty || !store.online).accessibilityLabel("Webseite prüfen").accessibilityIdentifier("checkAddress")
                        }.padding(12).background(.background,in:RoundedRectangle(cornerRadius:16))
                    }
                    if store.entries.isEmpty {
                        ContentUnavailableView("Ihre Bibliothek beginnt hier",systemImage:"globe",description:Text("Prüfen Sie eine Adresse und wählen Sie anschließend Vollständig oder Laufend sichern."))
                    }
                    ForEach(store.entries) { entry in entryCard(entry) }
                }.padding(20).frame(maxWidth:900).frame(maxWidth:.infinity)
            }
            .disabled(store.readFailure || store.checkingLibrary)
            .background(Color(uiColor:.systemGroupedBackground))
            .navigationTitle("OfflineBrowser").navigationBarTitleDisplayMode(.inline)
            .overlay(alignment:.bottom) { if let notice=store.notice { Text(notice).font(.callout).padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)).padding().allowsHitTesting(false).accessibilityIdentifier("notice") } }
            .confirmationDialog(confirmation?.text ?? "",isPresented:Binding(get:{confirmation != nil},set:{if !$0 { let cancelled=confirmation; confirmation=nil; cancelled?.onCancel?() }}),titleVisibility:.visible) {
                if let dialog=confirmation { ForEach(dialog.actions) { a in Button(a.title,role:a.destructive ? .destructive : nil) { confirmation=nil; a.run() } } }
                Button("Abbrechen",role:.cancel) { let cancelled=confirmation; confirmation=nil; cancelled?.onCancel?() }
            }
            .alert(probe?.kit != nil ? "Sicherung unterstützt" : (probe?.loginRequired == true ? "Anmeldung erforderlich" : "Kein Offline Kit"),isPresented:Binding(get:{probe != nil},set:{if !$0 { cancelProbe() }})) {
                Button(probe?.kit != nil ? "Ja" : (probe?.loginRequired == true ? "Eintrag zur Anmeldung anlegen" : "Versuchter Download")) { addProbed() }
                Button("Jetzt nicht",role:.cancel) { cancelProbe() }
            } message: { Text(probeText) }
            .fullScreenCover(item:$presented) { entry in
                if let file=environment.crawler.file(entry), FileManager.default.fileExists(atPath:file.path) {
                    ReplayScreen(entry:entry,file:file,environment:environment,onReturn:{ presented=nil })
                } else {
                    ViewerScreen(entry:entry,environment:environment,onReturn:{ presented=nil })
                }
            }
            .sheet(item:$showingReport) { entry in NavigationStack { List { Section("Bereich") { Text(entry.scope.absoluteString) }; Section("Prüfbericht") { ForEach(entry.report,id:\.self) { Text($0) }; if entry.report.isEmpty { Text("Noch keine Offline-Prüfung durchgeführt.") } } }.navigationTitle("Website-Prüfung").toolbar { Button("Schließen") { showingReport=nil } } } }
            .task { await environment.reconcile(); while !Task.isCancelled { await environment.downloads.tick(checkUpdates:scene == .active && environment.viewer == nil && environment.replay == nil); try? await Task.sleep(for:.seconds(store.entries.contains(where:{$0.busy}) ? 1 : 5)) } }
            .onChange(of:scene) { _,phase in if phase == .active { Task { await environment.downloads.tick() } } }
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("--architecture-test") { _=await ArchitectureTests(environment:environment).run() }
            if CommandLine.arguments.contains("--integration-test") { _=await IntegrationTests(environment:environment).run() }
        }
        #endif
    }
    private var probeText:String {
        guard let p=probe else { return "" }
        if p.loginRequired { return "Öffnen Sie den neuen Eintrag zur Anmeldung. Geschützte Dateien werden erst nach erfolgreicher Anmeldung gesichert." }
        if p.kit != nil { return "Die Sicherung der Seite wird vom Anbieter unterstützt. Möchten sie einen Eintrag anlegen?" }
        return "Die lokale Sicherung der Webseite wird nicht unterstützt. Wenden Sie sich an den Homepage Betreiber für die Integration eines Kits.\n\nSie können einen versuchten Download durchführen. Geprüfter Bereich: \(p.url.deletingLastPathComponent().absoluteString)\(p.reason.map { "\n"+$0 } ?? "")"
    }
    private func checkAddress() {
        addressFocused=false; guard !probing,store.online else { return }; probing=true
        Task {
            let temporary=UUID(); probeID=temporary
            do { probe=try await SupportProbe(broker:environment.broker).run(address,id:temporary) }
            catch { store.toast(error.localizedDescription); cancelProbe() }
            probing=false
        }
    }
    private func cancelProbe() { let id=probeID; probe=nil; probeID=nil; if let id { Task { await environment.broker.clear(id); try? await environment.archive.erase(id) } } }
    private func addProbed() {
        guard let result=probe else { return }; let id=store.add(result)
        if let reason=result.reason { store.change(id) { $0.report.append(reason) } }
        if result.loginRequired { store.change(id) { $0.mode = .continuous }; presented=store.entry(id) }
        cancelProbe(); address=""
    }
    private func entryCard(_ e:WebsiteEntry) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Button {
                addressFocused=false
                Task {
                    if e.waczFile != nil, let file=environment.crawler.file(e), !FileManager.default.fileExists(atPath:file.path) {
                        store.toast("Das lokale Browsertrix-Archiv ist nicht verfügbar."); return
                    }
                    if e.waczFile == nil && !store.online {
                        guard (try? await environment.broker.cached(e.id,url:e.startURL)) != nil else { store.toast(ArchiveError.offline.localizedDescription); return }
                    }
                    presented=store.entry(e.id) ?? e
                }
            } label: { HStack { Image(systemName:e.waczFile != nil ? "server.rack" : (e.kit == nil ? "globe" : "checkmark.shield")).font(.title2).foregroundStyle(.teal); Text(e.url.absoluteString).font(.headline).lineLimit(2).multilineTextAlignment(.leading); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.secondary) } }.buttonStyle(.plain).disabled(e.phase == .verifying || (e.mode == .idle && e.activeGeneration == nil && e.waczFile == nil && e.phase != .needsLogin)).accessibilityIdentifier("open-\(e.id)")
            HStack { Text(e.message).font(.subheadline).foregroundStyle(e.phase == .retrying || e.phase == .unsupported ? .orange : .secondary); Spacer(); Text(Self.bytes(e.bytes) + ((store.transferBytes[e.id]?.values.reduce(0,+) ?? 0)>0 ? " · "+Self.bytes(store.transferBytes[e.id]!.values.reduce(0,+))+" laden" : "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if let crawlerJob=e.crawlerJob {
                ProgressView(value:Double(crawlerJob.done),total:Double(max(1,crawlerJob.total))).tint(e.phase == .retrying ? .orange : .teal)
                Text("Browsertrix: \(crawlerJob.done) von \(max(1,crawlerJob.total)) Seiten").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if e.job != nil {
                ProgressView(value:Double(e.downloaded),total:Double(max(1,e.total))).tint(e.phase == .retrying ? .orange : .teal)
                Text("Elemente geladen: \(e.downloaded) von \(e.total)\(e.kit == nil ? " · weitere werden gesucht" : "")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:8) { modeButtons(e); utilityButtons(e) }
                VStack(alignment:.leading,spacing:8) { HStack { modeButtons(e) }; HStack { utilityButtons(e) } }
            }
            Button("Prüfbericht") { showingReport=e }.font(.caption).foregroundStyle(.secondary)
        }.disabled(e.phase == .resetting).padding(18).background(.background,in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(.primary.opacity(0.04)))
    }
    private func modeButtons(_ e:WebsiteEntry) -> some View {
        Group {
            Button(e.busy ? (e.crawlerJob != nil ? "Browsertrix · Abbrechen" : "Vollständig · Abbrechen") : (e.job != nil || e.crawlerJob != nil ? "Fortsetzen" : "Vollständig")) { full(e) }.tint(e.mode == .full || e.job != nil || e.crawlerJob != nil ? .teal : .gray).buttonStyle(.bordered)
            if environment.crawler.configured {
                Button(e.crawlerJob != nil ? "Browsertrix · Fortsetzen" : (e.waczFile != nil ? "Browsertrix · Aktualisieren" : "Browsertrix")) { browsertrix(e) }.tint(e.waczFile != nil || e.crawlerJob != nil ? .teal : .gray).buttonStyle(.bordered).disabled(e.busy && e.crawlerJob == nil)
            }
            Button("Laufend sichern") { continuous(e) }.tint(e.mode == .continuous && e.job == nil && e.crawlerJob == nil ? .teal : .gray).buttonStyle(.bordered).disabled(e.busy)
        }.font(.caption.weight(.semibold))
    }
    private func utilityButtons(_ e:WebsiteEntry) -> some View {
        Group {
            Button { confirmation=Confirmation(text:"Cache zurücksetzen? Die Wiedergabe dieses Eintrags wird beendet.",actions:[Action(title:"Zurücksetzen",destructive:true) { reset(e,mode:.continuous) }]) } label: { Image(systemName:"arrow.counterclockwise") }.disabled(e.mode != .continuous || e.job != nil || e.crawlerJob != nil).accessibilityLabel("Zurücksetzen")
            Button { Task { await environment.downloads.refresh(e.id) } } label: { Image(systemName:"arrow.triangle.2.circlepath"); if e.updateAvailable { Circle().fill(.teal).frame(width:6,height:6) } }.disabled(e.mode == .idle || e.job != nil || e.crawlerJob != nil || (e.waczFile != nil && !environment.crawler.configured) || !store.online).accessibilityLabel("Refresh")
            Button { confirmation=Confirmation(text:"Sind Sie sicher? Die gespeicherten Daten werden gelöscht und die Wiedergabe beendet.",actions:[Action(title:"Eintrag löschen",destructive:true) { reset(e,mode:.idle,delete:true) }]) } label: { Image(systemName:"trash") }.accessibilityLabel("Eintrag löschen")
        }.buttonStyle(.bordered).tint(.secondary)
    }
    private func full(_ e:WebsiteEntry) {
        if e.busy {
            environment.downloads.pause(e.id)
            confirmation=Confirmation(text:"Geladene Daten für Fortsetzung behalten oder löschen?",actions:[Action(title:"Behalten") {},Action(title:"Löschen",destructive:true) { Task { await environment.downloads.discard(e.id) } },Action(title:"Weiterladen") { environment.downloads.start(e.id) }],onCancel:{ environment.downloads.start(e.id) })
        } else if e.job != nil || e.crawlerJob != nil { environment.downloads.start(e.id) }
        else if e.mode == .full { idle(e) }
        else { environment.downloads.start(e.id) }
    }
    private func browsertrix(_ e:WebsiteEntry) {
        if e.busy {
            environment.downloads.pause(e.id)
            confirmation=Confirmation(text:"Die laufende Browsertrix-Erfassung anhalten? Der Serverjob bleibt für eine spätere Fortsetzung erhalten.",actions:[Action(title:"Behalten") {},Action(title:"Löschen",destructive:true) { Task { await environment.downloads.discard(e.id) } },Action(title:"Weiter") { environment.downloads.start(e.id) }],onCancel:{ environment.downloads.start(e.id) })
        } else if e.crawlerJob != nil {
            environment.downloads.start(e.id)
        } else {
            environment.downloads.startBrowsertrix(e.id,refresh:e.waczFile != nil)
        }
    }
    private func continuous(_ e:WebsiteEntry) {
        if e.mode == .continuous { idle(e) }
        else if e.mode == .full || e.job != nil || e.crawlerJob != nil || e.waczFile != nil { confirmation=Confirmation(text:"Bei Aktivierung laufender Speicherung wird der Website Cache vollständig gelöscht. Sind sie sicher?",actions:[Action(title:"Ja",destructive:true) { reset(e,mode:.continuous) },Action(title:"Nein") {}]) }
        else { store.change(e.id) { $0.mode = .continuous; $0.message="Laufend sichern · aktiv" } }
    }
    private func idle(_ e:WebsiteEntry) { confirmation=Confirmation(text:"Möchten Sie wirklich in den Leerlauf gehen? Dabei werden alle gesicherten Webseitendaten gelöscht. Die Wiedergabe wird beendet.",actions:[Action(title:"Ja",destructive:true) { reset(e,mode:.idle) },Action(title:"Nein") {}]) }
    private func reset(_ e:WebsiteEntry,mode:StorageMode,delete:Bool=false) { Task { await environment.downloads.reset(e.id,mode:mode,delete:delete) } }
    static func bytes(_ value:Int64) -> String { ByteCountFormatter.string(fromByteCount:value,countStyle:.file) }
}
struct ViewerScreen:View {
    let entry:WebsiteEntry
    let environment:AppEnvironment
    let onReturn:()->Void
    @ObservedObject private var store:LibraryStore
    @StateObject private var session:WebsiteSession
    init(entry:WebsiteEntry,environment:AppEnvironment,onReturn:@escaping ()->Void) { self.entry=entry; self.environment=environment; self.onReturn=onReturn; store=environment.store; _session=StateObject(wrappedValue:WebsiteSession(entry:entry,store:environment.store,broker:environment.broker)) }
    var body: some View {
        ZStack(alignment:.topTrailing) {
            WebContent(session:session,onReturn:onReturn).ignoresSafeArea(edges:.bottom)
            if let error=session.error { VStack { Spacer(); Text(error).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)); Spacer(); Button("Zur Übersicht") { onReturn() } }.padding().frame(maxWidth:.infinity) }
        }.overlay(alignment:.bottom) { if let notice=store.notice { Text(notice).font(.callout).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)).padding().allowsHitTesting(false) } }
        .toolbar(.hidden,for:.navigationBar)
        .task {
            environment.viewer=session
            do {
                try await session.start(); try await session.load(entry.lastVisitedURL ?? entry.startURL)
            } catch { session.error=error.localizedDescription }
        }.onDisappear { session.close(); environment.viewer=nil }
    }
}
struct WebContent:UIViewRepresentable {
    @ObservedObject var session:WebsiteSession
    let onReturn:()->Void
    func makeUIView(context:Context)->NativeViewerContainer { NativeViewerContainer(webView:session.webView,onReturn:onReturn) }
    func updateUIView(_ view:NativeViewerContainer,context:Context) { view.onReturn=onReturn }
}
/// Return without placing a control over website content.
final class NativeViewerContainer:UIView,UIGestureRecognizerDelegate {
    var onReturn:()->Void
    private var returnTriggered=false
    init(webView:WKWebView,onReturn:@escaping ()->Void) {
        self.onReturn=onReturn; super.init(frame:.zero)
        addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints=false
        // Observe touches without covering links with a separate hit-test view.
        // The 44-point margin also works inside resizable iPad windows.
        let edge=UIPanGestureRecognizer(target:self,action:#selector(returnFromEdge(_:)))
        edge.maximumNumberOfTouches=1; edge.delegate=self; edge.cancelsTouchesInView=false; addGestureRecognizer(edge)
        webView.accessibilityCustomActions=[UIAccessibilityCustomAction(name:"Zur Webseitenübersicht",target:self,selector:#selector(accessibleReturn))]
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo:leadingAnchor),webView.trailingAnchor.constraint(equalTo:trailingAnchor),
            webView.topAnchor.constraint(equalTo:topAnchor),webView.bottomAnchor.constraint(equalTo:bottomAnchor)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool { touch.location(in:self).x<=44 }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool {
        guard let pan=gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity=pan.velocity(in:self)
        return velocity.x>0 && abs(velocity.x)>abs(velocity.y)
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool { true }
    @objc private func returnFromEdge(_ gesture:UIPanGestureRecognizer) {
        let delta=gesture.translation(in:self)
        if gesture.state == .began { returnTriggered=false }
        if !returnTriggered, (gesture.state == .changed || gesture.state == .ended), delta.x>60, abs(delta.y)<delta.x {
            returnTriggered=true; onReturn()
        }
    }
    @objc private func accessibleReturn()->Bool { onReturn(); return true }
}
