import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Store {
    private var db: OpaquePointer?
    private let writable: Bool
    static let schema: Int32 = 1
    private static let optimizeLock = NSLock()
    private static var optimized = 0.0

    init?(readonly: Bool = false, path: String = Paths.db) {
        let flags = readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        writable = !readonly
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 5000)
        if !readonly {
            exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            migrate()
        }
    }

    // Each step runs once per database, recorded in user_version. Databases made before versioning
    // may already have some columns, so those are checked rather than assumed.
    private func migrate() {
        var version: Int32 = 0
        run("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        guard version < Self.schema else { return }
        exec("""
        CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, name TEXT, kind INT,
            mtime REAL, size INT, state INT, snippet TEXT);
        CREATE TABLE IF NOT EXISTS vecs(file_id INT, src INT, v BLOB);
        CREATE INDEX IF NOT EXISTS vecs_file ON vecs(file_id);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v BLOB);
        CREATE TABLE IF NOT EXISTS picks(q TEXT, key TEXT, n INT, t REAL, PRIMARY KEY(q, key));
        CREATE TABLE IF NOT EXISTS habits(key TEXT, ctx TEXT, hour INT, w REAL, t REAL, PRIMARY KEY(key, ctx, hour));
        CREATE VIRTUAL TABLE IF NOT EXISTS content USING fts5(file_id UNINDEXED, body, src UNINDEXED, loc UNINDEXED, tokenize='unicode61 remove_diacritics 2');
        """)
        func add(_ table: String, _ column: String, _ type: String) {
            var has = false
            run("SELECT 1 FROM pragma_table_info(?) WHERE name=?", [table, column]) { _ in has = true }
            if !has { exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
        }
        add("files", "textIndexed", "INT DEFAULT 0")
        add("files", "sourceRevision", "TEXT DEFAULT ''")
        add("vecs", "loc", "REAL DEFAULT 0")
        exec("PRAGMA user_version=\(Self.schema)")
    }

    deinit {
        // keeps query plans current; at most hourly, since every short-lived writer closes here
        if writable {
            let now = Date().timeIntervalSince1970
            Self.optimizeLock.lock()
            let due = now - Self.optimized > 3600
            if due { Self.optimized = now }
            Self.optimizeLock.unlock()
            if due { exec("PRAGMA analysis_limit=400; PRAGMA optimize;") }
        }
        sqlite3_close(db)
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            let m = String(cString: err)
            // BEGIN/COMMIT pairs on a connection already in or out of a transaction are harmless
            if !m.contains("within a transaction") && !m.contains("no transaction is active") { log("sqlite: \(m) in \(sql.prefix(80))") }
        }
        sqlite3_free(err)
    }

    // binds Int/Int64/Double/String/Data; calls row for each result row
    func run(_ sql: String, _ args: [Any] = [], row: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            log("sqlite prepare: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))")
            return
        }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32(v.count), TRANSIENT) }
            default: sqlite3_bind_null(st, n)
            }
        }
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { row?(st); rc = sqlite3_step(st) }
        if rc != SQLITE_DONE { log("sqlite step: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))") }
    }

    var lastID: Int64 { sqlite3_last_insert_rowid(db) }

    func meta(_ k: String) -> Data? {
        var out: Data?
        run("SELECT v FROM meta WHERE k=?", [k]) { st in
            if let p = sqlite3_column_blob(st, 0) { out = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0))) }
        }
        return out
    }

    func setMeta(_ k: String, _ v: Data?) {
        if let v { run("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", [k, v]) } else { run("DELETE FROM meta WHERE k=?", [k]) }
    }

    func metaString(_ k: String) -> String? { meta(k).flatMap { String(data: $0, encoding: .utf8) } }
    func setMeta(_ k: String, string: String?) { setMeta(k, string?.data(using: .utf8)) }

    struct ContentMatch {
        let id: Int64
        let path: String
        let src: Int
        let loc: Float
        let row: Int64          // content rowid, for its excerpt
        let expression: String  // the MATCH it came from
    }

    func addContent(_ id: Int64, _ text: String, src: Src = .text, loc: Double = 0) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run("INSERT INTO content(file_id,body,src,loc) VALUES(?,?,?,?)", [id, text, src.rawValue, loc])
    }

    // Best passage per match first. Excerpts are left to `excerpt`: highlighting every candidate costs
    // far more than finding them, and only the few shown need one.
    func contentMatches(_ query: String, literal: Bool = false) -> [ContentMatch] {
        let terms = Array(nameTokens(query).filter { literal || !stopwords.contains($0) }.prefix(24))
        guard !terms.isEmpty else { return [] }
        // Quotes bind words as data, so user input cannot inject FTS operators.
        // The last word may still be being typed: it also matches as a prefix ("invo" finds invoice).
        let expression = literal ? "\"" + terms.joined(separator: " ") + "\"" : terms.enumerated().map { i, t in
            "\"" + t + "\"" + (i == terms.count - 1 && t.count >= 3 ? "*" : "")
        }.joined(separator: " AND ")
        var result: [ContentMatch] = []
        run("SELECT file_id,src,loc,content.rowid,f.path FROM content JOIN files f ON f.id=content.file_id WHERE content MATCH ? ORDER BY bm25(content) LIMIT 300", [expression]) { st in
            result.append(ContentMatch(id: sqlite3_column_int64(st, 0), path: colText(st, 4), src: Int(sqlite3_column_int(st, 1)),
                                       loc: Float(sqlite3_column_double(st, 2)), row: sqlite3_column_int64(st, 3), expression: expression))
        }
        return result
    }

    func excerpt(_ m: ContentMatch) -> String {
        var out = ""
        run("SELECT snippet(content,1,'«','»','…',16) FROM content WHERE content MATCH ? AND rowid=?", [m.expression, m.row]) { out = colText($0, 0) }
        return out
    }

    func deleteFile(_ id: Int64) {
        run("DELETE FROM content WHERE file_id=?", [id])
        run("DELETE FROM vecs WHERE file_id=?", [id])
        run("DELETE FROM files WHERE id=?", [id])
    }
}

func colText(_ st: OpaquePointer, _ i: Int32) -> String {
    sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
}
