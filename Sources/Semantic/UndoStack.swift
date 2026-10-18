import AppKit

// Inverse of the file operations that change originals (rename, move, trash). Each entry is a list of
// moves that happened; undoing moves every item back, never over a file that now occupies the old place.
final class UndoStack {
    static let shared = UndoStack()
    static let window: TimeInterval = 120   // ⌘Z in the bar reaches back this far

    struct Move { let from: String; let to: String }
    final class Entry {
        let title: String
        let at = Date()
        fileprivate(set) var moves: [Move] = []
        fileprivate(set) var undone = false
        init(_ title: String) { self.title = title }
    }

    private var entries: [Entry] = []
    private let lock = NSLock()

    // called from the operation's background work, once per item actually moved
    func begin(_ title: String) -> Entry {
        let e = Entry(title)
        lock.lock(); entries.append(e); if entries.count > 20 { entries.removeFirst() }; lock.unlock()
        return e
    }

    func record(_ e: Entry, from: String, to: String) {
        lock.lock(); e.moves.append(Move(from: from, to: to)); lock.unlock()
    }

    var last: Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.last { !$0.undone && !$0.moves.isEmpty }
    }

    // Moves everything back. Returns a line for a toast; conflicts and missing items are reported, not forced.
    @discardableResult
    func undo(_ e: Entry) -> (ok: Bool, message: String) {
        lock.lock()
        guard !e.undone else { lock.unlock(); return (false, "Already undone") }
        e.undone = true
        let moves = e.moves
        lock.unlock()
        let fm = FileManager.default
        var restored: [String] = [], problems: [String] = [], left: [Move] = []
        for m in moves.reversed() {
            let name = (m.from as NSString).lastPathComponent
            guard fm.fileExists(atPath: m.to) else { problems.append("\((m.to as NSString).lastPathComponent) is gone"); continue }
            guard !fm.fileExists(atPath: m.from) else { problems.append("“\(name)” already exists again"); left.append(m); continue }
            do {
                try fm.createDirectory(atPath: (m.from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: m.to, toPath: m.from)
                restored.append(m.from)
            } catch { problems.append("\(name): \(error.localizedDescription)"); left.append(m) }
        }
        // what was blocked can be retried once the conflict is cleared
        lock.lock(); e.moves = left.reversed(); e.undone = left.isEmpty; lock.unlock()
        if problems.isEmpty { return (true, "↩ Undid \(e.title.lowercased())") }
        let head = restored.isEmpty ? "✗ Could not undo" : "Undid \(restored.count) of \(moves.count)"
        return (!restored.isEmpty, head + " · " + problems.prefix(2).joined(separator: "; "))
    }

    // ⌘Z in the bar: the newest operation from the last two minutes. false when there is nothing to undo.
    func undoLast() -> Bool {
        guard let e = last, Date().timeIntervalSince(e.at) <= Self.window else { return false }
        let r = undo(e)
        Toast.show(r.message, seconds: r.ok ? 2.4 : 5)
        return true
    }

    func undoAction(_ e: Entry) -> Toast.Action {
        Toast.Action(title: "Undo") { [weak self] in
            guard let self else { return }
            let r = self.undo(e)
            Toast.show(r.message, seconds: r.ok ? 2.4 : 5)
        }
    }
}

// Ops that record an entry carry this so the run UI can offer Undo once the work is done.
final class UndoSlot {
    var entry: UndoStack.Entry?
}
