import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Store {
    private var db: OpaquePointer?

    init?(readonly: Bool = false, path: String = Paths.db) {
        let flags = readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 5000)
        if !readonly {
            exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            exec("""
            CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, name TEXT, kind INT,
                mtime REAL, size INT, state INT, snippet TEXT);
            CREATE TABLE IF NOT EXISTS vecs(file_id INT, src INT, v BLOB);
            CREATE INDEX IF NOT EXISTS vecs_file ON vecs(file_id);
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v BLOB);
            CREATE TABLE IF NOT EXISTS picks(q TEXT, key TEXT, n INT, t REAL, PRIMARY KEY(q, key));
            CREATE TABLE IF NOT EXISTS habits(key TEXT, ctx TEXT, hour INT, w REAL, t REAL, PRIMARY KEY(key, ctx, hour));
            """)
            exec("ALTER TABLE files ADD COLUMN textIndexed INT DEFAULT 0")
            exec("ALTER TABLE files ADD COLUMN sourceRevision TEXT DEFAULT ''")
            exec("CREATE VIRTUAL TABLE IF NOT EXISTS content USING fts5(file_id UNINDEXED, body, src UNINDEXED, loc UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
            exec("ALTER TABLE vecs ADD COLUMN loc REAL DEFAULT 0") // no-op once the column exists
        }
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    // binds Int/Int64/Double/String/Data; calls row for each result row
    func run(_ sql: String, _ args: [Any] = [], row: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
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
        while sqlite3_step(st) == SQLITE_ROW { row?(st) }
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
        let excerpt: String
    }

    func addContent(_ id: Int64, _ text: String, src: Src = .text, loc: Double = 0) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run("INSERT INTO content(file_id,body,src,loc) VALUES(?,?,?,?)", [id, text, src.rawValue, loc])
    }

    func contentMatches(_ query: String, literal: Bool = false) -> [ContentMatch] {
        let terms = Array(nameTokens(query).filter { literal || !stopwords.contains($0) }.prefix(24))
        guard !terms.isEmpty else { return [] }
        // Quotes bind words as data, so user input cannot inject FTS operators.
        let expression = literal ? "\"" + terms.joined(separator: " ") + "\"" : terms.map { "\"" + $0 + "\"" }.joined(separator: " AND ")
        var result: [ContentMatch] = []
        run("SELECT file_id,src,loc,snippet(content,1,'«','»','…',16),f.path FROM content JOIN files f ON f.id=content.file_id WHERE content MATCH ? ORDER BY bm25(content) LIMIT 300", [expression]) { st in
            result.append(ContentMatch(id: sqlite3_column_int64(st, 0), path: colText(st, 4), src: Int(sqlite3_column_int(st, 1)),
                                       loc: Float(sqlite3_column_double(st, 2)), excerpt: colText(st, 3)))
        }
        return result
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
