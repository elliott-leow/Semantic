import AppKit
import Foundation
import SQLite3

struct Entry {
    let path: String      // file path, or URL / opaque key for non-file kinds
    let name: String
    let lname: String
    let pathTokens: [String]
    let lpath: String
    let tokens: [String]
    let initials: String
    let kind: Kind
    let mtime: Double
    let size: Int
    let ext: String
    let snippet: String   // kept only for kinds that are shown or acted on by their text
    let dupKey: String    // equal for copies of the same file
}

// Immutable snapshot of the index: entries plus one int8 matrix of vectors.
final class Index {
    var entries: [Entry] = []
    var rowEntry: [Int32] = []
    var rowSrc: [UInt8] = []
    var rowLoc: [Float] = []
    var byPath: [String: Int] = [:]
    var folders = Set<String>()
    var byID: [Int64: Int] = [:]
    var contentStore: Store?
    private(set) var vecs: UnsafeMutablePointer<Int8>?
    var rows: Int { rowEntry.count }

    deinit { vecs?.deallocate() }

    static func load(store: Store? = Store(readonly: true), vectors: Bool = true) -> Index {
        let ix = Index()
        guard let store else { return ix }
        ix.contentStore = store
        // A read transaction keeps metadata and vector row mappings in the same snapshot.
        store.exec("BEGIN")
        defer { store.exec("COMMIT") }
        var ids: [Int64: Int] = [:]
        store.run("SELECT id,path,name,kind,mtime,size,snippet FROM files ORDER BY id") { st in
            let name = colText(st, 2), path = colText(st, 1)
            let kind = Kind(rawValue: Int(sqlite3_column_int(st, 3))) ?? .other
            let toks = nameTokens(name), size = Int(sqlite3_column_int64(st, 5))
            let ext = kind.isFile ? (name as NSString).pathExtension.lowercased() : ""
            let base = (name as NSString).deletingPathExtension.lowercased()
                .replacingOccurrences(of: "(\\s*\\(\\d+\\)|\\s+copy(\\s+\\d+)?)+$", with: "", options: .regularExpression)
            // Do not collapse numbered chapters or unrelated same-size files in other folders.
            let parent = (path as NSString).deletingLastPathComponent
            let dup = kind.isFile && kind != .folder && kind != .app && size > 0 ? "\(parent)/\(base).\(ext)#\(size)" : path
            ids[sqlite3_column_int64(st, 0)] = ix.entries.count
            ix.byPath[path] = ix.entries.count
            if kind == .folder { ix.folders.insert(name.lowercased()) }
            ix.entries.append(Entry(path: path, name: name, lname: name.lowercased(), pathTokens: nameTokens(parent), lpath: path.lowercased(), tokens: toks,
                                    initials: String(toks.compactMap(\.first)), kind: kind,
                                    mtime: sqlite3_column_double(st, 4), size: size, ext: ext,
                                    snippet: kind.isFile ? "" : colText(st, 6), dupKey: dup))
        }
        ix.byID = ids
        guard vectors else { return ix }
        var n = 0
        store.run("SELECT count(*) FROM vecs") { n = Int(sqlite3_column_int64($0, 0)) }
        guard n > 0 else { return ix }
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: n * DIM)
        ix.vecs = buf
        store.run("SELECT file_id,src,v,loc FROM vecs ORDER BY file_id") { st in
            let src = Int(sqlite3_column_int(st, 1))
            guard let i = ids[sqlite3_column_int64(st, 0)], (0..<SRC_COUNT).contains(src),
                  ix.rows < n, sqlite3_column_bytes(st, 2) == DIM, let blob = sqlite3_column_blob(st, 2) else { return }
            memcpy(buf + ix.rows * DIM, blob, DIM)
            ix.rowEntry.append(Int32(i))
            ix.rowSrc.append(UInt8(src))
            ix.rowLoc.append(Float(sqlite3_column_double(st, 3)))
        }
        return ix
    }

    // Value arrays are shared until mutated; never share a SQLite connection between queues.
    func metadataSnapshot() -> Index {
        let ix = Index()
        ix.entries = entries
        ix.byPath = byPath
        ix.byID = byID
        ix.folders = folders
        return ix
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
    var debug = false

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

    func reloadIndex() {
        // Metadata and exact content remain available even while the model queue is busy.
        quickQueue.async {
            self.quickIndex = Index.load(vectors: false)
            DispatchQueue.main.async { self.onChange?() }
        }
        queue.async {
            self.index = Index.load()
            DispatchQueue.main.async { self.onChange?() }
        }
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
        var completed = 0
        for (id, name, body) in todo {
            if let v = e.document(title: name, body: String(body.prefix(900))) {
                store.exec("BEGIN")
                store.run("DELETE FROM vecs WHERE file_id=? AND src=?", [id, Src.text.rawValue])
                store.run("INSERT INTO vecs(file_id,src,v) VALUES(?,?,?)", [id, Src.text.rawValue, quantize(v)])
                store.run("UPDATE files SET state = 1 WHERE id = ?", [id])
                store.exec("COMMIT")
                completed += 1
            }
        }
        index = Index.load()
        DispatchQueue.main.async { self.onChange?() }
        if todo.count == 5 && completed > 0 { queue.async { self.embedPending() } }
    }

    // MARK: learning from picks

    static func norm(_ q: String) -> String {
        q.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // a chosen result, typed for or suggested; Habits keeps both the query and the routine
    func recordPick(_ query: String, _ key: String) {
        Habits.shared.recordPick(Self.norm(query), key)
    }

    private func boosts(_ q: String) -> [String: Float] { Habits.shared.boosts(q) }

    // Before anything is typed: what habit says is wanted now (time of day, the app in front, recency).
    // Only things still present in the index are offered, so a deleted file or app quietly drops out.
    private func suggestions(_ ix: Index) -> SearchResult {
        var hits: [Hit] = []
        for (key, score) in Habits.shared.predictions(limit: 12) where hits.count < 6 {
            guard let i = ix.byPath[key] else { continue }
            let e = ix.entries[i]
            if e.kind.isFile, !FileManager.default.fileExists(atPath: e.path) { continue }
            hits.append(hit(Ranked(i: i, score: score, lex: 0, loc: 0, src: 0), copies: 0, snapshot: ix))
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
            let qt = nameTokens(q)
            return index.entries.filter { $0.kind == .app }.map { ($0, lex(q, qt, $0)) }.filter { $0.1 >= 0.6 }.max { $0.1 < $1.1 }?.0.path
        }
    }

    // real files answering to a phrase like "the syllabus", best first; `strong` refuses a merely vague resemblance.
    // Documents are what people name this way, so they win ties against project files with a similar name.
    func bestFiles(_ phrase: String, strong: Bool = false, count: Int = 1) -> [String] {
        locked {
            let q = phrase.lowercased().replacingOccurrences(of: "^(the|my|a|an|this|that) ", with: "", options: .regularExpression)
            let ok: Set<Kind> = [.doc, .image, .audio, .video, .other]
            var r = rank(rest: q, full: q, filters: Filters(), gate: 3.4, boosts: [:]).filter { ok.contains(index.entries[$0.i].kind) }.prefix(25).map { x -> Ranked in
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
            if chips.isEmpty, let quick = self.quickFiles(text) {
                self.deliver(quick, generation: gen, done: done)
            }
            // Queue refinement after quick delivery was enqueued: it can never be followed
            // by an older preliminary result for the same generation.
            self.queue.async {
                guard self.isCurrent(gen) else { return }
                let r = self.build(text, chips: chips)
                self.deliver(r, generation: gen, done: done)
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
        let q = text.lowercased(), expanded = (text as NSString).expandingTildeInPath.lowercased()
        return index.entries.contains { e in
            e.kind.isFile && (e.lname == q || (e.lname as NSString).deletingPathExtension == q || e.lpath == expanded)
        }
    }

    private func quickFiles(_ text: String) -> SearchResult? {
        guard !text.isEmpty else { return SearchResult(hits: []) }
        let ix = quickIndex, query = FileQuery(text)
        if let error = query.error { return SearchResult(hits: [], note: error) }
        let literalName = Self.hasLiteralName(text, in: ix)
        if !query.explicit, !literalName {
            guard Calc.answer(text) == nil, !Assistant.looksLikeQuestion(text),
                  Calc.rx(text.lowercased(), "^(?:please )?(?:convert|turn|change|export|save|make|rename|move|copy|zip|compress|resize|rotate|trash|delete|print|email|send|mail|remind|set|create|run|quit|close)\\b.*") == nil else { return nil }
        }
        let filters: Filters, rest: String
        if query.explicit { (filters, rest) = (query.filters, query.text.lowercased()) }
        else if literalName { (filters, rest) = (Filters(), text.lowercased()) }
        else {
            (filters, rest) = Filters.parse(text, folderExists: { name in
                ix.folders.contains(name) || ix.entries.contains { $0.kind.isFile && $0.path.range(of: "/\(name)/", options: .caseInsensitive) != nil }
            })
        }
        let ranked: [Ranked]
        if query.pattern != nil {
            ranked = ix.entries.enumerated().filter { query.matches($0.element) }.sorted {
                if $0.element.mtime != $1.element.mtime { return $0.element.mtime > $1.element.mtime }
                return $0.element.path < $1.element.path
            }.map { Ranked(i: $0.offset, score: 1, lex: 1, loc: 0, src: 0) }
        } else {
            ranked = rank(rest: rest, full: text.lowercased(), filters: filters, gate: 3.4, boosts: boosts(Self.norm(query.explicit ? query.text : text)),
                          contentOnly: query.contentOnly, snapshot: ix, semantic: false)
        }
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

    private func lex(_ q: String, _ qt: [String], _ e: Entry) -> Float {
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
        // "chrome" names Google Chrome as surely as a file named chrome.tsx
        if e.kind == .app, !qt.isEmpty, qt.allSatisfy({ e.tokens.contains($0) }) { return 0.95 }
        if e.lname.hasPrefix(q) { return 0.9 }
        var best: Float = 0
        if !qt.isEmpty {
            let names = qt.filter { t in e.tokens.contains { $0.hasPrefix(t) } }.count
            let paths = qt.filter { t in e.tokens.contains { $0.hasPrefix(t) } || e.pathTokens.contains { $0.hasPrefix(t) } }.count
            if names == qt.count { best = 0.8 }
            else if paths == qt.count { best = 0.7 }
            else { best = 0.25 * Float(names) / Float(qt.count) }
        }
        if q.count >= 3, e.lname.contains(q) { best = max(best, 0.65) }
        if q.contains("/"), e.lpath.contains(expanded) { best = max(best, 0.7) }
        if e.kind == .app, q.count >= 2, e.initials.hasPrefix(q) { best = max(best, 0.7) }
        if best < 0.5, !qt.isEmpty, qt.count <= 4,
           qt.allSatisfy({ term in e.tokens.contains { token in
               token.hasPrefix(term) || (term.count >= 4 && Self.oneEdit(term, token))
           } }) { best = (qt.count == e.tokens.count || qt.count == nameTokens(stem).count) ? 0.62 : 0.56 }
        return best
    }

    // One insertion, deletion, substitution or adjacent transposition; short words stay exact.
    static func oneEdit(_ a: String, _ b: String) -> Bool {
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

    struct Ranked {
        let i: Int
        var score: Float
        let lex: Float
        let loc: Float
        let src: Int
        var excerpt = ""
        var learned: Float = 0  // part of the score that came from picks and habit rather than the query
    }

    struct SemanticSignal {
        let score: Float
        let admitted: Bool
    }

    // A population z-score cannot exceed sqrt(n - 1). When that makes the
    // admission gate unreachable, require absolute similarity instead. The
    // conservative floors separate matching and unrelated synthetic text/image
    // fixtures with the shipped model; they are not a universal accuracy claim.
    static func semanticSignals(raw: [Float], sources: [UInt8], gate: Float) -> [SemanticSignal] {
        precondition(raw.count == sources.count)
        var sum = [Float](repeating: 0, count: SRC_COUNT), sq = sum, cnt = sum
        for r in raw.indices {
            let s = Int(sources[r])
            sum[s] += raw[r]; sq[s] += raw[r] * raw[r]; cnt[s] += 1
        }
        var mean = [Float](repeating: 0, count: SRC_COUNT), sd = [Float](repeating: 1, count: SRC_COUNT)
        for s in 0..<SRC_COUNT where cnt[s] > 1 {
            mean[s] = sum[s] / cnt[s]
            sd[s] = max(1e-3, (sq[s] / cnt[s] - mean[s] * mean[s]).squareRoot())
        }
        return raw.indices.map { r in
            let s = Int(sources[r])
            if cnt[s] - 1 < gate * gate {
                // sb_scan_i8 returns the dot product against QSCALE-quantized
                // unit vectors, so division recovers approximate cosine.
                let cosine = raw[r] / QSCALE
                let floor: Float = gate > 3.4 ? 0.78 : 0.70
                return SemanticSignal(score: 6 * max(0, min(1, cosine)), admitted: cosine >= floor)
            }
            let z = (raw[r] - mean[s]) / sd[s]
            return SemanticSignal(score: z, admitted: z >= gate)
        }
    }

    #if SEARCH_TESTS
    // Exercise the production admission, filename ordering and passage selection
    // without loading a model or relying on its floating-point output.
    func semanticRanksForChecks(_ query: String, vector: [Float], gate: Float = 3.4) -> [Ranked] {
        rank(rest: query, full: query, filters: Filters(), gate: gate, boosts: [:], queryVector: vector)
    }
    #endif

    // every entry worth showing for a query, best first
    private func rank(rest: String, full: String, filters: Filters, gate: Float, boosts: [String: Float], nameOnly: Bool = false, contentOnly: Bool = false,
                      snapshot: Index? = nil, semantic: Bool = true, habits: [String: Float]? = nil, queryVector: [Float]? = nil) -> [Ranked] {
        let ix = snapshot ?? index
        let habit = habits ?? Habits.shared.prior()
        // a file that was learned and then moved or renamed keeps what was learned under its name
        func moved(_ learned: [String: Float]) -> [String: Float] {
            var out: [String: Float] = [:]
            for (key, v) in learned where key.hasPrefix("/") && ix.byPath[key] == nil {
                out[(key as NSString).lastPathComponent.lowercased(), default: 0] += v
            }
            return out
        }
        let movedBoosts = moved(boosts), movedHabit = moved(habit)
        let q = rest, listing = rest.isEmpty && !filters.isEmpty
        var qt = nameTokens(q).filter { !stopwords.contains($0) }
        if qt.isEmpty { qt = nameTokens(q) }
        let fullTokens = nameTokens(full)
        let identifier = qt.contains { $0.contains(where: { $0.isNumber }) }
        var content: [Int: Store.ContentMatch] = [:]
        // a letter or two typed is the start of a name, not a word to look for inside files
        if !nameOnly, contentOnly || q.count >= 3 {
            for match in ix.contentStore?.contentMatches(q, literal: contentOnly) ?? [] {
                if let i = ix.byID[match.id], match.path == ix.entries[i].path, content[i] == nil { content[i] = match }
            }
        }

        // One embedding, one scan; source-normalized scores (or bounded absolute
        // scores for small populations) keep text, media and passages comparable.
        let qv = semantic && !nameOnly && !contentOnly && ix.rows > 0 && q.count >= 3 ? (queryVector ?? embedder?.query(q)) : nil
        var sem = [Float](repeating: 0, count: ix.entries.count)
        var semanticAdmission = [Bool](repeating: false, count: ix.entries.count)
        var bestRow = [Int32](repeating: -1, count: ix.entries.count)
        if let qv, let vecs = ix.vecs, ix.rows > 0 {
            var raw = [Float](repeating: 0, count: ix.rows)
            sb_scan_i8(qv, vecs, ix.rows, &raw)
            let signals = Self.semanticSignals(raw: raw, sources: ix.rowSrc, gate: gate)
            for r in 0..<ix.rows {
                let e = Int(ix.rowEntry[r]), signal = signals[r]
                // An admitted passage must remain the destination even if a
                // different source has a higher score below its own gate.
                if (signal.admitted && !semanticAdmission[e]) ||
                    (signal.admitted == semanticAdmission[e] && signal.score > sem[e]) {
                    sem[e] = signal.score; bestRow[e] = Int32(r)
                }
                if signal.admitted { semanticAdmission[e] = true }
            }
        }

        // a few typed letters say little semantically, so lean on the name match until the query grows
        let semWeight = min(1, Float(max(0, q.count - 2)) / 4)
        let now = Date().timeIntervalSince1970
        var out: [Ranked] = []
        for (i, e) in ix.entries.enumerated() {
            let l = lex(q, qt, e)
            let boost = boosts[e.path] ?? (movedBoosts.isEmpty ? 0 : movedBoosts[e.lname] ?? 0)
            let words = content[i]
            if contentOnly && words == nil { continue }
            if !filters.isEmpty {
                guard filters.matches(e) else { continue }
            }
            var s: Float, learned: Float = 0
            if listing {
                // newest first; for events, the ones closest to now
                s = e.kind == .event ? -Float(abs(e.mtime - now) / 86400) : Float((e.mtime - 1.6e9) / 86400)
            } else {
                // Learned choices refine relevance; only a choice repeated for this exact query admits a result on its own.
                guard l >= 0.5 || words != nil || (!nameOnly && !identifier && semanticAdmission[i]) || boost >= 7 else { continue }
                if nameOnly, l < 0.9 { continue }
                // Exact names have a protected lead over merely inferred semantic matches.
                let nameScore: Float = l == 1 ? 16 : (l >= 0.9 ? 10 : 6 * l + (l >= 0.5 && l < 0.65 ? 3 : 0))
                let meaning = (identifier ? 0.35 : semWeight) * min(6, sem[i])
                s = nameScore + meaning + (words == nil ? 0 : (identifier ? 10 : 5)) + min(9, boost)
                // launching apps is what the bar is used for most: a named app outranks a file with a similar name,
                // and a letter or two is almost always the start of an app's name
                if e.kind == .app { s += (l >= 0.95 ? 7 : (l >= 0.7 ? 5 : (l > 0 ? 1 : 0))) + (l >= 0.7 && q.count <= 2 ? 2 : 0) }
                if e.kind == .other { s -= 0.4 }
                if e.kind == .web { s -= 1 } // history is plentiful; let files win ties
                if filters.softKinds.contains(e.kind) { s += 1.2 }
                learned = min(9, boost)
                if let h = habit[e.path] ?? (movedHabit.isEmpty ? nil : movedHabit[e.lname]) { s += min(4, h); learned += min(4, h) }
                if e.mtime > 0, e.kind.isFile {
                    let age = now - e.mtime
                    s += age < 7 * 86400 ? 0.3 : (age < 30 * 86400 ? 0.15 : 0)
                }
            }
            let r = Int(bestRow[i])
            // An exact passage is the most useful destination when exact words matched.
            out.append(Ranked(i: i, score: s, lex: l, loc: words?.loc ?? (r >= 0 ? ix.rowLoc[r] : 0),
                              src: words?.src ?? (r >= 0 ? Int(ix.rowSrc[r]) : 0), excerpt: words?.excerpt ?? "", learned: learned))
        }
        out.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = ix.entries[$0.i], b = ix.entries[$1.i]
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.path < b.path
        }
        if !listing {
            // relevance decides what is worth showing; learning only orders it, so it never hides runners-up
            let topFile = out.filter { ix.entries[$0.i].kind.isFile }.map { $0.score - $0.learned }.max() ?? 0
            let topOther = out.filter { !ix.entries[$0.i].kind.isFile }.map { $0.score - $0.learned }.max() ?? 0
            out.removeAll { $0.score - $0.learned < (ix.entries[$0.i].kind.isFile ? topFile : topOther) * 0.42 }
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

    private func explicitFiles(_ query: FileQuery) -> SearchResult {
        if let error = query.error { return SearchResult(hits: [], note: error) }
        let ranked: [Ranked]
        if query.pattern != nil {
            ranked = index.entries.enumerated().filter { query.matches($0.element) }.sorted {
                if $0.element.mtime != $1.element.mtime { return $0.element.mtime > $1.element.mtime }
                return $0.element.path < $1.element.path
            }.map { Ranked(i: $0.offset, score: 1, lex: 1, loc: 0, src: 0) }
        } else {
            ranked = rank(rest: query.text.lowercased(), full: query.text.lowercased(), filters: query.filters,
                          gate: 3.4, boosts: boosts(Self.norm(query.text)), contentOnly: query.contentOnly).filter { query.matches(index.entries[$0.i]) }
        }
        var seen = Set<String>()
        let top = ranked.filter { seen.insert(index.entries[$0.i].dupKey).inserted }.prefix(SearchResult.fileLimit)
        var hits = top.map { hit($0, copies: 0) }
        let files = Assistant.attachmentFiles(hits.compactMap(\.path))
        if !files.isEmpty, !Self.launching(query.text, hits) { hits.append(Assistant.hit(query.text, files: files)) }
        return SearchResult(hits: hits, note: query.filters.notes.joined(separator: " · "))
    }

    func build(_ text: String, chips: [String] = []) -> SearchResult {
        if !chips.isEmpty { return chipHits(text, chips) }
        guard !text.isEmpty else { return SearchResult(hits: []) }
        let fileQuery = FileQuery(text)
        if fileQuery.explicit || Self.hasLiteralName(text, in: index) { return explicitFiles(fileQuery) }
        let ix = index
        let q = text.lowercased()

        var out: [Hit] = []
        let calc = Calc.answer(text)
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

        let (filters, rest) = calc == nil ? Filters.parse(text, folderExists: { name in
            ix.folders.contains(name) || ix.entries.contains { $0.kind.isFile && $0.path.range(of: "/\(name)/", options: .caseInsensitive) != nil }
        }) : (Filters(), q)
        let learned = boosts(Self.norm(text))

        // intent pass: nearest exemplar per intent
        let iv = q.count >= 3 ? embedder?.query(q) : nil
        var best = [Float](repeating: -1, count: intents.count)
        if let iv, !intentVecs.isEmpty {
            intentVecs.withUnsafeBufferPointer { p in
                for x in 0..<intentOf.count {
                    var d: Float = 0
                    for k in 0..<DIM { d += iv[k] * p[x * DIM + k] }
                    best[intentOf[x]] = max(best[intentOf[x]], d)
                }
            }
        }
        let fileSim = best.first ?? -1
        let rankedIntents = best.enumerated().dropFirst().sorted { $0.element > $1.element }
        if debug {
            print("  intents: file=\(String(format: "%.3f", fileSim)) " + rankedIntents.prefix(3).map { "\(intents[$0.offset].id)=\(String(format: "%.3f", $0.element))" }.joined(separator: " "))
            if !filters.isEmpty { print("  filters: \(filters.notes.joined(separator: ", "))  rest: “\(rest)”") }
        }

        // a typed app/file name always beats an inferred action
        let qt = nameTokens(q)
        let strongName = ix.entries.contains { e in
            let l = lex(q, qt, e)
            return l >= 0.9 || (l >= 0.7 && e.kind == .app)
        }
        var lead: [Hit] = [], trail: [Hit] = []
        var sawWeb = false
        for (n, r) in rankedIntents.prefix(3).enumerated() {
            let it = intents[r.offset]
            // an action the user chose for this exact query before is what they mean now
            let chosen = learned["intent:" + it.id] ?? 0
            guard r.element >= 0.78 || chosen >= 3 else { continue }
            let wins = chosen >= 3 || (n == 0 && r.element >= fileSim + 0.05 && !strongName && calc == nil && filters.isEmpty)
            guard wins || r.element >= fileSim - 0.05 else { continue }
            if it.id == "web" { sawWeb = true }
            let made = it.hits(text).map { h -> Hit in
                var h = h
                if h.key == nil { h.key = "intent:" + it.id }
                return h
            }
            if wins { lead += made } else { trail += made }
        }

        // when an action or a computed answer already covers the query, only clearly related files are worth showing
        let gate: Float = lead.isEmpty ? 3.4 : 4.5
        let ranked = rank(rest: rest, full: q, filters: filters, gate: gate, boosts: learned, nameOnly: calc != nil)

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
        lead = lead.map { $0.tag == "ChatGPT" ? Assistant.hit(text, files: contextFiles) : $0 }
        trail = trail.map { $0.tag == "ChatGPT" ? Assistant.hit(text, files: contextFiles) : $0 }
        let asksOutright = Calc.rx(q, "^(ask )?(chat ?gpt|gpt)\\b.+") != nil
        if asksOutright || (calc == nil && !strongName && filters.isEmpty && Assistant.isComplex(q)), !lead.contains(where: { $0.tag == "ChatGPT" }) {
            trail.removeAll { $0.tag == "ChatGPT" }
            lead.insert(Assistant.hit(text, files: contextFiles), at: 0)
        }
        out += lead
        out += kept.filter { ix.entries[$0.0.i].kind.isFile }.map { hit($0.0, copies: $0.1) }
        out += kept.filter { !ix.entries[$0.0.i].kind.isFile }.map { hit($0.0, copies: $0.1) }
        out += trail
        // File searches expose their contextual Ask action without a separate attachment step.
        if !out.contains(where: { $0.tag == "ChatGPT" }), (!contextFiles.isEmpty || q.split(separator: " ").count >= 3), calc == nil, !Self.launching(text, out) { out.append(Assistant.hit(text, files: contextFiles)) }
        if !sawWeb, q.count >= 2 { out.append(Actions.web(text)) }
        // Ask remains Ask. File operations are resolved before displaying an executable row.
        return SearchResult(hits: out, note: filters.notes.isEmpty ? "" : "Filter: " + filters.notes.joined(separator: " · "))
    }

    // MARK: query by example

    private func mediaVector(_ path: String) -> [Float]? {
        if let i = index.byPath[path] {
            for r in 0..<index.rows where Int(index.rowEntry[r]) == i && Int(index.rowSrc[r]) == Src.media.rawValue { return index.vector(row: r) }
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
            var squaredNorm: Float = 0
            for k in 0..<DIM {
                let component = Float(vecs[r * DIM + k])
                squaredNorm += component * component
            }
            guard squaredNorm > 0 else { continue }
            let cosine = raw[r] / (queryNorm * squaredNorm.squareRoot())
            guard cosine.isFinite, cosine >= floor, cosine > (best[e]?.score ?? -1) else { continue }
            best[e] = Ranked(i: e, score: min(1, cosine), lex: 0, loc: ix.rowLoc[r], src: Src.media.rawValue)
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
