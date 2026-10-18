import AppKit
import SQLite3

// Clipboard rows live in the index (kind .clip, path "clip:<hash>"); this keeps them bounded and private.
enum ClipboardHistory {
    static let maxRows = 200

    static var days: Double { max(0, config.clipboardDays ?? 30) }
    static var ignoredApps: Set<String> { Set(config.clipboardIgnoreApps ?? Config.defaultIgnoreApps) }

    // password managers and Keychain Access: whatever they put on the clipboard is not kept
    static func ignored(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredApps.contains(bundleID)
    }

    // oldest beyond the row cap, and anything older than `days` (0 keeps no age limit)
    static func prune(_ store: Store, now: Date = Date(), days: Double = days) {
        var old: [Int64] = []
        store.run("SELECT id FROM files WHERE kind = ? ORDER BY mtime DESC LIMIT -1 OFFSET ?", [Kind.clip.rawValue, maxRows]) { old.append(sqlite3_column_int64($0, 0)) }
        if days > 0 {
            store.run("SELECT id FROM files WHERE kind = ? AND mtime < ?", [Kind.clip.rawValue, now.timeIntervalSince1970 - days * 86400]) { old.append(sqlite3_column_int64($0, 0)) }
        }
        for id in Set(old) { store.deleteFile(id) }
        if !old.isEmpty { store.bumpGeneration() }
    }

    static func clear(_ store: Store) -> Int {
        var ids: [Int64] = []
        store.run("SELECT id FROM files WHERE kind = ?", [Kind.clip.rawValue]) { ids.append(sqlite3_column_int64($0, 0)) }
        for id in ids { store.deleteFile(id) }
        if !ids.isEmpty { store.bumpGeneration() }
        return ids.count
    }

    // from a menu, the settings window or the "clear clipboard history" command
    static func clearAll() {
        ioQueue.async {
            let n = Store().map(clear) ?? 0
            DispatchQueue.main.async {
                Engine.shared.reloadIndex()
                Toast.show(n == 0 ? "Clipboard history is already empty" : "✓ Cleared \(n) clipboard item\(n == 1 ? "" : "s")")
            }
        }
    }

    static func add(_ s: String, store: Store, now: Date = Date()) {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        let key = "clip:\(h)"
        let name = String((s.split(separator: "\n").first ?? "").prefix(80))
        var old: [Int64] = []
        store.run("SELECT id FROM files WHERE path = ?", [key]) { old.append(sqlite3_column_int64($0, 0)) }
        for id in old { store.deleteFile(id) }
        // state 2: the bar embeds it the next time the text model is loaded
        store.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,2,?)",
                  [key, name, Kind.clip.rawValue, now.timeIntervalSince1970, s.count, s])
        prune(store, now: now)
        store.bumpGeneration()
    }
}
