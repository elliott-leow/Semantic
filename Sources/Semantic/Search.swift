import Accelerate
import AppKit
import Foundation
import SQLite3

// Constants only; a class so hot loops read fields in place instead of copying a dozen references.
final class Entry {
    let path: String      // file path, or URL / opaque key for non-file kinds
    let name: String
    let lname: String
    let stem: String      // lname without its extension
    let words: [String]   // stem tokens other than stopwords
    let stemCount: Int    // all stem tokens
    let ascii: Bool       // lname is ASCII, so substring tests can compare bytes
    let pathTokens: [String]
    let pathAscii: Bool   // so are the path tokens
    let lpath: String
    let tokens: [String]
    let initials: String
    let kind: Kind
    let mtime: Double
    let size: Int
    let ext: String
    let snippet: String   // kept only for kinds that are shown or acted on by their text
    let dupKey: String    // equal for copies of the same file

    init(path: String, name: String, lname: String, stem: String, words: [String], stemCount: Int, ascii: Bool, pathTokens: [String],
         pathAscii: Bool, lpath: String, tokens: [String], initials: String, kind: Kind, mtime: Double, size: Int, ext: String,
         snippet: String, dupKey: String) {
        self.path = path; self.name = name; self.lname = lname; self.stem = stem; self.words = words; self.stemCount = stemCount
        self.ascii = ascii; self.pathTokens = pathTokens; self.pathAscii = pathAscii; self.lpath = lpath; self.tokens = tokens
        self.initials = initials; self.kind = kind; self.mtime = mtime; self.size = size; self.ext = ext; self.snippet = snippet; self.dupKey = dupKey
    }
}

// Snapshot of the index: entries plus one int8 matrix of vectors. Only the engine queue appends rows.
final class Index {
    var entries: [Entry] = []
    var rowEntry: [Int32] = []
    var rowSrc: [UInt8] = []
    var rowLoc: [Float] = []
    var rowNorm: [Float] = []
    var byPath: [String: Int] = [:]
    var folders = Set<String>()
    var names = Set<String>()   // file names and names without extension, lowercased
    var lpaths = Set<String>()  // lowercased file paths
    var dirs = Set<String>()    // lowercased folder names occurring in some file's path
    var byID: [Int64: Int] = [:]
    var contentStore: Store?
    private(set) var vecs: UnsafeMutablePointer<Int8>?
    private var capacity = 0
    private var sortedRows = 0           // rows loaded in entry order, found by binary search
    private var addedRows: [Int: [Int]] = [:]
    var rows: Int { rowEntry.count }

    deinit { vecs?.deallocate() }

    static func load(store: Store? = Store(readonly: true), vectors: Bool = true) -> Index {
        let ix = Index()
        guard let store else { return ix }
        ix.contentStore = store
        // A read transaction keeps metadata and vector row mappings in the same snapshot.
        store.exec("BEGIN")
        defer { store.exec("COMMIT") }
        ix.loadMetadata(store)
        if vectors { ix.loadVectors(store) }
        return ix
    }

    func loadMetadata(_ store: Store) {
        var ids: [Int64: Int] = [:], parents = Set<String>()
        var folderTokens: [String: (String, [String], Bool)] = [:]  // files in one folder share its tokens
        store.run("SELECT id,path,name,kind,mtime,size,snippet FROM files ORDER BY id") { [self] st in
            let name = colText(st, 2), path = colText(st, 1)
            let kind = Kind(rawValue: Int(sqlite3_column_int(st, 3))) ?? .other
            let toks = nameTokens(name), size = Int(sqlite3_column_int64(st, 5))
            let ext = kind.isFile ? (name as NSString).pathExtension.lowercased() : ""
            let lname = name.lowercased(), lpath = path.lowercased()
            // NSString results are bridged; a native copy compares several times faster
            var stem = (lname as NSString).deletingPathExtension
            stem.makeContiguousUTF8()
            let stemToks = nameTokens(stem)
            var base = (name as NSString).deletingPathExtension.lowercased()
            // a match ends in ")" or holds "copy"; most names have neither
            if base.utf8.contains(0x29) || Engine.bytesContain(base, "copy") {
                base = Rx.replace(base, "(\\s*\\(\\d+\\)|\\s+copy(\\s+\\d+)?)+$", "")
            }
            // Do not collapse numbered chapters or unrelated same-size files in other folders.
            let parent = (path as NSString).deletingLastPathComponent
            // String keys compare canonically; reuse only for the very same bytes
            let (ptoks, pascii) = folderTokens[parent].flatMap { $0.0.utf8.elementsEqual(parent.utf8) ? ($0.1, $0.2) : nil } ?? {
                let t = nameTokens(parent), ascii = t.allSatisfy { $0.utf8.allSatisfy { $0 < 0x80 } }
                folderTokens[parent] = (parent, t, ascii)
                return (t, ascii)
            }()
            let dup = kind.isFile && kind != .folder && kind != .app && size > 0 ? "\(parent)/\(base).\(ext)#\(size)" : path
            ids[sqlite3_column_int64(st, 0)] = entries.count
            byPath[path] = entries.count
            if kind == .folder { folders.insert(lname) }
            if kind.isFile {
                names.insert(lname); names.insert(stem); lpaths.insert(lpath)
                let lparent = (lpath as NSString).deletingLastPathComponent
                if parents.insert(lparent).inserted {
                    for c in lparent.split(separator: "/") { dirs.insert(String(c)) }
                }
            }
            entries.append(Entry(path: path, name: name, lname: lname, stem: stem, words: stemToks.filter { !stopwords.contains($0) },
                                 stemCount: stemToks.count, ascii: lname.utf8.allSatisfy { $0 < 0x80 }, pathTokens: ptoks, pathAscii: pascii, lpath: lpath, tokens: toks,
                                 initials: String(toks.compactMap(\.first)), kind: kind,
                                 mtime: sqlite3_column_double(st, 4), size: size, ext: ext,
                                 snippet: kind.isFile ? "" : colText(st, 6), dupKey: dup))
        }
        byID = ids
    }

    func loadVectors(_ store: Store) {
        var n = 0
        store.run("SELECT count(*) FROM vecs") { n = Int(sqlite3_column_int64($0, 0)) }
        guard n > 0 else { return }
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: n * DIM)
        vecs?.deallocate()
        vecs = buf
        capacity = n
        var sorted = true
        store.run("SELECT file_id,src,v,loc FROM vecs ORDER BY file_id") { [self] st in
            let src = Int(sqlite3_column_int(st, 1))
            guard let i = byID[sqlite3_column_int64(st, 0)], (0..<SRC_COUNT).contains(src),
                  rows < n, sqlite3_column_bytes(st, 2) == DIM, let blob = sqlite3_column_blob(st, 2) else { return }
            memcpy(buf + rows * DIM, blob, DIM)
            if let last = rowEntry.last, last > Int32(i) { sorted = false }
            rowEntry.append(Int32(i))
            rowSrc.append(UInt8(src))
            rowLoc.append(Float(sqlite3_column_double(st, 3)))
        }
        rowNorm = [Float](repeating: 0, count: rows)
        sb_norms_i8(buf, rows, &rowNorm)
        if sorted { sortedRows = rows } else {
            for r in 0..<rows { addedRows[Int(rowEntry[r]), default: []].append(r) }
        }
    }

    // Value arrays are shared until mutated; never share a SQLite connection between queues.
    func metadataSnapshot(store: Store? = nil) -> Index {
        let ix = Index()
        ix.entries = entries
        ix.byPath = byPath
        ix.byID = byID
        ix.folders = folders
        ix.names = names
        ix.lpaths = lpaths
        ix.dirs = dirs
        ix.contentStore = store
        return ix
    }

    // a folder of this (lowercased) name is somewhere on an indexed file's path
    func hasFolder(_ name: String) -> Bool { folders.contains(name) || dirs.contains(name) }

    func rows(of e: Int) -> [Int] {
        var lo = 0, hi = sortedRows
        while lo < hi { let m = (lo + hi) / 2; if rowEntry[m] < Int32(e) { lo = m + 1 } else { hi = m } }
        var out: [Int] = []
        while lo < sortedRows, rowEntry[lo] == Int32(e) { out.append(lo); lo += 1 }
        return out + (addedRows[e] ?? [])
    }

    // Puts one new vector in place (replacing the entry's only row from that source). False when
    // the snapshot cannot express the change and must be reloaded instead.
    func append(entry e: Int, src: Int, vector v: Data) -> Bool {
        guard v.count == DIM, e < entries.count else { return false }
        let same = rows(of: e).filter { Int(rowSrc[$0]) == src }
        if same.count > 1 { return false }
        let r: Int
        if let old = same.first { r = old; rowLoc[r] = 0 } else {
            if rows == capacity {
                capacity = max(64, capacity * 2)
                let buf = UnsafeMutablePointer<Int8>.allocate(capacity: capacity * DIM)
                if let vecs { buf.update(from: vecs, count: rows * DIM); vecs.deallocate() }
                vecs = buf
            }
            r = rows
            rowEntry.append(Int32(e)); rowSrc.append(UInt8(src)); rowLoc.append(0); rowNorm.append(0)
            addedRows[e, default: []].append(r)
        }
        guard let vecs else { return false }
        _ = v.withUnsafeBytes { memcpy(vecs + r * DIM, $0.baseAddress!, DIM) }
        sb_norms_i8(vecs + r * DIM, 1, &rowNorm[r])
        return true
    }

    func vector(row r: Int) -> [Float] {
        guard let vecs else { return [] }
        return (0..<DIM).map { Float(vecs[r * DIM + $0]) / QSCALE }
    }
}

struct SearchResult {
    static let fileLimit = 5
    var hits: [Hit]
    var note: String
    var lookup: String?  // a plain name search that found few files: worth asking Spotlight

    init(hits: [Hit], note: String = "") {
        var files = 0
        var seen = Set<String>()
        self.hits = hits.filter { h in
            guard let path = h.path else { return true }
            guard seen.insert(path).inserted else { return false }
            files += 1
            return files <= Self.fileLimit
        }
        self.note = note
    }
}

final class Engine {
    static let shared = Engine()

    private let queue = DispatchQueue(label: "semantic.engine", qos: .userInteractive)
    private let quickQueue = DispatchQueue(label: "semantic.file-search", qos: .userInteractive)
    private var quickIndex: Index
    private static let onQueue = DispatchSpecificKey<Bool>()
    private var index = Index()
    private var embedder: Embedder?
    private let warmQueue = DispatchQueue(label: "semantic.model-load", qos: .userInitiated)
    private var warming = false
    private var modelGeneration = 0
    private var intents: [Intent] = Actions.all + Commands.intents + [Assistant.intent]
    private var intentVecs: [Float] = []
    private var intentOf: [Int] = []
    private let lock = NSLock()
    private var generation = 0
    private var scratch = Scratch()
    private let spotQueue = DispatchQueue(label: "semantic.spotlight", qos: .userInitiated)
    var debug = false
    var learning = true   // off to measure ranking on its own (`--eval`)
    #if SEARCH_TESTS
    var spotlight = false
    #else
    var spotlight = true
    #endif

    // per-query buffers, reused on the engine queue
    private final class Scratch {
        var raw: [Float] = []
        var sem: [Float] = []
        var admitted: [Bool] = []
        var best: [Int32] = []
    }

    var onChange: (() -> Void)? // model became ready or the index was reloaded

    init(index: Index = Index(), embedder: Embedder? = nil, quickIndex: Index? = nil) {
        self.index = index
        self.quickIndex = quickIndex ?? index.metadataSnapshot()
        self.embedder = embedder
        queue.setSpecific(key: Self.onQueue, value: true)
    }

    // run on the engine queue, whether or not we are already on it
    func locked<T>(_ f: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.onQueue) == true ? f() : queue.sync(execute: f)
    }

    private final class Load {
        let ready = DispatchSemaphore(value: 0)
        var index: Index?
        var store: Store?
    }

    // Metadata is read once, inside the transaction that then reads vectors: file search gets it as soon
    // as it is read, even while the model queue is busy, and both queues keep their enqueue order.
    func reloadIndex() {
        let job = Load()
        quickQueue.async {
            defer { job.ready.signal() }
            guard let store = Store(readonly: true) else { self.quickIndex = Index(); return }
            store.exec("BEGIN")
            let ix = Index()
            ix.loadMetadata(store)
            ix.contentStore = store
            (job.index, job.store) = (ix, store)
            self.quickIndex = ix.metadataSnapshot(store: Store(readonly: true))
            DispatchQueue.main.async { self.onChange?() }
        }
        queue.async {
            job.ready.wait()
            guard let ix = job.index, let store = job.store else { self.index = Index(); return }
            ix.loadVectors(store)
            store.exec("COMMIT")
            self.index = ix
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    // on the engine queue: a full load now, shared with file search
    private func loadNow() {
        let ix = Index.load()
        index = ix
        let quick = ix.metadataSnapshot(store: Store(readonly: true))
        quickQueue.async { self.quickIndex = quick }
    }

    func warm(wait: Bool = false) {
        // The command-line verifier can wait; opening the bar must never wait for model loading.
        if wait {
            queue.sync {
                guard self.embedder == nil, let e = Embedder(multimodal: false, nCtx: 256) else { return }
                let prepared = Self.prepareIntents(e, self.intents)
                self.embedder = e
                (self.intentVecs, self.intentOf) = prepared
            }
            return
        }
        queue.async {
            if self.embedder != nil { self.embedPending(); return }
            guard !self.warming else { return }
            self.warming = true
            let generation = self.modelGeneration, intents = self.intents
            self.warmQueue.async {
                let e = Embedder(multimodal: false, nCtx: 256)
                let prepared = e.map { Self.prepareIntents($0, intents) }
                self.queue.async {
                    guard generation == self.modelGeneration else { return }
                    self.warming = false
                    self.embedder = e
                    if let prepared { (self.intentVecs, self.intentOf) = prepared }
                    DispatchQueue.main.async { self.onChange?() }
                    self.embedPending()
                }
            }
        }
    }

    func unload() {
        queue.async {
            self.modelGeneration += 1
            self.warming = false
            self.embedder = nil
        }
    }

    func sync(_ work: () -> Void) { queue.sync(execute: work) }

    private static func prepareIntents(_ e: Embedder, _ intents: [Intent]) -> ([Float], [Int]) {
        let all = intents.flatMap(\.exemplars)
        var h: UInt64 = 5381
        for b in (Indexer.modelTag + all.joined(separator: "|")).utf8 { h = h &* 33 &+ UInt64(b) }
        let key = "intents:\(h)"
        let store = Store()
        let intentOf = intents.enumerated().flatMap { i, it in Array(repeating: i, count: it.exemplars.count) }
        if let d = store?.meta(key), d.count == all.count * DIM * 4 {
            return (d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, intentOf)
        }
        let intentVecs = all.flatMap { e.query($0) ?? [Float](repeating: 0, count: DIM) }
        store?.setMeta(key, intentVecs.withUnsafeBufferPointer { Data(buffer: $0) })
        return (intentVecs, intentOf)
    }

    // rows the bar itself added (clipboard history) get their vectors here, with the text model
    private func embedPending() {
        guard let e = embedder, let store = Store() else { return }
        var todo: [(Int64, String, String)] = []
        store.run("SELECT id, name, snippet FROM files WHERE state = 2 LIMIT 5") { todo.append((sqlite3_column_int64($0, 0), colText($0, 1), colText($0, 2))) }
        guard !todo.isEmpty else { return }
        // clips copied since the last load are not in the snapshot: load once, then add vectors in place
        var reload = todo.contains { index.byID[$0.0] == nil }
        if reload { loadNow() }
        var completed = 0
        for (id, name, body) in todo {
            if let v = e.document(title: name, body: String(body.prefix(900))) {
                let q = quantize(v)
                store.exec("BEGIN")
                store.run("DELETE FROM vecs WHERE file_id=? AND src=?", [id, Src.text.rawValue])
                store.run("INSERT INTO vecs(file_id,src,v) VALUES(?,?,?)", [id, Src.text.rawValue, q])
                store.run("UPDATE files SET state = 1 WHERE id = ?", [id])
                store.exec("COMMIT")
                completed += 1
                if let i = index.byID[id], index.append(entry: i, src: Src.text.rawValue, vector: q) { continue }
                reload = true
            }
        }
        if reload { loadNow() }
        DispatchQueue.main.async { self.onChange?() }
        if todo.count == 5 && completed > 0 { queue.async { self.embedPending() } }
    }

    // MARK: learning from picks

    static func norm(_ q: String) -> String {
        Rx.replace(q.lowercased().trimmingCharacters(in: .whitespaces), "\\s+", " ")
    }

    // a chosen result, typed for or suggested; Habits keeps both the query and the routine
    func recordPick(_ query: String, _ key: String) {
        Habits.shared.recordPick(Self.norm(query), key)
    }

    private func boosts(_ q: String) -> [String: Float] { learning ? Habits.shared.boosts(q) : [:] }

    func indexed(_ key: String) -> Bool { locked { index.byPath[key] != nil } }

    // Before anything is typed: what habit says is wanted now (time of day, the app in front, recency).
    // Only things still present in the index are offered, so a deleted file or app quietly drops out.
    private func suggestions(_ ix: Index) -> SearchResult {
        var hits: [Hit] = []
        for (key, score) in Habits.shared.predictions(limit: 12) where hits.count < 6 {
            guard let i = ix.byPath[key] else { continue }
            let e = ix.entries[i]
            if e.kind.isFile, !FileManager.default.fileExists(atPath: e.path) { continue }
            var r = Ranked(i: i, score: score, lex: 0, loc: 0, src: 0)
            r.why.learned = score
            hits.append(hit(r, copies: 0, snapshot: ix))
        }
        return SearchResult(hits: hits, note: hits.isEmpty ? "" : "Suggested")
    }

    // MARK: lookups used by commands

    func findFolder(_ name: String) -> String? {
        locked {
            let n = name.lowercased()
            let c = index.entries.filter { $0.kind == .folder && $0.lname == n }.min { $0.path.count < $1.path.count }
            return (c ?? index.entries.filter { $0.kind == .folder && $0.lname.hasPrefix(n) }.min { $0.path.count < $1.path.count })?.path
        }
    }

    func findApp(_ name: String) -> String? {
        locked {
            let q = name.lowercased().trimmingCharacters(in: .whitespaces)
            let lq = LexQuery(q, nameTokens(q))
            return index.entries.filter { $0.kind == .app }.map { ($0, Self.lex(lq, $0)) }.filter { $0.1 >= 0.6 }.max { $0.1 < $1.1 }?.0.path
        }
    }

    // real files answering to a phrase like "the syllabus", best first; `strong` refuses a merely vague resemblance.
    // Documents are what people name this way, so they win ties against project files with a similar name.
    func bestFiles(_ phrase: String, strong: Bool = false, count: Int = 1) -> [String] {
        locked {
            let q = Rx.replace(phrase.lowercased(), "^(the|my|a|an|this|that) ", "")
            let ok: Set<Kind> = [.doc, .image, .audio, .video, .other]
            var r = rank(rest: q, filters: Filters(), gate: 3.4, boosts: [:]).filter { ok.contains(index.entries[$0.i].kind) }.prefix(25).map { x -> Ranked in
                var x = x
                let k = index.entries[x.i].kind
                x.score += k == .doc ? 0.8 : (k == .other ? -0.6 : 0)
                return x
            }
            r.sort { $0.score > $1.score }
            guard let top = r.first, !strong || top.lex >= 0.4 || top.score >= 5.4 else { return [] }
            var seen = Set<String>()
            return r.filter { seen.insert(index.entries[$0.i].dupKey).inserted }.prefix(count).map { index.entries[$0.i].path }
        }
    }

    func bestFile(_ phrase: String, strong: Bool = false) -> String? { bestFiles(phrase, strong: strong).first }

    func newestIndexed(kinds: Set<Kind>?, exts: Set<String>?, count: Int) -> [(String, Double)] {
        locked {
            index.entries.filter { e in
                guard e.kind.isFile, e.kind != .folder, e.kind != .app else { return false }
                if let exts { return exts.contains(e.ext) }
                if let kinds { return kinds.contains(e.kind) }
                return true
            }.sorted { $0.mtime > $1.mtime }.prefix(count).map { ($0.path, $0.mtime) }
        }
    }

    // MARK: search

    func search(_ text: String, chips: [String] = [], done: @escaping (SearchResult) -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        quickQueue.async {
            guard self.isCurrent(gen) else { return }
            if chips.isEmpty, text.isEmpty {
                self.deliver(self.suggestions(self.quickIndex), generation: gen, done: done)
                return
            }
            // both passes share one reading of the text as arithmetic
            let calc = chips.isEmpty ? Calc.answer(text) : nil
            let stale = { !self.isCurrent(gen) }
            if chips.isEmpty, let quick = self.quickFiles(text, calc: calc, stale: stale) {
                self.deliver(quick, generation: gen, done: done)
            }
            // Queue refinement after quick delivery was enqueued: it can never be followed
            // by an older preliminary result for the same generation.
            self.queue.async {
                guard self.isCurrent(gen) else { return }
                let r = self.build(text, chips: chips, calc: .some(calc), stale: stale)
                guard self.isCurrent(gen) else { return }
                self.deliver(r, generation: gen, done: done)
                if self.spotlight, let lookup = r.lookup { self.addSpotlight(lookup, to: r, generation: gen, done: done) }
            }
        }
    }

    private static let roots = Indexer.roots().map { $0 + "/" }

    // Files outside the indexed folders, by name, delivered as a follow-up when the index found few.
    private func addSpotlight(_ text: String, to r: SearchResult, generation gen: Int, done: @escaping (SearchResult) -> Void) {
        let ix = index, have = Set(r.hits.compactMap(\.path))
        let room = SearchResult.fileLimit - have.count
        guard room > 0 else { return }
        spotQueue.async {
            guard self.isCurrent(gen) else { return }
            let paths = Spotlight.names(text, limit: room) { p in
                have.contains(p) || ix.byPath[p] != nil || Self.roots.contains { p.hasPrefix($0) }
            }
            guard !paths.isEmpty else { return }
            self.queue.async {
                guard self.isCurrent(gen) else { return }
                var hits = r.hits
                let at = (hits.lastIndex { $0.path != nil }).map { $0 + 1 } ?? 0
                hits.insert(contentsOf: paths.map { p -> Hit in
                    var h = self.pathHit(p)
                    h.why = "Spotlight name match"
                    return h
                }, at: at)
                self.deliver(SearchResult(hits: hits, note: r.note), generation: gen, done: done)
            }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    private func deliver(_ result: SearchResult, generation: Int, done: @escaping (SearchResult) -> Void) {
        DispatchQueue.main.async {
            if self.isCurrent(generation) { done(result) }
        }
    }

    // Preliminary results are file lookups only. Resolver and local-action interpretation
    // stay on the model queue, so an uncertain command is never provisionally executable.
    private static func hasLiteralName(_ text: String, in index: Index) -> Bool {
        index.names.contains(text.lowercased()) || index.lpaths.contains((text as NSString).expandingTildeInPath.lowercased())
    }

    private func quickFiles(_ text: String, calc: CalcResult?, stale: (() -> Bool)? = nil) -> SearchResult? {
        guard !text.isEmpty else { return SearchResult(hits: []) }
        let ix = quickIndex, query = FileQuery(text, isCalc: calc != nil)
        if let error = query.error { return SearchResult(hits: [], note: error) }
        let literalName = Self.hasLiteralName(text, in: ix)
        if !query.explicit, !literalName {
            guard calc == nil, !Assistant.looksLikeQuestion(text),
                  Calc.rx(text.lowercased(), "^(?:please )?(?:convert|turn|change|export|save|make|rename|move|copy|zip|compress|resize|rotate|trash|delete|print|email|send|mail|remind|set|create|run|quit|close)\\b.*") == nil else { return nil }
        }
        let filters: Filters, rest: String
        if query.explicit { (filters, rest) = (query.filters, query.text.lowercased()) }
        else if literalName { (filters, rest) = (Filters(), text.lowercased()) }
        else {
            (filters, rest) = Filters.parse(text, folderExists: ix.hasFolder)
        }
        let ranked: [Ranked]
        if query.pattern != nil {
            ranked = ix.entries.enumerated().filter { query.matches($0.element) }.sorted {
                if $0.element.mtime != $1.element.mtime { return $0.element.mtime > $1.element.mtime }
                return $0.element.path < $1.element.path
            }.map { Ranked(i: $0.offset, score: 1, lex: 1, loc: 0, src: 0) }
        } else {
            // every entry's name match is needed then; the full pass reuses them
            let lexes = filters.isEmpty && !query.contentOnly ? Self.lexes(LexQuery.ranking(rest), ix) : nil
            ranked = rank(rest: rest, filters: filters, gate: 3.4, boosts: boosts(Self.norm(query.explicit ? query.text : text)),
                          contentOnly: query.contentOnly, snapshot: ix, semantic: false, lexes: lexes, stale: stale)
        }
        if stale?() == true { return nil }
        var seen = Set<String>()
        let top = ranked.filter { r in
            let e = ix.entries[r.i]
            return e.kind.isFile && (!query.explicit || query.matches(e)) && seen.insert(e.dupKey).inserted
        }.prefix(SearchResult.fileLimit)
        var hits = top.map { hit($0, copies: 0, snapshot: ix) }
        guard !hits.isEmpty else { return nil }
        let files = Assistant.attachmentFiles(hits.compactMap(\.path))
        if !files.isEmpty, !Self.launching(text, hits) { hits.append(Assistant.hit(text, files: files)) }
        if !query.explicit, text.count >= 2 { hits.append(Actions.web(text)) }
        let note = filters.notes.joined(separator: " · ")
        return SearchResult(hits: hits, note: query.explicit || note.isEmpty ? note : "Filter: " + note)
    }

    // a single word whose best match is an app is someone opening that app, not a question about files
    private static func launching(_ text: String, _ hits: [Hit]) -> Bool {
        !text.contains(" ") && hits.first(where: { $0.path != nil })?.tag == Kind.app.label
    }

    // What lex needs from a query, worked out once rather than for every entry.
    struct LexQuery: Equatable {
        let q: String, qt: [String], qtLong: [Bool], expanded: String, suffix: String
        let slash: Bool, len: Int, ascii: Bool, qtAscii: Bool, prefixAscii: Bool

        init(_ q: String, _ qt: [String]) {
            self.q = q
            self.qt = qt
            qtLong = qt.map { $0.count >= 4 }
            expanded = (q as NSString).expandingTildeInPath.lowercased()
            suffix = "/" + q
            slash = q.contains("/")
            len = q.count
            ascii = q.utf8.allSatisfy { $0 < 0x80 }
            qtAscii = qt.allSatisfy { $0.utf8.allSatisfy { $0 < 0x80 } }
            // a trailing CR could be half of a CR LF character, which bytes cannot tell
            prefixAscii = ascii && !q.utf8.contains(13)
        }

        // rank's reading: stopwords are dropped unless nothing else is left
        static func ranking(_ q: String) -> LexQuery {
            let all = nameTokens(q), qt = all.filter { !stopwords.contains($0) }
            return LexQuery(q, qt.isEmpty ? all : qt)
        }
    }

    static func lex(_ x: LexQuery, _ e: Entry) -> Float {
        let q = x.q, qt = x.qt
        if x.len == 0 { return 0 }
        if e.lname == q || e.stem == q { return 1 }
        if !qt.isEmpty, !x.slash {
            if e.words == qt { return 1 }
            if e.words.starts(with: qt) { return 0.9 }
        }
        if e.lpath == x.expanded || (x.slash && e.lpath.hasSuffix(x.suffix)) { return 1 }
        // "chrome" names Google Chrome as surely as a file named chrome.tsx
        if e.kind == .app, !qt.isEmpty, qt.allSatisfy({ e.tokens.contains($0) }) { return 0.95 }
        // ASCII on both sides (nearly always) compares bytes; otherwise characters
        let ascii = x.prefixAscii && e.ascii
        if ascii ? Self.bytesPrefix(e.lname, q) : e.lname.hasPrefix(q) { return 0.9 }
        var best: Float = 0
        if !qt.isEmpty {
            var names = 0, paths = 0
            let tokAscii = x.qtAscii && e.ascii, pathAscii = x.qtAscii && e.pathAscii
            for t in qt {
                if tokAscii ? e.tokens.contains(where: { Self.bytesPrefix($0, t) }) : e.tokens.contains(where: { $0.hasPrefix(t) }) { names += 1; paths += 1 }
                else if pathAscii ? e.pathTokens.contains(where: { Self.bytesPrefix($0, t) }) : e.pathTokens.contains(where: { $0.hasPrefix(t) }) { paths += 1 }
            }
            if names == qt.count { best = 0.8 }
            else if paths == qt.count { best = 0.7 }
            else { best = 0.25 * Float(names) / Float(qt.count) }
        }
        if x.len >= 3, x.ascii && e.ascii ? Self.bytesContain(e.lname, q) : e.lname.contains(q) { best = max(best, 0.65) }
        if x.slash, e.lpath.contains(x.expanded) { best = max(best, 0.7) }
        if e.kind == .app, x.len >= 2, ascii ? Self.bytesPrefix(e.initials, q) : e.initials.hasPrefix(q) { best = max(best, 0.7) }
        if best < 0.5, !qt.isEmpty, qt.count <= 4 {
            var all = true
            for (n, term) in qt.enumerated() where !e.tokens.contains(where: { token in
                (x.qtAscii && e.ascii ? Self.bytesPrefix(token, term) : token.hasPrefix(term)) || (x.qtLong[n] && Self.oneEdit(term, token))
            }) { all = false; break }
            if all { best = (qt.count == e.tokens.count || qt.count == e.stemCount) ? 0.62 : 0.56 }
        }
        return best
    }

    // for ASCII strings, the same answer as hasPrefix
    @inline(__always)
    private static func bytesPrefix(_ s: String, _ t: String) -> Bool {
        var s = s, t = t
        return s.withUTF8 { a in t.withUTF8 { b in
            a.count >= b.count && (b.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, b.count) == 0)
        } }
    }

    static func bytesContain(_ s: String, _ t: String) -> Bool {
        var s = s, t = t
        return s.withUTF8 { a in t.withUTF8 { b in
            b.isEmpty || (a.count >= b.count && memmem(a.baseAddress!, a.count, b.baseAddress!, b.count) != nil)
        } }
    }

    #if SEARCH_TESTS
    static func lexForChecks(_ q: String, _ qt: [String], _ e: Entry) -> Float { lex(LexQuery(q, qt), e) }
    #endif

    // One insertion, deletion, substitution or adjacent transposition; short words stay exact.
    static func oneEdit(_ a: String, _ b: String) -> Bool {
        let na = a.utf8.count, nb = b.utf8.count
        guard abs(na - nb) <= 4 else { return false }
        // ASCII (nearly every name) compares bytes in place; anything else compares characters
        if a.utf8.allSatisfy({ $0 < 0x80 }), b.utf8.allSatisfy({ $0 < 0x80 }) {
            guard abs(na - nb) <= 1 else { return false }
            var a = a, b = b
            return a.withUTF8 { x in b.withUTF8 { y in oneEdit(x, y) } }
        }
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 1 else { return false }
        return oneEdit(x, y)
    }

    private static func oneEdit<C: RandomAccessCollection>(_ x: C, _ y: C) -> Bool where C.Element: Equatable, C.Index == Int {
        let nx = x.count, ny = y.count, n = min(nx, ny)
        var i = 0
        while i < n, x[x.startIndex + i] == y[y.startIndex + i] { i += 1 }
        if i == n { return true }
        func same(_ a: Int, _ b: Int) -> Bool {
            // x[a...] == y[b...]
            guard nx - a == ny - b else { return false }
            var a = a, b = b
            while a < nx { if x[x.startIndex + a] != y[y.startIndex + b] { return false }; a += 1; b += 1 }
            return true
        }
        if nx == ny {
            if same(i + 1, i + 1) { return true }
            return i + 1 < nx && x[x.startIndex + i] == y[y.startIndex + i + 1] && x[x.startIndex + i + 1] == y[y.startIndex + i] && same(i + 2, i + 2)
        }
        return nx > ny ? same(i + 1, i) : same(i, i + 1)
    }

    // how a score was made up, for the ⌥ breakdown
    struct Why {
        var name: Float = 0, meaning: Float = 0, words: Float = 0, app: Float = 0, kind: Float = 0
        var learned: Float = 0, recent: Float = 0, similarity: Float = 0
        var newest = false

        var text: String {
            if newest { return "newest first" }
            func f(_ v: Float) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
            return [("name", name), ("meaning", meaning), ("words", words), ("app", app), ("type", kind),
                    ("learned", learned), ("recent", recent)].filter { abs($0.1) >= 0.05 }.map { "\($0.0) \(f($0.1))" }
                .joined(separator: " · ") + (similarity > 0 ? String(format: "similarity %.2f", similarity) : "")
        }
    }

    struct Ranked {
        let i: Int
        var score: Float
        let lex: Float
        let loc: Float
        let src: Int
        var excerpt = ""
        var learned: Float = 0  // part of the score that came from picks and habit rather than the query
        var match: Store.ContentMatch?  // its excerpt is read only if the row is shown
        var why = Why()
    }

    struct SemanticSignal {
        let score: Float
        let admitted: Bool
    }

    private struct SourceStats {
        var mean = [Float](repeating: 0, count: SRC_COUNT), sd = [Float](repeating: 1, count: SRC_COUNT)
        var cnt = [Float](repeating: 0, count: SRC_COUNT)
    }

    private static func stats(_ raw: UnsafeBufferPointer<Float>, _ sources: [UInt8]) -> SourceStats {
        var sum = [Float](repeating: 0, count: SRC_COUNT), sq = sum, st = SourceStats()
        sources.withUnsafeBufferPointer { src in
            for r in 0..<raw.count {
                let s = Int(src[r]), v = raw[r]
                sum[s] += v; sq[s] += v * v; st.cnt[s] += 1
            }
        }
        for s in 0..<SRC_COUNT where st.cnt[s] > 1 {
            st.mean[s] = sum[s] / st.cnt[s]
            st.sd[s] = max(1e-3, (sq[s] / st.cnt[s] - st.mean[s] * st.mean[s]).squareRoot())
        }
        return st
    }

    @inline(__always)
    private static func signal(_ raw: Float, _ s: Int, _ st: SourceStats, gate: Float) -> SemanticSignal {
        if st.cnt[s] - 1 < gate * gate {
            // sb_scan_i8 returns the dot product against QSCALE-quantized
            // unit vectors, so division recovers approximate cosine.
            let cosine = raw / QSCALE
            let floor: Float = gate > 3.4 ? 0.78 : 0.70
            return SemanticSignal(score: 6 * max(0, min(1, cosine)), admitted: cosine >= floor)
        }
        let z = (raw - st.mean[s]) / st.sd[s]
        return SemanticSignal(score: z, admitted: z >= gate)
    }

    // A population z-score cannot exceed sqrt(n - 1). When that makes the
    // admission gate unreachable, require absolute similarity instead. The
    // conservative floors separate matching and unrelated synthetic text/image
    // fixtures with the shipped model; they are not a universal accuracy claim.
    static func semanticSignals(raw: [Float], sources: [UInt8], gate: Float) -> [SemanticSignal] {
        precondition(raw.count == sources.count)
        let st = raw.withUnsafeBufferPointer { stats($0, sources) }
        return raw.indices.map { signal(raw[$0], Int(sources[$0]), st, gate: gate) }
    }

    #if SEARCH_TESTS
    // Exercise the production admission, filename ordering and passage selection
    // without loading a model or relying on its floating-point output.
    func semanticRanksForChecks(_ query: String, vector: [Float], gate: Float = 3.4) -> [Ranked] {
        rank(rest: query, filters: Filters(), gate: gate, boosts: [:], queryVector: vector)
    }

    func rankForChecks(_ query: String, stale: (() -> Bool)? = nil) -> [Ranked] {
        rank(rest: query, filters: Filters(), gate: 3.4, boosts: [:], habits: [:], stale: stale)
    }
    #endif

    // every entry's name match for a query, in entry order
    // The file-search pass and the full pass ask for the same ones; entries are immutable, so the
    // same array (held here, so its storage cannot be reused) and the same query give the same values.
    private static let lexMemoLock = NSLock()
    private static var lexMemo: (entries: [Entry], query: LexQuery, lexes: [Float])?

    private static func lexes(_ x: LexQuery, _ ix: Index) -> [Float] {
        let entries = ix.entries
        func same(_ a: [Entry]) -> Bool {
            a.count == entries.count && a.withUnsafeBufferPointer { p in entries.withUnsafeBufferPointer { $0.baseAddress == p.baseAddress } }
        }
        lexMemoLock.lock()
        if let m = lexMemo, m.query == x, same(m.entries) { lexMemoLock.unlock(); return m.lexes }
        lexMemoLock.unlock()
        let out = entries.withUnsafeBufferPointer { es in es.map { lex(x, $0) } }
        lexMemoLock.lock()
        lexMemo = (entries, x, out)
        lexMemoLock.unlock()
        return out
    }

    // every entry worth showing for a query, best first; empty once `stale` says nobody is waiting for it
    private func rank(rest: String, filters: Filters, gate: Float, boosts: [String: Float], nameOnly: Bool = false, contentOnly: Bool = false,
                      snapshot: Index? = nil, semantic: Bool = true, habits: [String: Float]? = nil, queryVector: [Float]? = nil,
                      lexes: [Float]? = nil, stale: (() -> Bool)? = nil) -> [Ranked] {
        let ix = snapshot ?? index
        let habit = habits ?? (learning ? Habits.shared.prior() : [:])
        // a file that was learned and then moved or renamed keeps what was learned under its name
        func moved(_ learned: [String: Float]) -> [String: Float] {
            var out: [String: Float] = [:]
            for (key, v) in learned where key.hasPrefix("/") && ix.byPath[key] == nil {
                out[(key as NSString).lastPathComponent.lowercased(), default: 0] += v
            }
            return out
        }
        // learned keys are few; look them up by entry instead of hashing every entry's path
        func byEntry(_ learned: [String: Float]) -> [Int: Float] {
            var out: [Int: Float] = [:]
            for (key, v) in learned { if let i = ix.byPath[key] { out[i] = v } }
            return out
        }
        let movedBoosts = moved(boosts), movedHabit = moved(habit), boostAt = byEntry(boosts), habitAt = byEntry(habit)
        let q = rest, listing = rest.isEmpty && !filters.isEmpty
        let lq = LexQuery.ranking(q)
        let identifier = lq.qt.contains { $0.contains(where: { $0.isNumber }) }
        var content: [Int: Store.ContentMatch] = [:]
        // a letter or two typed is the start of a name, not a word to look for inside files
        if !nameOnly, contentOnly || lq.len >= 3 {
            for match in ix.contentStore?.contentMatches(q, literal: contentOnly) ?? [] {
                if let i = ix.byID[match.id], match.path == ix.entries[i].path, content[i] == nil { content[i] = match }
            }
            if stale?() == true { return [] }
        }

        // One embedding, one scan; source-normalized scores (or bounded absolute
        // scores for small populations) keep text, media and passages comparable.
        let qv = semantic && !nameOnly && !contentOnly && ix.rows > 0 && lq.len >= 3 ? (queryVector ?? embedder?.query(q)) : nil
        let n = ix.entries.count
        // buffers move out of the scratch and back, so reuse never copies them
        let reuse = DispatchQueue.getSpecific(key: Self.onQueue) == true
        var sem: [Float] = [], admitted: [Bool] = [], bestRow: [Int32] = []
        defer { if reuse && !sem.isEmpty { swap(&sem, &scratch.sem); swap(&admitted, &scratch.admitted); swap(&bestRow, &scratch.best) } }
        if let qv, let vecs = ix.vecs, ix.rows > 0 {
            if stale?() == true { return [] }
            var raw: [Float] = []
            if reuse { swap(&raw, &scratch.raw); swap(&sem, &scratch.sem); swap(&admitted, &scratch.admitted); swap(&bestRow, &scratch.best) }
            func reset<T>(_ a: inout [T], _ count: Int, _ v: T) {
                if a.count == count { for k in a.indices { a[k] = v } } else { a = [T](repeating: v, count: count) }
            }
            if raw.count != ix.rows { raw = [Float](repeating: 0, count: ix.rows) }
            reset(&sem, n, 0); reset(&admitted, n, false); reset(&bestRow, n, -1)
            raw.withUnsafeMutableBufferPointer { sb_scan_i8(qv, vecs, ix.rows, $0.baseAddress!) }
            raw.withUnsafeBufferPointer { raw in
                let st = Self.stats(raw, ix.rowSrc)
                for r in 0..<ix.rows {
                    let e = Int(ix.rowEntry[r]), signal = Self.signal(raw[r], Int(ix.rowSrc[r]), st, gate: gate)
                    // An admitted passage must remain the destination even if a
                    // different source has a higher score below its own gate.
                    if (signal.admitted && !admitted[e]) ||
                        (signal.admitted == admitted[e] && signal.score > sem[e]) {
                        sem[e] = signal.score; bestRow[e] = Int32(r)
                    }
                    if signal.admitted { admitted[e] = true }
                }
            }
            if reuse { swap(&raw, &scratch.raw) }
            if stale?() == true { return [] }
        }
        let scanned = !sem.isEmpty

        // a few typed letters say little semantically, so lean on the name match until the query grows
        let semWeight = min(1, Float(max(0, lq.len - 2)) / 4)
        let now = Date().timeIntervalSince1970
        var out: [Ranked] = []
        ix.entries.withUnsafeBufferPointer { es in
            for i in 0..<n {
                let e = es[i]
                let words = content[i]
                if contentOnly && words == nil { continue }
                if !filters.isEmpty {
                    guard filters.matches(e) else { continue }
                }
                let l = lexes?[i] ?? Self.lex(lq, e)
                let boost = boostAt[i] ?? (movedBoosts.isEmpty ? 0 : movedBoosts[e.lname] ?? 0)
                var s: Float, learned: Float = 0, why = Why()
                if listing {
                    // newest first; for events, the ones closest to now
                    s = e.kind == .event ? -Float(abs(e.mtime - now) / 86400) : Float((e.mtime - 1.6e9) / 86400)
                    why.newest = true
                } else {
                    // Learned choices refine relevance; only a choice repeated for this exact query admits a result on its own.
                    guard l >= 0.5 || words != nil || (!nameOnly && !identifier && scanned && admitted[i]) || boost >= 7 else { continue }
                    if nameOnly, l < 0.9 { continue }
                    // Exact names have a protected lead over merely inferred semantic matches.
                    why.name = l == 1 ? 16 : (l >= 0.9 ? 10 : 6 * l + (l >= 0.5 && l < 0.65 ? 3 : 0))
                    why.meaning = scanned ? (identifier ? 0.35 : semWeight) * min(6, sem[i]) : 0
                    why.words = words == nil ? 0 : (identifier ? 10 : 5)
                    s = why.name + why.meaning + why.words + min(9, boost)
                    // launching apps is what the bar is used for most: a named app outranks a file with a similar name,
                    // and a letter or two is almost always the start of an app's name
                    if e.kind == .app { why.app = (l >= 0.95 ? 7 : (l >= 0.7 ? 5 : (l > 0 ? 1 : 0))) + (l >= 0.7 && lq.len <= 2 ? 2 : 0); s += why.app }
                    if e.kind == .other { s -= 0.4; why.kind -= 0.4 }
                    if e.kind == .web { s -= 1; why.kind -= 1 } // history is plentiful; let files win ties
                    if filters.softKinds.contains(e.kind) { s += 1.2; why.kind += 1.2 }
                    learned = min(9, boost)
                    if let h = habitAt[i] ?? (movedHabit.isEmpty ? nil : movedHabit[e.lname]) { s += min(4, h); learned += min(4, h) }
                    why.learned = learned
                    if e.mtime > 0, e.kind.isFile {
                        let age = now - e.mtime
                        why.recent = age < 7 * 86400 ? 0.3 : (age < 30 * 86400 ? 0.15 : 0)
                        s += why.recent
                    }
                }
                let r = scanned ? Int(bestRow[i]) : -1
                // An exact passage is the most useful destination when exact words matched.
                out.append(Ranked(i: i, score: s, lex: l, loc: words?.loc ?? (r >= 0 ? ix.rowLoc[r] : 0),
                                  src: words?.src ?? (r >= 0 ? Int(ix.rowSrc[r]) : 0), learned: learned, match: words, why: why))
            }
        }
        let entries = ix.entries
        out.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = entries[$0.i], b = entries[$1.i]
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.path < b.path
        }
        if !listing {
            // relevance decides what is worth showing; learning only orders it, so it never hides runners-up
            let topFile = out.filter { entries[$0.i].kind.isFile }.map { $0.score - $0.learned }.max() ?? 0
            let topOther = out.filter { !entries[$0.i].kind.isFile }.map { $0.score - $0.learned }.max() ?? 0
            out.removeAll { $0.score - $0.learned < (entries[$0.i].kind.isFile ? topFile : topOther) * 0.42 }
        }
        return out
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let dateLock = NSLock()

    private static func date(_ time: Double) -> String {
        dateLock.lock()
        defer { dateLock.unlock() }
        return dateFmt.string(from: Date(timeIntervalSince1970: time))
    }

    static func clock(_ t: Float) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private func hit(_ r: Ranked, copies: Int, snapshot: Index? = nil) -> Hit {
        var h = makeHit(r, copies: copies, snapshot: snapshot)
        h.why = r.why.text
        let e = (snapshot ?? index).entries[r.i]
        if (e.kind.isFile && e.kind != .app || e.kind == .event) && e.mtime != 0 { h.date = e.mtime }
        return h
    }

    private func makeHit(_ r: Ranked, copies: Int, snapshot: Index?) -> Hit {
        var r = r
        if r.excerpt.isEmpty, let m = r.match { r.excerpt = (snapshot ?? index).contentStore?.excerpt(m) ?? "" }
        let e = (snapshot ?? index).entries[r.i]
        let path = e.path
        switch e.kind {
        case .web:
            let host = URL(string: path)?.host ?? path
            return Hit(title: e.name, subtitle: host, icon: .symbol("globe"), tag: "Web page", score: r.score, key: path) { _ in Sys.open(path) }
        case .clip:
            let text = e.snippet
            return Hit(title: e.name, subtitle: "Copied \(Self.date(e.mtime)) · ↩ copy again",
                       icon: .symbol("doc.on.clipboard"), tag: "Clipboard", score: r.score, key: path) { _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Toast.show("Copied")
            }
        case .event:
            let when = Date(timeIntervalSince1970: e.mtime)
            return Hit(title: e.name, subtitle: Commands.whenFmt.string(from: when), icon: .symbol("calendar"), tag: "Event", score: r.score, key: path) { _ in
                Sys.script("tell application \"Calendar\"\nactivate\nview calendar at (current date) + \(Int(when.timeIntervalSinceNow))\nend tell")
            }
        case .contact:
            let id = String(path.dropFirst("contact:".count))
            let detail = e.snippet.replacingOccurrences(of: "contact. ", with: "")
            return Hit(title: e.name, subtitle: detail.isEmpty ? "Contact" : detail, icon: .symbol("person.crop.circle"), tag: "Contact", score: r.score, key: path) { _ in
                Sys.open("addressbook://" + Sys.enc(id))
            }
        case .note:
            let id = String(path.dropFirst("note:".count))
            return Hit(title: e.name, subtitle: String(e.snippet.prefix(90)), icon: .symbol("note.text"), tag: "Note", score: r.score, key: path) { _ in
                Sys.script("tell application \"Notes\"\nactivate\nshow note id \"\(id)\"\nend tell")
            }
        default: break
        }
        let dir = Paths.tilde((path as NSString).deletingLastPathComponent)
        var sub = e.kind == .app || e.mtime == 0 ? dir : "\(dir) · \(Self.date(e.mtime))"
        // the match was inside the file: say where, and open there
        let page = r.src == Src.page.rawValue && r.loc > 1 ? Int(r.loc) : 0
        let time = r.src == Src.media.rawValue && r.loc >= 5 && (e.kind == .audio || e.kind == .video) ? r.loc : 0
        if page > 0 { sub = "Page \(page) · " + sub }
        if time > 0 { sub = "At \(Self.clock(time)) · " + sub }
        if copies > 0 { sub += " · +\(copies) cop\(copies == 1 ? "y" : "ies")" }
        return Hit(title: e.name, subtitle: sub, icon: .file(path), tag: e.kind.label, score: r.score, key: path, path: path, excerpt: r.excerpt, previewPage: max(1, page)) { alt in
            let url = URL(fileURLWithPath: path)
            if alt { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
            if page > 0, var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
                // Preview cannot be told which page to show; a browser can
                c.fragment = "page=\(page)"
                if let u = c.url { NSWorkspace.shared.open([u], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()); return }
            }
            if time > 0 {
                Sys.script("""
                tell application "QuickTime Player"
                activate
                set d to open POSIX file \(Commands.quote(path))
                set current time of d to \(Int(time))
                play d
                end tell
                """)
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    private static let calcIcons = ["Calculator": "equal.square", "Convert": "arrow.left.arrow.right.square", "Date": "calendar", "Time": "clock"]

    private func opHit(_ op: Op, _ files: [String]) -> Hit {
        let names = files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"
        return Hit(title: op.title, subtitle: op.unavailableReason ?? (op.detail.isEmpty ? names : op.detail), icon: .symbol(op.symbol), tag: op.unavailableReason == nil ? "Action" : "Unavailable", key: "op:" + op.id, unavailableReason: op.unavailableReason, stay: op.stay) { _ in
            guard op.unavailableReason == nil else { return }
            FileOps.run(op)
        }
    }

    // a file is in the bar: the text is a request about it
    // `question` is how the request reads when the file was named in the sentence rather than attached
    private func chipHits(_ text: String, _ files: [String], question: String? = nil) -> SearchResult {
        if text.isEmpty { return SearchResult(hits: FileOps.suggestions(files).map { opHit($0, files) }) }
        if Assistant.looksLikeQuestion(question ?? text) { return SearchResult(hits: Assistant.rows(question ?? text, files: files)) }
        if Calc.rx(text, "^(email|mail|send)\\b.*") != nil, Calc.rx(text.lowercased(), "^send (it |this )?to (my |the )?(desktop|documents|downloads)\\b.*") == nil {
            var h = Commands.email(text, nil, attached: files)
            if LLM.available {
                LLM.shared.preload()
                h.refine = { done in
                    LLM.shared.command(text, file: files.first) { j in
                        done((j?["action"] as? String) == "email" ? self.locked { Commands.email(text, j, attached: files) } : nil)
                    }
                }
            }
            return SearchResult(hits: [h])
        }
        let hits = FileOps.parse(text, files).map { opHit($0, files) }
        if !hits.isEmpty { return SearchResult(hits: hits) }
        // not something to do to the file, so it is something to ask about it
        let asks = Assistant.rows(question ?? text, files: files)
        let ask = asks[0]
        guard !Assistant.looksLikeQuestion(question ?? text), text.count >= 4, LLM.available else { return SearchResult(hits: asks) }
        LLM.shared.preload()
        var h = Hit(title: "Working out “\(text)”…", subtitle: (files[0] as NSString).lastPathComponent, icon: .symbol("sparkles"), tag: "Action", isPending: true, stay: true) { _ in }
        h.refine = { done in
            LLM.shared.command(text, file: files.first) { j in
                let op = j.flatMap { j in self.locked { FileOps.from(j, files) } }
                done(op.map { self.opHit($0, files) } ?? ask)
            }
        }
        return SearchResult(hits: [h])
    }

    private func pathHit(_ path: String) -> Hit {
        if let i = index.byPath[path] { return hit(Ranked(i: i, score: 0, lex: 0, loc: 0, src: 0), copies: 0) }
        // too new to be indexed yet
        let dir = Paths.tilde((path as NSString).deletingLastPathComponent)
        return Hit(title: (path as NSString).lastPathComponent, subtitle: "\(dir) · \(Resolver.age(path))", icon: .file(path),
                   tag: FileOps.kind(path).label, key: path, path: path) { alt in
            let url = URL(fileURLWithPath: path)
            if alt { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        }
    }

    private func refHits(_ ref: Resolver.Ref, _ text: String) -> SearchResult {
        var hits: [Hit] = []
        if ref.capture { hits = [Assistant.screenHit(ref.question)] } else if let clip = ref.clipText {
            hits = [Assistant.clipHit(ref.question, clip)]
        } else {
            let cmd = ref.command.lowercased()
            let files = ref.files.map(pathHit)
            let justShow = cmd.isEmpty || Calc.rx(cmd, "^(open|show|show me|find|view|see|get|give me|where is|where are|list|reveal|what is|what are)$") != nil
            if justShow { hits = files + (ref.listing ? [] : chipHits("", ref.files).hits) } else {
                hits = chipHits(ref.command, ref.files, question: ref.question).hits + files
            }
            // other files the description could have meant: Tab on one to act on it instead
            hits += ref.alternates.map(pathHit)
            if justShow {
                let context = Assistant.attachmentFiles(Array((ref.files + ref.alternates).prefix(SearchResult.fileLimit)))
                if !context.isEmpty { hits.append(Assistant.hit(text, files: context)) }
            }
        }
        hits.append(Actions.web(text))
        return SearchResult(hits: hits, note: ref.label)
    }

    private func explicitFiles(_ query: FileQuery, stale: (() -> Bool)?) -> SearchResult {
        if let error = query.error { return SearchResult(hits: [], note: error) }
        let ranked: [Ranked]
        if query.pattern != nil {
            ranked = index.entries.enumerated().filter { query.matches($0.element) }.sorted {
                if $0.element.mtime != $1.element.mtime { return $0.element.mtime > $1.element.mtime }
                return $0.element.path < $1.element.path
            }.map { Ranked(i: $0.offset, score: 1, lex: 1, loc: 0, src: 0) }
        } else {
            ranked = rank(rest: query.text.lowercased(), filters: query.filters, gate: 3.4, boosts: boosts(Self.norm(query.text)),
                          contentOnly: query.contentOnly, stale: stale).filter { query.matches(index.entries[$0.i]) }
        }
        var seen = Set<String>()
        let top = ranked.filter { seen.insert(index.entries[$0.i].dupKey).inserted }.prefix(SearchResult.fileLimit)
        var hits = top.map { hit($0, copies: 0) }
        let files = Assistant.attachmentFiles(hits.compactMap(\.path))
        if !files.isEmpty, !Self.launching(query.text, hits) { hits.append(Assistant.hit(query.text, files: files)) }
        return SearchResult(hits: hits, note: query.filters.notes.joined(separator: " · "))
    }

    // `calc` is the text's calculator answer when the caller already has it; `stale` ends a superseded query early
    func build(_ text: String, chips: [String] = [], calc known: CalcResult?? = nil, stale: (() -> Bool)? = nil) -> SearchResult {
        if !chips.isEmpty { return chipHits(text, chips) }
        guard !text.isEmpty else { return SearchResult(hits: []) }
        let calc = known ?? Calc.answer(text)
        let fileQuery = FileQuery(text, isCalc: calc != nil)
        if fileQuery.explicit || Self.hasLiteralName(text, in: index) { return explicitFiles(fileQuery, stale: stale) }
        let ix = index
        let q = text.lowercased()

        var out: [Hit] = []
        if let c = calc {
            out.append(Hit(title: c.title, subtitle: c.detail + (c.copy.isEmpty ? "" : "  ·  ↩ copy"), icon: .symbol(Self.calcIcons[c.tag] ?? "equal.square"), tag: c.tag) { _ in
                guard !c.copy.isEmpty else { return }
                c.remember()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.copy, forType: .string)
                Toast.show("Copied \(c.title)")
            })
        }
        if !q.contains(" "), q.range(of: "^(https?://)?[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}(/\\S*)?$", options: .regularExpression) != nil {
            let u = q.hasPrefix("http") ? text : "https://" + text
            out.append(Hit(title: "Open \(text)", subtitle: Sys.browserName, icon: .symbol("globe"), tag: "URL") { _ in Sys.open(u) })
        }

        // the sentence names what it is about ("my most recent screenshot", "my screen", "my clipboard")
        if calc == nil, let ref = Resolver.extract(text) { return refHits(ref, text) }

        let (filters, rest) = calc == nil ? Filters.parse(text, folderExists: ix.hasFolder) : (Filters(), q)
        let learned = boosts(Self.norm(text))

        // intent pass: nearest exemplar per intent
        let iv = q.count >= 3 ? embedder?.query(q) : nil
        if stale?() == true { return SearchResult(hits: []) }
        var best = [Float](repeating: -1, count: intents.count)
        if let iv, !intentVecs.isEmpty, intentVecs.count == intentOf.count * DIM {
            var d = [Float](repeating: 0, count: intentOf.count)
            vDSP_mmul(intentVecs, 1, iv, 1, &d, 1, vDSP_Length(intentOf.count), 1, vDSP_Length(DIM))
            for x in 0..<intentOf.count { best[intentOf[x]] = max(best[intentOf[x]], d[x]) }
        }
        let fileSim = best.first ?? -1
        let rankedIntents = best.enumerated().dropFirst().sorted { $0.element > $1.element }
        if debug {
            print("  intents: file=\(String(format: "%.3f", fileSim)) " + rankedIntents.prefix(3).map { "\(intents[$0.offset].id)=\(String(format: "%.3f", $0.element))" }.joined(separator: " "))
            if !filters.isEmpty { print("  filters: \(filters.notes.joined(separator: ", "))  rest: “\(rest)”") }
        }

        // A typed app/file name always beats an inferred action. Only consulted for plain queries, whose
        // ranking reads the text the same way, so that pass's name matches are reused when they agree.
        let strongQuery = LexQuery(q, nameTokens(q)), rankQuery = LexQuery.ranking(rest)
        let lexes = calc == nil && filters.isEmpty && strongQuery == rankQuery ? Self.lexes(rankQuery, ix) : nil
        func strong(_ l: Float, _ e: Entry) -> Bool { l >= 0.9 || (l >= 0.7 && e.kind == .app) }
        lazy var strongName: Bool = lexes.map { l in ix.entries.indices.contains { strong(l[$0], ix.entries[$0]) } }
            ?? ix.entries.contains { strong(Self.lex(strongQuery, $0), $0) }
        var lead: [Hit] = [], trail: [Hit] = []
        var sawWeb = false
        for (n, r) in rankedIntents.prefix(3).enumerated() {
            let it = intents[r.offset]
            // an action the user chose for this exact query before is what they mean now
            let chosen = learned["intent:" + it.id] ?? 0
            guard r.element >= 0.78 || chosen >= 3 else { continue }
            let wins = chosen >= 3 || (n == 0 && r.element >= fileSim + 0.05 && calc == nil && filters.isEmpty && !strongName)
            guard wins || r.element >= fileSim - 0.05 else { continue }
            if it.id == "web" { sawWeb = true }
            let made = it.hits(text).map { h -> Hit in
                var h = h
                if h.key == nil { h.key = "intent:" + it.id }
                return h
            }
            if wins { lead += made } else { trail += made }
        }

        // a row the command model will refine: have the model and its prompt ready by the time it is asked
        if lead.contains(where: { $0.refine != nil }) || trail.contains(where: { $0.refine != nil }) { LLM.shared.preload() }

        // when an action or a computed answer already covers the query, only clearly related files are worth showing
        let gate: Float = lead.isEmpty ? 3.4 : 4.5
        if stale?() == true { return SearchResult(hits: []) }
        let ranked = rank(rest: rest, filters: filters, gate: gate, boosts: learned, nameOnly: calc != nil, lexes: lexes, stale: stale)
        if stale?() == true { return SearchResult(hits: []) }

        // copies of one file collapse into its best-ranked instance
        let limit = SearchResult.fileLimit
        var fileCount = 0, otherCount = 0
        var seen: [String: Int] = [:]
        var kept: [(Ranked, Int)] = []
        for r in ranked {
            let k = ix.entries[r.i].dupKey
            if let at = seen[k] { kept[at].1 += 1; continue }
            if ix.entries[r.i].kind.isFile {
                if fileCount >= limit { continue }
                fileCount += 1
            } else {
                if otherCount >= 3 { continue }
                otherCount += 1
            }
            seen[k] = kept.count
            kept.append((r, 0))
        }

        // Reuse only candidates that cleared the search relevance gate, never folders or apps.
        let contextFiles = Assistant.attachmentFiles(kept.compactMap { pair in
            let entry = ix.entries[pair.0.i]
            return entry.kind.isFile && entry.kind != .folder && entry.kind != .app ? entry.path : nil
        })
        lead = lead.map { Assistant.isAsk($0) ? Assistant.hit(text, files: contextFiles) : $0 }
        trail = trail.map { Assistant.isAsk($0) ? Assistant.hit(text, files: contextFiles) : $0 }
        let asksOutright = Calc.rx(q, "^(ask )?(chat ?gpt|gpt|claude|gemini)\\b.+") != nil
        if asksOutright || (calc == nil && filters.isEmpty && !strongName && Assistant.isComplex(q)), !lead.contains(where: Assistant.isAsk) {
            trail.removeAll(where: Assistant.isAsk)
            lead.insert(Assistant.hit(text, files: contextFiles), at: 0)
        }
        out += lead
        out += kept.filter { ix.entries[$0.0.i].kind.isFile }.map { hit($0.0, copies: $0.1) }
        out += kept.filter { !ix.entries[$0.0.i].kind.isFile }.map { hit($0.0, copies: $0.1) }
        out += trail
        // File searches expose their contextual Ask action without a separate attachment step.
        if !out.contains(where: Assistant.isAsk), (!contextFiles.isEmpty || q.split(separator: " ").count >= 3), calc == nil, !Self.launching(text, out) { out.append(Assistant.hit(text, files: contextFiles)) }
        if !sawWeb, q.count >= 2 { out.append(Actions.web(text)) }
        // Ask remains Ask. File operations are resolved before displaying an executable row.
        var result = SearchResult(hits: out, note: filters.notes.isEmpty ? "" : "Filter: " + filters.notes.joined(separator: " · "))
        if fileCount < limit, q.count >= 3, lead.isEmpty, calc == nil, filters.isEmpty { result.lookup = text }
        return result
    }

    // File results past the first five, same ranking, for "show more". Delivered on the main queue.
    func moreFiles(_ text: String, chips: [String] = [], limit: Int = 50, done: @escaping ([Hit]) -> Void) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            var hits: [Hit] = []
            if chips.isEmpty, !text.isEmpty {
                let query = FileQuery(text), ix = self.index
                var ranked: [Ranked] = []
                if query.error != nil {
                } else if query.pattern != nil {
                    ranked = ix.entries.indices.filter { query.matches(ix.entries[$0]) }.sorted {
                        let a = ix.entries[$0], b = ix.entries[$1]
                        return a.mtime != b.mtime ? a.mtime > b.mtime : a.path < b.path
                    }.map { Ranked(i: $0, score: 1, lex: 1, loc: 0, src: 0) }
                } else if query.explicit || Self.hasLiteralName(text, in: ix) {
                    ranked = self.rank(rest: query.text.lowercased(), filters: query.filters, gate: 3.4, boosts: self.boosts(Self.norm(query.text)),
                                       contentOnly: query.contentOnly).filter { query.matches(ix.entries[$0.i]) }
                } else if Calc.answer(text) == nil {
                    let (filters, rest) = Filters.parse(text, folderExists: ix.hasFolder)
                    ranked = self.rank(rest: rest, filters: filters, gate: 3.4, boosts: self.boosts(Self.norm(text)))
                }
                var seen = Set<String>()
                hits = ranked.filter { ix.entries[$0.i].kind.isFile && seen.insert(ix.entries[$0.i].dupKey).inserted }
                    .dropFirst(SearchResult.fileLimit).prefix(limit).map { self.hit($0, copies: 0) }
            }
            DispatchQueue.main.async { done(hits) }
        }
    }

    // MARK: query by example

    private func mediaVector(_ path: String) -> [Float]? {
        if let i = index.byPath[path], let r = index.rows(of: i).first(where: { Int(index.rowSrc[$0]) == Src.media.rawValue }) {
            return index.vector(row: r)
        }
        // not indexed (pasted, or outside the indexed folders): ask a short-lived helper that has the encoders
        guard let exe = Bundle.main.executablePath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--embed", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let v = String(decoding: data, as: UTF8.self).split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return v.count == DIM ? v : nil
    }

    // Query-by-example must have evidence before deduplication or the five-hit
    // cap. Use actual cosine: stored int8 vectors are only approximately unit
    // length. The distinct floors were checked on synthetic shifted drawings
    // and synthesized speech/paraphrases, not inferred from text-image scores.
    static func similarRanks(in ix: Index, to path: String, vector: [Float], kind: Kind) -> [Ranked] {
        guard vector.count == DIM, let vecs = ix.vecs else { return [] }
        let queryNorm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard queryNorm.isFinite, queryNorm > 1e-6 else { return [] }
        let allowed: Set<Kind> = kind == .audio ? [.audio] : (kind == .video ? [.video, .image] : [.image])
        let floor: Float = kind == .audio ? 0.70 : 0.90
        var raw = [Float](repeating: 0, count: ix.rows)
        sb_scan_i8(vector, vecs, ix.rows, &raw)
        var best: [Int: Ranked] = [:]
        for r in 0..<ix.rows where Int(ix.rowSrc[r]) == Src.media.rawValue {
            let e = Int(ix.rowEntry[r])
            guard allowed.contains(ix.entries[e].kind), ix.entries[e].path != path else { continue }
            let norm = r < ix.rowNorm.count ? ix.rowNorm[r] : 0
            guard norm > 0 else { continue }
            let cosine = raw[r] / (queryNorm * norm)
            guard cosine.isFinite, cosine >= floor, cosine > (best[e]?.score ?? -1) else { continue }
            var x = Ranked(i: e, score: min(1, cosine), lex: 0, loc: ix.rowLoc[r], src: Src.media.rawValue)
            x.why.similarity = cosine
            best[e] = x
        }
        var seen = Set<String>()
        return Array(best.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ix.entries[$0.i].path < ix.entries[$1.i].path
        }.filter { seen.insert(ix.entries[$0.i].dupKey).inserted }.prefix(SearchResult.fileLimit))
    }

    func similar(to path: String, done: @escaping (SearchResult) -> Void) {
        queue.async {
            let ix = self.index
            guard let v = self.mediaVector(path), ix.vecs != nil else {
                DispatchQueue.main.async { done(SearchResult(hits: [], note: "Couldn't read that file as an image, video or audio")) }
                return
            }
            // like for like: blank video frames otherwise resemble every picture a little
            let k = FileOps.kind(path)
            let top = Self.similarRanks(in: ix, to: path, vector: v, kind: k)
            let hits = top.map { self.hit($0, copies: 0) }
            DispatchQueue.main.async { done(SearchResult(hits: hits, note: "Similar to \((path as NSString).lastPathComponent)")) }
        }
    }
}
