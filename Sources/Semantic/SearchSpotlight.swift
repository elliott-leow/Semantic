import CoreServices
import Foundation

// Files the index does not cover, found by name through Spotlight within a small time budget.
enum Spotlight {
    static let home = Paths.home + "/"

    // Folders people do not mean when they type a name: hidden, system, inside packages.
    static func ignored(_ path: String) -> Bool {
        guard path.hasPrefix(home) || path.hasPrefix("/Volumes/") else { return true }
        // the folders the indexer skips (dependencies, builds, caches) are no more wanted here
        return path.contains("/.") || path.contains(".app/") || path.contains("site-packages") ||
            path.split(separator: "/").dropLast().contains { Indexer.skipDirs.contains(String($0)) }
    }

    // Paths whose display name contains every word, best first. Never waits longer than `budget` seconds.
    static func names(_ text: String, limit: Int, budget: Double = 0.15, skip: (String) -> Bool) -> [String] {
        let words = Array(nameTokens(text).filter { !stopwords.contains($0) }.prefix(4))
        guard limit > 0, !words.isEmpty else { return [] }
        // tokens are letters and digits only, so they cannot break out of the quoted value
        let expr = words.map { "kMDItemDisplayName == \"*\($0)*\"cdw" }.joined(separator: " && ")
        guard let q = MDQueryCreate(kCFAllocatorDefault, expr as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(q, 60)
        guard MDQueryExecute(q, 0) else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        while !MDQueryIsGatheringComplete(q), Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        MDQueryStop(q)
        MDQueryDisableUpdates(q)
        var found: [(String, Int)] = []
        let joined = words.joined(separator: " ")
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !ignored(path), !skip(path) else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            // the whole name, then its start, then anywhere; shorter paths first within each
            let score = name == joined ? 0 : (name.hasPrefix(words[0]) ? 1 : 2)
            found.append((path, score))
        }
        return found.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.count != $1.0.count ? $0.0.count < $1.0.count : $0.0 < $1.0) }
            .prefix(limit).map(\.0)
    }
}
