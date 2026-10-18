import Foundation

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
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let support: String = {
        let p = ProcessInfo.processInfo.environment["SEMBAR_DATA_DIR"] ?? home + "/Library/Application Support/SemBar"
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
    static let config = ProcessInfo.processInfo.environment["SEMBAR_CONFIG_PATH"] ?? home + "/.config/sembar/config.json"

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
let ioQueue = DispatchQueue(label: "sembar.io", qos: .utility)

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

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
