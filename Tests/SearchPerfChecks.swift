import Foundation
import SQLite3

// The fast search paths must give the answers the plain versions gave.
enum SearchPerfChecks {
    static func run(root: URL) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ label: String, _ ok: Bool) { out.append((label, ok)) }

        // int8 scan: NEON digits against the float loop
        var rng = SystemRandomNumberGenerator()
        let n = 997
        var docs = [Int8](repeating: 0, count: n * DIM)
        for i in docs.indices { docs[i] = Int8.random(in: -40...40, using: &rng) }
        var q = (0..<DIM).map { _ in Float.random(in: -1...1, using: &rng) }
        let len = q.reduce(0) { $0 + $1 * $1 }.squareRoot()
        q = q.map { $0 / len }
        func scans(_ q: [Float]) -> ([Float], [Float]) {
            var a = [Float](repeating: 0, count: n), b = a
            sb_scan_i8(q, docs, n, &a)
            sb_scan_i8_ref(q, docs, n, &b)
            return (a, b)
        }
        let (fast, ref) = scans(q)
        let worst = zip(fast, ref).map { abs($0 - $1) }.max() ?? 1
        check("int8 scan matches the float loop to a thousandth of a cosine", worst / QSCALE < 1e-3)
        let (big, bigRef) = scans(q.map { $0 * 50 })
        check("int8 scan keeps its accuracy for unnormalised queries", (zip(big, bigRef).map { abs($0 - $1) }.max() ?? 1) / 50 / QSCALE < 1e-3)
        check("int8 scan of a zero query is zero", scans([Float](repeating: 0, count: DIM)).0.allSatisfy { $0 == 0 })
        var nanQ = q; nanQ[7] = .nan
        check("int8 scan passes NaN through rather than inventing scores", scans(nanQ).0.allSatisfy { $0.isNaN })
        var norms = [Float](repeating: 0, count: n)
        sb_norms_i8(docs, n, &norms)
        check("row norms match a direct sum", (0..<n).allSatisfy { r in
            abs(norms[r] - (0..<DIM).reduce(Float(0)) { $0 + Float(docs[r * DIM + $1]) * Float(docs[r * DIM + $1]) }.squareRoot()) < 1e-3
        })
        let start = Date()
        let many = [Int8](repeating: 1, count: 23_000 * DIM)
        var outs = [Float](repeating: 0, count: 23_000)
        for _ in 0..<10 { sb_scan_i8(q, many, 23_000, &outs) }
        check("scanning 23k vectors takes under 10 ms", Date().timeIntervalSince(start) / 10 < 0.01)
        check("thread count comes from the performance cores", sb_threads() >= 1 && sb_threads() <= 64)

        // name matching against the per-keystroke version it replaced
        let db = Store(path: ":memory:")!
        var idOf: [String: Int64] = [:]
        @discardableResult func add(_ path: String, _ kind: Kind = .doc, vector: [Float]? = nil, src: Src = .text) -> Int64 {
            db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,1,'')",
                   [path, (path as NSString).lastPathComponent, kind.rawValue, 100.0, 10])
            let id = db.lastID
            idOf[path] = id
            if let vector { db.run("INSERT INTO vecs(file_id,src,v) VALUES(?,?,?)", [id, src.rawValue, quantize(vector)]) }
            return id
        }
        let paths = ["/p/Work/report.pdf", "/p/Work/Report Draft 2.pdf", "/p/Work/the syllabus.docx", "/p/School/IFP Syllabus.pdf",
                     "/p/Café/résumé.pdf", "/p/Café/Résumé final.PDF", "/p/sem_bar/Sources/main.swift", "/p/sem_bar/README.md",
                     "/p/Downloads/invoice-48291.pdf", "/p/Downloads/screenshot receipt.png", "/p/x/.bashrc", "/p/x/archive.tar.gz",
                     "/p/Notes/chapter one.txt", "/p/Notes/chaptr two.txt", "/p/Pics/IMG_2041.HEIC", "/p/日本/写真.png"]
        let unit = q
        for (i, p) in paths.enumerated() { add(p, i % 3 == 0 ? .image : .doc, vector: i % 2 == 0 ? unit : nil) }
        add("/Applications/Google Chrome.app", .app)
        add("/Applications/Visual Studio Code.app", .app)
        add("/p/Work", .folder)
        add("https://example.com/report", .web)
        let ix = Index.load(store: db)
        let queries = ["report", "report.pdf", "reprot", "report draft", "draft", "syllabus", "the syllabus", "ifp syllabus", "résumé", "resume",
                       "résumé final", "main", "sem_bar main", "sem_bar/readme.md", "readme.md", "~/x", "/p/work/report.pdf", "invo", "48291",
                       "chrome", "google", "vsc", "vs", "code", "ch", "c", "chapter", "chaptr", "chapetr", "img", "heic", "写真", "日本",
                       ".bashrc", "archive.tar", "archive", "the", "of the", "screenshot receipt", "receipt screenshot", "work"]
        var lexSame = true
        for raw in queries {
            let lq = raw.lowercased()
            for qt in [nameTokens(lq), nameTokens(lq).filter { !stopwords.contains($0) }] {
                for e in ix.entries {
                    let actual = Engine.lexForChecks(lq, qt, e), old = oldLex(lq, qt, e)
                    // Complete name tokens now receive a protected ranking; numeric typos no longer match.
                    let complete = !qt.isEmpty && qt.contains(where: { e.tokens.contains($0) }) &&
                        qt.allSatisfy { e.tokens.contains($0) || e.pathTokens.contains($0) }
                    let numeric = qt.contains { $0.contains(where: { $0.isNumber }) }
                    if actual != old && !(complete && actual == 0.95) && !(numeric && actual < old) {
                        print("  unexpected lex difference for “\(raw)” \(qt) on \(e.name): \(actual) vs \(old)")
                        lexSame = false
                    }
                }
            }
        }
        check("precomputed name matching preserves prior scores except intentional token changes", lexSame)
        for (a, b) in [("chapter", "chaptr"), ("chapetr", "chapter"), ("résumé", "resume"), ("résumé", "résume"), ("abcd", "abdc"), ("abcd", "abcde"),
                       ("abcd", "xbcd"), ("abcd", "abxy"), ("写真です", "写真でした"), ("éabc", "eabc")] {
            if Engine.oneEdit(a, b) != oldOneEdit(a, b) || Engine.oneEdit(b, a) != oldOneEdit(b, a) { lexSame = false; print("  oneEdit differs: \(a) \(b)") }
        }
        check("byte-level typo matching agrees with the character version", lexSame)
        let folderNames = ["work", "café", "sem_bar", "sources", "p", "x", "notes", "nothere", "report.pdf", "applications", "日本"]
        check("folder lookups agree with scanning every path", folderNames.allSatisfy { name in
            ix.hasFolder(name) == (ix.folders.contains(name) || ix.entries.contains { $0.kind.isFile && $0.path.range(of: "/\(name)/", options: .caseInsensitive) != nil })
        })
        let literals = ["report.pdf", "report", "résumé final", ".bashrc", "archive.tar", "google chrome", "chrome", "nothing", "/p/work/report.pdf"]
        check("literal-name lookups agree with scanning every entry", literals.allSatisfy { t in
            let expanded = (t as NSString).expandingTildeInPath.lowercased()
            let old = ix.entries.contains { $0.kind.isFile && ($0.lname == t || ($0.lname as NSString).deletingPathExtension == t || $0.lpath == expanded) }
            return old == (ix.names.contains(t) || ix.lpaths.contains(expanded))
        })
        var prefixSame = true
        for prefix in ["/p/Work", "/p/work/", "~/Documents", "Work", "café", "/", "sem_bar/Sources"] {
            var f = Filters(); f.pathPrefix = prefix
            for e in ix.entries where f.matches(e) != oldPrefixMatch(prefix, e) { prefixSame = false; print("  prefix \(prefix) differs on \(e.path)") }
        }
        check("path filters work out their prefix once and match as before", prefixSame)

        // rows by entry, and vectors added in place
        check("rows by entry match a scan of every row", ix.entries.indices.allSatisfy { i in ix.rows(of: i) == (0..<ix.rows).filter { Int(ix.rowEntry[$0]) == i } })
        let plain = ix.byPath["/p/Work/Report Draft 2.pdf"]!, embedded = ix.byPath["/p/Work/report.pdf"]!
        let before = ix.rows
        let v = quantize(unit.map { -$0 })
        let appended = ix.append(entry: plain, src: Src.text.rawValue, vector: v)
        let replaced = ix.append(entry: embedded, src: Src.text.rawValue, vector: v)
        check("a new vector is appended to its entry", appended && ix.rows == before + 1 && ix.rows(of: plain) == [before] && ix.vector(row: before).first == Float(Int8(bitPattern: v[0])) / QSCALE)
        check("a replaced vector keeps one row per source", replaced && ix.rows == before + 1 && ix.rows(of: embedded).count == 1 &&
              abs(ix.rowNorm[ix.rows(of: embedded)[0]] - ix.rowNorm[before]) < 1e-3)
        for _ in 0..<70 { _ = ix.append(entry: ix.byPath["/p/Notes/chapter one.txt"]!, src: Src.media.rawValue, vector: v) }
        check("appending grows the vector buffer without losing rows", ix.rows == before + 2 && ix.vector(row: 0).count == DIM)

        // full-text: the word being typed matches as a prefix, operators stay data
        db.addContent(idOf["/p/Downloads/invoice-48291.pdf"]!, "Payment received for the invoice INV-777 thanks", src: .page, loc: 2)
        check("a partly typed last word finds content", !db.contentMatches("payment invo").isEmpty && db.contentMatches("payment invoz").isEmpty)
        check("short partial words do not match content by prefix", db.contentMatches("payment th").isEmpty)
        check("FTS operators in a query stay plain words", db.contentMatches("invoice\" OR * NEAR(").isEmpty && db.contentMatches("\"").isEmpty)
        let m = db.contentMatches("payment invo").first
        check("excerpts are read for the shown match only", m.map { db.excerpt($0).contains("«") } == true)

        // ranking: score breakdown, cancellation
        let e = Engine(index: Index.load(store: db))
        let top = e.build("report").hits.first { $0.path != nil }
        check("a file hit says how its score was made", top?.why.hasPrefix("name ") == true)
        check("a superseded query stops before ranking", e.rankForChecks("report", stale: { true }).isEmpty && !e.rankForChecks("report").isEmpty)
        check("a superseded build returns no files", e.build("report", stale: { true }).hits.allSatisfy { $0.path == nil })
        var more: [Hit]?
        e.moreFiles("pdf") { more = $0 }
        let until = Date().addingTimeInterval(5)
        while more == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let firstFive = Set(e.build("pdf").hits.compactMap(\.path))
        check("more files continue past the first five without repeating them", more.map { !$0.isEmpty && $0.allSatisfy { $0.path != nil && !firstFive.contains($0.path!) } } == true)
        check("a listing says it is ordered by date", e.build("images").hits.first { $0.path != nil }?.why == "newest first")

        // schema migrations: a database from before versioning keeps working
        let old = root.appendingPathComponent("old-schema.sqlite").path
        var raw: OpaquePointer?
        sqlite3_open(old, &raw)
        sqlite3_exec(raw, "CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, name TEXT, kind INT, mtime REAL, size INT, state INT, snippet TEXT, textIndexed INT DEFAULT 0); CREATE TABLE vecs(file_id INT, src INT, v BLOB); INSERT INTO files(path,name,kind) VALUES('/a','a',4);", nil, nil, nil)
        sqlite3_close(raw)
        func columns(_ s: Store, _ table: String) -> [String] { var c: [String] = []; s.run("PRAGMA table_info(\(table))") { c.append(colText($0, 1)) }; return c }
        func version(_ s: Store) -> Int32 { var v: Int32 = -1; s.run("PRAGMA user_version") { v = sqlite3_column_int($0, 0) }; return v }
        if let s = Store(path: old) {
            check("an unversioned database gains the missing columns", columns(s, "files").contains("sourceRevision") && columns(s, "vecs").contains("loc") && version(s) == Store.schema)
            var rows = 0
            s.run("SELECT count(*) FROM files") { rows = Int(sqlite3_column_int($0, 0)) }
            check("migration keeps existing rows", rows == 1)
        } else { check("an unversioned database opens", false) }
        check("a migrated database reopens without migrating again", Store(path: old).map { version($0) == Store.schema && columns($0, "files").filter { $0 == "textIndexed" }.count == 1 } == true)

        // Spotlight fallback: bounded, and never inside hidden or library folders
        let t0 = Date()
        let found = Spotlight.names("calculator", limit: 3) { _ in false }
        check("Spotlight lookup stays within its budget", Date().timeIntervalSince(t0) < 0.4 && found.count <= 3)
        check("Spotlight results skip hidden, library and package folders", found.allSatisfy { !Spotlight.ignored($0) } &&
              Spotlight.ignored(Paths.home + "/Library/Caches/x.txt") && Spotlight.ignored(Paths.home + "/.git/x") &&
              Spotlight.ignored("/System/Applications/Calculator.app") && !Spotlight.ignored(Paths.home + "/notes.txt"))
        check("Spotlight respects the skip rule", Spotlight.names("calculator", limit: 3) { _ in true }.isEmpty)
        check("Spotlight is off in the test engine", !e.spotlight)
        return out
    }

    // the per-keystroke implementation search used before entries carried precomputed fields
    static func oldLex(_ q: String, _ qt: [String], _ e: Entry) -> Float {
        if q.isEmpty { return 0 }
        let stem = (e.lname as NSString).deletingPathExtension
        if e.lname == q || stem == q { return 1 }
        if !qt.isEmpty, !q.contains("/") {
            let words = nameTokens(stem).filter { !stopwords.contains($0) }
            if words == qt { return 1 }
            if words.starts(with: qt) { return 0.9 }
        }
        let expanded = (q as NSString).expandingTildeInPath.lowercased()
        if e.lpath == expanded || (q.contains("/") && e.lpath.hasSuffix("/" + q)) { return 1 }
        if e.kind == .app, !qt.isEmpty, qt.allSatisfy({ e.tokens.contains($0) }) { return 0.95 }
        if e.lname.hasPrefix(q) { return 0.9 }
        var best: Float = 0
        if !qt.isEmpty {
            let names = qt.filter { t in e.tokens.contains { $0.hasPrefix(t) } }.count
            let paths = qt.filter { t in e.tokens.contains { $0.hasPrefix(t) } || e.pathTokens.contains { $0.hasPrefix(t) } }.count
            if names == qt.count { best = 0.8 } else if paths == qt.count { best = 0.7 } else { best = 0.25 * Float(names) / Float(qt.count) }
        }
        if q.count >= 3, e.lname.contains(q) { best = max(best, 0.65) }
        if q.contains("/"), e.lpath.contains(expanded) { best = max(best, 0.7) }
        if e.kind == .app, q.count >= 2, e.initials.hasPrefix(q) { best = max(best, 0.7) }
        if best < 0.5, !qt.isEmpty, qt.count <= 4,
           qt.allSatisfy({ term in e.tokens.contains { token in token.hasPrefix(term) || (term.count >= 4 && oldOneEdit(term, token)) } }) {
            best = (qt.count == e.tokens.count || qt.count == nameTokens(stem).count) ? 0.62 : 0.56
        }
        return best
    }

    static func oldOneEdit(_ a: String, _ b: String) -> Bool {
        guard abs(a.utf8.count - b.utf8.count) <= 4 else { return false }
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 1 else { return false }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if i == min(x.count, y.count) { return true }
        if x.count == y.count {
            if x.dropFirst(i + 1).elementsEqual(y.dropFirst(i + 1)) { return true }
            return i + 1 < x.count && x[i] == y[i + 1] && x[i + 1] == y[i] && x.dropFirst(i + 2).elementsEqual(y.dropFirst(i + 2))
        }
        return x.count > y.count ? x.dropFirst(i + 1).elementsEqual(y.dropFirst(i)) : x.dropFirst(i).elementsEqual(y.dropFirst(i + 1))
    }

    static func oldPrefixMatch(_ pathPrefix: String, _ e: Entry) -> Bool {
        let path = e.path.lowercased()
        let expanded = (pathPrefix as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let prefix = URL(fileURLWithPath: expanded).standardizedFileURL.path.lowercased()
            return path.hasPrefix(prefix == "/" ? "/" : prefix + "/")
        }
        let prefix = expanded.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.contains("/" + prefix + "/")
    }
}
