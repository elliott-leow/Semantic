import AppKit
import Contacts
import EventKit
import SQLite3

// Icons for rows that are not files: contact photos, site favicons from the browsers' own local caches,
// calendar-coloured dots, and the app that handles an action. Nothing here touches the network.
enum RowIcons {
    private static var cache: [String: NSImage] = [:]   // main thread only
    private static var missing = Set<String>()
    private static var loading = Set<String>()
    private static let queue = DispatchQueue(label: "semantic.rowicons", qos: .utility)

    // the app that obviously handles an action row
    private static let apps: [String: String] = [
        "Email": "com.apple.mail", "Reminder": "com.apple.reminders", "ChatGPT": "com.openai.chat",
        "Settings": "com.apple.systempreferences", "Dictionary": "com.apple.Dictionary",
    ]

    // An image to show now (cached or cheap); nil keeps the row's own icon. `loaded` runs on the main thread
    // once a slower lookup finishes, so the row can be redrawn.
    static func image(for hit: Hit, loaded: @escaping () -> Void) -> NSImage? {
        if hit.path != nil { return nil }
        let key = hit.key ?? ""
        if key.hasPrefix("contact:") { return lazy("c|" + key, loaded) { contactPhoto(String(key.dropFirst(8))) } }
        if key.hasPrefix("event:") {
            return cache["e|" + key] ?? lazy("e|" + key, loaded) { eventColor(key).map(dot) } ?? dot(.controlAccentColor)
        }
        if hit.tag == "Web page", let host = URL(string: key)?.host { return lazy("f|" + host, loaded) { favicon(host) } }
        if hit.tag == "Event", key == "intent:event" { return appIcon("com.apple.iCal") }
        if hit.tag == "Web" || hit.tag == "URL" {
            guard let u = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
            return fileIcon(u.path)
        }
        if let id = apps[hit.tag] { return appIcon(id) }
        return nil
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        if missing.contains(bundleID) { return nil }
        guard let u = Sys.app(bundleID) else { missing.insert(bundleID); return nil }
        return fileIcon(u.path)
    }

    private static func fileIcon(_ path: String) -> NSImage {
        if let i = cache["a|" + path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache["a|" + path] = i
        return i
    }

    private static func lazy(_ k: String, _ loaded: @escaping () -> Void, _ make: @escaping () -> NSImage?) -> NSImage? {
        if let i = cache[k] { return i }
        if missing.contains(k) || loading.contains(k) { return nil }
        loading.insert(k)
        queue.async {
            let img = make()
            DispatchQueue.main.async {
                loading.remove(k)
                if let img { cache[k] = img; loaded() } else { missing.insert(k) }
            }
        }
        return nil
    }

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 10, height: 10)).fill()
            return true
        }
    }

    private static func round(_ img: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 44, height: 44), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            img.draw(in: r)
            return true
        }
    }

    // MARK: lookups, off the main thread

    private static func contactPhoto(_ id: String) -> NSImage? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        guard let c = try? CNContactStore().unifiedContact(withIdentifier: id, keysToFetch: keys),
              let data = c.thumbnailImageData, let img = NSImage(data: data) else { return nil }
        return round(img)
    }

    private static var events: EKEventStore?
    private static func eventColor(_ key: String) -> NSColor? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        // event:<identifier>:<start>; identifiers contain colons themselves
        var id = String(key.dropFirst(6))
        if let c = id.lastIndex(of: ":") { id = String(id[..<c]) }
        if events == nil { events = EKEventStore() }
        return events?.event(withIdentifier: id)?.calendar?.color
    }

    // Chromium browsers keep favicons in a SQLite file; a private copy is read so the live one is never locked.
    private static var copies: [String]?
    private static func favicon(_ host: String) -> NSImage? {
        if copies == nil {
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
            let dbs = ["Google/Chrome/Default/Favicons", "BraveSoftware/Brave-Browser/Default/Favicons",
                       "Arc/User Data/Default/Favicons", "Microsoft Edge/Default/Favicons"]
            copies = dbs.enumerated().compactMap { i, rel in
                let src = base + "/" + rel, dst = Paths.tmp + "/favicons-\(i).db"
                guard FileManager.default.fileExists(atPath: src) else { return nil }
                try? FileManager.default.removeItem(atPath: dst)
                return (try? FileManager.default.copyItem(atPath: src, toPath: dst)) != nil ? dst : nil
            }
        }
        let hosts = host.hasPrefix("www.") ? [host, String(host.dropFirst(4))] : [host, "www." + host]
        for db in copies ?? [] {
            for h in hosts { for scheme in ["https", "http"] { if let img = favicon(db, prefix: "\(scheme)://\(h)/") { return img } } }
        }
        return nil
    }

    private static func favicon(_ db: String, prefix: String) -> NSImage? {
        var h: OpaquePointer?
        guard sqlite3_open_v2(db, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(h); return nil }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        // a range on page_url uses its index: "/" + 1 is "0"
        let sql = "SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id=m.icon_id WHERE m.page_url >= ? AND m.page_url < ? ORDER BY b.width DESC LIMIT 1"
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, prefix, -1, T)
        sqlite3_bind_text(st, 2, String(prefix.dropLast()) + "0", -1, T)
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { return nil }
        let data = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
        return NSImage(data: data)
    }
}
