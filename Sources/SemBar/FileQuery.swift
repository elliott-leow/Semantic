import Foundation

// Explicit syntax bypasses calculator/assistant interpretation; plain language still uses both signals.
struct FileQuery {
    var text: String
    var filters = Filters()
    var pattern: NSRegularExpression?
    var matchesPath = false
    var error: String?
    var explicit = false
    var contentOnly = false

    init(_ input: String) {
        text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, folders) in [("file:", false), ("folder:", true)] where text.lowercased().hasPrefix(prefix) {
            explicit = true
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            filters.kinds = folders ? [.folder] : [.image, .audio, .video, .doc, .other]
            filters.notes.append(folders ? "folders" : "files")
            break
        }
        // Small explicit filters compose with names, descriptions and grep text.
        let filterRE = try! NSRegularExpression(pattern: #"(?:^|\s)(ext|in|type):(?:"([^"\n]+)"|(\S+))"#, options: [.caseInsensitive])
        let matches = filterRE.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let ns = text as NSString
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            let value = ns.substring(with: range)
            explicit = true
            switch key {
            case "ext":
                filters.exts = Set(value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
                filters.notes.append(value.uppercased())
            case "in":
                filters.pathPrefix = (value as NSString).expandingTildeInPath
                filters.notes.append("in " + value)
            default:
                if let kind = Filters.kindWords[value.lowercased()] {
                    filters.kinds = kind == .other ? [.doc, .image, .audio, .video, .other] : [kind]
                    filters.notes.append(value)
                } else { error = "Unknown file type: " + value }
            }
            text = ns.replacingCharacters(in: match.range, with: " ")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("grep:") {
            explicit = true
            contentOnly = true
            text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            filters.notes.append("content")
            if text.isEmpty { error = "Enter words to find inside files" }
            return
        }
        var expression: String?
        if text.lowercased().hasPrefix("regex:") {
            explicit = true
            text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            expression = text
            matchesPath = text.contains("/")
            filters.notes.append("regex")
        } else if text.contains("*") || (text.contains("?") && text.contains(".")) {
            // Arithmetic such as 2*3 and ordinary questions keep their existing meaning.
            if explicit || text == "*" || text.contains("/") || text.contains(".") ||
                (text.contains("*") && text.contains(where: { $0.isLetter }) && !text.contains(" ")) {
                if explicit || Calc.answer(text) == nil {
                    explicit = true
                    matchesPath = text.contains("/")
                    let expanded = (text as NSString).expandingTildeInPath
                    expression = "^" + (matchesPath && !expanded.hasPrefix("/") ? "(?:.*/)?" : "") +
                        expanded.map { c in
                            c == "*" ? ".*" : c == "?" ? "." : NSRegularExpression.escapedPattern(for: String(c))
                        }.joined() + "$"
                    filters.notes.append("wildcard")
                }
            }
        }
        if let expression {
            if expression.isEmpty { error = "Enter a search pattern"; return }
            do { pattern = try NSRegularExpression(pattern: expression, options: [.caseInsensitive]) }
            catch { self.error = "Invalid search pattern" }
        }
    }

    func matches(_ e: Entry) -> Bool {
        guard e.kind.isFile, filters.matches(e) else { return false }
        guard let pattern else { return true }
        let value = matchesPath ? e.path : e.name
        return pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
