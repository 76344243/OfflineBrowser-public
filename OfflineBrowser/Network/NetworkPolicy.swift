import Foundation
final class NetworkPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var serial = 0
    private var tasks: [ObjectIdentifier: (URLSessionTask, ()->Void)] = [:]
    var online: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    var epoch: Int { lock.lock(); defer { lock.unlock() }; return serial }
    func setOnline(_ value: Bool) {
        lock.lock(); allowed = value; serial += 1
        let cancel = value ? [] : Array(tasks.values); lock.unlock()
        cancel.forEach { $0.1() }
    }
    func start(_ task: URLSessionTask, cancel: (() -> Void)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard allowed else { task.cancel(); throw ArchiveError.offline }
        tasks[ObjectIdentifier(task)] = (task,cancel ?? {task.cancel()}); task.resume()
    }
    func finished(_ task: URLSessionTask) { lock.lock(); tasks.removeValue(forKey: ObjectIdentifier(task)); lock.unlock() }
}
