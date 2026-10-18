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
    static var receivingChanged: ((UUID, Bool) -> Void)?
    static var generation = 0

    static func accept(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            handler?(urls.map(\.path))
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = URL(fileURLWithPath: Paths.tmp)
            let receipt = UUID(), acceptedGeneration = generation
            receivingChanged?(receipt, true)
            var got: [String] = []
            var remaining = promises.reduce(0) { $0 + max(1, $1.fileNames.count) }
            var failures = 0
            var finished = false
            Toast.show("Receiving dropped files…", sticky: true)
            func finish(timedOut: Bool = false) {
                guard !finished else { return }
                finished = true
                receivingChanged?(receipt, false)
                guard acceptedGeneration == generation else { return }
                if !got.isEmpty { handler?(got) }
                if timedOut || failures > 0 {
                    Toast.show("Some dropped files could not be received. Your request is kept; try the drop again.", seconds: 7)
                } else { Toast.show("\(got.count) file\(got.count == 1 ? "" : "s") attached") }
            }
            for p in promises {
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    guard !finished else { return }
                    if error == nil { got.append(url.path) } else { failures += 1 }
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(timedOut: true) }
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

final class ResultSelectionView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 12, yRadius: 12).fill()
    }
}

final class RowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let excerpt = NSTextField(labelWithString: "")
    let tagLabel = NSTextField(labelWithString: "")
    var isFile = false
    var hasExcerpt = false
    var pending = false
    var unavailable = false
    var label = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.lineBreakMode = .byTruncatingMiddle
        excerpt.font = .systemFont(ofSize: 12)
        excerpt.lineBreakMode = .byTruncatingTail
        tagLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tagLabel.alignment = .right
        for v in [icon, title, subtitle, excerpt, tagLabel] { addSubview(v) }
        imageView = icon
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ selected: Bool) {
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        subtitle.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.88) : .secondaryLabelColor
        excerpt.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.95) : .secondaryLabelColor
        tagLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        tagLabel.stringValue = unavailable ? "Unavailable" : pending ? "…" : selected ? "↩" : label
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let size: CGFloat = isFile ? 32 : 22
        icon.frame = NSRect(x: 16, y: (h - size) / 2, width: size, height: size)
        tagLabel.frame = NSRect(x: w - 96, y: (h - 16) / 2, width: 78, height: 16)
        let x: CGFloat = 60, contentWidth = w - x - 104
        title.font = .systemFont(ofSize: isFile ? 15 : 13, weight: isFile ? .medium : .regular)
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

// The attached file(s), shown as a pill in front of the text.
final class ChipView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    var onRemove: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon)
        addSubview(label)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove attached files")
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeFiles)
        removeButton.toolTip = "Remove attached files. Backspace also removes them when the field is empty."
        removeButton.setAccessibilityLabel("Remove attached files")
        addSubview(removeButton)
    }

    @objc private func removeFiles() { onRemove?() }
    required init?(coder: NSCoder) { fatalError() }

    // returns the width the chip wants
    func set(_ files: [String]) -> CGFloat {
        guard let first = files.first else { return 0 }
        icon.image = NSWorkspace.shared.icon(forFile: first)
        label.stringValue = files.count == 1 ? (first as NSString).lastPathComponent : "\(files.count) files"
        let w = min(230, label.intrinsicContentSize.width + 4)
        icon.frame = NSRect(x: 7, y: 5, width: 20, height: 20)
        label.frame = NSRect(x: 31, y: 6, width: w, height: 18)
        removeButton.frame = NSRect(x: w + 35, y: 5, width: 20, height: 20)
        toolTip = files.map { Paths.tilde($0) }.joined(separator: "\n")
        return w + 61
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
            fx.layer?.cornerRadius = 19
            fx.layer?.cornerCurve = .continuous
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
    private let width: CGFloat = 900, fieldH: CGFloat = 72, rowH: CGFloat = 64, footerH: CGFloat = 36, maxRows = 8
    private let panel: BarPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let preview = FilePreview(frame: .zero)
    private let previewRule = NSBox()
    private let footer = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let scope = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private let closeHint = NSTextField(labelWithString: "esc  Close")
    private let clearButton = NSButton()
    private let topRule = NSBox()
    private let bottomRule = NSBox()
    private var appliedQuery = ""
    private var appliedChips: [String] = []
    private var selectionSuppressed = false
    private var resultVersion = 0
    private var searchRequest = 0
    private var searching = false
    private var resultsCurrent: Bool { !searching && appliedQuery == field.stringValue && appliedChips == chips }
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
    private var draggingOut = false
    private var pinned = false // showing results that are not a function of the text (similar-to)

    private var receivingDrops = Set<UUID>()
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
        Drops.receivingChanged = { [weak self] receipt, receiving in
            guard let self else { return }
            if receiving { self.receivingDrops.insert(receipt); self.dropped = true }
            else { self.receivingDrops.remove(receipt) }
        }
        Drops.handler = { [weak self] paths in
            guard let self else { return }
            self.dropped = true
            let typed = self.field.stringValue
            self.attach(paths, preservingQuery: true, appending: true)
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
        fx.layer?.cornerRadius = 26
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        panel.contentView = fx

        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glyph.contentTintColor = .secondaryLabelColor
        fx.addSubview(glyph)
        chip.isHidden = true
        fx.addSubview(chip)
        chip.onRemove = { [weak self] in
            guard let self else { return }
            self.chips = []; self.pinned = false
            self.refresh()
            self.panel.makeFirstResponder(self.field)
        }

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = ""
        field.setAccessibilityLabel("Search files or ask a question")
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
        table.action = #selector(selectedByClick)
        table.doubleAction = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Search results, up to five files")
        table.registerForDraggedTypes(Drops.types)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        fx.addSubview(scroll)
        previewRule.boxType = .separator
        fx.addSubview(previewRule)
        fx.addSubview(preview)
        preview.onOpen = { [weak self] hit, alt in
            guard let self, self.resultsCurrent else { return }
            if let key = hit.key, self.chips.isEmpty { Engine.shared.recordPick(self.field.stringValue, key) }
            self.hide()
            hit.run(alt)
        }
        preview.onAttach = { [weak self] path in
            guard let self, self.resultsCurrent else { return }
            self.attach([path])
            self.panel.makeFirstResponder(self.field)
        }
        preview.onCopy = { [weak self] in self?.copySelectedFile() }
        preview.onDrag = { [weak self] active, operation in
            guard let self else { return }
            self.draggingOut = active
            if active { self.mouseTimer?.invalidate(); self.refineTimer?.invalidate() }
            else if operation.isEmpty { self.refresh() } else { self.hide() }
        }

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .labelColor.withAlphaComponent(0.8)
        summary.font = .systemFont(ofSize: 11.5, weight: .medium)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor
        scope.alignment = .right
        scope.lineBreakMode = .byTruncatingMiddle
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        closeHint.font = .systemFont(ofSize: 11)
        closeHint.textColor = .secondaryLabelColor
        closeHint.alignment = .right
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search")
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.toolTip = "Clear search"
        clearButton.setAccessibilityLabel("Clear search")
        topRule.boxType = .separator
        bottomRule.boxType = .separator
        for v in [footer, summary, scope, empty, closeHint, clearButton, topRule, bottomRule] { fx.addSubview(v) }

        // shortcuts that never reach the field editor as ordinary commands
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isKeyWindow, ev.modifierFlags.contains(.command) else { return ev }
            switch ev.keyCode {
            case 36: self.activate(alt: true); return nil            // ⌘↩ reveal
            case 8:
                // Command-C still copies a selected range of text. Shift-Command-C always copies the file.
                let selection = (self.panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0
                if ev.modifierFlags.contains(.shift) || selection == 0 {
                    if self.copySelectedFile() { return nil }
                }
                return ev
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
        let front = NSWorkspace.shared.frontmostApplication
        // what is in front shapes what is likely wanted next, and is never itself suggested
        Habits.shared.setContext(front?.bundleURL?.path)
        resize()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // opened over Finder with something selected: that selection is what the user wants to act on
        if front?.bundleIdentifier == "com.apple.finder", config.finderSelection != false { attachFinderSelection() }
        // with nothing typed, habit fills the list: ⌘Y then Return opens the likeliest thing
        refresh()
    }

    func hide() {
        let wasVisible = panel.isVisible
        Drops.generation += 1
        receivingDrops.removeAll()
        panel.orderOut(nil)
        preview.show(nil)
        refineTimer?.invalidate()
        field.stringValue = ""
        chips = []
        hits = []
        note = ""
        searching = false
        appliedQuery = ""
        appliedChips = []
        selectionSuppressed = false
        searchRequest += 1
        resultVersion += 1
        pinned = false
        table.reloadData()
        if wasVisible { onHide?() }
    }

    // A click elsewhere closes the bar, but a press that turns into a drag must be able to land on it:
    // while the button is held the bar stays, and it closes on release unless something was dropped.
    func windowDidResignKey(_ notification: Notification) {
        if draggingOut || !receivingDrops.isEmpty { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return hide() }
        dropped = false
        mouseTimer?.invalidate()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self, !self.dropped, self.receivingDrops.isEmpty, !self.panel.isKeyWindow else { return }
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

    // Real file URLs let Finder, mail composers, browsers and editors negotiate ordinary file drops.
    // Copy semantics preserve the indexed original; action rows never become drag sources.
    static func dragWriter(_ hit: Hit) -> NSPasteboardWriting? {
        guard let path = hit.path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard resultsCurrent, hits.indices.contains(row) else { return nil }
        return Self.dragWriter(hits[row])
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggingOut = true
        mouseTimer?.invalidate()
        refineTimer?.invalidate()
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingOut = false
        if operation.isEmpty { refresh() } else { hide() }
    }

    // drops that land on the result rows
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation { .copy }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        Drops.accept(info.draggingPasteboard)
    }

    // A completed pasted path can be lifted out of the text. Ordinary typing stays searchable.
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

    private func height(_ hit: Hit) -> CGFloat { hit.path == nil && hit.excerpt.isEmpty ? 46 : rowH }

    @objc private func clearSearch() {
        field.stringValue = ""
        pinned = false
        panel.makeFirstResponder(field)
        refresh()
    }

    private func resize() {
        let hasRows = !hits.isEmpty
        let idle = !hasRows && field.stringValue.isEmpty && chips.isEmpty && !searching && note.isEmpty
        let headerH: CGFloat = hasRows || !field.stringValue.isEmpty || searching || !note.isEmpty ? 30 : 0
        let selected = table.selectedRow
        let hasPreview = hits.indices.contains(selected) && hits[selected].path != nil
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let desiredList = hasRows ? hits.prefix(maxRows).reduce(CGFloat(0)) { $0 + height($1) } + 8 : 48
        let listH = idle ? 0 : min(max(hasPreview ? 370 : 0, desiredList), max(220, available - fieldH - headerH - footerH - 80))
        let h = fieldH + headerH + listH + (idle ? 0 : footerH)
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - h, width: width, height: h), display: true)
        glyph.frame = NSRect(x: 22, y: h - fieldH + 24, width: 24, height: 24)
        let chipW = chip.set(chips)
        chip.isHidden = chips.isEmpty
        chip.frame = NSRect(x: 58, y: h - fieldH + 21, width: chipW, height: 30)
        let x = 58 + (chips.isEmpty ? 0 : chipW + 10)
        field.frame = NSRect(x: x, y: h - fieldH + 20, width: width - x - 60, height: 32)
        field.placeholderString = ""
        clearButton.frame = NSRect(x: width - 48, y: h - fieldH + 22, width: 28, height: 28)
        clearButton.isHidden = field.stringValue.isEmpty
        topRule.frame = NSRect(x: 0, y: h - fieldH, width: width, height: 1)
        bottomRule.frame = NSRect(x: 0, y: footerH, width: width, height: 1)
        topRule.isHidden = idle
        bottomRule.isHidden = idle
        footer.isHidden = idle
        closeHint.isHidden = idle
        scroll.frame = NSRect(x: 8, y: footerH + 4, width: hasPreview ? 396 : width - 16, height: max(0, listH - 8))
        scroll.hasVerticalScroller = desiredList > listH
        previewRule.frame = NSRect(x: 411, y: footerH, width: 1, height: listH)
        previewRule.isHidden = !hasPreview
        preview.frame = NSRect(x: 412, y: footerH, width: width - 412, height: listH)
        updatePreview()
        scroll.isHidden = !hasRows
        let files = hits.filter { $0.path != nil }.count
        summary.stringValue = searching ? "Searching…" : files > 0 ? "\(files) file match\(files == 1 ? "" : "es")" : (hasRows ? "Actions" : "No matching files")
        if !note.isEmpty { summary.stringValue += " · " + note }
        if hasRows, field.stringValue.isEmpty, chips.isEmpty, !pinned { summary.stringValue = "Suggested for now · type to search" }
        summary.frame = NSRect(x: 22, y: h - fieldH - 23, width: width - 280, height: 16)
        scope.stringValue = status.isEmpty ? "On this Mac" : status
        scope.frame = NSRect(x: width - 250, y: h - fieldH - 23, width: 228, height: 16)
        summary.isHidden = headerH == 0
        scope.isHidden = headerH == 0
        empty.stringValue = searching ? (note.isEmpty ? "Searching…" : note) : !note.isEmpty ? note : "No matching files"
        empty.frame = NSRect(x: 22, y: footerH + 16, width: width - 44, height: 18)
        empty.isHidden = hasRows || idle
        updateHints()
        footer.frame = NSRect(x: 22, y: 11, width: width - 120, height: 15)
        closeHint.frame = NSRect(x: width - 98, y: 11, width: 76, height: 15)
    }

    private func updateHints() {
        let selected = table.selectedRow
        let isFile = selected >= 0 && selected < hits.count && hits[selected].path != nil
        footer.stringValue = hits.isEmpty ? "⌘Y  Show / hide     ·     Drop a file to ask about it" :
            (isFile ? "↑↓  Navigate    ↩  Open    ⌘↩  Reveal    ⇥  Add to bar    ⇧⌘C  Copy file    Drag to share" : "↑↓  Navigate     ↩  Run action")
        if !hits.isEmpty, selected < 0 { footer.stringValue = "↑↓  Select a result" }
        if hits.indices.contains(selected), hits[selected].isPending { footer.stringValue = "Working out your request…     esc  Cancel" }
        if hits.indices.contains(selected), let reason = hits[selected].unavailableReason { footer.stringValue = reason }
        for i in 0..<hits.count {
            (table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowView)?.select(i == selected)
        }
    }

    private func updatePreview() {
        let selected = table.selectedRow
        let hit = resultsCurrent && hits.indices.contains(selected) && hits[selected].path != nil ? hits[selected] : nil
        preview.show(hit)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { resize() }
    @objc private func selectedByClick() {
        updatePreview()
        panel.makeFirstResponder(field)
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(hits[row]) }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultSelectionView() }

    // MARK: attaching files

    func attach(_ files: [String], preservingQuery: Bool = false, appending: Bool = false) {
        let real = ((appending ? chips : []) + files).filter { !$0.isEmpty }
        guard !real.isEmpty else { return }
        var seen = Set<String>()
        chips = real.filter { seen.insert($0).inserted }
        pinned = false
        if !preservingQuery { field.stringValue = "" }
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try p.run() } catch { return }
            // Drain while running: waiting for termination first deadlocks large selections.
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return }
            let paths = out.split(separator: "\n").map { s -> String in
                let t = String(s)
                return t.count > 1 && t.hasSuffix("/") ? String(t.dropLast()) : t
            }
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible, self.chips.isEmpty, self.field.stringValue.isEmpty, !paths.isEmpty else { return }
                self.attach(paths)
            }
        }
    }

    // file references on a pasteboard, or failing that an image on it saved to a temporary PNG
    static func files(from pb: NSPasteboard, imageEvenWithText: Bool) -> [String] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        guard imageEvenWithText || pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let path = Paths.tmp + "/Pasted image \(UUID().uuidString).png"
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil ? [path] : []
    }

    // ⌘V: files copied in Finder, or an image copied from anywhere, become the attached file
    private func pasteFiles() -> Bool {
        let paths = Self.files(from: .general, imageEvenWithText: false)
        if !paths.isEmpty { attach(paths, preservingQuery: true, appending: true) }
        else if let text = NSPasteboard.general.string(forType: .string), let (path, rest) = Self.pathInText(text) {
            let editor = field.currentEditor() as? NSTextView
            if let editor { editor.insertText(rest, replacementRange: editor.selectedRange()) }
            else { field.stringValue += rest }
            attach([path], preservingQuery: true, appending: true)
            return true
        }
        return !paths.isEmpty
    }

    func showSimilar(to file: String) {
        if chips != [file] { chips = [file] }
        field.stringValue = ""
        pinned = true
        searching = true
        resultVersion += 1
        let version = resultVersion
        refineTimer?.invalidate()
        note = "Looking for similar files…"
        hits = []
        table.reloadData()
        resize()
        Engine.shared.similar(to: file) { [weak self] r in
            guard let self, self.pinned, self.resultVersion == version, self.chips == [file] else { return }
            self.apply(r)
        }
    }

    private func quickLook() {
        guard resultsCurrent else { return }
        let r = table.selectedRow
        let target = r >= 0 && r < hits.count ? hits[r].path : nil
        guard let path = target ?? chips.first else { return }
        hide()
        Sys.shell("/usr/bin/qlmanage", ["-p", path])
    }

    // Exercises the real controls without any synthetic input (`SemBar --selftest file`): typing through the
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
            let pb = NSPasteboard(name: NSPasteboard.Name("sembar.selftest"))
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
                // A typed path remains searchable until explicitly attached.
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

    #if SEARCH_TESTS
    static func verifyInteractions(file: String) -> [(String, Bool)] {
        _ = NSApplication.shared
        let bar = BarController()
        bar.panel.inert = true
        bar.top = 800
        var opened = 0
        let hit = Hit(title: "Fixture", subtitle: "", icon: .file(file), tag: "Document", path: file) { _ in opened += 1 }
        bar.field.stringValue = "fixture"
        bar.apply(SearchResult(hits: [hit]))
        bar.selectedByClick()
        var out = [("single click selects without opening the file", opened == 0)]
        bar.field.stringValue = "different query"
        bar.activate(alt: false)
        bar.preview.onOpen?(hit, false)
        bar.preview.onAttach?(file)
        out.append(("changed query disables stale Return preview-open and attachment", opened == 0 && bar.chips.isEmpty))
        bar.field.stringValue = "fixture"
        bar.apply(SearchResult(hits: [hit]))
        _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        out.append(("Tab attaches the selected result and clears the search", bar.chips == [file] && bar.field.stringValue.isEmpty))
        bar.field.stringValue = "summarize this"
        bar.attach([file], preservingQuery: true, appending: true)
        out.append(("adding pasted or dropped files preserves request and deduplicates chips", bar.field.stringValue == "summarize this" && bar.chips == [file]))
        let unavailable = file + ".unavailable"
        bar.chips = [unavailable]
        bar.attach([file], preservingQuery: true, appending: true)
        out.append(("adding a file retains unavailable explicit attachments for recovery", bar.chips == [unavailable, file] && bar.field.stringValue == "summarize this"))
        bar.chip.onRemove?()
        out.append(("attachment remove button preserves typed request", bar.chips.isEmpty && bar.field.stringValue == "summarize this"))
        bar.field.stringValue = "/Users"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        out.append(("typing a parent directory never consumes an unfinished path", bar.chips.isEmpty && bar.field.stringValue == "/Users"))
        bar.field.stringValue = "fixture"
        bar.apply(SearchResult(hits: [hit]))
        let replacement = Hit(title: "Other file", subtitle: "", icon: .symbol("doc"), tag: "Document", key: "different", path: file) { _ in opened += 100 }
        bar.apply(SearchResult(hits: [replacement]))
        bar.activate(alt: false)
        out.append(("refinement never silently selects a replacement when the selected result disappears", bar.table.selectedRow == -1 && opened == 0))
        bar.apply(SearchResult(hits: [replacement]))
        bar.activate(alt: false)
        out.append(("later callbacks preserve deselection after a result disappears", bar.table.selectedRow == -1 && opened == 0))
        bar.apply(SearchResult(hits: []))
        bar.apply(SearchResult(hits: [replacement]))
        out.append(("deselection survives an intervening empty callback", bar.table.selectedRow == -1))
        bar.restoreSelection(Self.selectionAfterPromotion(selected: -1, promoted: 0))
        out.append(("row refinement and promotion preserve deselection", bar.table.selectedRow == -1))
        bar.field.stringValue = "fixture again"
        bar.apply(SearchResult(hits: [hit]))
        bar.activate(alt: false)
        out.append(("Return activates the current selected file", opened == 1))
        bar.field.stringValue = "explain"
        let originalAsk = Assistant.hit("explain", files: [file])
        bar.apply(SearchResult(hits: [originalAsk]))
        bar.apply(SearchResult(hits: [Assistant.hit("explain", files: [file + ".other"])]))
        out.append(("Ask loses selection when refinement changes its attachment list", bar.table.selectedRow == -1))
        bar.apply(SearchResult(hits: [originalAsk]))
        bar.restoreSelection(0)
        bar.apply(SearchResult(hits: [Assistant.hit("explain", files: [file])]))
        out.append(("Ask keeps selection when its question files and destination are unchanged", bar.table.selectedRow == 0))
        bar.field.stringValue = "Keep this promised-file question"
        let receipt = UUID()
        Drops.receivingChanged?(receipt, true)
        bar.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        out.append(("promised-file receipt preserves the request through focus loss", bar.field.stringValue == "Keep this promised-file question" && bar.receivingDrops.contains(receipt)))
        Drops.receivingChanged?(receipt, false)
        bar.searching = true
        let oldRequest = bar.searchRequest
        bar.hide()
        bar.resize()
        out.append(("dismissed search resets to a blank compact bar and invalidates callbacks", !bar.searching && bar.searchRequest != oldRequest && bar.panel.frame.height == bar.fieldH && bar.empty.isHidden && bar.footer.isHidden))
        bar.preview.show(nil)
        return out
    }
    #endif

    // MARK: results

    func refresh() {
        if pinned { return }
        let text = field.stringValue, files = chips
        searchRequest += 1
        let request = searchRequest
        if appliedQuery != text || appliedChips != files {
            searching = true
            resultVersion += 1
            refineTimer?.invalidate()
            hits = []; note = ""
            table.reloadData()
            preview.show(nil)
            resize()
        }
        Engine.shared.search(text, chips: files) { [weak self] r in
            guard let self, self.searchRequest == request, !self.pinned, self.field.stringValue == text, self.chips == files else { return }
            self.apply(r)
        }
    }

    private func apply(_ r: SearchResult) {
        guard !draggingOut else { return }
        searching = false
        let sameQuery = appliedQuery == field.stringValue && appliedChips == chips
        let oldIndex = table.selectedRow
        let previous = sameQuery && oldIndex >= 0 && oldIndex < hits.count ? hits[oldIndex].selectionIdentity : nil
        if !sameQuery || previous != nil { selectionSuppressed = false }
        else if !hits.isEmpty { selectionSuppressed = true }
        resultVersion += 1
        hits = r.hits
        note = r.note
        appliedQuery = field.stringValue
        appliedChips = chips
        table.reloadData()
        if !hits.isEmpty {
            if let previous, let selected = hits.firstIndex(where: { $0.selectionIdentity == previous }) {
                table.selectRowIndexes([selected], byExtendingSelection: false)
                table.scrollRowToVisible(selected)
            } else if previous != nil {
                selectionSuppressed = true
                table.deselectAll(nil)
            } else if !selectionSuppressed {
                table.selectRowIndexes([0], byExtendingSelection: false)
                table.scrollRowToVisible(0)
            } else {
                table.deselectAll(nil)
            }
        } else if previous != nil {
            selectionSuppressed = true
        }
        resize()
        scheduleRefine()
    }

    static func selectionAfterPromotion(selected: Int, promoted: Int) -> Int {
        if selected < 0 { return -1 }
        if selected == promoted { return 0 }
        return selected < promoted ? selected + 1 : selected
    }

    private func restoreSelection(_ index: Int) {
        if hits.indices.contains(index) { table.selectRowIndexes([index], byExtendingSelection: false) }
        else { table.deselectAll(nil) }
    }

    // rows that the language model can improve are replaced in place once the user pauses typing
    private func scheduleRefine() {
        refineTimer?.invalidate()
        guard let idx = hits.firstIndex(where: { $0.refine != nil }), let refine = hits[idx].refine else { return }
        let text = field.stringValue, files = chips, version = resultVersion
        refineTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            refine { new in
                guard let self, let new, self.resultVersion == version, self.field.stringValue == text, self.chips == files, idx < self.hits.count else { return }
                guard !self.draggingOut else { return }
                let selected = self.table.selectedRow
                if new.promote {
                    // the model worked out what the sentence is about: that reading goes first
                    self.hits.remove(at: idx)
                    self.hits.insert(new, at: 0)
                    self.table.reloadData()
                    self.restoreSelection(Self.selectionAfterPromotion(selected: selected, promoted: idx))
                    self.resize()
                    return
                }
                self.hits[idx] = new
                self.table.reloadData()
                self.restoreSelection(selected)
                self.resize()
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        pinned = false
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
            if resultsCurrent, r >= 0, r < hits.count, let p = hits[r].path { attach([p]) }
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

    @discardableResult private func copySelectedFile() -> Bool {
        let row = table.selectedRow
        guard resultsCurrent, hits.indices.contains(row), let writer = Self.dragWriter(hits[row]) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([writer])
        Toast.show("File copied · paste it into another app")
        return true
    }

    @objc private func clicked() { activate(alt: NSEvent.modifierFlags.contains(.command)) }

    private func activate(alt: Bool) {
        guard resultsCurrent else { return }
        let r = table.selectedRow
        guard r >= 0, r < hits.count else { return }
        let h = hits[r]
        guard !h.isPending, h.unavailableReason == nil else { return }
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
        v.excerpt.stringValue = h.excerpt
        v.hasExcerpt = !h.excerpt.isEmpty
        v.isFile = h.path != nil
        v.label = h.tag
        v.pending = h.isPending
        v.unavailable = h.unavailableReason != nil
        v.select(row == table.selectedRow)
        v.setAccessibilityElement(true)
        v.setAccessibilityLabel(h.title + ", " + h.subtitle + (h.excerpt.isEmpty ? "" : ", " + h.excerpt))
        v.toolTip = h.path ?? h.subtitle
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
