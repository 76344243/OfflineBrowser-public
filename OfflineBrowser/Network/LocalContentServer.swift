import Foundation
import Network
struct LocalRequest { var method: String; var target: String; var headers: [String:String]; var body: Data }
struct LocalResponse {
    var status = 200
    var headers: [String:String] = [:]
    var data: Data? = nil
    var file: URL? = nil
    var offset: UInt64 = 0
    var length: Int64 = 0
}
private final class ReadyLatch: @unchecked Sendable {
    private let lock=NSLock(); private var done=false
    func finish(_ result:Result<Void,Error>,_ continuation:CheckedContinuation<Void,Error>) { lock.lock(); guard !done else { lock.unlock(); return }; done=true; lock.unlock(); continuation.resume(with:result) }
}
private final class LocalPortRegistry: @unchecked Sendable {
    static let shared=LocalPortRegistry()
    private let lock=NSLock(); private var owners:[UInt16:UUID]=[:]
    func claim(_ port:UInt16,owner:UUID)->Bool { lock.lock(); defer { lock.unlock() }; guard owners[port]==nil else { return false }; owners[port]=owner; return true }
    func release(_ port:UInt16,owner:UUID) { lock.lock(); defer { lock.unlock() }; if owners[port]==owner { owners[port]=nil } }
}
private final class ConnectionBank: @unchecked Sendable {
    private let lock=NSLock(); private var connections:[ObjectIdentifier:NWConnection]=[:]
    func insert(_ c:NWConnection) { lock.lock(); connections[ObjectIdentifier(c)]=c; lock.unlock() }
    func remove(_ c:NWConnection) { lock.lock(); connections[ObjectIdentifier(c)]=nil; lock.unlock() }
    func stop() { lock.lock(); let active=Array(connections.values); connections.removeAll(); lock.unlock(); for connection in active { connection.cancel() } }
}
final class LocalContentServer: @unchecked Sendable {
    private var listener: NWListener?
    private let owner=UUID()
    private let connections=ConnectionBank()
    private let queue = DispatchQueue(label:"OfflineBrowser.loopback")
    private let handler: @Sendable (LocalRequest) async -> LocalResponse
    private let port: UInt16
    init(port: UInt16, handler: @escaping @Sendable (LocalRequest) async -> LocalResponse) { self.port = port; self.handler = handler }
    func start() async throws {
        guard LocalPortRegistry.shared.claim(port,owner:owner) else { throw NSError(domain:"OfflineBrowser.LocalServer",code:48,userInfo:[NSLocalizedDescriptionKey:"Diese Website ist bereits geöffnet. Schließen Sie den Viewer für die Offline-Prüfung."]) }
        do {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse=true
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        let listener = try NWListener(using:parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let latch=ReadyLatch()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: latch.finish(.success(()),cont)
                case .failed(let error): latch.finish(.failure(error),cont)
                case .cancelled: latch.finish(.failure(CancellationError()),cont)
                default: break
                }
            }
            listener.start(queue:queue)
        }
        } catch { stop(); throw error }
    }
    func stop() { listener?.cancel(); listener = nil; connections.stop(); LocalPortRegistry.shared.release(port,owner:owner) }
    private func accept(_ connection: NWConnection) {
        connections.insert(connection); connection.start(queue:queue)
        Task {
            defer { connections.remove(connection); connection.cancel() }
            do {
                var bytes = Data()
                while bytes.range(of:Data("\r\n\r\n".utf8)) == nil {
                    let chunk = try await receive(connection); guard !chunk.isEmpty, bytes.count < 65536 else { return }; bytes += chunk
                }
                let end = bytes.range(of:Data("\r\n\r\n".utf8))!
                guard let header = String(data:bytes[..<end.lowerBound],encoding:.utf8) else { return }
                let lines = header.components(separatedBy:"\r\n"); let first = lines[0].split(separator:" ")
                guard first.count == 3 else { return }
                var headers: [String:String] = [:]
                for line in lines.dropFirst() { if let colon = line.firstIndex(of:":") { headers[String(line[..<colon]).lowercased()] = String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces) } }
                guard headers["transfer-encoding"] == nil else { return }
                let count = Int(headers["content-length"] ?? "0") ?? 0
                var body = Data(bytes[end.upperBound...])
                while body.count < count { let next = try await receive(connection); guard !next.isEmpty else { return }; body += next }
                let request = LocalRequest(method:String(first[0]),target:String(first[1]),headers:headers,body:body)
                var response = await handler(request)
                response.headers["Content-Length"] = String(response.data?.count ?? Int(response.length))
                response.headers["Connection"] = "close"; response.headers["Cache-Control"] = "no-store"
                let statusText = [200:"OK",206:"Partial Content",303:"See Other",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",416:"Range Not Satisfiable",502:"Bad Gateway",503:"Service Unavailable"][response.status] ?? "Response"
                var text = "HTTP/1.1 \(response.status) \(statusText)\r\n"
                for (key,value) in response.headers where !value.contains("\r") && !value.contains("\n") { text += "\(key): \(value)\r\n" }
                text += "\r\n"; try await send(connection,Data(text.utf8))
                guard request.method != "HEAD" else { return }
                if let data = response.data { try await send(connection,data) }
                else if let file = response.file {
                    let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
                    try handle.seek(toOffset:response.offset); var remaining = response.length
                    while remaining > 0 { guard let chunk = try handle.read(upToCount:Int(min(remaining,64*1024))), !chunk.isEmpty else { break }; try await send(connection,chunk); remaining -= Int64(chunk.count) }
                }
            } catch { /* A stopped navigation closes its socket; no error page is inserted. */ }
        }
    }
    private func receive(_ c: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in c.receive(minimumIncompleteLength:1,maximumLength:65536) { data,_,_,error in if let error { cont.resume(throwing:error) } else { cont.resume(returning:data ?? Data()) } } }
    }
    private func send(_ c: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont:CheckedContinuation<Void,Error>) in c.send(content:data,completion:.contentProcessed { error in if let error { cont.resume(throwing:error) } else { cont.resume() } }) }
    }
}
