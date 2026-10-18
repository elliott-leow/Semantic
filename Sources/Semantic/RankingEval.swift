import Foundation
import SQLite3

// Offline ranking check against the user's own history of picks (`Semantic --eval`).
// Reads the index only; each past query is replayed and the position of what was picked is scored.
enum RankingEval {
    struct Case { let q: String, key: String, n: Double }

    static func run(verbose: Bool) -> Int32 {
        guard let store = Store(readonly: true) else { print("no index at \(Paths.db)"); return 0 }
        var picks: [Case] = []
        store.run("SELECT q, key, n, t FROM picks ORDER BY t DESC") { st in
            picks.append(Case(q: colText(st, 0), key: colText(st, 1), n: sqlite3_column_double(st, 2)))
        }
        let e = Engine.shared
        e.reloadIndex()
        let semantic = !CommandLine.arguments.contains("--lexical") && FileManager.default.fileExists(atPath: Paths.model)
        if semantic { e.warm(wait: true) }
        e.sync {}
        let cases = picks.filter { !$0.key.hasPrefix("intent:") && !$0.key.hasPrefix("op:") && !$0.q.isEmpty && e.indexed($0.key) }
        print("\(cases.count) picked results to replay (\(picks.count - cases.count) skipped: actions, or no longer indexed)" +
              (semantic ? "" : "; names and words only, no model"))
        guard !cases.isEmpty else { return 0 }
        for learning in [false, true] {
            var ranks: [Int?] = [], tops: [String] = []
            e.sync {
                e.learning = learning
                for c in cases {
                    let hits = e.build(c.q).hits
                    ranks.append(hits.firstIndex { $0.key == c.key }.map { $0 + 1 })
                    tops.append(hits.first.map { "\($0.title) [\($0.tag)]" } ?? "nothing")
                }
                e.learning = true
            }
            let mrr = ranks.reduce(0.0) { $0 + ($1.map { 1 / Double($0) } ?? 0) } / Double(ranks.count)
            func at(_ k: Int) -> Double { Double(ranks.filter { ($0 ?? .max) <= k }.count) / Double(ranks.count) * 100 }
            print(String(format: "%@  MRR %.3f   hit@1 %.0f%%   hit@5 %.0f%%", learning ? "with learning   " : "ranking alone   ", mrr, at(1), at(5)))
            guard verbose, !learning else { continue }
            let misses = cases.indices.filter { (ranks[$0] ?? .max) > 1 }.sorted { (ranks[$0] ?? .max) > (ranks[$1] ?? .max) }
            if !misses.isEmpty { print("worst misses without learning:") }
            for i in misses.prefix(15) {
                let c = cases[i]
                print("  \(ranks[i].map { "#\($0)" } ?? "--")  “\(c.q)” → \(Paths.tilde(c.key))   top: \(tops[i])")
            }
        }
        return 0
    }
}
