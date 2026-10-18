# Search bar layout
Sources/Semantic/Panel.swift contains the single native floating search panel.
```swift
import AppKit
import QuickLookThumbnailing

final class BarPanel: NSPanel {
    var inert = false // self-test: must never take the keyboard
    override var canBecomeKey: Bool { !inert }
}

// Anything dragged onto the bar, wherever it lands, becomes the attached file.
enum Drops {
    // plain files, image data, and promised files (the floating screenshot thumbnail, images dragged out of browsers and Photos)
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static var handler: (([String]) -> Void)?

    static func accept(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            handler?(urls.map(\.path))
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = URL(fileURLWithPath: Paths.tmp)
            var got: [String] = []
            let group = DispatchGroup()
            for p in promises {
                for _ in 0..<max(1, p.fileTypes.count) { group.enter() }
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    if error == nil { got.append(url.path) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !got.isEmpty { handler?(got) } }
            return true
        }
        let paths = BarController.files(from: pb, imageEvenWithText: true)
        if !paths.isEmpty { handler?(paths) }
        return !paths.isEmpty
    }
}

final class DropView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Drops.types)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { Drops.accept(sender.draggingPasteboard) }
}

// The text field's editor. A stock one takes a dropped file and types its path into the field;
// this one hands the file to the bar instead.
final class BarEditor: NSTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Drops.types }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { Drops.accept(sender.draggingPasteboard) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}
}

final class RowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let tagLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        tagLabel.font = .systemFont(ofSize: 11.5)
        tagLabel.textColor = .tertiaryLabelColor
        tagLabel.alignment = .right
        for v in [icon, title, subtitle, tagLabel] { addSubview(v) }
        imageView = icon
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 12, y: 7, width: 30, height: 30)
        tagLabel.frame = NSRect(x: w - 112, y: 14, width: 100, height: 16)
        title.frame = NSRect(x: 52, y: 21, width: w - 172, height: 19)
        subtitle.frame = NSRect(x: 52, y: 5, width: w - 172, height: 15)
    }
}

// The attached file(s), shown as a pill in front of the text.
final class ChipView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    // returns the width the chip wants
    func set(_ files: [String]) -> CGFloat {
        guard let first = files.first else { return 0 }
        icon.image = NSWorkspace.shared.icon(forFile: first)
        label.stringValue = files.count == 1 ? (first as NSString).lastPathComponent : "\(files.count) files"
        let w = min(230, label.intrinsicContentSize.width + 4)
        icon.frame = NSRect(x: 7, y: 5, width: 20, height: 20)
        label.frame = NSRect(x: 31, y: 6, width: w, height: 18)
        return w + 40
    }
}

// A short confirmation that outlives the bar ("✓ Converted to JPEG → photo.jpg").
enum Toast {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var timer: Timer?

    static func show(_ text: String, seconds: Double = 2.4, sticky: Bool = false) {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 12
            fx.layer?.masksToBounds = true
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 13.5, weight: .medium)
            l.lineBreakMode = .byTruncatingMiddle
            fx.addSubview(l)
            p.contentView = fx
            (panel, label) = (p, l)
        }
        guard let panel, let label else { return }
        label.stringValue = text
        let w = min(560, label.intrinsicContentSize.width + 36)
        let mouse = NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.maxY - vf.height * 0.2 - 40, width: w, height: 38), display: true)
        label.frame = NSRect(x: 18, y: 10, width: w - 36, height: 18)
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = sticky ? nil : Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in panel.orderOut(nil) }
    }
}

final class BarController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let width: CGFloat = 720, fieldH: CGFloat = 58, rowH: CGFloat = 44, footerH: CGFloat = 22, maxRows = 9
    private let panel: BarPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let chip = ChipView(frame: .zero)
    private var hits: [Hit] = []
    private var note = ""
    private var top: CGFloat = 0
    private let thumbs = NSCache<NSString, NSImage>()
    private var monitor: Any?
    private var refineTimer: Timer?
    private var dropped = false
    private var mouseTimer: Timer?
    private var pinned = false // showing results that are not a function of the text (similar-to)

    private(set) var chips: [String] = []
    var status = "" { didSet { if panel.isVisible { resize() } } }
    var isVisible: Bool { panel.isVisible }
    var onHide: (() -> Void)?

    override init() {
        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: fieldH),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.delegate = self

        let fx = DropView(frame: panel.contentLayoutRect)
        Drops.handler = { [weak self] paths in
            guard let self else { return }
            self.dropped = true
            let typed = self.field.stringValue
            self.attach(paths)
            self.field.stringValue = typed // a question typed before the drop still stands
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
            self.refresh()
        }
        fx.material = .popover
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        panel.contentView = fx

        glyph.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glyph.contentTintColor = .secondaryLabelColor
        fx.addSubview(glyph)
        chip.isHidden = true
        fx.addSubview(chip)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Find anything…"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        fx.addSubview(field)

        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowH
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.registerForDraggedTypes(Drops.types)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        fx.addSubview(scroll)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        fx.addSubview(footer)

        // shortcuts that never reach the field editor as ordinary commands
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isKeyWindow, ev.modifierFlags.contains(.command) else { return ev }
            switch ev.keyCode {
            case 36: self.activate(alt: true); return nil            // ⌘↩ reveal
            case 35: self.quickLook(); return nil                    // ⌘P preview
            case 9: return self.pasteFiles() ? nil : ev              // ⌘V with files or an image on the clipboard
            default: return ev
            }
        }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            top = vf.maxY - vf.height * 0.2
            panel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: top - panel.frame.height))
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        resize()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // opened over Finder with something selected: that selection is what the user wants to act on
        if front == "com.apple.finder", config.finderSelection != false { attachFinderSelection() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        refineTimer?.invalidate()
        field.stringValue = ""
        chips = []
        hits = []
        note = ""
        pinned = false
        table.reloadData()
        onHide?()
    }

    // A click elsewhere closes the bar, but a press that turns into a drag must be able to land on it:
    // while the button is held the bar stays, and it closes on release unless something was dropped.
    func windowDidResignKey(_ notification: Notification) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return hide() }
        dropped = false
        mouseTimer?.invalidate()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self, !self.dropped, !self.panel.isKeyWindow else { return }
                self.hide()
            }
        }
    }

    private lazy var editor: BarEditor = {
        let e = BarEditor(frame: .zero)
        e.isFieldEditor = true
        return e
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }

    // drops that land on the result rows
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation { .copy }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        Drops.accept(info.draggingPasteboard)
    }

    // A path that ends up in the text (pasted, or typed) is a file to attach, not words to search for.
    // Returns the file and the text without it.
    static func pathInText(_ text: String) -> (String, String)? {
        guard text.contains("/") else { return nil }
        let t = text.replacingOccurrences(of: "file://", with: "")
        let chars = Array(t)
        for i in 0..<chars.count where chars[i] == "/" || chars[i] == "~" {
            if i > 0, chars[i - 1] != " " { continue }
            // file names contain spaces, so try the longest candidate first and shrink at word boundaries
            var end = chars.count
            while end > i + 1 {
                let raw = String(chars[i..<end]).trimmingCharacters(in: .whitespaces)
                let cand = ((raw.removingPercentEncoding ?? raw) as NSString).expandingTildeInPath
                if cand.count > 1, cand != "/", FileManager.default.fileExists(atPath: cand) {
                    let rest = (String(chars[..<i]) + " " + String(chars[end...])).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    return (cand, rest.trimmingCharacters(in: .whitespaces))
                }
                guard let sp = chars[i..<end].lastIndex(of: " ") else { break }
                end = sp
            }
        }
        return nil
    }

    private func resize() {
        let rows = CGFloat(min(hits.count, maxRows))
        let foot = note.isEmpty ? status : note
        footer.stringValue = foot
        let footH = foot.isEmpty ? 0 : footerH
        let listH = rows * rowH + (rows > 0 ? 8 : 0)
        let h = fieldH + listH + footH
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - h, width: width, height: h), display: true)
        glyph.frame = NSRect(x: 18, y: h - fieldH + 16, width: 26, height: 26)
        let chipW = chip.set(chips)
        chip.isHidden = chips.isEmpty
        chip.frame = NSRect(x: 54, y: h - fieldH + 14, width: chipW, height: 30)
        let x = 54 + (chips.isEmpty ? 0 : chipW + 10)
        field.frame = NSRect(x: x, y: h - fieldH + 12, width: width - x - 18, height: 32)
        field.placeholderString = chips.isEmpty ? "Find anything…" : "What should I do with it?"
        scroll.frame = NSRect(x: 0, y: footH, width: width, height: listH)
        footer.frame = NSRect(x: 18, y: 4, width: width - 36, height: 14)
        footer.isHidden = foot.isEmpty
    }

    // MARK: attaching files

    func attach(_ files: [String]) {
        let real = files.filter { FileManager.default.fileExists(atPath: $0) }
        guard !real.isEmpty else { return }
        chips = Array(real.prefix(50))
        pinned = false
        field.stringValue = ""
        refresh()
    }

    private func attachFinderSelection() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let paths = out.split(separator: "\n").map { s -> String in
                let t = String(s)
                return t.count > 1 && t.hasSuffix("/") ? String(t.dropLast()) : t
            }
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible, self.chips.isEmpty, self.field.stringValue.isEmpty, !paths.isEmpty else { return }
                self.attach(paths)
            }
        }
        try? p.run()
    }

    // file references on a pasteboard, or failing that an image on it saved to a temporary PNG
    static func files(from pb: NSPasteboard, imageEvenWithText: Bool) -> [String] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        guard imageEvenWithText || pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let path = Paths.tmp + "/Pasted image \(Int(Date().timeIntervalSince1970)).png"
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil ? [path] : []
    }

    // ⌘V: files copied in Finder, or an image copied from anywhere, become the attached file
    private func pasteFiles() -> Bool {
        let paths = Self.files(from: .general, imageEvenWithText: false)
        if !paths.isEmpty { attach(paths) }
        return !paths.isEmpty
    }

    func showSimilar(to file: String) {
        if chips != [file] { chips = [file] }
        field.stringValue = ""
        pinned = true
        note = "Looking for similar files…"
        hits = []
        table.reloadData()
        resize()
        Engine.shared.similar(to: file) { [weak self] r in
            guard let self, self.pinned else { return }
            self.apply(r)
        }
    }

    private func quickLook() {
        let r = table.selectedRow
        let target = r >= 0 && r < hits.count ? hits[r].path : nil
        guard let path = target ?? chips.first else { return }
        hide()
        Sys.shell("/usr/bin/qlmanage", ["-p", path])
    }

    // Exercises the real controls without any synthetic input (`Semantic --selftest file`): typing through the
    // field editor, a drop delivered to each drop target's handler, and what Return would run.
    func selfTest(_ file: String, report: @escaping ([String]) -> Void) {
        var out: [String] = []
        func wait(_ s: Double, _ then: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: then) }
        func first() -> String { hits.first.map { "\($0.tag): \($0.title)" } ?? "(no rows)" }
        // never shown and never key, so nothing the user types or sees is touched
        panel.inert = true
        self.top = 600
        resize()
        panel.makeFirstResponder(field)
        let ed = field.currentEditor()
        out.append("field editor is BarEditor: \(ed is BarEditor), accepts file drops: \((ed as? NSTextView)?.registeredDraggedTypes.contains(.fileURL) ?? false)")
        ed?.insertText("ifp syllabus")
        wait(1.5) {
            out.append("typed “ifp syllabus” -> field “\(self.field.stringValue)”, top row \(first())")
            self.field.stringValue = ""
            // the same call the field editor, the rows and the background make when something is dropped on them
            let pb = NSPasteboard(name: NSPasteboard.Name("semantic.selftest"))
            pb.clearContents()
            pb.writeObjects([URL(fileURLWithPath: file) as NSURL])
            out.append("drop accepted: \(Drops.accept(pb)), attached: \(self.chips.map { ($0 as NSString).lastPathComponent })")
            self.field.currentEditor()?.insertText("what does this say")
            wait(1.0) {
                out.append("typed “what does this say” -> rows: " + self.hits.map { "\($0.tag): \($0.title)" }.joined(separator: " | "))
                // image data with no file behind it (dragged out of a web page)
                self.chips = []
                self.field.stringValue = ""
                pb.clearContents()
                if let img = NSImage(contentsOfFile: file) { pb.writeObjects([img]) }
                out.append("image-data drop accepted: \(Drops.accept(pb)), attached: \(self.chips.map { ($0 as NSString).lastPathComponent })")
                // a path that lands in the text is lifted out of it
                self.chips = []
                self.field.stringValue = ""
                self.field.currentEditor()?.insertText(file + " answer this")
                wait(1.0) {
                    out.append("path typed into the text -> attached: \(self.chips.map { ($0 as NSString).lastPathComponent }), text “\(self.field.stringValue)”, top row \(first())")
                    self.panel.orderOut(nil)
                    report(out)
                }
            }
        }
    }

    // MARK: results

    func refresh() {
        if pinned { return }
        let text = field.stringValue, files = chips
        Engine.shared.search(text, chips: files) { [weak self] r in
            guard let self, !self.pinned, self.field.stringValue == text, self.chips == files else { return }
            self.apply(r)
        }
    }

    private func apply(_ r: SearchResult) {
        hits = r.hits
        note = r.note
        table.reloadData()
        resize()
        if !hits.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        scheduleRefine()
    }

    // rows that the language model can improve are replaced in place once the user pauses typing
    private func scheduleRefine() {
        refineTimer?.invalidate()
        guard let idx = hits.firstIndex(where: { $0.refine != nil }), let refine = hits[idx].refine else { return }
        let text = field.stringValue, files = chips
        refineTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            refine { new in
                guard let self, let new, self.field.stringValue == text, self.chips == files, idx < self.hits.count else { return }
                let selected = self.table.selectedRow
                if new.promote {
                    // the model worked out what the sentence is about: that reading goes first
                    self.hits.remove(at: idx)
                    self.hits.insert(new, at: 0)
                    self.table.reloadData()
                    self.table.selectRowIndexes([selected <= 0 ? 0 : min(selected + (idx > selected ? 1 : 0), self.hits.count - 1)], byExtendingSelection: false)
                    self.resize()
                    return
                }
                self.hits[idx] = new
                self.table.reloadData()
                self.table.selectRowIndexes([max(0, selected)], byExtendingSelection: false)
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        pinned = false
        if let (path, rest) = Self.pathInText(field.stringValue) {
            attach(chips + [path])
            field.stringValue = rest
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): activate(alt: false)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        case #selector(NSResponder.insertTab(_:)):
            // put the selected file into the bar, to act on it
            let r = table.selectedRow
            if r >= 0, r < hits.count, let p = hits[r].path { attach([p]) }
        case #selector(NSResponder.deleteBackward(_:)):
            guard field.stringValue.isEmpty, !chips.isEmpty else { return false }
            chips = []
            pinned = false
            refresh()
        default: return false
        }
        return true
    }

    private func move(_ d: Int) {
        guard !hits.isEmpty else { return }
        let r = max(0, min(hits.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func clicked() { activate(alt: NSEvent.modifierFlags.contains(.command)) }

    private func activate(alt: Bool) {
        let r = table.selectedRow
        guard r >= 0, r < hits.count else { return }
        let h = hits[r]
        if let key = h.key, chips.isEmpty { Engine.shared.recordPick(field.stringValue, key) }
        if !h.stay { hide() }
        h.run(alt)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? RowView ?? RowView(frame: .zero)
        v.identifier = id
        let h = hits[row]
        v.title.stringValue = h.title
        v.subtitle.stringValue = h.subtitle
        v.tagLabel.stringValue = h.tag
        switch h.icon {
        case .symbol(let name):
            v.icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            v.icon.symbolConfiguration = .init(pointSize: 19, weight: .regular)
            v.icon.contentTintColor = .secondaryLabelColor
        case .file(let path):
            v.icon.contentTintColor = nil
            v.icon.image = thumbs.object(forKey: path as NSString) ?? NSWorkspace.shared.icon(forFile: path)
            let k = Extract.kind(ext: (path as NSString).pathExtension.lowercased())
            if [.image, .video, .doc].contains(k), thumbs.object(forKey: path as NSString) == nil { thumbnail(path) }
        }
        return v
    }

    private func thumbnail(_ path: String) {
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 60, height: 60),
                                               scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbs.setObject(img, forKey: path as NSString)
                for (i, h) in self.hits.enumerated() {
                    if case .file(let p) = h.icon, p == path {
                        self.table.reloadData(forRowIndexes: [i], columnIndexes: [0])
                    }
                }
            }
        }
    }
}

```
