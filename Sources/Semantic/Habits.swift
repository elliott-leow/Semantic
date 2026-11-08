import Foundation
import SQLite3

// What the user opens, at what hour, and from which app, learned from picks in the bar and from app switches.
// Everything decays (three-week half-life for habits) so a changed routine overtakes an old one.
// The in-memory model is the source of truth; rows are written back in batches off the typing path.
final class Habits {
    static let shared = Habits()
    static let halfLife: Double = 21 * 86400
    static let pickHalfLife: Double = 60 * 86400
    static let activation = "@app"   // ctx of hour rows learned from app switches rather than bar picks

    private struct Cell { var w: Double; var t: Double }
    private struct Row: Hashable { let key: String; let ctx: String; let hour: Int }

    private let lock = NSLock()
    private var loaded = false
    private var cells: [Row: Cell] = [:]
    private var byKey: [String: [Row]] = [:]
    private var picks: [String: [String: Cell]] = [:]   // normalized query -> key -> decayed count
    private var dirty = Set<Row>()
    private var stale = Set<Row>()     // rows merged into another at load, deleted from the table at the next flush
    private var dirtyPicks = Set<[String]>()
    private var flushScheduled = false
    private var version = 0
    private var cachedPrior: (version: Int, hour: Int, ctx: String, value: [String: Float])?
    private var context = ""  // the app that was in front when the bar opened

    private let path: String
    init(path: String? = nil) { self.path = path ?? Paths.db }

    private static func decay(_ c: Cell, _ now: Double, _ half: Double = halfLife) -> Double {
        c.w * pow(0.5, max(0, now - c.t) / half)
    }

    private static let calendar = Calendar.autoupdatingCurrent
    static func hour(_ t: Double) -> Int { calendar.component(.hour, from: Date(timeIntervalSince1970: t)) }

    // learned picks never belong in the habit model when they are not something to reopen
    static func habitual(_ key: String) -> Bool { !key.hasPrefix("intent:") && !key.hasPrefix("op:") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let now = Date().timeIntervalSince1970
        guard let store = Store(readonly: true, path: path) else { return }
        store.run("SELECT key, ctx, hour, w, t FROM habits") { st in
            let raw = Row(key: colText(st, 0), ctx: colText(st, 1), hour: Int(sqlite3_column_int(st, 2)))
            let c = Cell(w: sqlite3_column_double(st, 3), t: sqlite3_column_double(st, 4))
            // rows learned under a path the app is not indexed by (Safari's cryptex) join the indexed path's row
            let r = Row(key: Self.indexed(raw.key), ctx: Self.indexed(raw.ctx), hour: raw.hour)
            if r != raw { self.stale.insert(raw); self.dirty.insert(r) }
            guard Self.decay(c, now) >= 0.01 else { return }
            self.merge(r, c)
        }
        store.run("SELECT q, key, n, t FROM picks") { st in
            self.picks[colText(st, 0), default: [:]][colText(st, 1)] = Cell(w: sqlite3_column_double(st, 2), t: sqlite3_column_double(st, 3))
        }
        // first run with this model: what was already picked in the bar is the best evidence there is
        if cells.isEmpty {
            for (_, chosen) in picks {
                for (key, c) in chosen where Self.habitual(key) { bump(Row(key: key, ctx: "", hour: Self.hour(c.t)), c.w, at: c.t) }
            }
            if !dirty.isEmpty { scheduleFlushLocked() }
        }
        if !stale.isEmpty { scheduleFlushLocked() }
    }

    // app keys and contexts as the index spells them; other keys (files, intents, "@app") are left alone
    static func indexed(_ key: String) -> String {
        key.hasPrefix("/") && key.hasSuffix(".app") ? Sys.indexedAppPath(key) : key
    }

    // two rows for one cell: their weights decayed to the later time, added
    private func merge(_ r: Row, _ c: Cell) {
        guard let old = cells[r] else { put(r, c); return }
        let t = max(old.t, c.t)
        put(r, Cell(w: Self.decay(old, t) + Self.decay(c, t), t: t))
    }

    private func put(_ r: Row, _ c: Cell) {
        if cells.updateValue(c, forKey: r) == nil { byKey[r.key, default: []].append(r) }
    }

    private func bump(_ r: Row, _ w: Double, at now: Double) {
        let old = cells[r].map { Self.decay($0, now) } ?? 0
        put(r, Cell(w: old + w, t: now))
        dirty.insert(r)
        version += 1
    }

    // MARK: recording

    func setContext(_ app: String?) {
        lock.lock(); defer { lock.unlock() }
        if context != (app ?? "") { context = app ?? ""; version += 1 }
    }

    // a result chosen in the bar; `query` is empty when it was a suggestion
    func recordPick(_ query: String, _ key: String, now: Double = Date().timeIntervalSince1970) {
        lock.lock()
        load()
        if !query.isEmpty {
            let old = picks[query]?[key].map { Self.decay($0, now, Self.pickHalfLife) } ?? 0
            picks[query, default: [:]][key] = Cell(w: old + 1, t: now)
            dirtyPicks.insert([query, key])
            version += 1
        }
        if Self.habitual(key) {
            bump(Row(key: key, ctx: "", hour: Self.hour(now)), 1, at: now)
            if !context.isEmpty, context != key { bump(Row(key: key, ctx: context, hour: -1), 1, at: now) }
        }
        lock.unlock()
        scheduleFlush()
    }

    // the user stayed in `app` after switching from `from`: a weaker signal than a pick, but a constant one
    func recordActivation(_ app: String, from: String?, now: Double = Date().timeIntervalSince1970) {
        lock.lock()
        load()
        bump(Row(key: app, ctx: Self.activation, hour: Self.hour(now)), 0.15, at: now)
        if let from, !from.isEmpty, from != app { bump(Row(key: app, ctx: from, hour: -1), 0.15, at: now) }
        lock.unlock()
        scheduleFlush()
    }

    private func scheduleFlush() {
        lock.lock()
        defer { lock.unlock() }
        scheduleFlushLocked()
    }

    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        ioQueue.asyncAfter(deadline: .now() + 15) { self.flush() }
    }

    func flush() {
        lock.lock()
        flushScheduled = false
        let rows = dirty.compactMap { r in cells[r].map { (r, $0) } }
        let chosen = dirtyPicks.compactMap { p in picks[p[0]]?[p[1]].map { (p[0], p[1], $0) } }
        let gone = stale
        dirty.removeAll()
        dirtyPicks.removeAll()
        stale.removeAll()
        lock.unlock()
        guard !rows.isEmpty || !chosen.isEmpty || !gone.isEmpty, let store = Store(path: path) else { return }
        store.exec("BEGIN")
        for r in gone {
            store.run("DELETE FROM habits WHERE key=? AND ctx=? AND hour=?", [r.key, r.ctx, r.hour])
        }
        for (r, c) in rows {
            store.run("INSERT OR REPLACE INTO habits(key, ctx, hour, w, t) VALUES(?,?,?,?,?)", [r.key, r.ctx, r.hour, c.w, c.t])
        }
        for (q, key, c) in chosen {
            store.run("INSERT OR REPLACE INTO picks(q, key, n, t) VALUES(?,?,?,?)", [q, key, c.w, c.t])
        }
        // ten half-lives later a row weighs under a thousandth of what it did
        store.run("DELETE FROM habits WHERE t < ?", [Date().timeIntervalSince1970 - 10 * Self.halfLife])
        store.exec("COMMIT")
    }

    // MARK: scoring

    // How strongly habit points at each key right now: frequency and recency of picks, how typical this hour
    // is for it, plain app usage, and how often it follows the app in front.
    private func score(_ key: String, hour: Int, now: Double) -> Float {
        var pick = 0.0, pickHour = 0.0, use = 0.0, useHour = 0.0, after = 0.0
        for r in byKey[key] ?? [] {
            guard let c = cells[r] else { continue }
            let w = Self.decay(c, now)
            let near = r.hour >= 0 && min((r.hour - hour + 24) % 24, (hour - r.hour + 24) % 24) <= 1
            if r.ctx.isEmpty { pick += w; if near { pickHour += w } }
            else if r.ctx == Self.activation { use += w; if near { useHour += w } }
            else if r.ctx == context { after += w }
        }
        // 1 means this hour is as typical as any other; a habit tied to this time of day counts up to 1.6x
        func timely(_ total: Double, _ near: Double) -> Double {
            guard total > 0 else { return 0 }
            let lift = min(2.5, (near / total) / (3.0 / 24))
            return log2(1 + total) * (0.6 + 0.4 * lift)
        }
        return Float(timely(pick, pickHour) + 0.4 * timely(use, useHour) + 1.2 * log2(1 + after))
    }

    // per-key habit strength for the current hour and context, cached until something is learned
    func prior(now: Double = Date().timeIntervalSince1970) -> [String: Float] {
        lock.lock(); defer { lock.unlock() }
        load()
        let hour = Self.hour(now)
        if let c = cachedPrior, c.version == version, c.hour == hour, c.ctx == context { return c.value }
        var out: [String: Float] = [:]
        for key in byKey.keys {
            let s = score(key, hour: hour, now: now)
            if s > 0.05 { out[key] = s }
        }
        cachedPrior = (version, hour, context, out)
        return out
    }

    // what to offer before anything is typed, best first; never the app already in front
    func predictions(limit: Int, now: Double = Date().timeIntervalSince1970) -> [(String, Float)] {
        let ctx: String = { lock.lock(); defer { lock.unlock() }; return context }()
        return prior(now: now).filter { $0.value >= 0.8 && $0.key != ctx }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { ($0.key, $0.value) }
    }

    // how much each previously chosen key should be lifted for this query
    func boosts(_ q: String, now: Double = Date().timeIntervalSince1970) -> [String: Float] {
        lock.lock(); defer { lock.unlock() }
        load()
        var exact: [String: Float] = [:], partial: [String: Float] = [:]
        guard !q.isEmpty else { return exact }
        for (pq, chosen) in picks {
            // a few typed letters already predict what was picked after typing more of them,
            // in proportion to how much of that earlier query they are
            let typed = pq == q ? 1 : pq.hasPrefix(q) ? 0.4 + 0.6 * Float(q.count) / Float(pq.count) : (q.hasPrefix(pq) && pq.count >= 3 ? 0.6 : 0)
            guard typed > 0 else { continue }
            for (key, c) in chosen {
                let n = Float(Self.decay(c, now, Self.pickHalfLife))
                guard n >= 0.2 else { continue }
                if typed == 1 { exact[key] = 4 + 2 * log2(n + 1) }
                // the best related query speaks for a key; many loosely related ones do not add up
                else { partial[key] = max(partial[key] ?? 0, typed * (2 + log2(n + 1))) }
            }
        }
        return exact.merging(partial) { $0 + min($1, 2) }
    }
}
