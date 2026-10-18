import AppKit
import Carbon.HIToolbox
import Foundation
import SQLite3

// App-level behavior: hotkey parsing, config writes, undo, clipboard retention, new intents. No UI, no user paths.
enum AppChecks {
    static func run(root: URL) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { out.append((label, passed)) }
        let fm = FileManager.default
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-app-checks-" + UUID().uuidString)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // hotkeys
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey)
        check("hotkey cmd+y parses", Hotkey("cmd+y") == Hotkey(code: UInt32(kVK_ANSI_Y), mods: cmd))
        check("hotkey alt+space parses", Hotkey("alt+space") == Hotkey(code: UInt32(kVK_Space), mods: opt))
        check("hotkey cmd+shift+space parses", Hotkey("cmd+shift+space") == Hotkey(code: UInt32(kVK_Space), mods: cmd | shift))
        check("hotkey ctrl+opt+k parses with spaces and case", Hotkey(" Ctrl + Opt + K ") == Hotkey(code: UInt32(kVK_ANSI_K), mods: ctrl | opt))
        check("bare F-key is a usable hotkey", Hotkey("f13") == Hotkey(code: UInt32(kVK_F13), mods: 0))
        check("plain letter, unknown key and two keys are rejected", Hotkey("y") == nil && Hotkey("cmd+banana") == nil && Hotkey("cmd+a+b") == nil && Hotkey("cmd+") == nil)
        check("hotkey spec round-trips", ["cmd+y", "alt+space", "ctrl+alt+shift+cmd+f5", "cmd+,"].allSatisfy { Hotkey($0).map { Hotkey($0.spec) == $0 } ?? false })
        check("hotkey display uses menu symbols in menu order", Hotkey("cmd+shift+ctrl+space")?.display == "⌃⇧⌘Space" && Hotkey.fallback.display == "⌘Y")

        // config writes keep unknown keys and remove nil ones
        let cfg = dir.appendingPathComponent("config.json").path
        try! #"{"roots": ["~/Docs"], "futureKey": {"x": 1}, "maps": "apple"}"#.write(toFile: cfg, atomically: true, encoding: .utf8)
        let wrote = updateConfig(["hotkey": "alt+space", "maps": nil, "excludes": ["*.secret"]], path: cfg)
        let back = loadConfig(cfg)
        let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cfg)))) as? [String: Any] ?? [:]
        check("config update writes known keys", wrote && back.hotkey == "alt+space" && back.excludes == ["*.secret"] && back.roots == ["~/Docs"])
        check("config update preserves unknown keys and removes nil keys", raw["futureKey"] != nil && raw["maps"] == nil)
        try! "{ not json".write(toFile: cfg, atomically: true, encoding: .utf8)
        check("config update refuses to overwrite invalid JSON", !updateConfig(["hotkey": "cmd+y"], path: cfg) && (try? String(contentsOfFile: cfg, encoding: .utf8)) == "{ not json")

        // undo
        let a = dir.appendingPathComponent("undo-a.txt")
        try! "alpha".write(to: a, atomically: true, encoding: .utf8)
        let rename = FileOps.renameOp([a.path], "undo-b")
        let renamed = (try? rename.work!()) ?? []
        let b = dir.appendingPathComponent("undo-b.txt").path
        check("rename records an undo entry", renamed == [b] && rename.undo?.entry?.moves.count == 1)
        if let e = rename.undo?.entry {
            let r = UndoStack.shared.undo(e)
            check("undo rename restores the original name", r.ok && fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: b))
            check("an entry cannot be undone twice", !UndoStack.shared.undo(e).ok)
        } else { check("undo rename restores the original name", false) }
        let sub = dir.appendingPathComponent("dest")
        try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let move = FileOps.relocateOp([a.path], sub.path, copy: false)
        _ = try? move.work!()
        let moved = sub.appendingPathComponent("undo-a.txt").path
        // something new now sits where the file was: undo must not overwrite it
        try! "newer".write(to: a, atomically: true, encoding: .utf8)
        if let e = move.undo?.entry {
            let r = UndoStack.shared.undo(e)
            check("undo move reports a conflict instead of overwriting", !r.ok && r.message.contains("already exists")
                  && (try? String(contentsOf: a, encoding: .utf8)) == "newer" && fm.fileExists(atPath: moved))
        } else { check("undo move reports a conflict instead of overwriting", false) }
        try! fm.removeItem(at: a)
        let e2 = UndoStack.shared.begin("Move to Trash")
        UndoStack.shared.record(e2, from: a.path, to: moved)
        check("undoLast undoes the newest recent operation", UndoStack.shared.last === e2 && UndoStack.shared.undoLast() && fm.fileExists(atPath: a.path))
        check("copy records no undo", FileOps.relocateOp([a.path], sub.path, copy: true).undo == nil)

        // clipboard retention
        let db = Store(path: ":memory:")!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        ClipboardHistory.add("an old copied line", store: db, now: now.addingTimeInterval(-40 * 86400))
        ClipboardHistory.add("a recent copied line", store: db, now: now)
        ClipboardHistory.prune(db, now: now, days: 30)
        var clips: [String] = []
        db.run("SELECT snippet FROM files WHERE kind = ?", [Kind.clip.rawValue]) { clips.append(colText($0, 0)) }
        check("clipboard rows older than clipboardDays are dropped", clips == ["a recent copied line"])
        for i in 0..<(ClipboardHistory.maxRows + 5) { ClipboardHistory.add("copied line number \(i)", store: db, now: now.addingTimeInterval(Double(i))) }
        var n = 0
        db.run("SELECT count(*) FROM files WHERE kind = ?", [Kind.clip.rawValue]) { n = Int(sqlite3_column_int64($0, 0)) }
        check("clipboard history keeps at most 200 rows", n == ClipboardHistory.maxRows)
        check("clear removes every clipboard row", ClipboardHistory.clear(db) == ClipboardHistory.maxRows)
        check("password managers are ignored by default", ClipboardHistory.ignored("com.1password.1password") && ClipboardHistory.ignored("com.apple.keychainaccess")
              && !ClipboardHistory.ignored("com.apple.TextEdit") && !ClipboardHistory.ignored(nil))

        // new intents
        check("emoji search finds party popper first", AppEmoji.search(AppEmoji.query("emoji party")).first?.char == "🎉")
        check("emoji search by keyword", AppEmoji.search(AppEmoji.query("thumbs up emoji")).first?.char == "👍")
        check("emoji table is a few hundred entries", AppEmoji.all.count >= 300 && Set(AppEmoji.all.map(\.char)).count == AppEmoji.all.count)
        check("emoji hits copy and are tagged", AppEmoji.hits("smile emoji").first?.tag == "Emoji")
        let q = AppQuitter.parse("force quit google chrome")
        check("force quit parses the app name", q.force && q.name == "google chrome" && !AppQuitter.parse("quit spotify").force && AppQuitter.parse("quit spotify").name == "spotify")
        check("quit matching prefers the whole name and finds a word of it", AppQuitter.rank("chrome", among: ["Safari", "Google Chrome", "Chrome Remote"]) == [2, 1]
              && AppQuitter.rank("spot", among: ["Spotify", "Finder"]) == [0] && AppQuitter.rank("", among: ["Finder"]).isEmpty)
        check("window query strips the verb and the word window", WindowSwitcher.query("switch to the figma window") == "figma" && WindowSwitcher.query("focus my terminal") == "terminal")
        check("window matching uses app and title words", WindowSwitcher.matches("roadmap", app: "Figma", title: "Q3 Roadmap") && !WindowSwitcher.matches("safari", app: "Figma", title: "Q3 Roadmap"))
        check("shortcut query strips the verb", Shortcuts.query("run shortcut morning routine") == "morning routine" && Shortcuts.query("run the shortcut called log water") == "log water")
        let ids = Set(Actions.all.map(\.id))
        check("new intents are registered", ["window", "quitapp", "emoji", "shortcut", "semantic.settings", "semantic.permissions", "clipboard.clear"].allSatisfy(ids.contains))
        check("intent ids stay unique", ids.count == Actions.all.count)

        // assistant destinations
        check("ChatGPT stays the default destination", Dest.configured == .chatgpt && Assistant.hit("what is a monad", files: []).title.hasPrefix("Ask ChatGPT"))
        let claude = Assistant.hit("ask claude what a monad is", files: [])
        check("naming Claude asks Claude", claude.title == "Ask Claude: “what a monad is”" && claude.tag == "Claude" && Assistant.isAsk(claude))
        check("Gemini goes to its website", Assistant.hit("ask gemini about rome", files: []).subtitle.contains("gemini.google.com"))

        // permissions probe: a readable file counts as access, an unreadable one does not
        let readable = dir.appendingPathComponent("probe").path
        try! "x".write(toFile: readable, atomically: true, encoding: .utf8)
        check("full disk probe reads a readable file as granted", Permission.fullDiskProbe([readable]) == .granted && Permission.fullDiskProbe([dir.appendingPathComponent("missing").path]) == .unknown)
        return out
    }
}
