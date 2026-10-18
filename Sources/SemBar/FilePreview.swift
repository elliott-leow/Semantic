import AppKit
import PDFKit
import QuickLookThumbnailing

// The preview is part of the search panel: no separate window and no keyboard focus change.
final class FilePreview: NSView, NSDraggingSource {
    private let picture = NSImageView()
    private let previewStatus = NSTextField(labelWithString: "")
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let fileIcon = NSImageView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let passage = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open  ↩", target: nil, action: nil)
    private let attachButton = NSButton(title: "Add to bar  ⇥", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal  ⌘↩", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy file  ⇧⌘C", target: nil, action: nil)
    private var hit: Hit?
    private var previewKey = ""
    private var generation = 0
    private var settled = -1   // the generation whose preview finished, rendered or not
    private var request: QLThumbnailGenerator.Request?
    private let cache = NSCache<NSString, NSImage>()
    var onOpen: ((Hit, Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onAttach: ((String) -> Void)?
    var onDrag: ((Bool, NSDragOperation) -> Void)?

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
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingMiddle
        passage.font = .systemFont(ofSize: 12)
        passage.textColor = .secondaryLabelColor
        passage.maximumNumberOfLines = 2
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
        for view in [picture, textScroll, previewStatus, fileIcon, name, detail, passage, openButton, attachButton, revealButton, copyButton] { addSubview(view) }
        cache.totalCostLimit = 24 * 1024 * 1024
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // Fixed action/metadata region; all remaining space belongs to the visible file.
        let previewH = max(120, h - 168)
        let previewFrame = NSRect(x: 18, y: h - previewH - 12, width: w - 36, height: previewH)
        picture.frame = previewFrame
        previewStatus.frame = NSRect(x: 20, y: previewFrame.minY + 6, width: w - 40, height: 20)
        textScroll.frame = previewFrame
        textView.frame.size.width = previewFrame.width
        // a one-line name sits level with the icon's centre; a two-line name centres on it too
        let nameW = w - 76
        let nameH = min(36, ceil(name.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: nameW, height: 1000)).height ?? 18))
        fileIcon.frame = NSRect(x: 20, y: 112, width: 28, height: 28)
        name.frame = NSRect(x: 56, y: fileIcon.frame.midY - nameH / 2, width: nameW, height: nameH)
        detail.frame = NSRect(x: 20, y: 76, width: w - 40, height: 30)
        passage.frame = NSRect(x: 20, y: 39, width: w - 40, height: 32)
        openButton.frame = NSRect(x: 16, y: 6, width: 84, height: 26)
        attachButton.frame = NSRect(x: 104, y: 6, width: 118, height: 26)
        revealButton.frame = NSRect(x: 226, y: 6, width: 106, height: 26)
        copyButton.frame = NSRect(x: 336, y: 6, width: 132, height: 26)
    }

    func show(_ next: Hit?) {
        hit = next
        guard let next, let path = next.path else {
            previewKey = ""; generation += 1; picture.image = nil; textView.string = ""; isHidden = true
            if let request { QLThumbnailGenerator.shared.cancel(request) }; request = nil
            return
        }
        isHidden = false
        name.stringValue = next.title
        needsLayout = true
        fileIcon.image = NSWorkspace.shared.icon(forFile: path)
        detail.stringValue = next.subtitle
        detail.toolTip = path
        passage.stringValue = next.excerpt
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(next.previewPage)|\(stamp)"
        guard previewKey != key else { return }
        previewKey = key; generation += 1
        let gen = generation
        if let request { QLThumbnailGenerator.shared.cancel(request) }; request = nil
        textView.string = ""; textScroll.isHidden = true; picture.isHidden = false
        // The file's own large icon is always an honest preview. "Loading" only appears if a render is slow,
        // and a file that cannot be rendered keeps its icon rather than an error.
        picture.image = NSWorkspace.shared.icon(forFile: path)
        previewStatus.stringValue = ""
        if let image = cache.object(forKey: key as NSString) { picture.image = image; settled = gen; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == gen, self.settled != gen else { return }
            self.previewStatus.stringValue = "Loading preview…"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == gen, self.previewStatus.stringValue == "Loading preview…" else { return }
            self.previewStatus.stringValue = ""
        }
        let url = URL(fileURLWithPath: path), ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            previewStatus.stringValue = "This file is no longer here"
            settled = gen
            return
        }
        if isDir.boolValue {
            // an app's icon is its preview; a folder shows what is inside it
            if ext == "app" || NSWorkspace.shared.isFilePackage(atPath: path) { settled = gen; return }
            background(gen) { Self.folderListing(path) }
            return
        }
        if ext == "pdf" {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image: NSImage? = autoreleasepool {
                    guard let document = PDFDocument(url: url), let page = document.page(at: max(0, next.previewPage - 1)) ?? document.page(at: 0) else { return nil }
                    return page.thumbnail(of: NSSize(width: 800, height: 640), for: .cropBox)
                }
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    if let image { self.accept(image, key: key, generation: gen) } else { self.thumbnail(url, ext: ext, key: key, generation: gen) }
                }
            }
        } else if Extract.plainExts.contains(ext) || Extract.codeExts.contains(ext) {
            background(gen) { Self.plainText(url) }
        } else {
            thumbnail(url, ext: ext, key: key, generation: gen)
        }
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = make() ?? ""
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self.accept(nil, key: "", generation: gen) }
                self.settled = gen
                self.previewStatus.stringValue = ""
                self.textView.string = text
                self.textView.textColor = .labelColor
                self.textScroll.isHidden = false; self.picture.isHidden = true
            }
        }
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
    var nameOffsetForChecks: CGFloat { layoutSubtreeIfNeeded(); return abs(name.frame.midY - fileIcon.frame.midY) }
    #endif

    @objc private func copyFile() { onCopy?() }
    @objc private func openFile() { if let hit { onOpen?(hit, false) } }
    @objc private func revealFile() { if let hit { onOpen?(hit, true) } }
    @objc private func attachFile() { if let path = hit?.path { onAttach?(path) } }

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
        guard let hit, let writer = BarController.dragWriter(hit) else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(x: convert(event.locationInWindow, from: nil).x - 24,
                                     y: convert(event.locationInWindow, from: nil).y - 24, width: 48, height: 48),
                              contents: picture.image)
        onDrag?(true, [])
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDrag?(false, operation) }
}
