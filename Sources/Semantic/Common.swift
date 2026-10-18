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

let config: Config = {
    guard let d = FileManager.default.contents(atPath: Paths.config),
          let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
    return c
}()

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
    s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
}

let logger = Logger(subsystem: "local.semantic", category: "app")

// visible in Console.app (subsystem local.semantic); also echoed to stderr for the command-line tools
func log(_ s: String) {
    logger.log("\(s, privacy: .public)")
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
