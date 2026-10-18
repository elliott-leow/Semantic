import AppKit
import AVFoundation
import AVKit
import PDFKit
import QuickLookThumbnailing

// PDF and player views must never take the keyboard from the search field.
private final class PreviewPDFView: PDFView {
    override var acceptsFirstResponder: Bool { false }
}

private final class PreviewPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}

// The preview is part of the search panel: no separate window and no keyboard focus change.
final class FilePreview: NSView, NSDraggingSource {
    private let picture = NSImageView()
    private let previewStatus = NSTextField(labelWithString: "")
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let fileIcon = NSImageView()
    private let detail = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let passage = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open  ↩", target: nil, action: nil)
    private let attachButton = NSButton(title: "Add to bar  ⇥", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal  ⌘↩", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy file  ⇧⌘C", target: nil, action: nil)
    private lazy var pdfView: PreviewPDFView = {
        let v = PreviewPDFView()
        v.displayMode = .singlePage
        v.autoScales = true
        v.displaysPageBreaks = false
        v.backgroundColor = .underPageBackgroundColor
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.setAccessibilityLabel("PDF page preview")
        addSubview(v, positioned: .below, relativeTo: previewStatus)
        return v
    }()
    private lazy var playerView: PreviewPlayerView = {
        let v = PreviewPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.setAccessibilityLabel("Media player, paused")
        addSubview(v, positioned: .below, relativeTo: previewStatus)
        return v
    }()
    private var media: Kind?        // .audio/.video while the player is showing
    private var hit: Hit?
    private var previewKey = ""
    private var generation = 0
    private var settled = -1   // the generation whose preview finished, rendered or not
    private var request: QLThumbnailGenerator.Request?
    private let cache = NSCache<NSString, NSImage>()
    private var summaryMode = false
    var onOpen: ((Hit, Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onAttach: ((String) -> Void)?
    var onDrag: ((Bool, NSDragOperation) -> Void)?
    var query = ""          // the typed words, highlighted in text previews when the excerpt has no marks
    // false while the results under it are stale: nothing here may open, attach or drag
    var interactive = true {
        didSet { for b in [openButton, attachButton, revealButton, copyButton] { b.isEnabled = interactive } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewStatus.font = .systemFont(ofSize: 12)
        previewStatus.alignment = .center
        previewStatus.textColor = .secondaryLabelColor
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 12
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.setAccessibilityLabel("File content preview; drag to another app")
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.maximumNumberOfLines = 2
        name.toolTip = "Drag this file name into another app"
        name.setAccessibilityLabel("File name; drag to another app")
        fileIcon.toolTip = "Drag this file into another app"
        fileIcon.setAccessibilityLabel("Drag file to another app")
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.setAccessibilityLabel("File details")
        passage.font = .systemFont(ofSize: 12)
        passage.textColor = .secondaryLabelColor
        passage.maximumNumberOfLines = 2
        passage.lineBreakMode = .byTruncatingTail
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.autoresizingMask = [.width]
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textScroll.wantsLayer = true
        textScroll.layer?.cornerRadius = 12
        textScroll.layer?.cornerCurve = .continuous
        textScroll.layer?.masksToBounds = true
        textScroll.isHidden = true
        for button in [openButton, attachButton, revealButton, copyButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
        }
        openButton.action = #selector(openFile)
        attachButton.action = #selector(attachFile)
        revealButton.action = #selector(revealFile)
        copyButton.action = #selector(copyFile)
        copyButton.toolTip = "Copy this file to paste into another app. Shift-Command-C."
        attachButton.toolTip = "Add this file to the search field, then type a request. Keyboard: Tab."
        openButton.toolTip = "Open this file. Keyboard: Return."
        revealButton.toolTip = "Show in Finder. Keyboard: Command-Return."
        for view in [picture, textScroll, previewStatus, fileIcon, name, detail, meta, passage, openButton, attachButton, revealButton, copyButton] { addSubview(view) }
        cache.totalCostLimit = 24 * 1024 * 1024
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        if summaryMode {
            // an action row: its icon and what Return does, centred where the file would be
            picture.frame = NSRect(x: w / 2 - 28, y: h / 2 + 4, width: 56, height: 56)
            name.frame = NSRect(x: 24, y: h / 2 - 36, width: w - 48, height: 34)
            detail.frame = NSRect(x: 24, y: h / 2 - 54, width: w - 48, height: 15)
            passage.frame = NSRect(x: 24, y: h / 2 - 90, width: w - 48, height: 32)
            return
        }
        // Fixed action/metadata region; all remaining space belongs to the visible file.
        let previewH = max(120, h - 168)
        let previewFrame = NSRect(x: 18, y: h - previewH - 12, width: w - 36, height: previewH)
        picture.frame = media == .audio ? NSRect(x: previewFrame.minX, y: previewFrame.minY + 52, width: previewFrame.width, height: previewFrame.height - 52) : previewFrame
        previewStatus.frame = NSRect(x: 20, y: previewFrame.minY + 6, width: w - 40, height: 20)
        textScroll.frame = previewFrame
        textView.frame.size.width = previewFrame.width
        if pdfLoaded { pdfView.frame = previewFrame }
        if media != nil {
            playerView.frame = media == .audio ? NSRect(x: previewFrame.minX, y: previewFrame.minY, width: previewFrame.width, height: 44) : previewFrame
        }
        // a one-line name sits level with the icon's centre; a two-line name centres on it too
        let nameW = w - 76
        let nameH = min(36, ceil(name.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: nameW, height: 1000)).height ?? 18))
        fileIcon.frame = NSRect(x: 20, y: 112, width: 28, height: 28)
        name.frame = NSRect(x: 56, y: fileIcon.frame.midY - nameH / 2, width: nameW, height: nameH)
        detail.frame = NSRect(x: 20, y: 92, width: w - 40, height: 15)
        meta.frame = NSRect(x: 20, y: 75, width: w - 40, height: 15)
        passage.frame = NSRect(x: 20, y: 39, width: w - 40, height: 32)
        openButton.frame = NSRect(x: 16, y: 6, width: 84, height: 26)
        attachButton.frame = NSRect(x: 104, y: 6, width: 118, height: 26)
        revealButton.frame = NSRect(x: 226, y: 6, width: 106, height: 26)
        copyButton.frame = NSRect(x: 336, y: 6, width: 132, height: 26)
    }

    private var pdfLoaded = false
    private func hideMedia() {
        if media != nil { playerView.player?.pause(); playerView.player = nil; playerView.isHidden = true; media = nil }
        if pdfLoaded { pdfView.document = nil; pdfView.isHidden = true; pdfLoaded = false }
    }

    private func setFileChrome(_ visible: Bool) {
        for v in [fileIcon, meta, openButton, attachButton, revealButton, copyButton] as [NSView] { v.isHidden = !visible }
    }

    // A non-file row while files are listed: keeps the column (and the panel) the same size,
    // and says what Return will do instead of leaving a hole.
    func showSummary(_ next: Hit?, image: NSImage?, hint: String? = nil) {
        show(nil)
        hit = nil
        isHidden = false
        summaryMode = true
        setFileChrome(false)
        textScroll.isHidden = true
        previewStatus.stringValue = ""
        picture.isHidden = false
        picture.image = image
        picture.contentTintColor = .tertiaryLabelColor
        name.alignment = .center
        detail.alignment = .center
        passage.alignment = .center
        name.stringValue = next.map { Marked.plain($0.title) } ?? "No result selected"
        detail.stringValue = next?.subtitle ?? "↑↓ to choose a result"
        passage.stringValue = hint ?? next.map { $0.unavailableReason ?? ($0.isPending ? "Working it out…" : "Return to run") } ?? ""
        needsLayout = true
    }

    private func leaveSummary() {
        guard summaryMode else { return }
        summaryMode = false
        setFileChrome(true)
        picture.contentTintColor = nil
        name.alignment = .natural
        detail.alignment = .natural
        passage.alignment = .natural
    }

    func show(_ next: Hit?) {
        hit = next
        guard let next, let path = next.path else {
            previewKey = ""; generation += 1; picture.image = nil; textView.string = ""; isHidden = true
            hideMedia()
            if let request { QLThumbnailGenerator.shared.cancel(request) }; request = nil
            return
        }
        leaveSummary()
        isHidden = false
        name.stringValue = next.title
        needsLayout = true
        fileIcon.image = NSWorkspace.shared.icon(forFile: path)
        detail.stringValue = RelativeDate.rewrite(next.subtitle, path: path, date: next.date)
        detail.toolTip = path
        passage.attributedStringValue = Marked.attributed(next.excerpt, font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                                                          strong: .systemFont(ofSize: 12, weight: .semibold), strongColor: .labelColor)
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(next.previewPage)|\(stamp)|\(next.excerpt)"
        guard previewKey != key else { return }
        previewKey = key; generation += 1
        let gen = generation
        if let request { QLThumbnailGenerator.shared.cancel(request) }; request = nil
        hideMedia()
        textView.string = ""; textScroll.isHidden = true; picture.isHidden = false
        meta.stringValue = ""
        // The file's own large icon is always an honest preview. "Loading" only appears if a render is slow,
        // and a file that cannot be rendered keeps its icon rather than an error.
        picture.image = NSWorkspace.shared.icon(forFile: path)
        previewStatus.stringValue = ""
        let url = URL(fileURLWithPath: path), ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            previewStatus.stringValue = "This file is no longer here"
            settled = gen
            return
        }
        loadMeta(url, ext: ext, isDir: isDir.boolValue, gen: gen)
        let kind = Extract.kind(ext: ext)
        if !isDir.boolValue, kind == .audio || kind == .video { play(url, kind: kind, at: Self.time(in: next.subtitle)) }
        if let image = cache.object(forKey: key as NSString) { picture.image = image; settled = gen; if ext == "pdf" { loadPDF(url, next, gen) }; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == gen, self.settled != gen else { return }
            self.previewStatus.stringValue = "Loading preview…"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == gen, self.previewStatus.stringValue == "Loading preview…" else { return }
            self.previewStatus.stringValue = ""
        }
        if isDir.boolValue {
            // an app's icon is its preview; a folder shows what is inside it
            if ext == "app" || NSWorkspace.shared.isFilePackage(atPath: path) { settled = gen; return }
            background(gen) { Self.folderListing(path) }
            return
        }
        if ext == "pdf" {
            loadPDF(url, next, gen)
        } else if Extract.plainExts.contains(ext) || Extract.codeExts.contains(ext) {
            background(gen) { Self.plainText(url) }
        } else if kind != .video {
            thumbnail(url, ext: ext, key: key, generation: gen)
        } else { settled = gen }
    }

    // "At 3:20 · ~/Movies" → 200 s
    static func time(in subtitle: String) -> Double? {
        guard let r = subtitle.range(of: "^At (\\d+):(\\d\\d)", options: .regularExpression) else { return nil }
        let parts = subtitle[r].dropFirst(3).split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    private func play(_ url: URL, kind: Kind, at time: Double?) {
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        if let time { player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        media = kind
        playerView.player = player
        playerView.isHidden = false
        if kind == .video { picture.isHidden = true }
        needsLayout = true
    }

    // The matched page itself, scrollable, with the excerpt's words marked; the thumbnail is the fallback.
    private func loadPDF(_ url: URL, _ hit: Hit, _ gen: Int) {
        let terms = Marked.terms(hit.excerpt).isEmpty ? Marked.tokens(query).filter { $0.count > 2 } : Marked.terms(hit.excerpt)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let doc = PDFDocument(url: url)
            var marks: [PDFSelection] = []
            let page = doc.flatMap { $0.page(at: max(0, hit.previewPage - 1)) ?? $0.page(at: 0) }
            if let page, let text = page.string as NSString? {
                for t in terms.prefix(6) {
                    var from = 0
                    while marks.count < 40, from < text.length {
                        let r = text.range(of: t, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: text.length - from))
                        guard r.location != NSNotFound else { break }
                        if let s = page.selection(for: r) { s.color = .findHighlightColor; marks.append(s) }
                        from = r.location + max(1, r.length)
                    }
                }
            }
            let thumb: NSImage? = doc == nil ? nil : autoreleasepool { page?.thumbnail(of: NSSize(width: 800, height: 640), for: .cropBox) }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                guard let doc, let page else { return self.thumbnail(url, ext: "pdf", key: self.previewKey, generation: gen) }
                if let thumb { self.accept(thumb, key: self.previewKey, generation: gen) } else { self.settled = gen }
                self.pdfLoaded = true
                self.pdfView.document = doc
                self.pdfView.go(to: page)
                self.pdfView.highlightedSelections = marks.isEmpty ? nil : marks
                if let first = marks.first { self.pdfView.go(to: first) }
                self.pdfView.isHidden = false
                self.picture.isHidden = true
                self.needsLayout = true
            }
        }
    }

    // Size plus what matters for the kind: pixels, pages, running time, version.
    private func loadMeta(_ url: URL, ext: String, isDir: Bool, gen: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var parts: [String] = []
            let kind = Extract.kind(ext: ext)
            if isDir {
                if ext == "app", let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String { parts.append("Version \(v)") }
            } else {
                if kind == .image, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                    parts.append("\(w) × \(h)")
                }
                if ext == "pdf", let d = CGPDFDocument(url as CFURL) { parts.append("\(d.numberOfPages) page\(d.numberOfPages == 1 ? "" : "s")") }
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }
            let finish = { (extra: String?) in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.meta.stringValue = ([extra].compactMap { $0 } + parts).joined(separator: " · ")
                }
            }
            guard kind == .audio || kind == .video else { return finish(nil) }
            Task {
                let d = try? await AVURLAsset(url: url).load(.duration)
                let s = d.map { CMTimeGetSeconds($0) } ?? .nan
                finish(s.isFinite && s > 0 ? Self.duration(s) : nil)
            }
        }
    }

    nonisolated static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    // Quick Look first; when it can only offer the generic icon, documents fall back to their text.
    private func thumbnail(_ url: URL, ext: String, key: String, generation gen: Int) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 440, height: 320), scale: 2, representationTypes: .all)
        request = req
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let image = rep?.nsImage, rep?.type != .icon { return self.accept(image, key: key, generation: gen) }
                if Extract.richExts.contains(ext) || Extract.kind(ext: ext) == .doc {
                    self.background(gen) { Self.documentText(url, ext: ext) }
                } else { self.accept(nil, key: key, generation: gen) }
            }
        }
    }

    // text produced off the main thread; nothing is shown when there is none, the icon stays
    private func background(_ gen: Int, _ make: @escaping () -> String?) {
        let terms = Marked.terms(hit?.excerpt ?? "").isEmpty ? Marked.tokens(query).filter { $0.count > 2 } : Marked.terms(hit?.excerpt ?? "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = make() ?? ""
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self.accept(nil, key: "", generation: gen) }
                self.settled = gen
                self.previewStatus.stringValue = ""
                self.textView.string = text
                self.textView.textColor = .labelColor
                if let first = Self.mark(self.textView, terms) { self.textView.scrollRangeToVisible(first) }
                else { self.textView.scrollToBeginningOfDocument(nil) }
                self.textScroll.isHidden = false; self.picture.isHidden = true
            }
        }
    }

    // highlights matches in a text preview; returns the first so it can be scrolled to
    @discardableResult static func mark(_ tv: NSTextView, _ terms: [String]) -> NSRange? {
        guard let storage = tv.textStorage else { return nil }
        let ns = storage.string as NSString
        var first: NSRange?, count = 0
        storage.beginEditing()
        for t in terms.prefix(6) {
            var from = 0
            while count < 200, from < ns.length {
                let r = ns.range(of: t, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                storage.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: r)
                if first == nil || r.location < first!.location { first = r }
                count += 1
                from = r.location + max(1, r.length)
            }
        }
        storage.endEditing()
        return first
    }

    static func folderListing(_ path: String, limit: Int = 60) -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return "" }
        let visible = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if visible.isEmpty { return "Empty folder" }
        var lines = visible.prefix(limit).map { name -> String in
            var d: ObjCBool = false
            fm.fileExists(atPath: path + "/" + name, isDirectory: &d)
            return d.boolValue && !name.hasSuffix(".app") ? name + "/" : name
        }
        if visible.count > limit { lines.append("… and \(visible.count - limit) more") }
        return "\(visible.count) item\(visible.count == 1 ? "" : "s")\n\n" + lines.joined(separator: "\n")
    }

    static func documentText(_ url: URL, ext: String) -> String? {
        let text = Extract.text(url, ext: ext, limit: 5000)
        return text.isEmpty ? nil : text
    }

    // Preserve line structure and indentation; search extraction normalizes them.
    static func plainText(_ url: URL, limit: Int = 5000) -> String? {
        let count = max(0, min(limit, 100_000))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // at end of file, read returns nil rather than empty data
        let data = (try? handle.read(upToCount: count * 4)) ?? nil ?? Data()
        if data.isEmpty { return "Empty file" }
        // a cut can split one UTF-8 character; anything else that is not UTF-8 is probably Latin-1 or Windows text
        let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(3), encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        return String(text.prefix(count))
    }

    private func accept(_ image: NSImage?, key: String, generation gen: Int) {
        guard generation == gen else { return }
        settled = gen
        // nothing better than the file's icon, which is already showing: say nothing
        guard let image else { previewStatus.stringValue = ""; return }
        previewStatus.stringValue = ""
        picture.image = image
        cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
    }
    #if SEARCH_TESTS
    var statusForChecks: String { previewStatus.stringValue }
    var textForChecks: String? { textScroll.isHidden ? nil : textView.string }
    var metaForChecks: String { meta.stringValue }
    var markedForChecks: Int {
        var n = 0
        textView.textStorage?.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { v, _, _ in if v != nil { n += 1 } }
        return n
    }
    var pdfShownForChecks: Bool { pdfLoaded && !pdfView.isHidden }
    var pdfMarksForChecks: Int { pdfLoaded ? pdfView.highlightedSelections?.count ?? 0 : 0 }
    var nameOffsetForChecks: CGFloat { layoutSubtreeIfNeeded(); return abs(name.frame.midY - fileIcon.frame.midY) }
    #endif

    @objc private func copyFile() { if interactive { onCopy?() } }
    @objc private func openFile() { if interactive, let hit { onOpen?(hit, false) } }
    @objc private func revealFile() { if interactive, let hit { onOpen?(hit, true) } }
    @objc private func attachFile() { if interactive, let path = hit?.path { onAttach?(path) } }

    // The preview image also acts like the file in Finder. Buttons and text keep their normal semantics.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if view === picture || view === name || view === fileIcon { return self }
        return view
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { openFile() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard interactive, let hit, let writer = BarController.dragWriter(hit) else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(x: convert(event.locationInWindow, from: nil).x - 24,
                                     y: convert(event.locationInWindow, from: nil).y - 24, width: 48, height: 48),
                              contents: picture.image ?? fileIcon.image)
        onDrag?(true, [])
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDrag?(false, operation) }
}
