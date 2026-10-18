import AppKit
import Foundation

// Works out which thing a sentence is about: "what does my most recent screenshot say",
// "convert the last download to pdf", "explain what's on my screen", "fix the grammar of my clipboard".
// Whatever is left of the sentence is then handled exactly as if that file had been dragged into the bar.
enum Resolver {
    struct Ref {
        var files: [String] = []
        var command = ""        // the sentence without the reference: "convert to jpg", "what does say"
        var question = ""       // the sentence with the reference made generic: "what does this screenshot say"
        var label = ""          // shown under the bar, so the user sees what was picked
        var clipText: String?   // the reference was the clipboard, and it holds text
        var capture = false     // the reference was the screen: take a screenshot when run
        var listing = false     // several were asked for ("latest screenshots")
        var alternates: [String] = [] // runners-up when the file was named by description
    }

    static let nouns = "screenshots?|screen ?shots?|screen captures?|screen ?grabs?|photos?|images?|pictures?|pics?|pdfs?|downloads?|documents?|docs?|files?|recordings?|videos?|slides|presentations?|spreadsheets?"
    static let numbers = ["two": 2, "three": 3, "four": 4, "five": 5, "couple": 2, "few": 3]

    static func singular(_ noun: String) -> String {
        let n = noun.replacingOccurrences(of: " ", with: "")
        if n.hasPrefix("screen") { return "screenshot" }
        if n.hasPrefix("pic") || n.hasPrefix("photo") || n.hasPrefix("image") { return "image" }
        if n.hasPrefix("doc") { return "document" }
        return n.hasSuffix("s") && n != "slides" ? String(n.dropLast()) : n
    }

    static let screenshotDirs: [String] = {
        var dirs: [String] = []
        if let d = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") { dirs.append((d as NSString).expandingTildeInPath) }
        dirs += [Paths.home + "/Screenshots", Paths.home + "/Pictures/Screenshots", Paths.home + "/Desktop"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
    }()

    // newest first, straight from disk: a screenshot taken seconds ago is not in the index yet
    static func referenceTime(modified: Date?, added: Date?, preferArrival: Bool) -> Double {
        if preferArrival { return (added ?? modified)?.timeIntervalSince1970 ?? 0 }
        return max(modified?.timeIntervalSince1970 ?? 0, added?.timeIntervalSince1970 ?? 0)
    }

    static func scan(_ dir: String, preferArrival: Bool = false) -> [(String, Double)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            let e = u.pathExtension.lowercased()
            if ["download", "crdownload", "part", "tmp"].contains(e) { return nil }
            // a file downloaded today can carry an old modification date; when it arrived is what "latest" means
            let t = referenceTime(modified: v.contentModificationDate, added: v.addedToDirectoryDate, preferArrival: preferArrival)
            return (u.path, t)
        }
    }

    static func newest(_ noun: String, count: Int, folder: String?) -> [String] {
        let n = singular(noun)
        var found: [(String, Double)] = []
        let folderPath = folder.flatMap { FileOps.folder(named: $0) }
        switch n {
        case "screenshot":
            for d in folderPath.map({ [$0] }) ?? screenshotDirs {
                let requireName = d.hasSuffix("/Desktop") || (folderPath != nil && !d.lowercased().contains("screenshot"))
                found += scan(d).filter { Extract.imageExts.contains(($0.0 as NSString).pathExtension.lowercased()) }
                    .filter { !requireName || ($0.0 as NSString).lastPathComponent.lowercased().hasPrefix("screen") }
            }
        case "download":
            found = scan(folderPath ?? Paths.home + "/Downloads", preferArrival: true)
        default:
            let kinds: Set<Kind>? = ["image": [.image], "pdf": [.doc], "document": [.doc], "recording": [.audio], "video": [.video],
                                     "slides": [.doc], "presentation": [.doc], "spreadsheet": [.doc]][n]
            let exts: Set<String>? = ["pdf": ["pdf"], "slides": ["pptx", "ppt", "key"], "presentation": ["pptx", "ppt", "key"],
                                      "spreadsheet": ["xlsx", "xls", "csv", "numbers"]][n]
            func fits(_ p: String) -> Bool {
                let e = (p as NSString).pathExtension.lowercased()
                if let exts { return exts.contains(e) }
                if let kinds { return kinds.contains(Extract.kind(ext: e)) }
                return true
            }
            if let folderPath { found = scan(folderPath).filter { fits($0.0) } } else {
                found = Engine.shared.newestIndexed(kinds: kinds, exts: exts, count: count + 5)
                // the usual landing places, read live so the index's lag does not matter
                for d in [Paths.home + "/Downloads", Paths.home + "/Desktop", Paths.home + "/Documents"] { found += scan(d).filter { fits($0.0) } }
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.1 > $1.1 }.filter { seen.insert($0.0).inserted }.prefix(count).map(\.0)
    }

    static func age(_ path: String) -> String {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }

    private static func cut(_ text: String, _ range: NSRange, replacement: String) -> (String, String) {
        let ns = text as NSString
        func tidy(_ s: String) -> String { s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        return (tidy(ns.replacingCharacters(in: range, with: " ")), tidy(ns.replacingCharacters(in: range, with: " " + replacement + " ")))
    }

    private static func find(_ text: String, _ pattern: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ text: String) -> String {
        Range(m.range(at: i), in: text).map { String(text[$0]).lowercased() } ?? ""
    }

    static func extract(_ text: String) -> Ref? {
        // what is on the screen right now
        if let m = find(text, "(?:what(?:'s| is|s) )?(?:on |in )?\\b(?:my|the|this) (?:screen|display)\\b|\\bwhat (?:am i|i'm|im|i am) looking at\\b|\\b(?:this|the current) (?:window|page|error|dialog)\\b") {
            var r = Ref(capture: true)
            r.command = cut(text, m.range, replacement: "").0
            r.question = r.command.split(separator: " ").count < 1 ? "What is on my screen? Explain it." : text
            r.label = "Uses a screenshot of your screen, taken when you press Return"
            return r
        }

        // the clipboard: an image on it is a file, text on it is quoted into the question
        if let m = find(text, "\\b(?:what(?:'s| is) (?:in|on) )?(?:my |the )?clipboard\\b|\\bwhat i(?: just|'ve)? copied\\b|\\b(?:the|my) copied (?:text|image)\\b") {
            var r = Ref()
            (r.command, r.question) = cut(text, m.range, replacement: "the following")
            let images = BarController.files(from: .general, imageEvenWithText: false)
            if !images.isEmpty {
                r.files = images
                r.label = "Using the \(images.count == 1 ? "file" : "files") on your clipboard"
                return r
            }
            guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            r.clipText = s
            r.label = "Using your clipboard: “\(s.prefix(60).replacingOccurrences(of: "\n", with: " "))\(s.count > 60 ? "…" : "")”"
            return r
        }

        // the newest of something: "most recent screenshot", "last 3 downloads", "latest pdf in downloads",
        // "the screenshot i just took", "my screenshot"
        let lead = "(?:(?:of|in|from|on|at|about|with) )?(?:my |the |that |this |those |these )?"
        let folder = "(?:\\s+(?:in|from)\\s+(?:my |the )?(downloads|documents|desktop|pictures|movies|music)(?:\\s+folder)?)?"
        var noun = "", count = 1, where_: String?, range: NSRange?, plural = false
        if let m = find(text, "\\b\(lead)(?:most recent|most-recent|latest|newest|last|recent|previous)\\s+(?:(\\d+|two|three|four|five|couple|few)\\s+)?(?:[a-z]+\\s+)?(\(nouns))\\b\(folder)") {
            let num = group(m, 1, text)
            noun = group(m, 2, text)
            plural = noun.hasSuffix("s") && noun != "slides"
            count = Int(num) ?? numbers[num] ?? (plural ? 5 : 1)
            where_ = group(m, 3, text).isEmpty ? nil : group(m, 3, text)
            range = m.range
        } else if let m = find(text, "\\b\(lead)(\(nouns))\\s+(?:that )?(?:i|i've|ive) (?:just |have just )?(?:took|taken|made|saved|downloaded|got|grabbed|captured)(?: just now| earlier| a (?:second|minute|moment) ago)?") {
            (noun, range) = (group(m, 1, text), m.range)
        } else if let m = find(text, "\\b(?:(?:of|in|from|on|at|about|with) )?(?:my|this|that)\\s+(screenshots?|screen ?shots?|downloads?)\\b(?! folder)") {
            (noun, range) = (group(m, 1, text), m.range)
        }
        if range == nil, let m = find(text, "^(?:please )?(?:convert|turn|change|export|save|make|rename|move|copy|zip|compress|resize|rotate|trash|delete|print|summari[sz]e|explain|translate|proofread|review|critique|grade|read|email|send|mail|open|show)\\s+((?:my|the)\\s+(.+?))(?=\\s+(?:into|to|as|in|by|and|for|so)\\b|$)") {
            // a thing named by description: only when one file clearly answers to it
            let phrase = group(m, 2, text)
            let found = phrase.split(separator: " ").count <= 8 ? Engine.shared.bestFiles(phrase, strong: true, count: 4) : []
            guard let f = found.first else { return nil }
            var r = Ref(files: [f], alternates: Array(found.dropFirst()))
            (r.command, r.question) = cut(text, m.range(at: 1), replacement: "this file")
            r.label = "Using \((f as NSString).lastPathComponent) · \(age(f))" + (found.count > 1 ? " · ⇥ on another file to use that instead" : "")
            return r
        }
        guard let range, !noun.isEmpty else { return nil }
        let files = newest(noun, count: min(max(count, 1), 12), folder: where_)
        guard !files.isEmpty else { return nil }
        var r = Ref(files: files, listing: files.count > 1)
        let one = singular(noun)
        (r.command, r.question) = cut(text, range, replacement: files.count > 1 ? "these \(one)s" : "this \(one)")
        let name = (files[0] as NSString).lastPathComponent
        r.label = files.count > 1 ? "Using your \(files.count) newest \(one)s" : "Using your newest \(one): \(name) · \(age(files[0]))"
        return r
    }

    // a phrase the language model pulled out ("organic chemistry lab manual", "most recent screenshot") -> file
    static func resolve(_ phrase: String) -> [String] {
        if let r = extract(phrase), !r.files.isEmpty { return r.files }
        if let r = extract("my " + phrase), !r.files.isEmpty { return r.files }
        return Engine.shared.bestFile(phrase, strong: true).map { [$0] } ?? []
    }

    static let fileWords = try! NSRegularExpression(pattern: "\\b(screenshots?|photos?|images?|pictures?|pdfs?|files?|docs?|documents?|downloads?|recordings?|videos?|slides|papers?|essays?|reports?|resume|cv|syllabus|notes|spreadsheets?|presentations?|homework|assignment|manual|handout|lecture|transcript|invoice|receipt)\\b", options: [.caseInsensitive])

    static func mentionsAFile(_ text: String) -> Bool {
        fileWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
