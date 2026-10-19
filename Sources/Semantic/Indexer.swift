import AppKit
import Foundation
import SQLite3
import CryptoKit

// Runs as a short-lived child process (`Semantic --index`) so the vision/audio encoders
// are only resident while indexing, never in the bar itself.
enum Indexer {
    static let modelTag = "embeddinggemma-2/Q4/512/v2"
    static let skipDirs: Set<String> = ["node_modules", "Library", "Applications", "Public", "build", "dist", "target", "venv", "env",
                                        "__pycache__", "DerivedData", "Pods", "vendor", "site-packages", "nltk_data", "cache", "tmp"]

    struct Cand {
        let path: String
        let name: String
        let kind: Kind
        let mtime: Double
        let size: Int
        var body: String?
        var semantic = true
        var sourceRevision: String {
            guard let body else { return "" }
            return Extract.hex(SHA256.hash(data: Data((name + "\0" + body).utf8)))
        }
    }

    static let maxAttempts = 3
    static let sourceInterval: Double = 3600

    static func roots() -> [String] {
        let rules = IndexRules.shared
        if let r = config.roots { return r.map { ($0 as NSString).expandingTildeInPath }.filter { !rules.excluded($0) } }
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: Paths.home)) ?? []).sorted().compactMap { n in
            var isDir: ObjCBool = false
            let p = Paths.home + "/" + n
            guard !n.hasPrefix("."), !skipDirs.contains(n), !rules.excluded(p), fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
            return p
        }
    }

    static func apps() -> [Cand] {
        let fm = FileManager.default
        var out: [Cand] = []
        func add(_ p: String) {
            let attrs = try? fm.attributesOfItem(atPath: p)
            let m = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(Cand(path: p, name: fm.displayName(atPath: p).replacingOccurrences(of: ".app", with: ""), kind: .app, mtime: m, size: 0))
        }
        func scan(_ dir: String, depth: Int) {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !n.hasPrefix(".") {
                let p = dir + "/" + n
                if n.hasSuffix(".app") { add(p) } else if depth > 0 { scan(p, depth: depth - 1) }
            }
        }
        scan("/Applications", depth: 1)
        scan("/System/Applications", depth: 1)
        scan(Paths.home + "/Applications", depth: 1)
        scan("/System/Library/CoreServices/Applications", depth: 0)
        add("/System/Library/CoreServices/Finder.app")
        return out
    }

    // a folder whose contents are never indexed
    static func skipFolder(_ path: String, name: String, rules: IndexRules) -> Bool {
        name.hasPrefix(".") || skipDirs.contains(name) || name.hasSuffix(".egg-info") || rules.excluded(path) ||
            FileManager.default.fileExists(atPath: path + "/pyvenv.cfg")
    }

    // What a walk starting at `dir` inherits from the folders above it, up to the root it lies in:
    // the enclosing repository and the .semanticignore rules. nil when `dir` itself is never indexed.
    struct Start {
        var repo: String?
        var ignores: [IndexRules.Ignore] = []
    }

    static func start(_ dir: String, roots: [String], rules: IndexRules = .shared) -> Start? {
        let base = roots.filter { dir == $0 || dir.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? dir
        var s = Start()
        if let i = IndexRules.ignoreFile(in: base) { s.ignores.append(i) }
        guard dir != base else { return s }
        var p = base
        for comp in dir.dropFirst(base.count + 1).split(separator: "/") {
            p += "/" + comp
            // a package (an app, a document bundle, a Photos library) is one file: its inside is never walked
            if skipFolder(p, name: String(comp), rules: rules) || s.ignores.contains(where: { $0.matches(p) }) ||
                (comp.contains(".") && isPackage(p) == true) { return nil }
            if s.repo == nil, FileManager.default.fileExists(atPath: p + "/.git") { s.repo = p }
            if let i = IndexRules.ignoreFile(in: p) { s.ignores.append(i) }
        }
        return s
    }

    // A cheap, string-only filter for the bar's file watcher: changes under hidden, dependency or
    // excluded folders (or the index itself) never schedule a run.
    static func ignorable(_ path: String, roots: [String]) -> Bool {
        if path == Paths.support || path.hasPrefix(Paths.support + "/") || IndexRules.shared.excluded(path) { return true }
        guard let base = roots.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return true }
        return path.dropFirst(base.count).split(separator: "/").contains { $0.hasPrefix(".") || skipDirs.contains(String($0)) || $0.hasSuffix(".egg-info") }
    }

    // nil when `path` cannot be read (gone already)
    static func isPackage(_ path: String) -> Bool? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage
    }

    // `recursive: false` lists only the entries directly inside `root` (an incremental rescan)
    static func walk(_ root: String, recursive: Bool = true, roots: [String] = roots(), rules: IndexRules = .shared,
                     onError: ((String) -> Void)? = nil) -> [Cand] {
        let fm = FileManager.default
        do { _ = try fm.contentsOfDirectory(atPath: root) }
        catch {
            let e = error as NSError
            if !(e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code)) { onError?(root) }
            return []
        }
        guard let st = start(root, roots: roots, rules: rules) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        func spelled(_ u: URL) -> String { u.path.hasPrefix(resolved + "/") ? root + u.path.dropFirst(resolved.count) : u.path }
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in onError?(spelled(url)); return true }) else { onError?(root); return [] }
        var out: [Cand] = []
        var repo = st.repo
        var ignores = st.ignores
        let homeDepth = Paths.home.split(separator: "/").count
        for case let url as URL in en {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { onError?(spelled(url)); continue }
            // spelled under `root` as given: enumerator URLs drop a /private prefix, which would break prefix rules
            let name = url.lastPathComponent, path = root + "/" + url.pathComponents.suffix(en.level).joined(separator: "/")
            if let r = repo, !path.hasPrefix(r + "/") { repo = nil }
            // the enumerator is depth-first, so rules of folders it has left are the last ones pushed
            while ignores.count > st.ignores.count, let last = ignores.last, !path.hasPrefix(last.dir + "/") { ignores.removeLast() }
            let isDir = rv.isDirectory == true && rv.isPackage != true
            if rules.excluded(path) || ignores.contains(where: { $0.matches(path) }) {
                if isDir { en.skipDescendants() }
                continue
            }
            let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
            if isDir {
                if skipFolder(path, name: name, rules: rules) {
                    en.skipDescendants()
                    continue
                }
                if !recursive { en.skipDescendants() } else if let i = IndexRules.ignoreFile(in: path) { ignores.append(i) }
                let isRepo = repo == nil && fm.fileExists(atPath: path + "/.git")
                if isRepo { repo = path }
                let depth = path.split(separator: "/").count - homeDepth
                out.append(Cand(path: path, name: name, kind: .folder, mtime: 0, size: 0,
                                semantic: isRepo || (repo == nil && depth <= 3)))
                continue
            }
            let ext = url.pathExtension.lowercased()
            let kind = rv.isPackage == true && Extract.kind(ext: ext) == .other ? Kind.other : Extract.kind(ext: ext)
            let size = rv.fileSize ?? 0
            // Every visible file gets cheap metadata. Keep expensive content work selective.
            // .key is both a private key and a Keynote deck; decks are packages or far larger than any key
            let secret = ["pem", "key", "p12", "pfx", "mobileprovision", "cer", "crt", "kdbx"].contains(ext) && !(ext == "key" && (rv.isPackage == true || size > 65_536))
            let semantic = !Extract.junkExts.contains(ext) && !secret &&
                !(repo != nil && (kind == .other || (kind == .image && size < 20_000)))
            out.append(Cand(path: path, name: name, kind: kind, mtime: mtime, size: size, semantic: semantic))
        }
        return out
    }

    static func clean(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
    }

    // (title, body, snippet) for the text vector; `stored` is this file version's exact-text passages, when already extracted
    static func describe(_ c: Cand, stored: [Extract.Passage]? = nil) -> (String, String, String)? {
        if let body = c.body { return (c.name, body, c.kind == .web ? "" : String(body.prefix(300))) }
        let url = URL(fileURLWithPath: c.path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let ext = url.pathExtension.lowercased()
        switch c.kind {
        case .app:
            let cat = (Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String ?? "")
                .replacingOccurrences(of: "public.app-category.", with: "").replacingOccurrences(of: "-", with: " ")
            return (c.name, "macOS application" + (cat.isEmpty ? "" : ", \(cat)"), "")
        case .folder:
            return (c.name, "folder in \(parent)", "")
        case .doc:
            guard let body = stored.map({ Extract.summary($0) }) ?? Extract.textResult(url, ext: ext) else { return nil }
            return (clean(c.name), body.isEmpty ? "\(ext) document in \(parent)" : body, String(body.prefix(200)))
        case .image:
            return (clean(c.name), "image in \(parent)", "")
        case .audio, .video:
            // what is said, when a transcript exists, is a better description than the container
            let said = stored.map { Extract.summary($0.filter { $0.src == .media }, limit: 1000) } ?? ""
            let what = c.kind == .audio ? "audio recording in \(parent)" : "video in \(parent)"
            return (clean(c.name), said.isEmpty ? what : what + ". " + said, "")
        case .other:
            var body = ""
            if Extract.codeExts.contains(ext) {
                guard let extracted = stored.map({ Extract.summary($0, limit: 600) }) ?? Extract.textResult(url, ext: ext, limit: 600) else { return nil }
                body = extracted
            }
            return (c.name, body.isEmpty ? "\(ext) file in \(parent)" : body, "")
        default:
            return (c.name, "", "")
        }
    }

    // name-only description for a file whose content could never be read
    static func placeholder(_ c: Cand) -> (String, String, String) {
        let url = URL(fileURLWithPath: c.path)
        return (clean(c.name), "\(url.pathExtension.lowercased()) file in \(url.deletingLastPathComponent().lastPathComponent)", "")
    }

    static func storedPassages(_ store: Store, id: Int64) -> [Extract.Passage] {
        var out: [Extract.Passage] = []
        // body, src, loc straight from the FTS content shadow table, in rowid order as a scan of `content` returns them
        store.run("SELECT c1, c2, c3 FROM content_content WHERE c0=? ORDER BY id", [id]) { st in
            out.append(Extract.Passage(text: colText(st, 0), src: Src(rawValue: Int(sqlite3_column_int(st, 1))) ?? .text, loc: sqlite3_column_double(st, 2)))
        }
        return out
    }

    // Columns this indexer adds; checked first so the ALTERs stay idempotent whatever migrated the rest.
    static func migrate(_ store: Store) {
        var cols = Set<String>()
        store.run("PRAGMA table_info(files)") { cols.insert(colText($0, 1)) }
        for (c, def) in [("attempts", "INT DEFAULT 0"), ("retryAt", "REAL DEFAULT 0"), ("contentHash", "TEXT DEFAULT ''")] where !cols.contains(c) {
            store.exec("ALTER TABLE files ADD COLUMN \(c) \(def)")
        }
    }

    // One run in which a file's extraction or embedding failed. Retries back off (15 min, then 1 h); after
    // maxAttempts the file is done without content until its mtime or size changes. A text-pending file keeps
    // one more pass to get a name-only vector. Returns true once the file has been given up on.
    @discardableResult
    static func recordFailure(_ store: Store, id: Int64, now: Double = Date().timeIntervalSince1970) -> Bool {
        var n = 0
        store.run("SELECT attempts FROM files WHERE id=?", [id]) { n = Int(sqlite3_column_int64($0, 0)) }
        n += 1
        guard n >= maxAttempts else {
            store.run("UPDATE files SET attempts=?, retryAt=? WHERE id=?", [n, now + 900 * pow(4, Double(n - 1)), id])
            return false
        }
        store.run("UPDATE files SET attempts=?, retryAt=0, textIndexed=1, state=CASE WHEN state=0 OR (state=3 AND ?>?) THEN 1 ELSE state END WHERE id=?",
                  [n, n, maxAttempts, id])
        return true
    }

    // Extraction failure preserves the previous searchable text and its pending flag. `hash` is the
    // version whose text is now stored; a later touch with the same bytes keeps it.
    @discardableResult
    static func persistContentExtraction(_ store: Store, id: Int64, passages: [Extract.Passage]?, hash: (() -> String)? = nil) -> Bool {
        guard let passages else { return false }
        let hash = hash?()
        store.exec("BEGIN")
        store.deleteContent(id)
        for part in passages { store.addContent(id, part.text, src: part.src, loc: part.loc) }
        store.run("UPDATE files SET textIndexed=1 WHERE id=?", [id])
        if let hash { store.run("UPDATE files SET contentHash=? WHERE id=?", [hash, id]) }
        store.exec("COMMIT")
        return true
    }

    struct MediaVector {
        let src: Src
        let data: Data
        var loc: Double = 0
    }

    // Publish one complete bounded extraction together. A failed decode or model
    // call publishes nothing; retrying replaces these sources without duplicates.
    // Text vectors with loc > 0 are passage vectors of long documents; loc 0 is the file's own text vector.
    @discardableResult
    static func persistMediaExtraction(_ store: Store, id: Int64, vectors: [MediaVector]?, snippet: String? = nil) -> Bool {
        guard let vectors else { return false }
        store.exec("BEGIN")
        store.run("DELETE FROM vecs WHERE file_id=? AND (src IN (?,?,?) OR (src=? AND loc>0))",
                  [id, Src.media.rawValue, Src.ocr.rawValue, Src.page.rawValue, Src.text.rawValue])
        for v in vectors {
            store.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [id, v.src.rawValue, v.data, v.loc])
        }
        if let snippet { store.run("UPDATE files SET state=1,snippet=? WHERE id=?", [snippet, id]) }
        else { store.run("UPDATE files SET state=1 WHERE id=?", [id]) }
        store.exec("COMMIT")
        return true
    }

    static let passageVectors = 16

    // `stored` (this version's exact-text passages) saves a second OCR or PDF read
    static func mediaVectors(_ url: URL, kind: Kind, embedder: Embedder, stored: [Extract.Passage]? = nil) -> (vectors: [MediaVector], snippet: String?)? {
        var vectors: [MediaVector] = []
        var snippet: String?
        let title = clean(url.lastPathComponent)
        switch kind {
        case .image:
            guard let cg = Extract.image(url, maxPixel: 896) else { return nil }
            // Valid tiny images have no useful model input, but are not failures.
            guard cg.width >= 48, cg.height >= 48 else { return ([], nil) }
            guard let v = embedder.image(cg) else { return nil }
            vectors.append(MediaVector(src: .media, data: quantize(v)))
            let text: String
            if let stored { text = stored.filter { $0.src == .ocr }.map(\.text).joined(separator: " ") }
            else {
                guard let big = Extract.image(url, maxPixel: 2200), let t = Extract.ocrResult(big) else { return nil }
                text = t
            }
            if text.count >= 12 {
                guard let v = embedder.document(title: title, body: String(text.prefix(2500))) else { return nil }
                vectors.append(MediaVector(src: .ocr, data: quantize(v)))
                snippet = String(text.prefix(200))
            }
        case .audio:
            guard let segments = Extract.audioSegmentsResult(url) else { return nil }
            for (time, pcm) in segments {
                guard let v = embedder.audio(pcm) else { return nil }
                vectors.append(MediaVector(src: .media, data: quantize(v), loc: time))
            }
        case .video:
            guard let frames = Extract.videoFramesResult(url) else { return nil }
            for (time, cg) in frames {
                guard let v = embedder.image(cg) else { return nil }
                vectors.append(MediaVector(src: .media, data: quantize(v), loc: time))
            }
        case .doc where url.pathExtension.lowercased() == "pdf":
            guard let pages = stored.map(Extract.pdfPages) ?? Extract.pdfPagesResult(url) else { return nil }
            for (page, text) in pages {
                guard let v = embedder.document(title: "\(title) page \(page)", body: text) else { return nil }
                vectors.append(MediaVector(src: .page, data: quantize(v), loc: Double(page)))
            }
        case .doc:
            // Long documents: one text vector per passage after the first, which the file's own vector covers.
            // Src.text keeps them out of Search's page/time display (a .docx cannot be opened at a page).
            guard let parts = stored ?? Extract.keywordPassagesResult(url, kind: .doc) else { return nil }
            for p in parts.filter({ $0.src == .text && $0.loc >= 1 }).sorted(by: { $0.loc < $1.loc }).prefix(passageVectors) {
                guard let v = embedder.document(title: "\(title) part \(Int(p.loc) + 1)", body: p.text) else { return nil }
                vectors.append(MediaVector(src: .text, data: quantize(v), loc: p.loc))
            }
        default: break
        }
        return (vectors, snippet)
    }

    // A disabled source is always "read" (as nothing), so its rows go at once, and one just enabled is read at once.
    // `signature` is "off", "on", or the browser databases' mtimes; browsers write their history on every visit, so
    // a 5-minute floor keeps active browsing from re-reading it on every file-change run.
    static func sourceDue(full: Bool, enabled: Bool, now: Double, last: Double, signature: String, previous: String) -> Bool {
        full || !enabled || now - last >= sourceInterval || now < last || previous == "off" ||
            (signature != previous && now - last >= 300)
    }

    // p.hasPrefix(d + "/") for some d in `dirs`; many dirs are looked up by p's ancestors instead
    static func inside(_ p: String, _ dirs: Set<String>) -> Bool {
        if dirs.count < 8 { return dirs.contains { p.hasPrefix($0 + "/") } }
        var i = p.utf8.startIndex
        while let j = p.utf8[i...].firstIndex(of: UInt8(ascii: "/")) {
            let d = String(p[..<j])
            if dirs.contains(d), p.hasPrefix(d + "/") { return true }
            i = p.utf8.index(after: j)
        }
        return false
    }

    // --paths <file>: folders whose entries changed, one per line, written by the bar's file watcher
    static func argPaths() -> [String]? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--paths"), i + 1 < a.count,
              let s = try? String(contentsOfFile: a[i + 1], encoding: .utf8) else { return nil }
        return s.split(separator: "\n").map(String.init)
    }

    static func run(full: Bool, namesOnly: Bool = false, paths: [String]? = argPaths()) -> Int32 {
        let fd = open(Paths.lock, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { log("cannot open indexer lock"); return 1 }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { log("indexer already running"); return 0 }
        guard let store = Store() else { log("cannot open index"); return 1 }
        migrate(store)
        let progress = IndexProgress(store)
        defer { progress.clear() }
        var wrote = false
        defer { if wrote { store.bumpGeneration() } }
        let multimodal = FileManager.default.fileExists(atPath: Paths.mmproj)
        let now = Date().timeIntervalSince1970

        var full = full
        if full || store.metaString("model") != modelTag {
            store.exec("DELETE FROM content; DELETE FROM vecs; DELETE FROM files;")
            store.setMeta("model", string: modelTag)
            full = true
            wrote = true
        }
        let incremental = !full && paths != nil
        let rootList = roots()
        let pathSet = Set(paths ?? [])
        let listed = incremental ? pathSet.filter { d in rootList.contains(where: { d == $0 || d.hasPrefix($0 + "/") }) && start(d, roots: rootList) != nil } : []

        struct Old { let id: Int64; let mtime: Double; let size: Int; let kind: Int; let revision: String; let hash: String }
        var old: [String: Old] = [:]
        func loadOld(_ filter: String = "", _ args: [Any] = []) {
            store.run("SELECT id, path, mtime, size, kind, sourceRevision, contentHash FROM files" + filter, args) { st in
                old[colText(st, 1)] = Old(id: sqlite3_column_int64(st, 0), mtime: sqlite3_column_double(st, 2), size: Int(sqlite3_column_int64(st, 3)),
                                          kind: Int(sqlite3_column_int(st, 4)), revision: colText(st, 5), hash: colText(st, 6))
            }
        }
        // A file-change run only looks up or deletes rows under the folders it lists, and non-file rows (replaced
        // whenever their source is read). A byte range ('0' sorts right after '/') matches Swift's string
        // comparison only for ASCII folders, so any other spelling loads everything.
        if incremental, listed.allSatisfy({ $0.utf8.allSatisfy { $0 < 0x80 } }) {
            for d in listed where !listed.contains(where: { $0 != d && d.hasPrefix($0 + "/") }) {
                loadOld(" WHERE path >= ? AND path < ?", [d + "/", d + "0"])
            }
            loadOld(" WHERE kind > ?", [Kind.folder.rawValue])
        } else {
            loadOld()
        }

        var cands: [Cand] = []
        // Preserve only paths whose enumeration failed; a readable empty root means deletion.
        var blind: [String] = []
        // incremental: the folders listed this run; only their direct entries (and vanished subfolders) may be deleted
        var scanned = Set<String>()
        if incremental {
            for d in pathSet where listed.contains(d) {
                scanned.insert(d)
                let found = walk(d, recursive: false, roots: rootList, onError: { blind.append($0) })
                cands += found
                // a folder the index has not seen (created, or moved or renamed in) is walked whole
                for f in found where f.kind == .folder && old[f.path] == nil {
                    cands += walk(f.path, roots: rootList, onError: { blind.append($0) })
                }
            }
        } else {
            cands = apps()
            for r in rootList { cands += walk(r, roots: rootList, onError: { blind.append($0) }) }
        }
        // Other sources have their own cadence: re-read hourly, when a browser's database changed, or on --full.
        // One that is not due, or cannot be read right now, keeps the rows it already has.
        var keepKinds: Set<Int> = [Kind.clip.rawValue] // clipboard rows belong to the bar process
        var readSources: [(String, String)] = []
        for (name, kind, read) in [("web", Kind.web, Sources.web), ("calendar", .event, Sources.events), ("contacts", .contact, Sources.contacts), ("notes", .note, Sources.notes)] {
            let sig = !Sources.enabled(name) ? "off" : name == "web" ? Sources.webSignature() : "on"
            let due = sourceDue(full: full, enabled: Sources.enabled(name), now: now, last: Double(store.metaString("source.\(name).read") ?? "") ?? 0,
                                signature: sig, previous: store.metaString("source.\(name).sig") ?? "")
            guard due, let items = read() else { keepKinds.insert(kind.rawValue); continue }
            readSources.append((name, sig))
            cands += items.map { Cand(path: $0.key, name: $0.name, kind: $0.kind, mtime: $0.mtime, size: 0, body: $0.body) }
        }

        var seen = Set<String>()
        cands = cands.filter { seen.insert($0.path).inserted }.sorted { $0.mtime > $1.mtime }

        let blindSet = Set(blind)
        let isBlind = { (p: String) in blindSet.contains(p) || inside(p, blindSet) }
        let vanished = incremental ? Set(old.filter { p, o in
            o.kind == Kind.folder.rawValue && !seen.contains(p) && scanned.contains((p as NSString).deletingLastPathComponent) && !isBlind(p)
        }.map(\.key)) : []
        func authoritative(_ p: String, _ o: Old) -> Bool {
            if keepKinds.contains(o.kind) || isBlind(p) { return false }
            guard incremental, Kind(rawValue: o.kind)?.isFile ?? true else { return true }
            return scanned.contains((p as NSString).deletingLastPathComponent) || inside(p, vanished)
        }
        store.exec("BEGIN")
        for (path, o) in old where !seen.contains(path) && authoritative(path, o) {
            store.deleteFile(o.id)
            wrote = true
        }
        store.exec("COMMIT")

        let todo = cands.map { ($0, $0.sourceRevision) }.filter { c, revision in
            guard let o = old[c.path] else { return true }
            return o.mtime != c.mtime || o.size != c.size || o.revision != revision
        }
        if !todo.isEmpty { wrote = true }
        // Publish names first, before loading a model or extracting any content.
        // state: 3 = text pending, 4 = metadata only, 0 = media pending, 1 = complete, 2 = clipboard.
        store.exec("BEGIN")
        for (c, revision) in todo {
            guard let o = old[c.path] else {
                store.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet,sourceRevision) VALUES(?,?,?,?,?,?,?,?)",
                          [c.path, c.name, c.kind.rawValue, c.mtime, c.size, c.semantic ? 3 : 4, c.body ?? "", revision])
                continue
            }
            if c.body == nil, ![.folder, .app].contains(c.kind), o.kind == c.kind.rawValue, !o.hash.isEmpty, Extract.contentHash(c.path) == o.hash {
                // touched or copied over with the same bytes: content, vectors and state stand
                store.run("UPDATE files SET name=?,mtime=?,size=? WHERE id=?", [c.name, c.mtime, c.size, o.id])
                continue
            }
            // Changed in place: the id stays, and the old text and vectors stay searchable until each pass replaces them.
            store.run("""
            UPDATE files SET name=?,kind=?,mtime=?,size=?,state=?,snippet=COALESCE(?,snippet),sourceRevision=?,
                textIndexed=0,attempts=0,retryAt=0,contentHash='' WHERE id=?
            """, [c.name, c.kind.rawValue, c.mtime, c.size, c.semantic ? 3 : 4, c.body.map { $0 as Any } ?? NSNull(), revision, o.id])
        }
        for (name, sig) in readSources {
            store.setMeta("source.\(name).read", string: String(now))
            store.setMeta("source.\(name).sig", string: sig)
        }
        progress.begin("names", total: cands.count)
        progress.tick(cands.count, label: "names ready · \(cands.count) items", force: true)
        store.exec("COMMIT")
        log("indexing\(incremental ? " \(scanned.count) changed folders" : ""): \(cands.count) items, \(todo.count) new or changed; names ready")
        if namesOnly { return 0 }

        var failed = Set<Int64>()
        // counts at most once per run; true once the file has been given up on
        func fail(_ id: Int64) -> Bool {
            if failed.insert(id).inserted { return recordFailure(store, id: id, now: now) }
            var n = 0
            store.run("SELECT attempts FROM files WHERE id=?", [id]) { n = Int(sqlite3_column_int64($0, 0)) }
            return n >= maxAttempts
        }
        let deferMedia = IndexPower.deferMedia
        let vision = multimodal && !deferMedia
        let ids = { (kinds: [Kind]) in kinds.map { String($0.rawValue) }.joined(separator: ",") }

        // Exact text is independent of embeddings too. Backfill existing files once after migration.
        var textKinds: [Kind] = [.doc, .image, .other]
        if !deferMedia && Extract.speechReady { textKinds += [.audio, .video] }
        var contentPending: [(Int64, String, Kind)] = []
        store.run("SELECT id,path,kind FROM files WHERE textIndexed=0 AND state NOT IN (2,4) AND retryAt<=? AND kind IN (\(ids(textKinds))) ORDER BY mtime DESC", [now]) { st in
            contentPending.append((sqlite3_column_int64(st, 0), colText(st, 1), Kind(rawValue: Int(sqlite3_column_int(st, 2))) ?? .other))
        }
        if !contentPending.isEmpty { wrote = true }
        progress.begin("text", total: contentPending.count)
        var speechLeft = 1800.0 // seconds of audio transcribed per run; the rest waits for the next one
        for (i, (id, path, kind)) in contentPending.enumerated() {
            autoreleasepool {
                let url = URL(fileURLWithPath: path)
                var passages: [Extract.Passage]?
                if kind == .audio || kind == .video {
                    guard speechLeft >= 30 else { return }
                    let r = Extract.transcriptResult(url, maxSeconds: min(600, speechLeft))
                    speechLeft -= r?.seconds ?? 60
                    passages = r?.passages
                } else {
                    passages = Extract.keywordPassagesResult(url, kind: kind)
                }
                guard persistContentExtraction(store, id: id, passages: passages, hash: { Extract.contentHash(path) ?? "" }) else { _ = fail(id); return }
                // new passages need their vectors even when the file's own text vector is current
                if kind == .doc, (passages?.count ?? 0) > 1 { store.run("UPDATE files SET state=0 WHERE id=? AND state=1", [id]) }
            }
            progress.tick(i + 1)
        }

        var textPending: [(Int64, Cand, Int, Bool)] = []
        store.run("SELECT id,path,name,kind,mtime,size,snippet,attempts,textIndexed FROM files WHERE state=3 AND retryAt<=? ORDER BY mtime DESC", [now]) { st in
            let kind = Kind(rawValue: Int(sqlite3_column_int(st, 3))) ?? .other
            textPending.append((sqlite3_column_int64(st, 0), Cand(path: colText(st, 1), name: colText(st, 2), kind: kind,
                mtime: sqlite3_column_double(st, 4), size: Int(sqlite3_column_int64(st, 5)),
                body: kind.isFile ? nil : colText(st, 6)), Int(sqlite3_column_int(st, 7)), sqlite3_column_int(st, 8) == 1))
        }
        let visionKinds: [Kind] = [.image, .audio, .video]
        let mediaKinds: [Kind] = [.doc, .other] + (vision ? visionKinds : [])
        var mediaPending = 0, visionPending = false
        store.run("SELECT kind, count(*) FROM files WHERE state=0 AND retryAt<=? GROUP BY kind", [now]) { st in
            guard let k = Kind(rawValue: Int(sqlite3_column_int(st, 0))), mediaKinds.contains(k) else { return }
            mediaPending += Int(sqlite3_column_int64(st, 1))
            if visionKinds.contains(k) { visionPending = true }
        }
        if textPending.isEmpty && mediaPending == 0 { return 0 }
        wrote = true
        // the vision/audio encoders are only loaded when something will use them this run
        visionPending = vision && (visionPending || textPending.contains { visionKinds.contains($0.1.kind) })
        guard let emb = Embedder(multimodal: visionPending, nCtx: 1024) else { log("names searchable; content model unavailable"); return 1 }
        progress.begin("contents", total: textPending.count)
        for (i, (id, c, attempts, textIndexed)) in textPending.enumerated() {
            autoreleasepool {
                let stored = textIndexed && [.doc, .other, .audio, .video].contains(c.kind) ? storedPassages(store, id: id) : nil
                var described = describe(c, stored: stored)
                if described == nil, attempts >= maxAttempts || fail(id) { described = placeholder(c) }
                guard let (title, body, snippet) = described else { return }
                let pdf = c.kind == .doc && c.path.lowercased().hasSuffix(".pdf")
                let passages = c.kind == .doc && (stored?.filter { $0.src == .text }.count ?? 0) > 1
                let needsMedia = (multimodal && visionKinds.contains(c.kind)) || pdf || passages
                // Failed embeddings stay pending so a later indexing pass can retry.
                guard let v = emb.document(title: title, body: body) else { _ = fail(id); return }
                let hash = c.kind.isFile && c.kind != .folder && c.kind != .app ? Extract.contentHash(c.path) ?? "" : ""
                store.exec("BEGIN")
                store.run("DELETE FROM vecs WHERE file_id=? AND src=?", [id, Src.text.rawValue])
                store.run("INSERT INTO vecs(file_id,src,v) VALUES(?,?,?)", [id, Src.text.rawValue, quantize(v)])
                store.run("UPDATE files SET state=?,snippet=?,contentHash=CASE WHEN contentHash='' THEN ? ELSE contentHash END WHERE id=?",
                          [needsMedia ? 0 : 1, snippet, hash, id])
                store.exec("COMMIT")
            }
            progress.tick(i + 1)
        }

        // pass 2: look at / listen to the media itself, and embed PDF pages and long-document passages
        var media: [(Int64, String, Kind, Bool)] = []
        store.run("SELECT id,path,kind,textIndexed FROM files WHERE state=0 AND retryAt<=? AND kind IN (\(ids(mediaKinds))) ORDER BY mtime DESC", [now]) { st in
            media.append((sqlite3_column_int64(st, 0), colText(st, 1), Kind(rawValue: Int(sqlite3_column_int(st, 2))) ?? .other, sqlite3_column_int(st, 3) == 1))
        }
        if deferMedia { log("on battery, in Low Power Mode or hot: image, audio and video analysis deferred") }
        progress.begin("media", total: media.count)
        for (i, (id, path, kind, textIndexed)) in media.enumerated() {
            autoreleasepool {
                let stored = textIndexed && [.doc, .image].contains(kind) ? storedPassages(store, id: id) : nil
                let result = mediaVectors(URL(fileURLWithPath: path), kind: kind, embedder: emb, stored: stored)
                if !persistMediaExtraction(store, id: id, vectors: result?.vectors, snippet: result?.snippet) { _ = fail(id) }
            }
            progress.tick(i + 1, label: "contents \(i + 1)/\(media.count)")
        }
        log("indexing done")
        return 0
    }
}
