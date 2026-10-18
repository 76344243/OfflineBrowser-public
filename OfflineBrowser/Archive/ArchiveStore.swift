import Foundation
import CryptoKit
import SQLite3

actor ArchiveStore {
    let root: URL
    private var epochs:[UUID:Int]=[:]
    #if DEBUG
    var failWritesFor:Set<UUID>=[]
    func simulateFullDisk(_ id:UUID,enabled:Bool) { if enabled { failWritesFor.insert(id) } else { failWritesFor.remove(id) } }
    #endif
    func epoch(_ id:UUID) -> Int { epochs[id] ?? 0 }
    private var databases: [UUID: OpaquePointer] = [:]
    private var pinnedGenerations: [UUID:[String:String]] = [:]
    private var pinnedHashes: [UUID:[String:Set<String>]] = [:]
    init(root: URL) { self.root = root }
    func directory(_ id: UUID) throws -> URL {
        var folder = root.appendingPathComponent("entries/\(id.uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("objects"), withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        return folder
    }
    private func database(_ id: UUID) throws -> OpaquePointer {
        if let db = databases[id] { return db }
        let file = try directory(id).appendingPathComponent("index.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw ArchiveError.storage }
        let sql = "PRAGMA journal_mode=WAL; PRAGMA user_version=1; CREATE TABLE IF NOT EXISTS resources (generation TEXT NOT NULL, url TEXT NOT NULL, record BLOB NOT NULL, PRIMARY KEY(generation,url));"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw ArchiveError.storage }
        databases[id] = db; return db
    }
    func records(_ id: UUID, generation: String) throws -> [ResourceRecord] {
        let db = try database(id); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT record FROM resources WHERE generation=?", -1, &statement, nil) == SQLITE_OK else { throw ArchiveError.storage }
        defer { sqlite3_finalize(statement) }
        bind(generation, at: 1, in: statement)
        var result: [ResourceRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let p = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: p, count: Int(sqlite3_column_bytes(statement, 0)))
            result.append(try JSONDecoder().decode(ResourceRecord.self, from: data))
        }
        return result
    }
    func record(_ id: UUID, url: URL, generations: [String]) throws -> ResourceRecord? {
        let db = try database(id)
        for generation in generations {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT record FROM resources WHERE generation=? AND url=?", -1, &s, nil) == SQLITE_OK else { throw ArchiveError.storage }
            bind(generation, at: 1, in: s); bind(URLMapper.key(url), at: 2, in: s)
            defer { sqlite3_finalize(s) }
            if sqlite3_step(s) == SQLITE_ROW, let p = sqlite3_column_blob(s, 0) {
                let r = try JSONDecoder().decode(ResourceRecord.self, from: Data(bytes: p, count: Int(sqlite3_column_bytes(s, 0))))
                if FileManager.default.fileExists(atPath: try object(id, hash: r.hash).path) { return r }
            }
        }
        return nil
    }
    func object(_ id: UUID, hash: String) throws -> URL {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw ArchiveError.integrity }
        return try directory(id).appendingPathComponent("objects/\(hash)")
    }
    func hash(_ file: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hasher = SHA256(); var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty { hasher.update(data: chunk); bytes += Int64(chunk.count) }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    func put(_ id: UUID, generation: String, url: URL, file: URL, response: HTTPURLResponse, expectedHash: String? = nil, expectedBytes: Int64? = nil, expectedEpoch: Int? = nil) throws -> ResourceRecord {
        if let expectedEpoch, expectedEpoch != epoch(id) { throw CancellationError() }
        #if DEBUG
        if failWritesFor.contains(id) { throw ArchiveError.storage }
        #endif
        let (digest, size) = try hash(file)
        guard expectedHash == nil || expectedHash?.lowercased() == digest, expectedBytes == nil || expectedBytes == size else { throw ArchiveError.integrity }
        let target = try object(id, hash: digest)
        let existing=FileManager.default.fileExists(atPath:target.path)
        let existingValid=existing && ((try? hash(target).0)==digest)
        if !existingValid {
            let temporary=target.deletingLastPathComponent().appendingPathComponent(".incoming-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:temporary) }
            try FileManager.default.copyItem(at:file,to:temporary)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:temporary.path)
            if existing { _ = try FileManager.default.replaceItemAt(target,withItemAt:temporary) }
            else { try FileManager.default.moveItem(at:temporary,to:target) }
        }
        let headers = response.allHeaderFields.reduce(into: [String:String]()) { r, p in
            let key = String(describing: p.key).lowercased()
            if !["set-cookie", "connection", "transfer-encoding"].contains(key) { r[key] = String(describing: p.value) }
        }
        let record = ResourceRecord(url: URLMapper.key(url), generation: generation, hash: digest, size: size, mime: response.mimeType ?? "application/octet-stream", status: response.statusCode, headers: headers)
        let data = try JSONEncoder().encode(record); let db = try database(id); var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO resources VALUES (?,?,?)", -1, &s, nil) == SQLITE_OK else { throw ArchiveError.storage }
        defer { sqlite3_finalize(s) }; bind(generation, at: 1, in: s); bind(record.url, at: 2, in: s)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ArchiveError.storage }
        return record
    }
    private func bind(_ value: String, at index: Int32, in s: OpaquePointer?) { _ = value.withCString { sqlite3_bind_text(s, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
    func pin(_ id: UUID, owner: String, generation: String?, hashes: Set<String> = []) {
        if let generation { pinnedGenerations[id, default:[:]][owner] = generation }
        if !hashes.isEmpty { pinnedHashes[id, default:[:]][owner] = hashes }
    }
    func unpin(_ id: UUID, owner: String) { pinnedGenerations[id]?[owner] = nil; pinnedHashes[id]?[owner] = nil }
    func removeGeneration(_ id: UUID, _ generation: String) throws {
        if pinnedGenerations[id]?.values.contains(generation) == true { return }
        let db = try database(id); var s: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM resources WHERE generation=?", -1, &s, nil)
        defer { sqlite3_finalize(s) }; bind(generation, at: 1, in: s); guard sqlite3_step(s) == SQLITE_DONE else { throw ArchiveError.storage }
        // Blobs are collected only when no live viewer/player holds the entry.
    }
    func garbageCollect(_ id: UUID, keeping generations: [String]) throws {
        var hashes = Set<String>()
        for values in pinnedHashes[id]?.values ?? [:].values { hashes.formUnion(values) }
        for g in pinnedGenerations[id]?.values ?? [:].values { for r in try records(id,generation:g) { hashes.insert(r.hash) } }
        for g in generations { for r in try records(id, generation: g) { hashes.insert(r.hash) } }
        let objects = try directory(id).appendingPathComponent("objects")
        for file in try FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) where !hashes.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
    }
    func prune(_ id:UUID, keeping:[String]) throws {
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("entries/\(id.uuidString)/index.sqlite").path) else { return }
        let db=try database(id); var s:OpaquePointer?
        sqlite3_prepare_v2(db,"SELECT DISTINCT generation FROM resources",-1,&s,nil)
        var generations:[String]=[]
        while sqlite3_step(s)==SQLITE_ROW { if let p=sqlite3_column_text(s,0) { generations.append(String(cString:p)) } }
        sqlite3_finalize(s)
        for g in generations where !keeping.contains(g) { try removeGeneration(id,g) }
        try garbageCollect(id,keeping:keeping)
    }
    func bytes(_ id: UUID) throws -> Int64 {
        let folder=root.appendingPathComponent("entries/\(id.uuidString)")
        guard FileManager.default.fileExists(atPath:folder.path) else { return 0 }
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var count: Int64 = 0
        while let file = files?.nextObject() as? URL { let v = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]); if v.isRegularFile == true { count += Int64(v.fileSize ?? 0) } }
        return count
    }
    func erase(_ id: UUID) throws {
        epochs[id]=(epochs[id] ?? 0)+1
        pinnedHashes[id]=nil; pinnedGenerations[id]=nil
        if let db = databases.removeValue(forKey: id) { sqlite3_close(db) }
        let p = root.appendingPathComponent("entries/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: p.path) { try FileManager.default.removeItem(at: p) }
    }
}
