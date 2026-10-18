import AppKit

final class ResultSelectionView: NSTableRowView {
    static let radius: CGFloat = 10
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}

// Matched words: FTS wraps them in « », titles match the typed words.
enum Marked {
    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "") }

    // the words inside « »
    static func terms(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inside = false
        for ch in s {
            if ch == "«" { inside = true; cur = "" } else if ch == "»" {
                inside = false
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !out.contains(t) { out.append(t) }
            } else if inside { cur.append(ch) }
        }
        return out
    }

    static func attributed(_ s: String, font: NSFont, color: NSColor, strong: NSFont, strongColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var cur = "", inside = false
        func flush() {
            guard !cur.isEmpty else { return }
            out.append(NSAttributedString(string: cur, attributes: [.font: inside ? strong : font, .foregroundColor: inside ? strongColor : color]))
            cur = ""
        }
        for ch in s {
            if ch == "«" { flush(); inside = true } else if ch == "»" { flush(); inside = false } else { cur.append(ch) }
        }
        flush()
        return out
    }

    private static let stop: Set<String> = ["the", "a", "an", "of", "in", "on", "my", "to", "for", "and", "from", "with", "at", "is", "it", "me"]
    private static let quotes = CharacterSet(charactersIn: "\"'“”*")
    private static let alnum = CharacterSet.alphanumerics, lower = CharacterSet.lowercaseLetters, upper = CharacterSet.uppercaseLetters
    private static let letters = CharacterSet.letters, digits = CharacterSet.decimalDigits

    // typed words that start a word of the title (case and accent insensitive); filters like ext:pdf are not words
    static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { !$0.contains(":") && !stop.contains($0) }
            .map { $0.trimmingCharacters(in: quotes) }.filter { !$0.isEmpty }
    }

    static func ranges(of query: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        for t in tokens(query) {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: t, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                if r.location == 0 || boundary(ns, r.location) { out.append(r); break }
                from = r.location + 1
            }
        }
        return out
    }

    private static func boundary(_ ns: NSString, _ i: Int) -> Bool {
        let prev = ns.character(at: i - 1), cur = ns.character(at: i)
        guard let p = Unicode.Scalar(prev), let c = Unicode.Scalar(cur) else { return true }
        if !alnum.contains(p) { return true }
        // camelCase and digits after letters start a new word too
        return lower.contains(p) && upper.contains(c) || letters.contains(p) && digits.contains(c)
    }

    static func title(_ s: String, query: String, font: NSFont, strong: NSFont, color: NSColor) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        for r in ranges(of: query, in: s) { a.addAttribute(.font, value: strong, range: r) }
        return a
    }
}

// "~/Downloads · 3 Oct 2026" reads better as "~/Downloads · Yesterday". Only a date that is the file's own
// modification day is rewritten; anything else in the subtitle is left alone.
enum RelativeDate {
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    private static var mtimes: [String: Date] = [:]
    private static let stamp = try! NSRegularExpression(pattern: "\\b\\d{1,2} [A-Z][a-z]{2,4} \\d{4}\\b")

    static func text(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d), cal = Calendar.current
        if s < 0 { return fmt.string(from: d) }
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if cal.isDate(d, inSameDayAs: now) { return "\(Int(s / 3600)) hr ago" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        if let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), d >= start { return weekday.string(from: d) }
        return cal.component(.year, from: d) == cal.component(.year, from: now) ? day.string(from: d) : fmt.string(from: d)
    }

    // `date` is the time the engine formatted into the subtitle; without it the file is asked
    static func rewrite(_ subtitle: String, path: String?, date: Double? = nil, now: Date = Date()) -> String {
        guard let found = stamp.firstMatch(in: subtitle, range: NSRange(subtitle.startIndex..., in: subtitle)),
              let r = Range(found.range, in: subtitle) else { return subtitle }
        let m: Date
        if let date, date > 0 { m = Date(timeIntervalSince1970: date) }
        else if let path, let c = mtimes[path] { m = c } else {
            guard let path else { return subtitle }
            guard let d = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return subtitle }
            if mtimes.count > 500 { mtimes.removeAll() }
            mtimes[path] = d; m = d
        }
        guard fmt.string(from: m) == String(subtitle[r]) else { return subtitle }
        return subtitle.replacingCharacters(in: r, with: text(m, now: now))
    }
    static func forget() { mtimes.removeAll() }
}

final class HeaderView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 16, y: 3, width: bounds.width - 32, height: 15)
    }
}

final class RowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let excerpt = NSTextField(labelWithString: "")
    let tagLabel = NSTextField(labelWithString: "")
    var isFile = false
    var pending = false
    var unavailable = false
    var label = ""          // kind tag; empty when a section header already says it
    var titleText = ""
    var query = ""          // highlighted in the title; empty for action rows, whose titles quote the query anyway
    var subtitleText = ""
    var why = ""            // shown instead of the subtitle while ⌥ is held
    var excerptText = ""    // FTS excerpt with « » marks
    var shortcut = 0        // ⌘N badge while ⌘ is held; 0 for none
    var showShortcut = false
    var showWhy = false
    var hasExcerpt: Bool { !excerptText.isEmpty }
    private var selected = false
    // what select() last rendered; the same inputs render the same strings, so they are not rebuilt
    private struct Shown: Equatable {
        var selected: Bool, isFile: Bool, pending: Bool, unavailable: Bool, showShortcut: Bool, showWhy: Bool, shortcut: Int
        var label: String, titleText: String, query: String, subtitleText: String, why: String, excerptText: String
        var appearance: NSAppearance.Name
    }
    private var shown: Shown?

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    static let titleStrong = NSFont.systemFont(ofSize: 15, weight: .bold)
    static let actionFont = NSFont.systemFont(ofSize: 13)
    static let actionStrong = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let smallFont = NSFont.systemFont(ofSize: 12)
    static let smallStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = Self.smallFont
        subtitle.lineBreakMode = .byTruncatingMiddle
        excerpt.lineBreakMode = .byTruncatingTail
        tagLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tagLabel.alignment = .right
        for v in [icon, title, subtitle, excerpt, tagLabel] { addSubview(v) }
        imageView = icon
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ selected: Bool) {
        let now = Shown(selected: selected, isFile: isFile, pending: pending, unavailable: unavailable, showShortcut: showShortcut, showWhy: showWhy,
                        shortcut: shortcut, label: label, titleText: titleText, query: query, subtitleText: subtitleText, why: why,
                        excerptText: excerptText, appearance: effectiveAppearance.name)
        guard now != shown else { return }
        shown = now
        self.selected = selected
        let main: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        let font = isFile ? Self.titleFont : Self.actionFont, strong = isFile ? Self.titleStrong : Self.actionStrong
        title.attributedStringValue = query.isEmpty ? NSAttributedString(string: titleText, attributes: [.font: font, .foregroundColor: main])
            : Marked.title(titleText, query: query, font: font, strong: strong, color: main)
        let whyShown = showWhy && !why.isEmpty
        subtitle.stringValue = whyShown ? why : subtitleText
        subtitle.textColor = whyShown ? (selected ? main : .controlAccentColor) : secondary
        excerpt.attributedStringValue = Marked.attributed(excerptText, font: Self.smallFont, color: secondary, strong: Self.smallStrong, strongColor: main)
        tagLabel.textColor = secondary
        tagLabel.stringValue = unavailable ? "Unavailable" : pending ? "…" : showShortcut && shortcut > 0 ? "⌘\(shortcut)" : selected ? "↩" : label
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let size: CGFloat = isFile ? 32 : 22
        icon.frame = NSRect(x: 16, y: (h - size) / 2, width: size, height: size)
        // the reserve does not depend on selection, so titles never re-truncate as the selection moves
        let reserve: CGFloat = label.isEmpty && !unavailable ? 56 : 104
        tagLabel.frame = NSRect(x: w - reserve + 8, y: (h - 16) / 2, width: reserve - 26, height: 16)
        let x: CGFloat = 60, contentWidth = w - x - reserve
        if hasExcerpt {
            title.frame = NSRect(x: x, y: h - 23, width: contentWidth, height: 19)
            subtitle.frame = NSRect(x: x, y: h - 39, width: contentWidth, height: 15)
            excerpt.frame = NSRect(x: x, y: 7, width: contentWidth, height: 15)
        } else {
            title.frame = NSRect(x: x, y: h / 2 + 1, width: contentWidth, height: 19)
            subtitle.frame = NSRect(x: x, y: h / 2 - 16, width: contentWidth, height: 15)
        }
        excerpt.isHidden = !hasExcerpt
    }
}

// "Show all files": the row after the file group when the engine stopped at its cap.
final class MoreView: NSTableCellView {
    let label = NSTextField(labelWithString: "Show all files")
    let hint = NSTextField(labelWithString: "⌘↓")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.alignment = .right
        addSubview(label); addSubview(hint)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show all matching files")
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(_ selected: Bool) {
        label.textColor = selected ? .alternateSelectedControlTextColor : .controlAccentColor
        hint.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 60, y: (bounds.height - 17) / 2, width: bounds.width - 160, height: 17)
        hint.frame = NSRect(x: bounds.width - 96, y: (bounds.height - 16) / 2, width: 70, height: 16)
    }
}

// The result list: hovering selects, but only when the pointer actually moves, never because rows moved under it.
final class ResultTable: NSTableView {
    var onHover: ((Int) -> Void)?
    private var last = NSPoint(x: -1, y: -1)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self && a.options.contains(.mouseMoved) { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = NSEvent.mouseLocation
        guard p != last else { return }
        last = p
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { onHover?(r) }
    }
}

// Determinate indexing progress, small enough to sit beside the scope text.
final class ProgressRing: NSView {
    private let track = CAShapeLayer(), bar = CAShapeLayer()
    var fraction: CGFloat = 0 { didSet { bar.strokeEnd = max(0.02, min(1, fraction)) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, bar] {
            l.fillColor = nil
            l.lineWidth = 2
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGMutablePath()
        // start at twelve o'clock, run clockwise
        path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        track.path = path; bar.path = path
        track.frame = bounds; bar.frame = bounds
        updateColors()
    }
    override func viewDidChangeEffectiveAppearance() { updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.cgColor
            bar.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }
}
