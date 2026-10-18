import Foundation

// A small local language model whose only job is to turn a sentence into one flat JSON command.
// Loaded on first use, freed again after a minute and a half of not being needed.
final class LLM {
    static let shared = LLM()

    private let queue = DispatchQueue(label: "semantic.llm", qos: .userInitiated)
    private var ctx: OpaquePointer?
    private var unload: DispatchWorkItem?

    static var path: String { ProcessInfo.processInfo.environment["SEMANTIC_LLM"] ?? Paths.llm }
    static var available: Bool { FileManager.default.fileExists(atPath: path) }

    // {"action": "...", "key": "string" | number, ...}
    static let grammar = """
    root ::= "{" ws "\\"action\\"" ws ":" ws string ( ws "," ws string ws ":" ws value )* ws "}"
    value ::= string | number
    string ::= "\\"" ( [^"\\\\\\n] | "\\\\" ["\\\\/bfnrt] )* "\\""
    number ::= "-"? [0-9]+ ( "." [0-9]+ )?
    ws ::= " "?
    """

    static let system = """
    Convert the request into one JSON command. Reply with JSON only.
    Actions and their fields:
    - reminder: title, when
    - event: title, when, location
    - email: to, subject, body, attach
    - convert: format (jpg, png, heic, tiff, gif, pdf, txt, m4a, wav, mp4, zip)
    - resize: width, height, percent
    - rotate: degrees (right is 90, left is -90)
    - rename: name
    - move: folder
    - copy: folder
    - ocr (read the text in a file)
    - trash
    - ask: file, question (a question about one of the user's own files)
    - none (anything else)
    When no file is attached and the request names one of the user's files, add file: the words that name it.
    Copy words from the request exactly. Leave out fields the request does not mention.
    """

    static let shots: [(String, String)] = [
        ("Request: remind me to call mum at 5", #"{"action":"reminder","title":"Call mum","when":"at 5"}"#),
        ("Request: lunch with sam friday 1pm at nobu", #"{"action":"event","title":"Lunch with Sam","when":"friday 1pm","location":"Nobu"}"#),
        ("Request: email the syllabus to dan and tell him i'll be late",
         #"{"action":"email","to":"Dan","subject":"Syllabus","body":"I'll be late.","attach":"the syllabus"}"#),
        ("File: IMG_2041.png\nRequest: make this a jpeg", #"{"action":"convert","format":"jpg"}"#),
        ("File: scan.pdf\nRequest: turn into pngs", #"{"action":"convert","format":"png"}"#),
        ("File: photo.heic\nRequest: shrink it to 800 pixels wide", #"{"action":"resize","width":800}"#),
        ("File: chart.png\nRequest: make it a quarter of the size", #"{"action":"resize","percent":25}"#),
        ("File: notes.txt\nRequest: call this meeting notes october", #"{"action":"rename","name":"meeting notes october"}"#),
        ("File: report.pdf\nRequest: put it in my documents", #"{"action":"move","folder":"documents"}"#),
        ("File: IMG_1.jpg\nRequest: turn it sideways to the left", #"{"action":"rotate","degrees":-90}"#),
        ("Request: dentist appointment next tuesday at 9am", #"{"action":"event","title":"Dentist appointment","when":"next tuesday at 9am"}"#),
        ("Request: what does my most recent screenshot say", #"{"action":"ask","file":"most recent screenshot","question":"What does it say?"}"#),
        ("Request: summarize the organic chemistry lab manual", #"{"action":"ask","file":"organic chemistry lab manual","question":"Summarize it."}"#),
        ("Request: turn the budget spreadsheet into a pdf", #"{"action":"convert","file":"budget spreadsheet","format":"pdf"}"#),
        ("Request: why is the sky blue", #"{"action":"none"}"#),
        ("Request: seafood restaurants near me", #"{"action":"none"}"#),
    ]

    // everything before the request; decoded once per model load and kept
    static let prefix: String = {
        var p = "<|im_start|>system\n\(system)<|im_end|>\n"
        for (u, a) in shots { p += "<|im_start|>user\n\(u)<|im_end|>\n<|im_start|>assistant\n\(a)<|im_end|>\n" }
        return p + "<|im_start|>user\n"
    }()

    static func prompt(_ user: String) -> String {
        prefix + "\(user)<|im_end|>\n<|im_start|>assistant\n"
    }

    func commandSync(_ request: String, file: String?) -> [String: Any]? {
        queue.sync { self.run(request, file: file) }
    }

    func command(_ request: String, file: String?, done: @escaping ([String: Any]?) -> Void) {
        queue.async {
            let r = self.run(request, file: file)
            DispatchQueue.main.async { done(r) }
        }
    }

    // Loads the model and decodes the fixed prompt in the background, so the first command is quick.
    // Call it when the typed text starts to look like a command.
    func preload() {
        guard Self.available else { return }
        queue.async { _ = self.load() }
    }

    private func load() -> OpaquePointer? {
        unload?.cancel()
        if ctx == nil, let c = sb_llm_init(Self.path, 2048) {
            ctx = c
            if sb_llm_cache_prefix(c, Self.prefix) < 0 { log("command model: prompt prefix not cached") }
        }
        let w = DispatchWorkItem { [weak self] in
            guard let self, let c = self.ctx else { return }
            sb_llm_free(c)
            self.ctx = nil
        }
        unload = w
        queue.asyncAfter(deadline: .now() + 90, execute: w)
        return ctx
    }

    private func run(_ request: String, file: String?) -> [String: Any]? {
        guard let ctx = load() else { return nil }

        let user = (file.map { "File: \(($0 as NSString).lastPathComponent)\n" } ?? "") + "Request: \(request)"
        // a request identical to one of the examples confuses a small model; the answer is already known
        if let known = Self.shots.first(where: { $0.0.lowercased() == user.lowercased() }),
           let d = known.1.data(using: .utf8) { return try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
        var buf = [CChar](repeating: 0, count: 2048)
        guard sb_llm_generate(ctx, Self.prompt(user), Self.grammar, 120, &buf, Int32(buf.count)) > 0,
              let data = String(cString: buf).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func free() {
        queue.sync {
            if let c = ctx { sb_llm_free(c); ctx = nil }
        }
    }
}
