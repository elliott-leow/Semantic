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
            return SHA256.hash(data: Data((name + "\0" + body).utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func roots() -> [String] {
        if let r = config.roots { return r.map { ($0 as NSString).expandingTildeInPath } }
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: Paths.home)) ?? []).sorted().compactMap { n in
            var isDir: ObjCBool = false
            let p = Paths.home + "/" + n
            guard !n.hasPrefix("."), !skipDirs.contains(n), fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
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

    static func walk(_ root: String, onError: ((String) -> Void)? = nil) -> [Cand] {
        let fm = FileManager.default
        do { _ = try fm.contentsOfDirectory(atPath: root) }
        catch {
            let e = error as NSError
            if !(e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code)) { onError?(root) }
            return []
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in onError?(url.path); return true }) else { onError?(root); return [] }
        var out: [Cand] = []
        var repo: String?
        let homeDepth = Paths.home.split(separator: "/").count
        for case let url as URL in en {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { onError?(url.path); continue }
            let path = url.path, name = url.lastPathComponent
            if let r = repo, !path.hasPrefix(r + "/") { repo = nil }
            let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
            if rv.isDirectory == true, rv.isPackage != true {
                if skipDirs.contains(name) || name.hasSuffix(".egg-info") || fm.fileExists(atPath: path + "/pyvenv.cfg") {
                    en.skipDescendants()
                    continue
                }
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
            let semantic = !Extract.junkExts.contains(ext) && !["pem", "key", "p12", "pfx", "mobileprovision", "cer", "crt", "kdbx"].contains(ext) &&
                !(repo != nil && (kind == .other || (kind == .image && size < 20_000)))
            out.append(Cand(path: path, name: name, kind: kind, mtime: mtime, size: size, semantic: semantic))
        }
        return out
    }

    static func clean(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
    }

    // (title, body, snippet) for the text vector
    static func describe(_ c: Cand) -> (String, String, String)? {
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
            guard let body = Extract.textResult(url, ext: ext) else { return nil }
            return (clean(c.name), body.isEmpty ? "\(ext) document in \(parent)" : body, String(body.prefix(200)))
        case .image:
            return (clean(c.name), "image in \(parent)", "")
        case .audio:
            return (clean(c.name), "audio recording in \(parent)", "")
        case .video:
            return (clean(c.name), "video in \(parent)", "")
        case .other:
            var body = ""
            if Extract.codeExts.contains(ext) {
                guard let extracted = Extract.textResult(url, ext: ext, limit: 600) else { return nil }
                body = extracted
            }
            return (c.name, body.isEmpty ? "\(ext) file in \(parent)" : body, "")
        default:
            return (c.name, "", "")
        }
    }

    // Extraction failure preserves the previous searchable text and its pending flag.
    @discardableResult
    static func persistContentExtraction(_ store: Store, id: Int64, passages: [Extract.Passage]?) -> Bool {
        guard let passages else { return false }
        store.exec("BEGIN")
        store.run("DELETE FROM content WHERE file_id=?", [id])
        for part in passages { store.addContent(id, part.text, src: part.src, loc: part.loc) }
        store.run("UPDATE files SET textIndexed=1 WHERE id=?", [id])
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
    @discardableResult
    static func persistMediaExtraction(_ store: Store, id: Int64, vectors: [MediaVector]?, snippet: String? = nil) -> Bool {
        guard let vectors else { return false }
        store.exec("BEGIN")
        store.run("DELETE FROM vecs WHERE file_id=? AND src IN (?,?,?)", [id, Src.media.rawValue, Src.ocr.rawValue, Src.page.rawValue])
        for v in vectors {
            store.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [id, v.src.rawValue, v.data, v.loc])
        }
        if let snippet { store.run("UPDATE files SET state=1,snippet=? WHERE id=?", [snippet, id]) }
        else { store.run("UPDATE files SET state=1 WHERE id=?", [id]) }
        store.exec("COMMIT")
        return true
    }

    static func mediaVectors(_ url: URL, kind: Kind, embedder: Embedder) -> (vectors: [MediaVector], snippet: String?)? {
        var vectors: [MediaVector] = []
        var snippet: String?
        switch kind {
        case .image:
            guard let cg = Extract.image(url, maxPixel: 896) else { return nil }
            // Valid tiny images have no useful model input, but are not failures.
            guard cg.width >= 48, cg.height >= 48 else { return ([], nil) }
            guard let v = embedder.image(cg) else { return nil }
            vectors.append(MediaVector(src: .media, data: quantize(v)))
            guard let big = Extract.image(url, maxPixel: 2200), let text = Extract.ocrResult(big) else { return nil }
            if text.count >= 12 {
                guard let v = embedder.document(title: clean(url.lastPathComponent), body: String(text.prefix(2500))) else { return nil }
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
        case .doc:
            guard let pages = Extract.pdfPagesResult(url) else { return nil }
            let title = clean(url.lastPathComponent)
            for (page, text) in pages {
                guard let v = embedder.document(title: "\(title) page \(page)", body: text) else { return nil }
                vectors.append(MediaVector(src: .page, data: quantize(v), loc: Double(page)))
            }
        default: break
        }
        return (vectors, snippet)
    }

    static func run(full: Bool, namesOnly: Bool = false) -> Int32 {
        let fd = open(Paths.lock, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { log("cannot open indexer lock"); return 1 }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { log("indexer already running"); return 0 }
        guard let store = Store() else { log("cannot open index"); return 1 }
        let multimodal = FileManager.default.fileExists(atPath: Paths.mmproj)

        if full || store.metaString("model") != modelTag {
            store.exec("DELETE FROM content; DELETE FROM vecs; DELETE FROM files;")
            store.setMeta("model", string: modelTag)
        }

        struct Old { let id: Int64; let mtime: Double; let size: Int; let kind: Int; let revision: String }
        var old: [String: Old] = [:]
        store.run("SELECT id, path, mtime, size, kind, sourceRevision FROM files") { st in
            old[colText(st, 1)] = Old(id: sqlite3_column_int64(st, 0), mtime: sqlite3_column_double(st, 2), size: Int(sqlite3_column_int64(st, 3)),
                                      kind: Int(sqlite3_column_int(st, 4)), revision: colText(st, 5))
        }

        var cands = apps()
        // Preserve only paths whose enumeration failed; a readable empty root means deletion.
        var blind: [String] = []
        for r in roots() {
            let found = walk(r, onError: { blind.append($0) })
            cands += found
        }
        // other sources; one that cannot be read right now keeps the rows it already has
        var keepKinds: Set<Int> = [Kind.clip.rawValue] // clipboard rows belong to the bar process
        for (kind, read) in [(Kind.web, Sources.web), (.event, Sources.events), (.contact, Sources.contacts), (.note, Sources.notes)] {
            guard let items = read() else { keepKinds.insert(kind.rawValue); continue }
            cands += items.map { Cand(path: $0.key, name: $0.name, kind: $0.kind, mtime: $0.mtime, size: 0, body: $0.body) }
        }

        var seen = Set<String>()
        cands = cands.filter { seen.insert($0.path).inserted }.sorted { $0.mtime > $1.mtime }

        store.exec("BEGIN")
        for (path, o) in old where !seen.contains(path) && !keepKinds.contains(o.kind) && !blind.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            store.deleteFile(o.id)
        }
        store.exec("COMMIT")

        let todo = cands.filter { c in
            guard let o = old[c.path] else { return true }
            return o.mtime != c.mtime || o.size != c.size || o.revision != c.sourceRevision
        }
        // Publish names first, before loading a model or extracting any content.
        // state: 3 = text pending, 4 = metadata only, 0 = media pending, 1 = complete, 2 = clipboard.
        store.exec("BEGIN")
        for c in todo {
            if let o = old[c.path] { store.deleteFile(o.id) }
            store.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet,sourceRevision) VALUES(?,?,?,?,?,?,?,?)",
                      [c.path, c.name, c.kind.rawValue, c.mtime, c.size, c.semantic ? 3 : 4, c.body ?? "", c.sourceRevision])
        }
        store.setMeta("progress", string: "names ready · \(cands.count) items")
        store.exec("COMMIT")
        log("indexing: \(cands.count) items, \(todo.count) new or changed; names ready")
        if namesOnly {
            store.setMeta("progress", nil)
            return 0
        }
        // Exact text is independent of embeddings too. Backfill existing files once after migration.
        var contentPending: [(Int64, String, Kind)] = []
        let contentPaths = Set(cands.filter { $0.semantic && [.doc, .image, .other].contains($0.kind) }.map(\.path))
        store.run("SELECT id,path,kind FROM files WHERE textIndexed=0 ORDER BY mtime DESC") { st in
            let path = colText(st, 1)
            if contentPaths.contains(path) {
                contentPending.append((sqlite3_column_int64(st, 0), path, Kind(rawValue: Int(sqlite3_column_int(st, 2))) ?? .other))
            }
        }
        for (i, item) in contentPending.enumerated() {
            let (id, path, kind) = item
            autoreleasepool {
                persistContentExtraction(store, id: id, passages: Extract.keywordPassagesResult(URL(fileURLWithPath: path), kind: kind))
            }
            if i % 10 == 0 { store.setMeta("progress", string: "text \(i + 1)/\(contentPending.count)") }
        }
        var textPending: [(Int64, Cand)] = []
        store.run("SELECT id,path,name,kind,mtime,size,snippet FROM files WHERE state=3 ORDER BY mtime DESC") { st in
            let kind = Kind(rawValue: Int(sqlite3_column_int(st, 3))) ?? .other
            textPending.append((sqlite3_column_int64(st, 0), Cand(path: colText(st, 1), name: colText(st, 2), kind: kind,
                mtime: sqlite3_column_double(st, 4), size: Int(sqlite3_column_int64(st, 5)),
                body: kind.isFile ? nil : colText(st, 6))))
        }
        var pending = 0
        store.run("SELECT count(*) FROM files WHERE state=0") { pending = Int(sqlite3_column_int64($0, 0)) }
        if textPending.isEmpty && pending == 0 { store.setMeta("progress", nil); return 0 }
        guard let emb = Embedder(multimodal: multimodal, nCtx: 1024) else { log("names searchable; content model unavailable"); return 1 }
        for (i, item) in textPending.enumerated() {
            let (id, c) = item
            autoreleasepool {
                guard let (title, body, snippet) = describe(c) else { return }
                let needsMedia = (multimodal && [.image, .audio, .video].contains(c.kind)) || c.path.lowercased().hasSuffix(".pdf")
                // Failed embeddings stay pending so a later indexing pass can retry.
                if let v = emb.document(title: title, body: body) {
                    store.exec("BEGIN")
                    store.run("DELETE FROM vecs WHERE file_id=? AND src=?", [id, Src.text.rawValue])
                    store.run("INSERT INTO vecs(file_id,src,v) VALUES(?,?,?)", [id, Src.text.rawValue, quantize(v)])
                    store.run("UPDATE files SET state=?,snippet=? WHERE id=?", [needsMedia ? 0 : 1, snippet, id])
                    store.exec("COMMIT")
                }
            }
            if i % 25 == 24 { store.setMeta("progress", string: "contents \(i + 1)/\(textPending.count)") }
        }

        // pass 2: look at / listen to the media itself
        var media: [(Int64, String, Kind)] = []
        store.run("SELECT id, path, kind FROM files WHERE state=0 ORDER BY mtime DESC") { st in
            media.append((sqlite3_column_int64(st, 0), colText(st, 1), Kind(rawValue: Int(sqlite3_column_int(st, 2))) ?? .other))
        }
        for (i, (id, path, kind)) in media.enumerated() {
            autoreleasepool {
                let url = URL(fileURLWithPath: path)
                let result = mediaVectors(url, kind: kind, embedder: emb)
                persistMediaExtraction(store, id: id, vectors: result?.vectors, snippet: result?.snippet)
            }
            if i % 10 == 9 {
                store.setMeta("progress", string: "contents \(i + 1)/\(media.count)")
            }
        }
        store.setMeta("progress", nil)
        log("indexing done")
        return 0
    }
}
