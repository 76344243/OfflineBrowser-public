import Foundation
import CryptoKit

struct DownloadedResponse { let file: URL; let response: HTTPURLResponse }
final class TransferService: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: NetworkPolicy
    let vault: CookieVault
    let directory: URL
    private let lock = NSLock()
    private var active=true
    private var invalidation:CheckedContinuation<Void,Never>?
    private var continuations: [Int: CheckedContinuation<DownloadedResponse, Error>] = [:]
    private var files: [Int: URL] = [:]
    private var fileErrors: [Int: Error] = [:]
    private var bytesCallback: (@Sendable (Int64) -> Void)?
    private var restored: [String: DownloadedResponse] = [:]
    private let background: Bool
    private let identifier: String
    var progress: (@Sendable (String,Int64)->Void)?
    private let progressID=UUID().uuidString
    var backgroundCompletion: (() -> Void)?
    lazy var session: URLSession = {
        let configuration = background ? URLSessionConfiguration.background(withIdentifier: identifier) : .ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 3
        if background { configuration.sessionSendsLaunchEvents = true; configuration.isDiscretionary = false }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    init(policy: NetworkPolicy, vault: CookieVault, directory: URL, id: UUID, background: Bool = false) {
        self.policy = policy; self.vault = vault; self.directory = directory; self.background = background
        self.identifier = "org.local.offlinebrowser.\(id.uuidString).\(background ? "background" : "viewer")"
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "receipt" {
                if let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(Receipt.self, from: data), let url = URL(string: receipt.url), let response = HTTPURLResponse(url: url, statusCode: receipt.status, httpVersion: "HTTP/1.1", headerFields: receipt.headers) {
                    let blob = directory.appendingPathComponent(receipt.filename)
                    if FileManager.default.fileExists(atPath: blob.path) { restored[receipt.key] = DownloadedResponse(file: blob, response: response) }
                }
            }
        }
    }
    private struct Receipt: Codable { var key: String; var url: String; var status: Int; var headers: [String:String]; var filename: String }
    func download(_ url: URL, headers: [String:String] = [:], context: String = "default") async throws -> DownloadedResponse {
        guard policy.online, isActive else { throw ArchiveError.offline }
        try await TransferLimiter.shared.acquire()
        defer { Task { await TransferLimiter.shared.release() } }
        let key = context + "|" + URLMapper.key(url)
        if background, let old = takeRestored(key) { return old }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue("de,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(await vault.header(url), forHTTPHeaderField: "Cookie")
        for (key,value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let existing = await session.allTasks.first { $0.taskDescription == key && $0.state != .completed && $0.state != .canceling && self.isOrphan($0.taskIdentifier) } as? URLSessionDownloadTask
        let resume = directory.appendingPathComponent(SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined() + ".resume")
        let task: URLSessionDownloadTask
        if let existing { task = existing }
        else if let data = try? Data(contentsOf: resume), headers.isEmpty { task = session.downloadTask(withResumeData: data); try? FileManager.default.removeItem(at: resume) }
        else { task = session.downloadTask(with: request) }
        task.taskDescription = key
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); continuations[task.taskIdentifier] = continuation; lock.unlock()
                do { try policy.start(task,cancel:{self.pause(task)}) } catch { lock.lock(); continuations.removeValue(forKey: task.taskIdentifier); lock.unlock(); continuation.resume(throwing: error) }
            }
        }, onCancel: { self.pause(task) })
    }
    private func isOrphan(_ identifier: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return continuations[identifier] == nil }
    private var isActive:Bool { lock.lock(); defer {lock.unlock()}; return active }
    func shutdown() async {
        await withCheckedContinuation { continuation in
            lock.lock(); guard active else { lock.unlock(); continuation.resume(); return }; active=false; invalidation=continuation; lock.unlock(); session.invalidateAndCancel()
        }
    }
    func urlSession(_ session:URLSession,didBecomeInvalidWithError error:Error?) { lock.lock(); let c=invalidation; invalidation=nil; lock.unlock(); c?.resume() }
    private func takeRestored(_ key: String) -> DownloadedResponse? { lock.lock(); defer { lock.unlock() }; return restored.removeValue(forKey: key) }
    func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard policy.online, isActive else { throw ArchiveError.offline }
        try await TransferLimiter.shared.acquire()
        defer { Task { await TransferLimiter.shared.release() } }
        var r = request; r.setValue(await vault.header(request.url!), forHTTPHeaderField: "Cookie")
        let response: (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: r) { data, response, error in
                if let error { cont.resume(throwing: error) }
                else if let data, let http = response as? HTTPURLResponse { cont.resume(returning: (data,http)) }
                else { cont.resume(throwing: ArchiveError.http(502)) }
            }
            do { try policy.start(task) } catch { cont.resume(throwing: error) }
        }
        await vault.receive(response.1); return response
    }
    func pause(_ task: URLSessionDownloadTask) {
        task.cancel { data in
            guard self.isActive, let data, let key=task.taskDescription else { return }
            let filename=SHA256.hash(data:Data(key.utf8)).map {String(format:"%02x",$0)}.joined()+".resume"
            try? data.write(to:self.directory.appendingPathComponent(filename),options:.atomic)
        }
    }
    func reconnectPolicy() async {
        for task in await session.allTasks where task.state != .completed && task.state != .canceling {
            do { try policy.start(task,cancel:{ if let download=task as? URLSessionDownloadTask { self.pause(download) } else { task.cancel() } }) }
            catch { if let download=task as? URLSessionDownloadTask { pause(download) } else { task.cancel() } }
        }
    }
    func cancelAll() { session.getAllTasks { tasks in for task in tasks { if let download=task as? URLSessionDownloadTask { self.pause(download) } else { task.cancel() } } } }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) { if isActive { progress?(progressID+"-"+String(downloadTask.taskIdentifier),totalBytesWritten) } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        progress?(progressID+"-"+String(downloadTask.taskIdentifier),0)
        guard isActive else { return }
        let file = directory.appendingPathComponent(UUID().uuidString + ".download")
        do {
            try FileManager.default.moveItem(at: location, to: file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            lock.lock(); files[downloadTask.taskIdentifier] = file; lock.unlock()
            if let response = downloadTask.response as? HTTPURLResponse, let key = downloadTask.taskDescription, let url = response.url {
                let headers = response.allHeaderFields.reduce(into:[String:String]()) { values,pair in
                    let name=String(describing:pair.key); if !["set-cookie","authorization"].contains(name.lowercased()) { values[name]=String(describing:pair.value) }
                }
                let receipt = Receipt(key:key,url:url.absoluteString,status:response.statusCode,headers:headers,filename:file.lastPathComponent)
                try JSONEncoder().encode(receipt).write(to: file.appendingPathExtension("receipt"), options:.atomic)
            }
        } catch { lock.lock(); fileErrors[downloadTask.taskIdentifier] = error; lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progress?(progressID+"-"+String(task.taskIdentifier),0)
        policy.finished(task)
        lock.lock(); let continuation = continuations.removeValue(forKey: task.taskIdentifier); let file = files.removeValue(forKey: task.taskIdentifier); let diskError = fileErrors.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if isActive,let response = task.response as? HTTPURLResponse { Task { await vault.receive(response) } }
        if isActive,let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let key = task.taskDescription {
            try? data.write(to: directory.appendingPathComponent(SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined() + ".resume"), options:.atomic)
        }
        if let error = diskError ?? error { continuation?.resume(throwing:error) }
        else if let file, let response = task.response as? HTTPURLResponse {
            if let continuation { continuation.resume(returning: DownloadedResponse(file:file,response:response)) }
            else if let key = task.taskDescription { lock.lock(); restored[key] = DownloadedResponse(file:file,response:response); lock.unlock() }
        } else { continuation?.resume(throwing:ArchiveError.http(502)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard policy.online, isActive, let url = request.url, ["http","https"].contains(url.scheme) else { completionHandler(nil); return }
        Task {
            await vault.receive(response)
            var next = request; next.setValue(await vault.header(url), forHTTPHeaderField:"Cookie")
            if URLMapper.origin(url) != URLMapper.origin(response.url!) { next.setValue(nil, forHTTPHeaderField:"Authorization") }
            completionHandler(policy.online && isActive ? next : nil)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil } }
    func dispose(_ result: DownloadedResponse) { try? FileManager.default.removeItem(at: result.file); try? FileManager.default.removeItem(at: result.file.appendingPathExtension("receipt")) }
}
