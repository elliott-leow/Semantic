import AppKit
import ApplicationServices

// Prepares a new ChatGPT draft with actual files. The user sends the message.
enum Assistant {
    static let appIDs = ["com.openai.chat", "com.openai.codex"]

    static var appURL: URL? { appIDs.lazy.compactMap { Sys.app($0) }.first }
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
        text.replacingOccurrences(of: "^(ask )?(chat ?gpt|gpt)[,:]?\\s*(to |about )?", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func selectionID(_ kind: String, _ parts: [String]) -> String {
        kind + ":" + String(data: try! JSONSerialization.data(withJSONObject: parts), encoding: .utf8)!
    }

    static func hit(_ text: String, files: [String]) -> Hit {
        let files = requestedFiles(files)
        let q = clean(text)
        let app = prefersApp
        let place = app ? "ChatGPT app" : "chatgpt.com"
        let other = appURL == nil ? "" : " · ⌘↩ for the \(prefersApp ? "website" : "app")"
        let what = files.isEmpty ? "" : (files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files") + " · "
        let title = q.isEmpty ? "Ask ChatGPT about this" : "Ask ChatGPT: “\(q)”"
        let how = files.isEmpty ? "" : " · attach on Return"
        let icon: Icon = files.first.map { .file($0) } ?? .symbol("bubble.left.and.text.bubble.right")
        return Hit(title: title, subtitle: what + place + how + other, icon: icon, tag: "ChatGPT", key: "intent:ask", selectionID: selectionID("ask", [q, app ? "app" : "web"] + files), excerpt: files.map { ($0 as NSString).lastPathComponent }.joined(separator: " · ")) { alt in
            ask(q, files: files, app: app != alt)
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
                retry: { edited, remaining in sendText(edited, files: remaining) })
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
                        retry: { edited, remaining in sendText(edited, files: remaining) })
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
                   icon: .file(files[0]), tag: "ChatGPT", key: "intent:asktext", selectionID: selectionID("asktext", [q] + files)) { _ in sendText(q, files: files) }
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
        Hit(title: "Ask ChatGPT: “\(question)”", subtitle: "Captures your screen when invoked · prepares a ChatGPT draft", icon: .symbol("rectangle.dashed.badge.record"),
            tag: "ChatGPT", key: "intent:askscreen") { _ in
            captureScreen(question)
        }
    }

    private static func captureScreen(_ question: String) {
        func recover(_ reason: String) {
            AssistantDraft.show(question: question, files: [], destination: prefersApp ? appURL : nil, reason: reason,
                retry: { edited, _ in captureScreen(edited) }, settings: { AssistantHandoff.openScreenSettings() })
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            recover("Allow Semantic in Privacy & Security → Screen & System Audio Recording, then retry capture. Your question is saved below.")
            return
        }
        let path = Paths.tmp + "/Screen \(UUID().uuidString).png"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            do {
                try AssistantDraft.withHiddenWindows { try FileOps.sh("/usr/sbin/screencapture", ["-x", "-m", path]) }
                guard attachmentIssue(path) == nil else { recover("Screen capture did not produce a readable image. Retry capture."); return }
                best(question, files: [path])
            } catch {
                recover("Could not capture the screen: \(error.localizedDescription). Check Screen Recording access, then retry.")
            }
        }
    }

    static func clipHit(_ question: String, _ clip: String) -> Hit {
        Hit(title: "Ask ChatGPT: “\(question)”", subtitle: "Clipboard · \(clip.count) characters · prepares a draft", icon: .symbol("doc.on.clipboard"),
            tag: "ChatGPT", key: "intent:askclip", selectionID: selectionID("askclip", [question, clip])) { _ in
            ask("\(question)\n\n\(clip)", files: [], app: prefersApp)
        }
    }

    static func ask(_ question: String, files: [String], app wantApp: Bool) {
        let requested = requestedFiles(files)
        guard requested.allSatisfy({ attachmentIssue($0) == nil }) else {
            AssistantDraft.show(question: question, files: requested, destination: wantApp ? appURL : nil,
                reason: "Some attachments need attention. Restore access or remove the affected files, then retry. No files were handed off.",
                retry: { edited, remaining in ask(edited, files: remaining, app: wantApp) })
            return
        }
        AssistantHandoff.start(question: question, files: requested, app: wantApp ? appURL : nil)
    }

    static let intent = Intent(id: "ask", exemplars: [
        "explain how transformers work in simple terms", "write a python script that renames files by date", "help me draft an email declining a job offer",
        "solve x^2 + 3x + 2 = 0 step by step", "compare react and vue for a small project", "why does my c program segfault when i free twice",
        "summarize the causes of the first world war", "give me a four day workout plan", "answer this", "ask chatgpt what a monad is",
        "what are the tradeoffs between sql and nosql databases", "prove that the square root of 2 is irrational",
        "rewrite this paragraph to sound more formal", "brainstorm names for a podcast about soundscapes",
        "walk me through the mechanism of an sn2 reaction", "what should i consider when choosing a graduate program",
    ]) { text in [hit(text, files: [])] }
}
