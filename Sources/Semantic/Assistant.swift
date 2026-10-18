import AppKit
import ApplicationServices

// Where Ask goes. ChatGPT gets the automated handoff; the others get the local draft window.
enum Dest: String, CaseIterable {
    case chatgpt, claude, gemini

    var name: String { ["chatgpt": "ChatGPT", "claude": "Claude", "gemini": "Gemini"][rawValue]! }
    var appIDs: [String] {
        switch self {
        case .chatgpt: return ["com.openai.chat", "com.openai.codex"]
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .gemini: return []
        }
    }
    var web: String {
        switch self {
        case .chatgpt: return "https://chatgpt.com/"
        case .claude: return "https://claude.ai/new"
        case .gemini: return "https://gemini.google.com/app"
        }
    }
    var site: String { URL(string: web)?.host ?? web }
    var appURL: URL? { appIDs.lazy.compactMap { Sys.app($0) }.first }

    // `"assistant"`: "chatgpt" (and the older "app"), "web" (ChatGPT's website), "claude", "gemini"
    static var configured: Dest { Dest(rawValue: config.assistant ?? "") ?? .chatgpt }

    // "ask claude …" goes to Claude whatever the setting
    static func named(in text: String) -> Dest? {
        let t = text.lowercased()
        if Calc.rx(t, "^(ask )?(chat ?gpt|gpt)\\b.*") != nil { return .chatgpt }
        if Calc.rx(t, "^(ask )?claude\\b.*") != nil { return .claude }
        if Calc.rx(t, "^(ask )?gemini\\b.*") != nil { return .gemini }
        return nil
    }
}

// Prepares a new draft with actual files. The user sends the message.
enum Assistant {
    static var appIDs: [String] { Dest.configured.appIDs }
    static var dest: Dest { Dest.configured }
    static var name: String { dest.name }
    static var tags: Set<String> { Set(Dest.allCases.map(\.name)) }
    // Ask rows are tagged with the destination name; Search.swift can use this instead of comparing to "ChatGPT"
    static func isAsk(_ h: Hit) -> Bool { tags.contains(h.tag) }

    static var appURL: URL? { dest.appURL }
    static var prefersApp: Bool { config.assistant != "web" && appURL != nil }

    static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("?") { return true }
        return Calc.rx(t, "^(answer|solve|explain|what|what's|whats|why|how|who|when|where|which|is|are|can|could|does|do|describe|summari[sz]e|translate|tell me|help|ask|chatgpt|gpt|check|grade|critique|review|identify|prove|simplify|derive|write|draft|compare|is this|what does)\\b.*") != nil
    }

    // a request to produce or reason about something, as opposed to a lookup a search engine answers
    static func isComplex(_ text: String) -> Bool {
        let t = text.lowercased()
        let words = t.split(separator: " ").count
        if words >= 3, Calc.rx(t, "^(explain|write|prove|compare|summari[sz]e|solve|help me|draft|brainstorm|rewrite|rephrase|walk me through|derive|give me|create|design|plan|outline|critique|debug|translate|teach me|come up with|generate|answer|proofread|simplify)\\b.*") != nil {
            return true
        }
        return words >= 9 && Calc.rx(t, "^(what|why|how|can|could|should|is|are|does|do|which|would|if)\\b.*") != nil
    }

    static func clean(_ text: String) -> String {
        Rx.replace(text, "^(ask )?(chat ?gpt|gpt|claude|gemini)[,:]?\\s*(to |about )?", "", .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func selectionID(_ kind: String, _ parts: [String]) -> String {
        kind + ":" + String(data: try! JSONSerialization.data(withJSONObject: parts), encoding: .utf8)!
    }

    static func hit(_ text: String, files: [String]) -> Hit {
        let files = requestedFiles(files)
        let q = clean(text)
        let d = Dest.named(in: text) ?? dest
        let app = d == dest ? prefersApp : d.appURL != nil
        let place = app ? "\(d.name) app" : d.site
        let other = d.appURL == nil ? "" : " · ⌘↩ for the \(app ? "website" : "app")"
        let what = files.isEmpty ? "" : (files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files") + " · "
        let title = q.isEmpty ? "Ask \(d.name) about this" : "Ask \(d.name): “\(q)”"
        // only ChatGPT's app is automated; elsewhere Return opens a draft window to paste from
        let how = files.isEmpty ? "" : (d == .chatgpt ? " · attach on Return" : " · copies files on Return")
        let icon: Icon = files.first.map { .file($0) } ?? .symbol("bubble.left.and.text.bubble.right")
        return Hit(title: title, subtitle: what + place + how + other, icon: icon, tag: d.name, key: "intent:ask", selectionID: selectionID("ask", [q, app ? "app" : "web", d.rawValue] + files), excerpt: files.map { ($0 as NSString).lastPathComponent }.joined(separator: " · ")) { alt in
            ask(q, files: files, app: app != alt, to: d)
        }
    }

    static func hasText(_ path: String) -> Bool {
        let e = FileOps.ext(path)
        return FileOps.kind(path) == .image || Extract.richExts.contains(e) || Extract.plainExts.contains(e) || Extract.codeExts.contains(e)
    }

    static func read(_ files: [String]) -> String {
        files.map { f -> String in
            if FileOps.kind(f) == .image || FileOps.ext(f) == "pdf" { return String(((try? FileOps.recognise([f])) ?? "").prefix(4000)) }
            return Extract.text(URL(fileURLWithPath: f), ext: FileOps.ext(f), limit: 4000)
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Explicit text-only alternative. It uses the same draft handoff and never sends a message.
    static func sendText(_ question: String, files: [String]) {
        guard files.allSatisfy({ attachmentIssue($0) == nil }) else {
            AssistantDraft.show(question: question, files: requestedFiles(files), destination: prefersApp ? appURL : nil,
                reason: "Some files cannot be read. Restore access or remove them before retrying text extraction.",
                retry: { edited, remaining in sendText(edited, files: remaining) }, to: dest)
            return
        }
        Toast.show("Reading text…", sticky: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let text = read(files)
            DispatchQueue.main.async {
                Toast.show(text.isEmpty ? "No readable text found" : "Text extracted · preparing draft")
                guard !text.isEmpty else {
                    AssistantDraft.show(question: question, files: requestedFiles(files), destination: prefersApp ? appURL : nil,
                        reason: "No readable text found. Your original question and files are kept here.",
                        retry: { edited, remaining in sendText(edited, files: remaining) }, to: dest)
                    return
                }
                ask("\(question.isEmpty ? "Explain this." : question)\n\nExtracted text:\n\(text.prefix(12000))", files: [], app: prefersApp)
            }
        }
    }

    static func textHit(_ text: String, files: [String]) -> Hit? {
        guard !files.isEmpty, files.allSatisfy(hasText) else { return nil }
        let q = clean(text)
        let name = files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"
        return Hit(title: "Use extracted text instead", subtitle: "Text excerpt from \(name) · up to 4,000 characters per file",
                   icon: .file(files[0]), tag: Self.name, key: "intent:asktext", selectionID: selectionID("asktext", [q] + files)) { _ in sendText(q, files: files) }
    }

    static func rows(_ text: String, files: [String]) -> [Hit] {
        let files = requestedFiles(files)
        return [hit(text, files: files)] + (textHit(text, files: files).map { [$0] } ?? [])
    }

    static func best(_ question: String, files: [String]) {
        ask(question, files: files, app: prefersApp)
    }

    static func attachmentFiles(_ paths: [String]) -> [String] {
        requestedFiles(paths).filter { attachmentIssue($0) == nil }
    }

    // Deduplication never drops explicit inputs because they are missing or unsupported.
    static func requestedFiles(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
    }

    static func attachmentIssue(_ path: String) -> String? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return "Missing file — restore or remove" }
        guard !directory.boolValue else { return "Folder unsupported — attach individual files" }
        guard FileManager.default.isReadableFile(atPath: path) else { return "Unreadable file — allow access or remove" }
        return nil
    }

    // "what's on my screen", "explain this error": capture the screen once the bar is out of the way
    static func screenHit(_ question: String) -> Hit {
        Hit(title: "Ask \(name): “\(question)”", subtitle: "Captures your screen when invoked · prepares a \(name) draft", icon: .symbol("rectangle.dashed.badge.record"),
            tag: name, key: "intent:askscreen") { _ in
            captureScreen(question)
        }
    }

    private static func captureScreen(_ question: String) {
        func recover(_ reason: String) {
            AssistantDraft.show(question: question, files: [], destination: prefersApp ? appURL : nil, reason: reason,
                retry: { edited, _ in captureScreen(edited) }, settings: { AssistantHandoff.openScreenSettings() }, to: dest)
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            recover("Allow Semantic in Privacy & Security → Screen & System Audio Recording, then retry capture. Your question is saved below.")
            return
        }
        let path = Paths.tmp + "/Screen \(UUID().uuidString).png"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            do {
                _ = try AssistantDraft.withHiddenWindows { try FileOps.sh("/usr/sbin/screencapture", ["-x", "-m", path]) }
                guard attachmentIssue(path) == nil else { recover("Screen capture did not produce a readable image. Retry capture."); return }
                best(question, files: [path])
            } catch {
                recover("Could not capture the screen: \(error.localizedDescription). Check Screen Recording access, then retry.")
            }
        }
    }

    static func clipHit(_ question: String, _ clip: String) -> Hit {
        Hit(title: "Ask \(name): “\(question)”", subtitle: "Clipboard · \(clip.count) characters · prepares a draft", icon: .symbol("doc.on.clipboard"),
            tag: name, key: "intent:askclip", selectionID: selectionID("askclip", [question, clip])) { _ in
            ask("\(question)\n\n\(clip)", files: [], app: prefersApp)
        }
    }

    static func ask(_ question: String, files: [String], app wantApp: Bool, to d: Dest = Assistant.dest) {
        let requested = requestedFiles(files)
        let appURL = wantApp ? d.appURL : nil
        guard requested.allSatisfy({ attachmentIssue($0) == nil }) else {
            AssistantDraft.show(question: question, files: requested, destination: appURL, reason: "Some attachments need attention. Restore access or remove the affected files, then retry. No files were handed off.",
                retry: { edited, remaining in ask(edited, files: remaining, app: wantApp, to: d) }, to: d)
            return
        }
        guard d == .chatgpt else { return manual(question, files: requested, app: appURL, to: d) }
        AssistantHandoff.start(question: question, files: requested, app: appURL)
    }

    // No automation for Claude or Gemini: open it, put the files (or the question) on the clipboard,
    // and keep everything in a draft window to paste from. Nothing is submitted.
    static func manual(_ question: String, files: [String], app: URL?, to d: Dest) {
        let prompt = question.isEmpty ? "Explain the attached files." : question
        let pb = NSPasteboard.general
        pb.clearContents()
        if files.isEmpty { pb.setString(prompt, forType: .string) } else {
            pb.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
            pb.setPropertyList(files, forType: .init("NSFilenamesPboardType"))
        }
        if let app { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) } else { Sys.open(d.web) }
        let copied = files.isEmpty ? "Your question is on the clipboard" : "\(files.count) file\(files.count == 1 ? " is" : "s are") on the clipboard"
        AssistantDraft.show(question: prompt, files: files, destination: app, reason: "\(d.name) opened. \(copied); paste it into a new chat, then send when ready.",
            retry: { edited, remaining in ask(edited, files: remaining, app: app != nil, to: d) }, to: d)
    }

    static let intent = Intent(id: "ask", exemplars: [
        "explain how transformers work in simple terms", "write a python script that renames files by date", "help me draft an email declining a job offer",
        "solve x^2 + 3x + 2 = 0 step by step", "compare react and vue for a small project", "why does my c program segfault when i free twice",
        "summarize the causes of the first world war", "give me a four day workout plan", "answer this", "ask chatgpt what a monad is",
        "ask claude to review this paragraph", "ask gemini about the history of rome",
        "what are the tradeoffs between sql and nosql databases", "prove that the square root of 2 is irrational",
        "rewrite this paragraph to sound more formal", "brainstorm names for a podcast about soundscapes",
        "walk me through the mechanism of an sn2 reaction", "what should i consider when choosing a graduate program",
    ]) { text in [hit(text, files: [])] }
}
