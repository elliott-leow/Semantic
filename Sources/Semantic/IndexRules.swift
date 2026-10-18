import Foundation

// What the indexer must never look at: `excludes` from the config (folder prefixes or fnmatch globs)
// and `.semanticignore` files (one glob per line) that apply to the subtree they sit in.
struct IndexRules {
    static let shared = IndexRules(config.excludes ?? [])

    let prefixes: [String]
    let globs: [String] // with a "/" matched against the whole path, otherwise against the name

    init(_ excludes: [String]) {
        var p: [String] = [], g: [String] = []
        for raw in excludes {
            var e = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            while e.count > 1, e.hasSuffix("/") { e.removeLast() }
            guard !e.isEmpty else { continue }
            if e.contains(where: { "*?[".contains($0) }) { g.append(e) } else { p.append(e) }
        }
        prefixes = p
        globs = g
    }

    func excluded(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return prefixes.contains { path == $0 || path.hasPrefix($0 + "/") } ||
            globs.contains { fnmatch($0, $0.contains("/") ? path : name, 0) == 0 }
    }

    struct Ignore {
        let dir: String
        let patterns: [String]

        func matches(_ path: String) -> Bool {
            guard path.hasPrefix(dir + "/") else { return false }
            let rel = String(path.dropFirst(dir.count + 1)), name = (path as NSString).lastPathComponent
            return patterns.contains { p in p.contains("/") ? fnmatch(p, rel, 0) == 0 : fnmatch(p, name, 0) == 0 }
        }
    }

    static func ignoreFile(in dir: String) -> Ignore? {
        guard let s = try? String(contentsOfFile: dir + "/.semanticignore", encoding: .utf8) else { return nil }
        // gitignore-like lines; negation is not supported, so "!" lines are dropped rather than misread
        let pats = s.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var p = line.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, !p.hasPrefix("#"), !p.hasPrefix("!") else { return nil }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            if p.hasPrefix("/") { p.removeFirst() }
            return p.isEmpty ? nil : p
        }
        return pats.isEmpty ? nil : Ignore(dir: dir, patterns: pats)
    }
}
