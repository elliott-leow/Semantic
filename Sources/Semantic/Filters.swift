import Foundation

// Constraints pulled out of a query: "pdfs from last week in downloads larger than 2 mb".
struct Filters {
    var exts: Set<String>?
    var kinds: Set<Kind>?        // hard only when nothing else is left to search for
    var softKinds: Set<Kind> = []
    var after: Double?
    var before: Double?
    var pathPrefix: String?
    var folder: String?
    var minSize: Int?
    var maxSize: Int?
    var notes: [String] = []     // shown under the bar so the user sees what was understood

    var isEmpty: Bool { pathPrefix == nil && exts == nil && kinds == nil && after == nil && before == nil && folder == nil && minSize == nil && maxSize == nil }

    func matches(_ e: Entry) -> Bool {
        if let exts, !exts.contains(e.ext) { return false }
        if let kinds, !kinds.contains(e.kind) { return false }
        if let after, e.mtime < after { return false }
        if let before, e.mtime >= before { return false }
        if let pathPrefix {
            let path = e.path.lowercased()
            let expanded = (pathPrefix as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                let prefix = URL(fileURLWithPath: expanded).standardizedFileURL.path.lowercased()
                if !path.hasPrefix(prefix == "/" ? "/" : prefix + "/") { return false }
            } else {
                let prefix = expanded.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !path.contains("/" + prefix + "/") { return false }
            }
        }
        if let folder, e.path.range(of: "/" + folder + "/", options: .caseInsensitive) == nil { return false }
        if let minSize, e.size < minSize { return false }
        if let maxSize, e.size > maxSize || e.size == 0 { return false }
        return true
    }

    static let extWords: [String: [String]] = [
        "pdf": ["pdf"], "pdfs": ["pdf"], "png": ["png"], "pngs": ["png"], "jpg": ["jpg", "jpeg"], "jpgs": ["jpg", "jpeg"], "jpeg": ["jpg", "jpeg"],
        "heic": ["heic"], "gif": ["gif"], "gifs": ["gif"], "docx": ["docx", "doc"], "pptx": ["pptx", "ppt"], "xlsx": ["xlsx", "xls"],
        "csv": ["csv"], "csvs": ["csv"], "markdown": ["md"], "txt": ["txt"], "mp3": ["mp3"], "mp3s": ["mp3"], "wav": ["wav"], "wavs": ["wav"],
        "mp4": ["mp4"], "mp4s": ["mp4"], "mov": ["mov"], "zip": ["zip"], "zips": ["zip"], "svg": ["svg"], "svgs": ["svg"],
        "powerpoint": ["pptx", "ppt", "key"], "powerpoints": ["pptx", "ppt", "key"], "spreadsheet": ["xlsx", "xls", "csv", "numbers"],
        "spreadsheets": ["xlsx", "xls", "csv", "numbers"], "word doc": ["docx", "doc"], "word docs": ["docx", "doc"],
        "word document": ["docx", "doc"], "word documents": ["docx", "doc"],
    ]
    static let kindWords: [String: Kind] = [
        "image": .image, "images": .image, "picture": .image, "pictures": .image, "photo": .image, "photos": .image, "pics": .image,
        "screenshot": .image, "screenshots": .image, "video": .video, "videos": .video, "movie": .video, "movies": .video,
        "audio": .audio, "recording": .audio, "recordings": .audio, "song": .audio, "songs": .audio, "sound": .audio, "sounds": .audio,
        "folder": .folder, "folders": .folder, "document": .doc, "documents": .doc, "docs": .doc, "app": .app, "apps": .app,
        "application": .app, "applications": .app, "bookmark": .web, "bookmarks": .web, "website": .web, "websites": .web, "webpage": .web,
        "link": .web, "links": .web, "note": .note, "notes": .note, "contact": .contact, "contacts": .contact,
        "event": .event, "events": .event, "meeting": .event, "meetings": .event, "clipboard": .clip, "copied": .clip, "files": .other,
    ]
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    // returns the filters and what is left of the query to search for
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current, folderExists: (String) -> Bool) -> (Filters, String) {
        var f = Filters()
        var q = " " + text.lowercased() + " "
        let cal = calendar
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Double { (cal.date(byAdding: .day, value: offset, to: today) ?? today).timeIntervalSince1970 }

        func take(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
                  let r = Range(m.range, in: q) else { return nil }
            let groups = (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: q).map { String(q[$0]) } ?? "" }
            q.replaceSubrange(r, with: " ")
            return groups
        }
        func bytes(_ n: String, _ unit: String) -> Int {
            let value = (Double(n) ?? .infinity) * (["kb": 1e3, "mb": 1e6, "gb": 1e9][unit] ?? 1)
            return value.isFinite && value < Double(Int.max) ? Int(max(0, value)) : Int.max
        }

        if let m = take("\\s(?:larger|bigger|greater|more|over|above)\\s+(?:than\\s+)?(\\d+(?:\\.\\d+)?)\\s*(kb|mb|gb)\\b") {
            f.minSize = bytes(m[1], m[2]); f.notes.append("over \(m[1]) \(m[2].uppercased())")
        }
        if let m = take("\\s(?:smaller|less|under|below)\\s+(?:than\\s+)?(\\d+(?:\\.\\d+)?)\\s*(kb|mb|gb)\\b") {
            f.maxSize = bytes(m[1], m[2]); f.notes.append("under \(m[1]) \(m[2].uppercased())")
        }

        func start(of c: Calendar.Component, offset: Int) -> Date {
            let base = cal.dateInterval(of: c, for: now)?.start ?? today
            return cal.date(byAdding: c, value: offset, to: base) ?? base
        }
        if let m = take("\\s(?:from |in |since |during |over |within )?(?:the )?(?:last|past)\\s+(\\d+)\\s*(day|week|month|year)s?\\b") {
            let c: Calendar.Component = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year][m[2]]!
            f.after = cal.date(byAdding: c, value: -(Int(m[1]) ?? 1), to: today)?.timeIntervalSince1970
            f.notes.append("last \(m[1]) \(m[2])s")
        } else if let m = take("\\s(?:from |in |since |during )?(today|tonight|tomorrow|yesterday|this week|next week|last week|this month|next month|last month|this year|last year|recently|recent)\\b") {
            switch m[1] {
            case "today", "tonight": (f.after, f.before) = (day(0), day(1))
            case "tomorrow": (f.after, f.before) = (day(1), day(2))
            case "next week": (f.after, f.before) = (start(of: .weekOfYear, offset: 1).timeIntervalSince1970, start(of: .weekOfYear, offset: 2).timeIntervalSince1970)
            case "next month": (f.after, f.before) = (start(of: .month, offset: 1).timeIntervalSince1970, start(of: .month, offset: 2).timeIntervalSince1970)
            case "yesterday": (f.after, f.before) = (day(-1), day(0))
            case "this week": f.after = start(of: .weekOfYear, offset: 0).timeIntervalSince1970
            case "last week": (f.after, f.before) = (start(of: .weekOfYear, offset: -1).timeIntervalSince1970, start(of: .weekOfYear, offset: 0).timeIntervalSince1970)
            case "this month": f.after = start(of: .month, offset: 0).timeIntervalSince1970
            case "last month": (f.after, f.before) = (start(of: .month, offset: -1).timeIntervalSince1970, start(of: .month, offset: 0).timeIntervalSince1970)
            case "this year": f.after = start(of: .year, offset: 0).timeIntervalSince1970
            case "last year": (f.after, f.before) = (start(of: .year, offset: -1).timeIntervalSince1970, start(of: .year, offset: 0).timeIntervalSince1970)
            default: f.after = day(-14)
            }
            f.notes.append(m[1])
        } else if let m = take("\\s(?:from|in|since|during)\\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*(?:\\s+(20\\d\\d))?\\b"),
                  let mi = months.firstIndex(of: m[1]) {
            var year = Int(m[2]) ?? cal.component(.year, from: now)
            if m[2].isEmpty, mi + 1 > cal.component(.month, from: now) { year -= 1 } // "in november" said in october means last november
            if let s = cal.date(from: DateComponents(year: year, month: mi + 1, day: 1)), let e = cal.date(byAdding: .month, value: 1, to: s) {
                (f.after, f.before) = (s.timeIntervalSince1970, e.timeIntervalSince1970)
                f.notes.append("\(m[1].capitalized) \(year)")
            }
        } else if let m = take("\\s(?:from|in|during)\\s+(20\\d\\d)\\b"), let y = Int(m[1]),
                  let s = cal.date(from: DateComponents(year: y, month: 1, day: 1)), let e = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) {
            (f.after, f.before) = (s.timeIntervalSince1970, e.timeIntervalSince1970)
            f.notes.append(m[1])
        }

        // "in downloads", "from the homework folder": only when such a folder exists
        if let re = try? NSRegularExpression(pattern: "\\s(?:in|from|inside|under)\\s+(?:my\\s+|the\\s+)?([a-z0-9][a-z0-9 _.-]*?)(?:\\s+folder)?\\s*$"),
           let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), let r = Range(m.range, in: q), let g = Range(m.range(at: 1), in: q) {
            let name = String(q[g]).trimmingCharacters(in: .whitespaces)
            if folderExists(name) {
                f.folder = name
                f.notes.append("in \(name)")
                q.replaceSubrange(r, with: " ")
            }
        }

        // file types named outright are hard filters
        for (word, exts) in extWords.sorted(by: { $0.key.count > $1.key.count }) {
            if take("(?<! to)(?<! into)(?<! as)(?<! to a)(?<! into a)(?<! as a)\\s\(word)(?:\\s+files?)?\\s") != nil {
                f.exts = (f.exts ?? []).union(exts)
                f.notes.append(exts[0].uppercased())
                q = " " + q + " "
            }
        }

        var rest = q.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // kind words only nudge ranking ("lecture notes" must still find PDFs), unless they are all that is left
        let words = rest.split(separator: " ").map(String.init)
        let kindHits = words.compactMap { kindWords[$0] }
        let filler: Set<String> = ["my", "the", "all", "any", "some", "show", "find", "list", "of", "from", "me", "files", "file", "recent", "latest", "newest"]
        if !kindHits.isEmpty, words.allSatisfy({ kindWords[$0] != nil || filler.contains($0) }) {
            let ks = Set(kindHits.filter { $0 != .other })
            if ks.isEmpty, words.contains("files") || words.contains("file") {
                f.kinds = [.image, .audio, .video, .doc, .other]; f.notes.append("files")
            }
            if !ks.isEmpty { f.kinds = ks; f.notes.append(ks.map(\.label).sorted().joined(separator: "/").lowercased() + "s") }
            if !f.isEmpty { rest = "" }
        } else {
            f.softKinds = Set(kindHits.filter { $0 != .other })
            if !f.isEmpty, words.allSatisfy({ filler.contains($0) }) { rest = "" }
        }
        return (f, rest)
    }
}
