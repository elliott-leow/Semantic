import Foundation
import os

enum Kind: Int {
    case app = 0, image, audio, video, doc, other, folder
    // things that are not files; `path` holds a URL or an opaque key
    case web, clip, event, contact, note

    var label: String {
        switch self {
        case .app: return "Application"
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .doc: return "Document"
        case .other: return "File"
        case .folder: return "Folder"
        case .web: return "Web page"
        case .clip: return "Clipboard"
        case .event: return "Event"
        case .contact: return "Contact"
        case .note: return "Note"
        }
    }

    var isFile: Bool { rawValue <= Kind.folder.rawValue }
}

// which signal a vector was computed from; `page` rows carry a page number, media rows a time offset
enum Src: Int { case text = 0, media = 1, ocr = 2, page = 3 }
let SRC_COUNT = 4

let DIM = Int(SB_DIM)
// unit vectors at 512-d have components well under 0.45; 280 keeps them inside int8
let QSCALE: Float = 280

struct Config: Codable {
    var roots: [String]?       // folders to index; default: every visible folder in ~
    var maps: String?          // "browser" (default) or "apple"
    var searchURL: String?     // %s is replaced with the query
    var unloadAfter: Double?   // seconds hidden before the model is freed
    var clipboard: Bool?       // keep a searchable clipboard history (default true)
    var finderSelection: Bool? // attach the Finder selection when the bar opens over Finder (default true)
    var sources: [String]?     // any of: web, calendar, contacts, notes (default all)
    var assistant: String?     // "app" by default when installed; "web" explicitly uses the browser
    var hotkey: String?        // e.g. "cmd+y" (default), "alt+space", "cmd+shift+space"
    var excludes: [String]?    // folders (~ allowed) or glob patterns never indexed, e.g. "~/Private", "*.secret"
    var clipboardDays: Double? // clipboard rows older than this are dropped (default 30)
    var clipboardIgnoreApps: [String]? // bundle identifiers whose copies are never kept
    var reduceIndexingOnBattery: Bool? // defer image/audio/video work on battery or when hot (default true)
    var menuBar: Bool?         // show the menu bar item (default true)

    static let defaultIgnoreApps = ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop",
                                    "com.apple.keychainaccess", "com.apple.Passwords"]
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let support: String = {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["SEMANTIC_DATA_DIR"] {
            try? fm.createDirectory(atPath: p + "/models", withIntermediateDirectories: true)
            return p
        }
        let p = home + "/Library/Application Support/Semantic", old = home + "/Library/Application Support/SemBar"
        // the app was called SemBar; keep its index and downloaded models
        if !fm.fileExists(atPath: p), fm.fileExists(atPath: old) { try? fm.moveItem(atPath: old, toPath: p) }
        try? FileManager.default.createDirectory(atPath: p + "/models", withIntermediateDirectories: true)
        return p
    }()
    static let db = support + "/index.sqlite"
    static let lock = support + "/indexer.lock"
    static let model = support + "/models/embeddinggemma-2-Q4.gguf"
    static let mmproj = support + "/models/mmproj-Q8_0.gguf"
    static let llm = support + "/models/command-model.gguf"
    static let tmp: String = {
        let p = support + "/tmp"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }()
    static let config: String = {
        if let p = ProcessInfo.processInfo.environment["SEMANTIC_CONFIG_PATH"] { return p }
        let p = home + "/.config/semantic/config.json", old = home + "/.config/sembar/config.json"
        return !FileManager.default.fileExists(atPath: p) && FileManager.default.fileExists(atPath: old) ? old : p
    }()

    static func tilde(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

func loadConfig(_ path: String = Paths.config) -> Config {
    guard let d = FileManager.default.contents(atPath: path),
          let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
    return c
}

// a var so the settings window can change it; readers just see the new value next time
var config = loadConfig()
func reloadConfig() { config = loadConfig() }

// Writes keys into config.json without dropping keys this version does not know. nil removes a key.
@discardableResult
func updateConfig(_ changes: [String: Any?], path: String = Paths.config) -> Bool {
    var dict: [String: Any] = [:]
    if let d = FileManager.default.contents(atPath: path) {
        // a file that is not valid JSON is the user's to fix; never overwrite it
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { log("config.json is not valid JSON; not saving"); return false }
        dict = j
    }
    for (k, v) in changes { dict[k] = v }
    guard let out = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
    do {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { log("could not write config: \(error.localizedDescription)"); return false }
    if path == Paths.config { reloadConfig() }
    return true
}

// database writes that must never hold up typing
let ioQueue = DispatchQueue(label: "semantic.io", qos: .utility)

func quantize(_ v: [Float]) -> Data {
    var out = Data(count: v.count)
    out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
        let b = p.bindMemory(to: Int8.self)
        for i in 0..<v.count { b[i] = Int8(max(-127, min(127, (v[i] * QSCALE).rounded()))) }
    }
    return out
}

let stopwords: Set<String> = ["a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "my", "me", "and", "or",
                              "from", "that", "this", "is", "it", "open", "show", "find", "file", "about"]

func nameTokens(_ s: String) -> [String] {
    // ASCII (nearly every name): letters and digits are exactly A-Z, a-z, 0-9
    if s.utf8.allSatisfy({ $0 < 0x80 }) {
        var out: [String] = [], tok: [UInt8] = []
        for var c in s.utf8 {
            if c &- 65 < 26 { c |= 0x20 } else if !(c &- 97 < 26 || c &- 48 < 10) {
                if !tok.isEmpty { out.append(String(decoding: tok, as: UTF8.self)); tok.removeAll(keepingCapacity: true) }
                continue
            }
            tok.append(c)
        }
        if !tok.isEmpty { out.append(String(decoding: tok, as: UTF8.self)) }
        return out
    }
    return s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
}

// Patterns compiled once. NSRegularExpression is safe to share between threads.
enum Rx {
    private struct Key: Hashable { let pattern: String; let options: UInt }
    private static var cache: [Key: NSRegularExpression?] = [:]
    private static let lock = NSLock()

    static func get(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        lock.lock()
        defer { lock.unlock() }
        if let re = cache[key] { return re }
        let re = try? NSRegularExpression(pattern: pattern, options: options)
        if cache.count >= 1024 { cache.removeAll() }
        cache[key] = re
        return re
    }

    // what `replacingOccurrences(of:with:options: .regularExpression)` does, same template syntax
    static func replace(_ s: String, _ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> String {
        guard let re = get(pattern, options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func first(_ s: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        get(pattern, options)?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
}

let logger = Logger(subsystem: "local.semantic", category: "app")

// visible in Console.app (subsystem local.semantic); also echoed to stderr for the command-line tools
func log(_ s: String) {
    logger.log("\(s, privacy: .public)")
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
