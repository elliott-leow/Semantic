import Contacts
import CryptoKit
import EventKit
import Foundation
import SQLite3

// Things worth finding that are not files. Read by the indexer process only.
// Each reader returns nil when its source cannot be read, so existing rows are kept.
enum Sources {
    struct Item {
        let key: String
        let name: String
        let kind: Kind
        let mtime: Double
        let body: String
    }

    static func enabled(_ name: String) -> Bool { config.sources?.contains(name) ?? true }

    static func rows(_ dbPath: String, _ sql: String) -> [[String]]? {
        // browsers keep their databases locked, so query a private copy
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return nil }
        // a stable name: String.hashValue is seeded per process, which left a copy behind on every crash
        let copy = Paths.tmp + "/src-" + Extract.hex(SHA256.hash(data: Data(dbPath.utf8)).prefix(8)) + ".sqlite"
        for suffix in ["", "-wal"] {
            try? fm.removeItem(atPath: copy + suffix)
            try? fm.copyItem(atPath: dbPath + suffix, toPath: copy + suffix)
        }
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: copy + suffix) } }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        var out: [[String]] = []
        let n = sqlite3_column_count(st)
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((0..<n).map { colText(st!, $0) })
        }
        return out
    }

    static let support = Paths.home + "/Library/Application Support"
    static let chromium = ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Vivaldi",
                           "com.operasoftware.Opera", "Dia/User Data"]
    static let firefox = ["Firefox/Profiles", "zen/Profiles"]

    // Chromium profile folders: Default and Profile N; Opera keeps its files in the base folder itself
    static func chromiumProfiles() -> [String] {
        let fm = FileManager.default
        return chromium.flatMap { b -> [String] in
            let base = support + "/" + b
            let names = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            return (fm.fileExists(atPath: base + "/History") ? [base] : []) + names.map { base + "/" + $0 }
        }
    }

    static func firefoxProfiles() -> [String] {
        firefox.flatMap { f -> [String] in
            let dir = support + "/" + f
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().map { dir + "/" + $0 }
        }
    }

    static let orionHistory = support + "/Orion/Defaults/history"
    static let safariHistory = Paths.home + "/Library/Safari/History.db"
    static let safariBookmarks = Paths.home + "/Library/Safari/Bookmarks.plist"

    // every file web() reads; their mtimes tell the indexer whether a re-read can find anything new
    static func webFiles() -> [String] {
        chromiumProfiles().flatMap { [$0 + "/History", $0 + "/Bookmarks"] } + firefoxProfiles().map { $0 + "/places.sqlite" } +
            [orionHistory, safariHistory, safariBookmarks]
    }

    static func webSignature() -> String {
        let fm = FileManager.default
        return webFiles().flatMap { [$0, $0 + "-wal"] }.compactMap { p -> String? in
            guard let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return nil }
            return "\(p):\(Int(m.timeIntervalSince1970))"
        }.joined(separator: "\n")
    }

    // browser history and bookmarks, most-used first
    static func web() -> [Item]? {
        guard enabled("web") else { return [] }
        var found: [(String, String, Double)] = [] // url, title, last visit
        var readable = false
        let fm = FileManager.default

        for profile in firefoxProfiles() {
            let db = profile + "/places.sqlite"
            if let r = rows(db, """
            SELECT p.url, COALESCE(b.title, p.title), COALESCE(p.last_visit_date, 0) / 1000000
            FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk WHERE b.type = 1
            """) { readable = true; found += r.map { ($0[0], $0[1], Double($0[2]) ?? 0) } }
            if let r = rows(db, """
            SELECT url, title, COALESCE(last_visit_date, 0) / 1000000 FROM moz_places
            WHERE title IS NOT NULL AND title != '' AND hidden = 0 ORDER BY frecency DESC LIMIT 2500
            """) { readable = true; found += r.map { ($0[0], $0[1], Double($0[2]) ?? 0) } }
        }
        for dir in chromiumProfiles() {
            if let d = fm.contents(atPath: dir + "/Bookmarks"),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                readable = true
                func walk(_ node: Any?) {
                    guard let n = node as? [String: Any] else { return }
                    if let u = n["url"] as? String { found.append((u, n["name"] as? String ?? "", 0)) }
                    for c in n["children"] as? [Any] ?? [] { walk(c) }
                }
                for (_, root) in j["roots"] as? [String: Any] ?? [:] { walk(root) }
            }
            if let r = rows(dir + "/History", """
            SELECT url, title, last_visit_time / 1000000 - 11644473600 FROM urls
            WHERE title != '' ORDER BY visit_count DESC, last_visit_time DESC LIMIT 2000
            """) { readable = true; found += r.map { ($0[0], $0[1], Double($0[2]) ?? 0) } }
        }
        // Orion (WebKit) keeps a Safari-like history_items table; its schema is not documented, so a mismatch reads nothing
        if let r = rows(orionHistory, """
        SELECT url, title, 0 FROM history_items WHERE title IS NOT NULL AND title != '' ORDER BY visit_count DESC LIMIT 2000
        """) { readable = true; found += r.map { ($0[0], $0[1], Double($0[2]) ?? 0) } }
        // Safari needs Full Disk Access; silently absent without it
        if let r = rows(safariHistory, """
        SELECT i.url, v.title, MAX(v.visit_time) + 978307200 FROM history_items i JOIN history_visits v ON v.history_item = i.id
        WHERE v.title IS NOT NULL AND v.title != '' GROUP BY i.id ORDER BY i.visit_count DESC LIMIT 2000
        """) { readable = true; found += r.map { ($0[0], $0[1], Double($0[2]) ?? 0) } }
        if let d = fm.contents(atPath: safariBookmarks),
           let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
            readable = true
            found += safariBookmarkList(plist).map { ($0.0, $0.1, 0) }
        }

        guard readable else { return nil }
        var seenURL = Set<String>(), seenTitle = Set<String>()
        var out: [Item] = []
        for (url, title, t) in found {
            guard url.hasPrefix("http"), !title.isEmpty, url.count < 300, let u = URL(string: url), let host = u.host else { continue }
            // one row per page: the same title on the same site is the same page with different parameters
            guard seenURL.insert(url).inserted, seenTitle.insert(host + "|" + title).inserted else { continue }
            out.append(Item(key: url, name: title, kind: .web, mtime: (t / 86400).rounded(.down) * 86400,
                            body: "web page on \(host)\(u.path.count > 1 ? u.path : "")"))
            if out.count >= 4000 { break }
        }
        return out
    }

    static func safariBookmarkList(_ node: [String: Any]) -> [(String, String)] {
        if let u = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            return [(u, title)]
        }
        return (node["Children"] as? [[String: Any]] ?? []).flatMap(safariBookmarkList)
    }

    static let eventDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        return f
    }()

    static func events() -> [Item]? {
        guard enabled("calendar") else { return [] }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-45 * 86400), end: now.addingTimeInterval(180 * 86400), calendars: nil)
        return store.events(matching: pred).prefix(1500).compactMap { e in
            guard let title = e.title, !title.isEmpty, let start = e.startDate else { return nil }
            var body = "calendar event on \(eventDate.string(from: start))"
            if let l = e.location, !l.isEmpty { body += " at \(l)" }
            if let n = e.notes, !n.isEmpty { body += ". \(n.prefix(400))" }
            return Item(key: "event:\(e.eventIdentifier ?? title):\(Int(start.timeIntervalSince1970))", name: title, kind: .event,
                        mtime: start.timeIntervalSince1970, body: body)
        }
    }

    static func contacts() -> [Item]? {
        guard enabled("contacts") else { return [] }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
                    CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        var out: [Item] = []
        do { try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = c.organizationName }
            guard !name.isEmpty else { return }
            let emails = c.emailAddresses.map { $0.value as String }
            let phones = c.phoneNumbers.map(\.value.stringValue)
            let parts = [c.nickname, c.jobTitle, c.organizationName].filter { !$0.isEmpty && $0 != name } + emails + phones
            out.append(Item(key: "contact:" + c.identifier, name: name, kind: .contact, mtime: 0, body: "contact. " + parts.joined(separator: ", ")))
        } } catch { return nil }
        return out
    }

    // Apple Notes through one scripting call per property (three Apple events in total)
    static func notes() -> [Item]? {
        guard enabled("notes") else { return [] }
        // scripting Notes would launch it; only read while the user already has it open
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        running.arguments = ["-x", "Notes"]
        running.standardOutput = FileHandle.nullDevice
        guard (try? running.run()) != nil else { return nil }
        running.waitUntilExit()
        guard running.terminationStatus == 0 else { return nil }
        let js = """
        const N = Application("Notes"); const ids = N.notes.id(), names = N.notes.name(), body = N.notes.plaintext(), mod = N.notes.modificationDate();
        JSON.stringify(ids.slice(0, 1500).map((id, i) => ({id: id, name: names[i], body: (body[i] || "").slice(0, 2500), m: mod[i].getTime() / 1000})))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", js]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // a permission prompt nobody answers must not stall indexing forever
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { n in
            guard let id = n["id"] as? String, let name = n["name"] as? String else { return nil }
            return Item(key: "note:" + id, name: name, kind: .note, mtime: n["m"] as? Double ?? 0, body: n["body"] as? String ?? "")
        }
    }
}
