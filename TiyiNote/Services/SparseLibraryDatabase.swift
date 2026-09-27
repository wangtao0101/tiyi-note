import Foundation
import SQLite3

/// Durable entity store and outbox. Acknowledgements compare revisions, so an upload can never
/// acknowledge an edit made while its request was in flight. Large immutable bytes stay on disk.
struct SparseLibraryEntry: Sendable {
    let kind: String
    let id: String
    let documentID: String
    let pageID: String
    let payload: Data
    let filePath: String?
    let revision: Int64
    let pending: Bool
    var key: String { "\(kind)|\(id)" }
}

@MainActor
final class SparseLibraryDatabase {
    private var handle: OpaquePointer?
    let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let pageLifecycleFilter = """
    kind='operation' AND CASE WHEN json_valid(CAST(payload AS TEXT)) THEN
      (json_type(CAST(payload AS TEXT),'$.payload.pageDelete') IS NOT NULL
       OR json_type(CAST(payload AS TEXT),'$.payload.pageRestore') IS NOT NULL
       OR json_type(CAST(payload AS TEXT),'$.payload.pagePosition') IS NOT NULL
       OR json_extract(CAST(payload AS TEXT),'$.payload.metadataSet.field')='pageArchive')
      ELSE 0 END
    """

    init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "TiyiSQLite", code: 1)
        }
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS entries(kind TEXT NOT NULL,id TEXT NOT NULL,document_id TEXT NOT NULL,page_id TEXT NOT NULL,payload BLOB NOT NULL,file_path TEXT,revision INTEGER NOT NULL DEFAULT 1,pending INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(kind,id))")
        try execute("CREATE INDEX IF NOT EXISTS pending_entries ON entries(pending,kind)")
        try execute("CREATE INDEX IF NOT EXISTS document_entries ON entries(document_id,kind,page_id)")
        try execute("CREATE INDEX IF NOT EXISTS missing_assets ON entries(kind,file_path)")
        // A persisted partial index keeps sidebar refreshes independent of ink/image history size.
        // Existing databases pay the scan once; subsequent reads visit only page lifecycle events.
        try execute("CREATE INDEX IF NOT EXISTS page_lifecycle_entries ON entries(document_id,page_id) WHERE \(Self.pageLifecycleFilter)")
        try execute("CREATE TABLE IF NOT EXISTS local_state(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
        try migrateLocalPaths()
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        let name = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    @discardableResult
    func put(kind: String, id: String, documentID: String = "", pageID: String = "",
             payload: Data, filePath: String? = nil, pending: Bool = true) throws -> Bool {
        let sql = """
        INSERT INTO entries(kind,id,document_id,page_id,payload,file_path,pending) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(kind,id) DO UPDATE SET document_id=excluded.document_id,page_id=excluded.page_id,
        payload=excluded.payload,file_path=excluded.file_path,revision=entries.revision+1,
        pending=excluded.pending WHERE entries.payload!=excluded.payload OR entries.file_path IS NOT excluded.file_path
        """
        try statement(sql) { s in
            bind(kind, s, 1); bind(id, s, 2); bind(documentID, s, 3); bind(pageID, s, 4)
            bind(payload, s, 5); bind(filePath.map(storedPath), s, 6); sqlite3_bind_int(s, 7, pending ? 1 : 0)
            try step(s)
        }
        return sqlite3_changes(handle) > 0
    }

    func entries(kind: String? = nil, documentID: String? = nil, pageID: String? = nil,
                 pendingOnly: Bool = false, missingFileOnly: Bool = false,
                 pageLifecycleOnly: Bool = false, limit: Int = 100_000) throws -> [SparseLibraryEntry] {
        var filters: [String] = []; var strings: [String] = []
        if let kind { filters.append("kind=?"); strings.append(kind) }
        if let documentID { filters.append("document_id=?"); strings.append(documentID) }
        if let pageID { filters.append("page_id=?"); strings.append(pageID) }
        if pendingOnly { filters.append("pending=1") }
        if missingFileOnly { filters.append("file_path IS NULL") }
        if pageLifecycleOnly { filters.append(Self.pageLifecycleFilter) }
        let whereClause = filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")
        let order = " ORDER BY CASE kind WHEN 'folder' THEN 0 WHEN 'document' THEN 1 WHEN 'page' THEN 2 WHEN 'operation' THEN 3 WHEN 'cover' THEN 4 ELSE 5 END,id LIMIT \(max(0, limit))"
        // Without this hint SQLite can choose the general document index and parse every ink
        // payload to evaluate the JSON predicate, defeating the purpose of the partial index.
        let table = pageLifecycleOnly ? "entries INDEXED BY page_lifecycle_entries" : "entries"
        return try statement("SELECT kind,id,document_id,page_id,payload,file_path,revision,pending FROM " + table + whereClause + order) { s in
            for (i, string) in strings.enumerated() { bind(string, s, Int32(i + 1)) }
            var result: [SparseLibraryEntry] = []
            while true {
                let status = sqlite3_step(s)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                result.append(SparseLibraryEntry(kind: string(s, 0), id: string(s, 1),
                    documentID: string(s, 2), pageID: string(s, 3), payload: data(s, 4),
                    filePath: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : resolvedPath(string(s, 5)),
                    revision: sqlite3_column_int64(s, 6), pending: sqlite3_column_int(s, 7) != 0))
            }
            return result
        }
    }

    func entry(kind: String, id: String) throws -> SparseLibraryEntry? {
        // Index lookup, including for immutable operation deduplication.
        try statement("SELECT kind,id,document_id,page_id,payload,file_path,revision,pending FROM entries WHERE kind=? AND id=?") { s in
            bind(kind, s, 1); bind(id, s, 2)
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            return SparseLibraryEntry(kind: string(s, 0), id: string(s, 1), documentID: string(s, 2),
                pageID: string(s, 3), payload: data(s, 4), filePath: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : resolvedPath(string(s, 5)),
                revision: sqlite3_column_int64(s, 6), pending: sqlite3_column_int(s, 7) != 0)
        }
    }

    func acknowledge(_ entry: SparseLibraryEntry) throws {
        try statement("UPDATE entries SET pending=0 WHERE kind=? AND id=? AND revision=?") { s in
            bind(entry.kind, s, 1); bind(entry.id, s, 2); sqlite3_bind_int64(s, 3, entry.revision); try step(s)
        }
    }

    func remove(kind: String, id: String) throws {
        try statement("DELETE FROM entries WHERE kind=? AND id=?") { s in
            bind(kind, s, 1); bind(id, s, 2); try step(s)
        }
    }

    func state(_ key: String) throws -> Data? {
        try statement("SELECT value FROM local_state WHERE key=?") { s in
            bind(key, s, 1)
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            let value = data(s, 0)
            if key.hasPrefix("cover.previousFile."), let path = String(data: value, encoding: .utf8), !path.isEmpty {
                return resolvedPath(path).map { Data($0.utf8) }
            }
            return value
        }
    }

    func setState(_ key: String, _ value: Data) throws {
        try statement("INSERT INTO local_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") { s in
            var storedValue = value
            if key.hasPrefix("cover.previousFile."), let path = String(data: value, encoding: .utf8), !path.isEmpty {
                storedValue = Data(storedPath(path).utf8)
            }
            bind(key, s, 1); bind(storedValue, s, 2); try step(s)
        }
    }

    /// Keep local paths relative to this library. App updates can relocate the entire sandbox.
    /// Legacy rebasing matches the complete library suffix, never just a PDF filename, so files
    /// belonging to another account/library cannot be mistaken for this library's assets.
    private func storedPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let root = url.deletingLastPathComponent().standardizedFileURL.path + "/"
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        if absolute.hasPrefix(root) { return String(absolute.dropFirst(root.count)) }
        let marker = "/Library/Application Support/"
        if let currentRange = root.range(of: marker), let oldRange = absolute.range(of: marker) {
            let librarySuffix = String(root[currentRange.upperBound...])
            let oldSuffix = String(absolute[oldRange.upperBound...])
            if oldSuffix.hasPrefix(librarySuffix) {
                return String(oldSuffix.dropFirst(librarySuffix.count))
            }
        }
        return path
    }

    private func resolvedPath(_ path: String) -> String? {
        let stored = storedPath(path)
        if stored.hasPrefix("/") { return stored }
        guard !stored.isEmpty, !stored.split(separator: "/").contains("..") else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(stored).standardizedFileURL.path
    }

    private func migrateLocalPaths() throws {
        // This is local bookkeeping, not a document edit: retain revisions, pending flags and
        // sync tokens. In particular, migration must not enqueue reuploads of downloaded PDFs.
        let paths: [(String, String, String)] = try statement("SELECT kind,id,file_path FROM entries WHERE file_path IS NOT NULL") { s in
            var result: [(String, String, String)] = []
            while sqlite3_step(s) == SQLITE_ROW { result.append((string(s, 0), string(s, 1), string(s, 2))) }
            return result
        }
        let covers: [(String, Data)] = try statement("SELECT key,value FROM local_state WHERE key LIKE 'cover.previousFile.%'") { s in
            var result: [(String, Data)] = []
            while sqlite3_step(s) == SQLITE_ROW { result.append((string(s, 0), data(s, 1))) }
            return result
        }
        try transaction {
            for (kind, id, path) in paths where storedPath(path) != path {
                try statement("UPDATE entries SET file_path=? WHERE kind=? AND id=?") { s in
                    bind(storedPath(path), s, 1); bind(kind, s, 2); bind(id, s, 3); try step(s)
                }
            }
            for (key, value) in covers {
                guard let path = String(data: value, encoding: .utf8), storedPath(path) != path else { continue }
                try setState(key, value)
            }
        }
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else { throw failure() }
        defer { sqlite3_finalize(s) }
        return try body(s)
    }
    private func bind(_ value: String?, _ s: OpaquePointer, _ i: Int32) {
        if let value { sqlite3_bind_text(s, i, value, -1, transient) } else { sqlite3_bind_null(s, i) }
    }
    private func bind(_ value: Data, _ s: OpaquePointer, _ i: Int32) {
        if value.isEmpty { sqlite3_bind_zeroblob(s, i, 0) }
        else { _ = value.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32(value.count), transient) } }
    }
    private func data(_ s: OpaquePointer, _ i: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(s, i) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, i)))
    }
    private func string(_ s: OpaquePointer, _ i: Int32) -> String {
        String(cString: sqlite3_column_text(s, i))
    }
    private func step(_ s: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    private func failure() -> NSError {
        NSError(domain: "TiyiSQLite", code: Int(sqlite3_errcode(handle)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
}
