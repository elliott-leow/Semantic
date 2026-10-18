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
                    Toast.show("⚠ Some dropped files could not be received. Your request is kept; try the drop again.", seconds: 7)
                } else { Toast.show("✓ \(got.count) file\(got.count == 1 ? "" : "s") attached") }
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
    var onResize: (() -> Void)?   // every step of an animated resize, so the layout follows the frame
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Drops.types)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
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
        setAccessibilityLabel("Attached: " + label.stringValue)
        return w + 61
    }
}

// menu items that run a closure
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class BarController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let width: CGFloat = 900, fieldH: CGFloat = 72, rowH: CGFloat = 64, footerH: CGFloat = 36, maxRows = 8
    private let listW: CGFloat = 396, splitMinH: CGFloat = 370
    private let panel: BarPanel
    private let field = NSTextField()
    private let table = ResultTable()
    private let scroll = NSScrollView()
    private let preview = FilePreview(frame: .zero)
    private let previewRule = NSBox()
    private let footer = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let scope = NSTextField(labelWithString: "")
    private let ring = ProgressRing(frame: .zero)
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
    private var chipW: CGFloat = 0
    private var hits: [Hit] = []     // in display order: grouped by section, sections in order of their best row
    private var note = ""
    private var top: CGFloat = 0
    private let thumbs = NSCache<NSString, NSImage>()
    private var monitor: Any?
    private var flagsMonitor: Any?
    private var refineTimer: Timer?
    private var dimTimer: Timer?
    private var announceTimer: Timer?
    private var commandTimer: Timer?
    private var dropped = false
    private var mouseTimer: Timer?
    private var draggingOut = false
    private var pinned = false // showing results that are not a function of the text (similar-to)

    // table rows: section headers, results, and the "Show all files" row
    private enum Line: Equatable { case header(String), hit(Int), more }
    private var lines: [Line] = []
    private var grouped = false
    private var cursor = -1          // the row the keyboard is on; with several selected, the one previewed
    private var anchor = -1          // where a ⇧ extension started
    private var extending = false
    private var commandHeld = false  // ⌘ held: rows show ⌘1…⌘9
    private var optionHeld = false   // ⌥ held: rows show how they were scored
    // the laid-out state that animated resizes keep following
    private var idle = true, split = false, headerH: CGFloat = 0, listH: CGFloat = 0

    // "Show all files": the engine caps files at five; this hook returns the rest for (query, attachments).
    var loadMore: ((_ query: String, _ chips: [String], _ done: @escaping ([Hit]) -> Void) -> Void)?
    private var expandedFor: String?
    private var expandedHits: [Hit] = []

    // previous queries for ↑ on an empty field, and the last search for reopening within 10 s
    private var history: [String] = BarController.loadHistory()
    private var historyPos: Int?
    private var lastSession: (text: String, identity: String?, at: Date)?
    private var restoreIdentity: String?

    private var receivingDrops = Set<UUID>()
    private(set) var chips: [String] = []
    var status = "" { didSet { if panel.isVisible { resize() } } }
    // determinate indexing progress; when nil, a "stage 25/7000" or JSON status string is read instead
    var progress: (done: Int, total: Int, eta: Double?)? { didSet { if panel.isVisible { resize() } } }
    var isVisible: Bool { panel.isVisible }
    var onHide: (() -> Void)?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
        fx.layer?.cornerRadius = 22
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
        field.setAccessibilityLabel("Search files or ask a question")
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        fx.addSubview(field)
        updatePlaceholder()

        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowH
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectedByClick)
        table.doubleAction = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Search results")
        table.registerForDraggedTypes(Drops.types)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.onHover = { [weak self] row in self?.hover(row) }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.wantsLayer = true
        fx.addSubview(scroll)
        previewRule.boxType = .separator
        fx.addSubview(previewRule)
        fx.addSubview(preview)
        preview.onOpen = { [weak self] hit, alt in
            guard let self, self.resultsCurrent else { return }
            if let key = hit.key, self.chips.isEmpty { Engine.shared.recordPick(self.field.stringValue, key) }
            if self.chips.isEmpty { self.remember(self.field.stringValue) }
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
        footer.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 11.5, weight: .medium)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor
        scope.alignment = .right
        scope.lineBreakMode = .byTruncatingMiddle
        ring.isHidden = true
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
        for v in [footer, summary, scope, ring, empty, closeHint, clearButton, topRule, bottomRule] { fx.addSubview(v) }
        fx.onResize = { [weak self] in self?.layoutContent() }

        // shortcuts that never reach the field editor as ordinary commands
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isKeyWindow, ev.modifierFlags.contains(.command) else { return ev }
            let others = ev.modifierFlags.intersection([.shift, .option, .control])
            if others.isEmpty, let c = ev.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
                self.openNth(n); return nil                          // ⌘1…⌘9 open that row
            }
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
            case 40: self.actionMenu(); return nil                   // ⌘K actions for the selected file
            case 6 where others.isEmpty && self.field.stringValue.isEmpty: // ⌘Z undoes the last rename, move or trash
                return UndoStack.shared.undoLast() ? nil : ev
            case 125 where self.canLoadMore: self.expand(); return nil // ⌘↓ show all files
            default: return ev
            }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            self?.modifiersChanged(ev.modifierFlags)
            return ev
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
        let overFinder = front?.bundleIdentifier == "com.apple.finder" && config.finderSelection != false
        // reopened right after closing: the same search, with the same row selected, ready to be typed over
        var restored = false
        if let s = lastSession, Date().timeIntervalSince(s.at) < 10, !overFinder, field.stringValue.isEmpty, chips.isEmpty {
            field.stringValue = s.text
            restoreIdentity = s.identity
            restored = true
        }
        lastSession = nil
        // what is in front shapes what is likely wanted next, and is never itself suggested
        Habits.shared.setContext(front?.bundleURL?.path)
        resize()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if restored { field.currentEditor()?.selectAll(nil) }
        // opened over Finder with something selected: that selection is what the user wants to act on
        if overFinder { attachFinderSelection() }
        // with nothing typed, habit fills the list: ⌘Y then Return opens the likeliest thing
        refresh()
    }

    func hide() {
        let wasVisible = panel.isVisible
        if !field.stringValue.isEmpty, chips.isEmpty, !pinned {
            lastSession = (field.stringValue, selectedHit?.selectionIdentity, Date())
        }
        Drops.generation += 1
        receivingDrops.removeAll()
        panel.orderOut(nil)
        preview.show(nil)
        refineTimer?.invalidate()
        dimTimer?.invalidate()
        announceTimer?.invalidate()
        commandTimer?.invalidate()
        commandHeld = false
        optionHeld = false
        setDim(false)
        field.stringValue = ""
        chips = []
        hits = []
        lines = []
        cursor = -1; anchor = -1
        note = ""
        searching = false
        appliedQuery = ""
        appliedChips = []
        selectionSuppressed = false
        searchRequest += 1
        resultVersion += 1
        pinned = false
        expandedFor = nil; expandedHits = []
        historyPos = nil
        restoreIdentity = nil
        listH = 0
        table.reloadData()
        RelativeDate.forget()
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
        guard resultsCurrent, let i = hitIndex(row) else { return nil }
        return Self.dragWriter(hits[i])
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

    // MARK: rows

    static func group(_ h: Hit) -> String {
        if h.path != nil { return h.tag == Kind.app.label ? "Apps" : "Files" }
        switch h.tag {
        case "Web page", "URL": return "Web"
        case "Contact": return "Contacts"
        case "Note": return "Notes"
        case "Clipboard": return "Clipboard"
        case "Event" where h.key?.hasPrefix("event:") == true: return "Events"
        default: return "Actions"
        }
    }

    private func hitIndex(_ row: Int) -> Int? {
        guard lines.indices.contains(row), case .hit(let i) = lines[row] else { return nil }
        return i
    }
    private func row(of i: Int) -> Int? { lines.firstIndex(of: .hit(i)) }
    private func selectable(_ row: Int) -> Bool {
        guard lines.indices.contains(row) else { return false }
        if case .header = lines[row] { return false }
        return true
    }
    private func isFileRow(_ row: Int) -> Bool { hitIndex(row).map { hits[$0].path != nil } ?? false }
    private var primaryRow: Int {
        let s = table.selectedRowIndexes
        return s.count > 1 && s.contains(cursor) ? cursor : table.selectedRow
    }
    private var selectedIndex: Int? { hitIndex(primaryRow) }
    private var selectedHit: Hit? { selectedIndex.map { hits[$0] } }
    // every selected file; one row when only one is selected
    private var selectedFiles: [Hit] {
        let rows = table.selectedRowIndexes
        if rows.count > 1 { return rows.compactMap { hitIndex($0) }.map { hits[$0] }.filter { $0.path != nil } }
        return selectedHit.flatMap { $0.path != nil ? [$0] : nil } ?? []
    }

    // Sections follow their best row, so the top result stays on top; rows keep their order inside a section.
    @discardableResult private func regroup() -> [Int] {
        var order: [String] = []
        for h in hits where !order.contains(Self.group(h)) { order.append(Self.group(h)) }
        let perm = order.flatMap { g in hits.indices.filter { Self.group(hits[$0]) == g } }
        hits = perm.map { hits[$0] }
        return perm
    }

    private var canLoadMore: Bool {
        loadMore != nil && expandedFor != appliedQuery && !pinned && chips.isEmpty && !appliedQuery.isEmpty
            && hits.filter { $0.path != nil }.count >= SearchResult.fileLimit && hits.contains { Self.group($0) == "Files" }
    }

    private func rebuildLines() {
        var groups: [String] = []
        for h in hits where !groups.contains(Self.group(h)) { groups.append(Self.group(h)) }
        // one kind of result needs no heading: the summary line already names it
        grouped = groups.count > 1
        let more = canLoadMore
        lines = []
        var last: String?
        for (i, h) in hits.enumerated() {
            let g = Self.group(h)
            if g != last {
                if last == "Files", more { lines.append(.more) }
                if grouped { lines.append(.header(g)) }
                last = g
            }
            lines.append(.hit(i))
        }
        if last == "Files", more { lines.append(.more) }
    }

    private func height(_ l: Line) -> CGFloat {
        switch l {
        case .header: return 24
        case .more: return 34
        case .hit(let i): return hits[i].path == nil && hits[i].excerpt.isEmpty ? 46 : rowH
        }
    }

    private func selectRow(_ r: Int) {
        guard lines.indices.contains(r) else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        cursor = r; anchor = r
        table.scrollRowToVisible(r)
    }

    @objc private func clearSearch() {
        field.stringValue = ""
        pinned = false
        panel.makeFirstResponder(field)
        refresh()
    }

    private func updatePlaceholder() {
        let text = chips.isEmpty ? "Search files, apps, or ask…" : "Say what to do with \(chips.count == 1 ? "it" : "them")…"
        guard field.placeholderAttributedString?.string != text else { return }
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor])
    }

    private func resize() {
        let hasRows = !hits.isEmpty
        idle = !hasRows && field.stringValue.isEmpty && chips.isEmpty && !searching && note.isEmpty
        headerH = hasRows || !field.stringValue.isEmpty || searching || !note.isEmpty ? 30 : 0
        // with any file in the results the preview column stays for the whole set, so moving between
        // a file and an action never changes the list's width or the panel's height
        split = hits.contains { $0.path != nil }
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        var desiredList: CGFloat = 48
        if hasRows, table.numberOfRows == lines.count {
            // up to maxRows results with their headers, plus the inset table's own top and bottom padding
            var n = 0, last = 0
            for (r, l) in lines.enumerated() {
                if case .hit = l { if n == maxRows { break }; n += 1 }
                last = r
            }
            desiredList = table.rect(ofRow: last).maxY + table.rect(ofRow: 0).minY + 8
        }
        var list = idle ? 0 : min(max(split ? splitMinH : 0, desiredList), max(220, available - fieldH - headerH - footerH - 80))
        // while typing, the previous rows stay and the panel never shrinks; it settles when the new results arrive
        if searching, hasRows { list = max(list, listH) }
        listH = list
        let h = fieldH + headerH + listH + (idle ? 0 : footerH)
        chipW = chip.set(chips)
        chip.isHidden = chips.isEmpty
        updatePlaceholder()
        clearButton.isHidden = field.stringValue.isEmpty
        topRule.isHidden = idle
        bottomRule.isHidden = idle
        footer.isHidden = idle
        closeHint.isHidden = idle
        scroll.hasVerticalScroller = desiredList > listH
        previewRule.isHidden = !split
        scroll.isHidden = !hasRows
        let files = hits.filter { $0.path != nil }.count
        summary.stringValue = searching ? "Searching…" : files > 0 ? "\(files) file match\(files == 1 ? "" : "es")" : (hasRows ? "Actions" : "No matching files")
        if !note.isEmpty { summary.stringValue += " · " + note }
        if hasRows, field.stringValue.isEmpty, chips.isEmpty, !pinned { summary.stringValue = "Suggested for now · type to search" }
        summary.isHidden = headerH == 0
        scope.isHidden = headerH == 0
        updateScope()
        empty.stringValue = searching ? (note.isEmpty ? "Searching…" : note) : !note.isEmpty ? note : "No matching files"
        empty.isHidden = hasRows || idle
        setHeight(h)
        layoutContent()
        updatePreview()
        updateHints()
    }

    private func setHeight(_ h: CGFloat) {
        let target = NSRect(x: panel.frame.minX, y: top - h, width: width, height: h)
        guard target != panel.frame else { return }
        guard panel.isVisible, !reduceMotion else { return panel.setFrame(target, display: true) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            c.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }

    // Positions everything for the content view's current height, which is mid-animation during a resize.
    private func layoutContent() {
        guard let fx = panel.contentView else { return }
        let h = fx.bounds.height
        let listArea = max(0, h - fieldH - headerH - (idle ? 0 : footerH))
        glyph.frame = NSRect(x: 22, y: h - fieldH + 24, width: 24, height: 24)
        chip.frame = NSRect(x: 58, y: h - fieldH + 21, width: chipW, height: 30)
        let x = 58 + (chips.isEmpty ? 0 : chipW + 10)
        field.frame = NSRect(x: x, y: h - fieldH + 20, width: width - x - 60, height: 32)
        clearButton.frame = NSRect(x: width - 48, y: h - fieldH + 22, width: 28, height: 28)
        topRule.frame = NSRect(x: 0, y: h - fieldH, width: width, height: 1)
        bottomRule.frame = NSRect(x: 0, y: footerH, width: width, height: 1)
        scroll.frame = NSRect(x: 8, y: footerH + 4, width: split ? listW : width - 16, height: max(0, listArea - 8))
        previewRule.frame = NSRect(x: listW + 15, y: footerH, width: 1, height: listArea)
        preview.frame = NSRect(x: listW + 16, y: footerH, width: width - listW - 16, height: listArea)
        summary.frame = NSRect(x: 22, y: h - fieldH - 23, width: width - 320, height: 16)
        let scopeW = min(290, ceil(scope.attributedStringValue.size().width) + 4)
        scope.frame = NSRect(x: width - 22 - scopeW, y: h - fieldH - 23, width: scopeW, height: 16)
        ring.frame = NSRect(x: scope.frame.minX - 17, y: h - fieldH - 21, width: 12, height: 12)
        empty.frame = NSRect(x: 22, y: footerH + 16, width: width - 44, height: 18)
        footer.frame = NSRect(x: 22, y: 11, width: width - 120, height: 15)
        closeHint.frame = NSRect(x: width - 98, y: 11, width: 76, height: 15)
    }

    // "Indexing contents 25/7000", or JSON {"stage","done","total","eta"} from the indexer
    static func parseProgress(_ s: String) -> (done: Int, total: Int, eta: Double?)? {
        if let b = s.firstIndex(of: "{"), let o = try? JSONSerialization.jsonObject(with: Data(s[b...].utf8)) as? [String: Any],
           let d = (o["done"] as? NSNumber)?.intValue, let t = (o["total"] as? NSNumber)?.intValue, t > 0 {
            return (d, t, (o["eta"] as? NSNumber)?.doubleValue)
        }
        guard let r = s.range(of: "\\d+/\\d+", options: .regularExpression) else { return nil }
        let p = s[r].split(separator: "/").compactMap { Int($0) }
        return p.count == 2 && p[1] > 0 ? (p[0], p[1], nil) : nil
    }

    private static let grouping: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
    static func progressText(_ p: (done: Int, total: Int, eta: Double?)) -> String {
        func n(_ v: Int) -> String { grouping.string(from: NSNumber(value: v)) ?? String(v) }
        var s = "Indexing \(n(min(p.done, p.total)))/\(n(p.total))"
        if let e = p.eta, e.isFinite, e > 0 {
            s += e < 60 ? " · <1 min" : e < 5400 ? " · ~\(Int((e / 60).rounded())) min" : " · ~\(Int((e / 3600).rounded())) hr"
        }
        return s
    }

    private func updateScope() {
        if let p = progress ?? Self.parseProgress(status) {
            scope.stringValue = Self.progressText(p)
            ring.fraction = CGFloat(p.done) / CGFloat(max(1, p.total))
            ring.isHidden = scope.isHidden
            ring.setAccessibilityLabel("Indexing progress")
            ring.setAccessibilityValue("\(Int(ring.fraction * 100)) percent")
        } else {
            scope.stringValue = status.isEmpty ? "On this Mac" : status
            ring.isHidden = true
        }
    }

    private func updateHints() {
        let sel = table.selectedRowIndexes
        let files = selectedFiles
        let h = selectedHit
        if hits.isEmpty { footer.stringValue = "⌘Y  Show / hide     ·     Drop a file to ask about it" }
        else if files.count > 1 { footer.stringValue = "\(files.count) files     ↩  Open all    ⌘↩  Reveal all    ⇥  Add all to bar    ⇧⌘C  Copy    Drag to share" }
        else if lines.indices.contains(primaryRow), lines[primaryRow] == .more { footer.stringValue = "↩  Show all matching files" }
        else if h == nil { footer.stringValue = "↑↓  Select a result" }
        else if h?.path != nil { footer.stringValue = "↑↓  Navigate    ↩  Open    ⌘↩  Reveal    ⇥  Add to bar    ⇧⌘C  Copy file    ⌘K  Actions    ⇧↑↓  Select more" }
        else { footer.stringValue = "↑↓  Navigate     ↩  Run action     ⌘1–9  Open by number" }
        if let h, h.isPending { footer.stringValue = "Working out your request…     esc  Cancel" }
        if let reason = h?.unavailableReason { footer.stringValue = reason }
        for r in 0..<lines.count {
            let v = table.view(atColumn: 0, row: r, makeIfNecessary: false)
            (v as? RowView)?.select(sel.contains(r))
            (v as? MoreView)?.select(sel.contains(r))
        }
    }

    private func updatePreview() {
        preview.interactive = resultsCurrent
        preview.query = appliedQuery
        guard split else { return preview.show(nil) }
        // stale rows keep their preview, dimmed and inert, until the new results arrive
        if let h = selectedHit, h.path != nil, selectedFiles.count <= 1 { return preview.show(h) }
        let files = selectedFiles
        if files.count > 1 {
            let multi = Hit(title: "\(files.count) files selected", subtitle: files.compactMap { $0.path.map { ($0 as NSString).lastPathComponent } }.joined(separator: ", "),
                            icon: .symbol("doc.on.doc"), tag: "") { _ in }
            return preview.showSummary(multi, image: summaryImage(multi), hint: "Return opens all · ⌘↩ reveals all · ⇥ adds all")
        }
        if lines.indices.contains(primaryRow), lines[primaryRow] == .more {
            let more = Hit(title: "Show all files", subtitle: "Every file that matches “\(appliedQuery)”", icon: .symbol("list.bullet"), tag: "") { _ in }
            return preview.showSummary(more, image: summaryImage(more), hint: "Return or ⌘↓ to list them")
        }
        preview.showSummary(selectedHit, image: selectedHit.map(summaryImage) ?? symbol("doc.text.magnifyingglass", 40))
    }

    private func symbol(_ name: String, _ size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .light))
    }

    private func summaryImage(_ h: Hit) -> NSImage? {
        if let i = RowIcons.image(for: h, loaded: {}) { return i }
        switch h.icon {
        case .symbol(let name): return symbol(name, 40)
        case .file(let path): return NSWorkspace.shared.icon(forFile: path)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !extending {
            cursor = table.selectedRow
            if table.selectedRowIndexes.count <= 1 { anchor = cursor }
        }
        resize()
    }
    // headers are never selected; several rows can only be files
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        let ok = IndexSet(proposed.filter { selectable($0) })
        if ok.isEmpty { return proposed.isEmpty ? proposed : tableView.selectedRowIndexes }
        guard ok.count > 1 else { return ok }
        let files = IndexSet(ok.filter { isFileRow($0) })
        return files.count > 1 ? files : IndexSet(integer: ok.last!)
    }
    @objc private func selectedByClick() {
        updatePreview()
        panel.makeFirstResponder(field)
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(lines[row]) }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultSelectionView() }

    // the pointer moved onto a row: it becomes the selection (several selected files are left alone)
    private func hover(_ row: Int) {
        guard selectable(row), row != table.selectedRow, table.selectedRowIndexes.count <= 1 else { return }
        selectRow(row)
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard panel.isVisible else { return }
        let cmd = flags.contains(.command) && flags.intersection([.shift, .option, .control]).isEmpty
        commandTimer?.invalidate()
        // a quick ⌘C or ⌘↩ should not flash the badges
        if cmd, !commandHeld {
            commandTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                self?.commandHeld = true; self?.redrawRows()
            }
        } else if !cmd, commandHeld { commandHeld = false; redrawRows() }
        let opt = flags.contains(.option)
        if opt != optionHeld { optionHeld = opt; redrawRows() }
    }

    private func redrawRows() {
        guard !lines.isEmpty else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<lines.count), columnIndexes: [0])
    }

    private func setDim(_ on: Bool) {
        let a: CGFloat = on ? 0.5 : 1
        guard scroll.alphaValue != a else { return }
        if panel.isVisible, !reduceMotion {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.12
                scroll.animator().alphaValue = a
                preview.animator().alphaValue = a
            }
        } else { scroll.alphaValue = a; preview.alphaValue = a }
    }

    private func crossfade() {
        guard panel.isVisible, !reduceMotion else { return }
        let t = CATransition()
        t.type = .fade
        t.duration = 0.12
        scroll.layer?.add(t, forKey: "rows")
    }

    // VoiceOver hears how many results there are once typing pauses
    private func announce() {
        announceTimer?.invalidate()
        guard panel.isVisible, !panel.inert else { return }
        announceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, self.panel.isVisible, self.resultsCurrent else { return }
            let n = self.hits.count, files = self.hits.filter { $0.path != nil }.count
            let text = n == 0 ? "No results" : "\(n) result\(n == 1 ? "" : "s")" + (files > 0 ? ", \(files) file\(files == 1 ? "" : "s")" : "")
            NSAccessibility.post(element: self.table, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

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
        lines = []
        table.reloadData()
        resize()
        Engine.shared.similar(to: file) { [weak self] r in
            guard let self, self.pinned, self.resultVersion == version, self.chips == [file] else { return }
            self.apply(r)
        }
    }

    private func quickLook() {
        guard resultsCurrent else { return }
        guard let path = selectedHit?.path ?? (selectedHit == nil ? chips.first : nil) else { return }
        hide()
        Sys.shell("/usr/bin/qlmanage", ["-p", path])
    }

    // MARK: query history

    private static let historyKey = "panel.queryHistory"
    #if SEARCH_TESTS
    // checks never write to the user's defaults
    private static var testHistory: [String] = []
    private static func loadHistory() -> [String] { testHistory }
    private static func saveHistory(_ h: [String]) { testHistory = h }
    #else
    private static func loadHistory() -> [String] { UserDefaults.standard.stringArray(forKey: historyKey) ?? [] }
    private static func saveHistory(_ h: [String]) { UserDefaults.standard.set(h, forKey: historyKey) }
    #endif

    private func remember(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, chips.isEmpty, !pinned else { return }
        history.removeAll { $0 == q }
        history.insert(q, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        Self.saveHistory(history)
    }

    // ↑ with the field empty (or showing a recalled query) and the selection at the top steps back through history
    private func recallHistory() -> Bool {
        guard chips.isEmpty, !history.isEmpty else { return false }
        let firstRow = lines.indices.first { selectable($0) } ?? -1
        let recalling = historyPos.map { history.indices.contains($0) && field.stringValue == history[$0] } ?? false
        guard primaryRow <= firstRow, field.stringValue.isEmpty || recalling else { return false }
        let next = recalling ? historyPos! + 1 : 0
        guard next < history.count else { return true }
        historyPos = next
        field.stringValue = history[next]
        field.currentEditor()?.selectedRange = NSRange(location: (history[next] as NSString).length, length: 0)
        pinned = false
        refresh()
        return true
    }

    // MARK: ⌘K

    private func actionMenu() {
        guard resultsCurrent else { return }
        let targets = selectedFiles
        let paths = targets.compactMap(\.path)
        guard let first = paths.first, let r = row(of: selectedIndex ?? -1) ?? table.selectedRowIndexes.first else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult func add(_ title: String, _ symbol: String?, key: String = "", mods: NSEvent.ModifierFlags = [], to m: NSMenu? = nil,
                                    _ run: @escaping () -> Void) -> NSMenuItem {
            let a = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = a
            item.representedObject = a
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            (m ?? menu).addItem(item)
            return item
        }
        let many = paths.count > 1
        add(many ? "Open \(paths.count) Files" : "Open", "arrow.up.forward.app", key: "\r") { [weak self] in
            if targets.count == 1, let key = targets[0].key, let self, self.chips.isEmpty { Engine.shared.recordPick(self.field.stringValue, key) }
            self?.hide(); targets.forEach { $0.run(false) }
        }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: urls[0])
        if !apps.isEmpty {
            let sub = NSMenu()
            let def = NSWorkspace.shared.urlForApplication(toOpen: urls[0])
            for app in apps.prefix(16) {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let item = add(name + (app == def ? " (default)" : ""), nil, to: sub) { [weak self] in
                    self?.hide()
                    NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
            item.submenu = sub
            menu.addItem(item)
        }
        add("Reveal in Finder", "folder", key: "\r", mods: .command) { [weak self] in
            self?.hide(); NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        if !many {
            add("Quick Look", "eye", key: "p", mods: .command) { [weak self] in
                self?.hide(); Sys.shell("/usr/bin/qlmanage", ["-p", first])
            }
        }
        menu.addItem(.separator())
        add(many ? "Copy Files" : "Copy File", "doc.on.doc", key: "c", mods: [.command, .shift]) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            Toast.show("✓ \(many ? "Files" : "File") copied · paste into another app")
        }
        add(many ? "Copy Paths" : "Copy Path", "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            Toast.show("✓ Path\(many ? "s" : "") copied")
        }
        add("Add to Bar", "plus.rectangle.on.rectangle", key: "\t") { [weak self] in
            guard let self else { return }
            self.attach(paths)
            self.panel.makeFirstResponder(self.field)
        }
        if !many, [.image, .audio, .video].contains(Extract.kind(ext: (first as NSString).pathExtension.lowercased())) {
            add("Find Similar", "square.stack.3d.down.right") { [weak self] in self?.showSimilar(to: first) }
        }
        let ops = FileOps.suggestions(paths).filter { $0.id != "similar" }
        if !ops.isEmpty {
            menu.addItem(.separator())
            for op in ops {
                let item = add(op.title, op.symbol) { [weak self] in
                    if !op.stay { self?.hide() }
                    FileOps.run(op)
                }
                if let reason = op.unavailableReason { item.isEnabled = false; item.toolTip = reason }
            }
        }
        let rect = table.rect(ofRow: r)
        menu.popUp(positioning: nil, at: NSPoint(x: min(rect.maxX - 40, rect.minX + 260), y: rect.maxY - 4), in: table)
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

    // Fixture rows covering every section, for the panel checks and the offscreen snapshots.
    static func fixtureHits(_ files: [String], ran: @escaping (String) -> Void) -> [Hit] {
        var out = files.enumerated().map { i, f in
            Hit(title: (f as NSString).lastPathComponent, subtitle: "~/Documents · 12 Mar 2025", icon: .file(f), tag: "Document", key: f, path: f,
                excerpt: i == 0 ? "…the «invoice» number is «48291» for March…" : "") { _ in ran(f) }
        }
        out[0].why = "name 16 · meaning 2.1 · habit 1"
        out.insert(Hit(title: "Search the web for “invoice”", subtitle: "Safari", icon: .symbol("magnifyingglass"), tag: "Web") { _ in ran("web") }, at: 1)
        out.append(Hit(title: "Invoices · Acme", subtitle: "acme.example.com", icon: .symbol("globe"), tag: "Web page", key: "https://acme.example.com/invoices") { _ in ran("page") })
        out.append(Hit(title: "Ask ChatGPT", subtitle: "With 2 files", icon: .symbol("sparkles"), tag: "ChatGPT", key: "intent:ask") { _ in ran("ask") })
        return out
    }

    static func verifyPanel(files: [String]) -> [(String, Bool)] {
        _ = NSApplication.shared
        let bar = BarController()
        bar.panel.inert = true
        bar.top = 900
        var ran: [String] = []
        var out: [(String, Bool)] = []
        let hits = fixtureHits(files) { ran.append($0) }
        bar.field.stringValue = "invoice"
        bar.apply(SearchResult(hits: hits))
        out.append(("sections follow their best row and keep the top result first", bar.hits.first?.path == files[0] && bar.lines.first == .header("Files")))
        out.append(("section headers appear once per section", bar.lines.filter { if case .header = $0 { return true }; return false }.count == 3))
        out.append(("the top result is selected, not its header", bar.selectedIndex == 0 && bar.table.selectedRow == 1))
        bar.move(-1)
        out.append(("↑ never lands on a header", bar.table.selectedRow == 1))
        let fileRows = files.count
        for _ in 0..<fileRows { bar.move(1) }
        out.append(("↓ skips the next header", bar.selectedHit.map(Self.group) == "Web" || bar.selectedHit.map(Self.group) == "Actions"))
        bar.resize()
        let actionWidth = bar.scroll.frame.width, actionH = bar.panel.frame.height
        out.append(("an action row keeps the preview column with a summary", !bar.preview.isHidden && bar.split))
        bar.selectRow(bar.row(of: 0)!)
        bar.resize()
        out.append(("moving between action and file rows keeps the list width and panel height", bar.scroll.frame.width == actionWidth && bar.panel.frame.height == actionH))
        // typing: the old rows stay, the height holds, and nothing stale can run
        let rowsBefore = bar.table.numberOfRows, heightBefore = bar.panel.frame.height
        bar.field.stringValue = "invoice n"
        bar.refresh()
        out.append(("typing keeps the previous rows instead of blanking the list", bar.table.numberOfRows == rowsBefore && !bar.hits.isEmpty))
        out.append(("typing keeps the panel height until new results arrive", bar.panel.frame.height == heightBefore))
        bar.activate(alt: false)
        bar.openNth(1)
        _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        out.append(("stale rows cannot be opened, numbered or attached", ran.isEmpty && bar.chips.isEmpty))
        out.append(("stale rows cannot be dragged", bar.tableView(bar.table, pasteboardWriterForRow: 1) == nil && !bar.preview.interactive))
        bar.apply(SearchResult(hits: hits))
        out.append(("arriving results make the preview interactive again", bar.preview.interactive))
        let second = bar.hits[1].path ?? "?"
        bar.openNth(2)
        out.append(("⌘2 opens the second result", ran == [second]))
        // multi-select
        ran = []
        bar.field.stringValue = "invoice"
        bar.apply(SearchResult(hits: hits))
        bar.extend(1)
        out.append(("⇧↓ extends the selection over file rows", bar.selectedFiles.count == 2))
        _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        out.append(("Tab attaches every selected file", bar.chips == Array(files.prefix(2))))
        bar.chips = []
        bar.field.stringValue = "invoice"
        bar.apply(SearchResult(hits: hits))
        out.append(("an action row cannot join a multiple selection",
                    bar.tableView(bar.table, selectionIndexesForProposedSelection: IndexSet([1, bar.lines.count - 1])).count == 1))
        // show all files
        var asked = ""
        bar.loadMore = { q, _, done in asked = q; done(files.map { Hit(title: "more " + $0, subtitle: "", icon: .file($0), tag: "Document", path: $0 + ".more") { _ in } }) }
        let five = (0..<5).map { i in Hit(title: "f\(i)", subtitle: "", icon: .file(files[0]), tag: "Document", path: files[0] + "\(i)") { _ in } }
        bar.apply(SearchResult(hits: five))
        out.append(("a capped file list offers Show all files", bar.lines.last == .more))
        bar.expand()
        out.append(("Show all files asks for the query and appends the rest", asked == "invoice" && bar.hits.count == 5 + files.count && !bar.lines.contains(.more)))
        // history and restore
        bar.loadMore = nil
        bar.field.stringValue = "invoice"
        bar.apply(SearchResult(hits: hits))
        bar.remember("quarterly report"); bar.remember("invoice")
        bar.field.stringValue = ""
        bar.apply(SearchResult(hits: hits))
        _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
        out.append(("↑ on an empty field recalls the last query", bar.field.stringValue == "invoice"))
        bar.apply(SearchResult(hits: hits))
        _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
        out.append(("↑ again steps further back", bar.field.stringValue == "quarterly report"))
        bar.field.stringValue = "invoice"
        bar.apply(SearchResult(hits: hits))
        bar.selectRow(bar.row(of: 2)!)
        let identity = bar.selectedHit?.selectionIdentity
        bar.hide()
        out.append(("closing keeps the last search briefly", bar.lastSession?.text == "invoice" && bar.lastSession?.identity == identity))
        bar.field.stringValue = bar.lastSession?.text ?? ""
        bar.restoreIdentity = identity
        bar.apply(SearchResult(hits: hits))
        out.append(("reopening restores the selected result", bar.selectedHit?.selectionIdentity == identity))
        bar.resize()
        out.append(("the empty field has a quiet placeholder", bar.field.placeholderAttributedString?.string == "Search files, apps, or ask…"))
        bar.field.stringValue = "invoice"
        bar.status = "Indexing contents 25/7000"
        bar.resize()
        out.append(("indexing progress shows a count and a ring", bar.scope.stringValue == "Indexing 25/7,000" && !bar.ring.isHidden))
        bar.progress = (25, 7000, 120)
        bar.resize()
        out.append(("an estimate follows the count", bar.scope.stringValue == "Indexing 25/7,000 · ~2 min"))
        bar.hide()
        bar.preview.show(nil)
        return out
    }

    // Offscreen renders of the panel for visual review (SEMANTIC_PANEL_SNAPSHOTS=dir ./build.sh --test).
    static func snapshots(files: [String], to dir: String) {
        _ = NSApplication.shared
        for dark in [false, true] {
            let bar = BarController()
            bar.panel.inert = true
            bar.top = 900
            bar.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let fx = bar.panel.contentView as! DropView
            bar.field.stringValue = "invoice"
            bar.apply(SearchResult(hits: fixtureHits(files) { _ in }))
            func shot(_ name: String) {
                bar.resize()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                fx.layoutSubtreeIfNeeded()
                bar.table.layoutSubtreeIfNeeded()
                let size = fx.bounds.size
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                bar.panel.appearance?.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 22, yRadius: 22).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                let top = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                top.size = size
                fx.cacheDisplay(in: fx.bounds, to: top)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                top.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(name)-\(dark ? "dark" : "light").png"))
            }
            shot("file")
            bar.selectRow(bar.row(of: bar.hits.firstIndex { $0.tag == "Web" }!)!)
            shot("action")
            bar.commandHeld = true; bar.optionHeld = true
            bar.redrawRows()
            shot("modifiers")
            bar.commandHeld = false; bar.optionHeld = false
            bar.redrawRows()
            bar.selectRow(bar.row(of: 0)!)
            bar.extend(1)
            shot("multi")
            bar.field.stringValue = "invoice x"
            bar.searching = true
            bar.setDim(true)
            bar.status = "Indexing contents 2500/7000"
            shot("stale")
            bar.hide()
        }
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
            note = ""
            // the previous rows stay (inert) so the list never blanks; they dim only if the new ones are slow
            dimTimer?.invalidate()
            if !hits.isEmpty {
                dimTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                    guard let self, self.searching else { return }
                    self.setDim(true)
                }
            }
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
        dimTimer?.invalidate()
        setDim(false)
        let sameQuery = appliedQuery == field.stringValue && appliedChips == chips
        let previous = sameQuery ? selectedHit?.selectionIdentity : nil
        let alsoSelected = sameQuery ? Set(selectedFiles.map(\.selectionIdentity)) : []
        if !sameQuery || previous != nil { selectionSuppressed = false }
        else if !hits.isEmpty { selectionSuppressed = true }
        resultVersion += 1
        let before = hits.map(\.selectionIdentity)
        hits = r.hits
        note = r.note
        if !sameQuery { expandedFor = nil; expandedHits = [] } else if expandedFor == field.stringValue { mergeExpanded() }
        appliedQuery = field.stringValue
        appliedChips = chips
        regroup()
        rebuildLines()
        if before != hits.map(\.selectionIdentity) { crossfade() }
        table.reloadData()
        cursor = -1; anchor = -1
        if !hits.isEmpty {
            if let previous, let selected = hits.firstIndex(where: { $0.selectionIdentity == previous }), let r = row(of: selected) {
                selectRow(r)
                // a refinement keeps every selected file that is still there
                if alsoSelected.count > 1 {
                    let rows = lines.indices.filter { isFileRow($0) && alsoSelected.contains(hits[hitIndex($0)!].selectionIdentity) }
                    extending = true
                    table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
                    extending = false
                }
            } else if previous != nil {
                selectionSuppressed = true
                table.deselectAll(nil)
            } else if let want = restoreIdentity, let i = hits.firstIndex(where: { $0.selectionIdentity == want }), let r = row(of: i) {
                selectRow(r)
            } else if !selectionSuppressed, let r = row(of: 0) {
                selectRow(r)
            } else {
                table.deselectAll(nil)
            }
        } else if previous != nil {
            selectionSuppressed = true
        }
        if !sameQuery || !hits.isEmpty { restoreIdentity = nil }
        resize()
        scheduleRefine()
        announce()
    }

    private func mergeExpanded() {
        let have = Set(hits.compactMap(\.path))
        let extra = expandedHits.filter { $0.path.map { !have.contains($0) } ?? false }
        let at = (hits.lastIndex { $0.path != nil }).map { $0 + 1 } ?? hits.count
        hits.insert(contentsOf: extra, at: at)
    }

    // "Show all files": the rest of the files for this query, appended after the five
    private func expand() {
        guard resultsCurrent, canLoadMore, let loadMore else { return }
        let text = field.stringValue, files = chips, version = resultVersion
        loadMore(text, files) { [weak self] more in
            let finish = {
                guard let self, self.resultVersion == version, self.field.stringValue == text, self.chips == files else { return }
                self.expandedFor = text
                self.expandedHits = more.filter { $0.path != nil }
                let selected = self.selectedHit?.selectionIdentity
                let count = self.hits.count
                self.mergeExpanded()
                self.regroup()
                self.rebuildLines()
                self.table.reloadData()
                // the first new file, so the user sees where the list grew
                let old = Set(self.hits.prefix(count).map(\.selectionIdentity))
                let firstNew = self.hits.firstIndex { !old.contains($0.selectionIdentity) }
                if let i = firstNew ?? self.hits.firstIndex(where: { $0.selectionIdentity == selected }), let r = self.row(of: i) { self.selectRow(r) }
                self.resize()
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
    }

    static func selectionAfterPromotion(selected: Int, promoted: Int) -> Int {
        if selected < 0 { return -1 }
        if selected == promoted { return 0 }
        return selected < promoted ? selected + 1 : selected
    }

    // index into hits
    private func restoreSelection(_ index: Int) {
        if hits.indices.contains(index), let r = row(of: index) { selectRow(r) }
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
                let selected = self.selectedIndex ?? -1
                var target = selected
                if new.promote {
                    // the model worked out what the sentence is about: that reading goes first
                    self.hits.remove(at: idx)
                    self.hits.insert(new, at: 0)
                    target = Self.selectionAfterPromotion(selected: selected, promoted: idx)
                } else {
                    self.hits[idx] = new
                }
                let perm = self.regroup()
                self.rebuildLines()
                self.table.reloadData()
                self.restoreSelection(target < 0 ? -1 : perm.firstIndex(of: target) ?? -1)
                self.resize()
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        pinned = false
        historyPos = nil
        // the command model takes a moment to load; start before the sentence is finished
        if LLM.available, !chips.isEmpty || field.stringValue.range(of: "^(remind|email|mail|send|add|schedule|lunch|dinner|meet|book|convert|turn|rename|move)\\b",
                                                                     options: [.regularExpression, .caseInsensitive]) != nil { LLM.shared.preload() }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): if !recallHistory() { move(-1) }
        case #selector(NSResponder.moveDownAndModifySelection(_:)): extend(1)
        case #selector(NSResponder.moveUpAndModifySelection(_:)): extend(-1)
        case #selector(NSResponder.insertNewline(_:)): activate(alt: false)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        case #selector(NSResponder.insertTab(_:)):
            // put the selected file(s) into the bar, to act on them
            let paths = selectedFiles.compactMap(\.path)
            if resultsCurrent, !paths.isEmpty { attach(paths) }
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
        let rows = lines.indices.filter { selectable($0) }
        guard !rows.isEmpty else { return }
        let next = rows.firstIndex(of: primaryRow).map { rows[max(0, min(rows.count - 1, $0 + d))] } ?? rows[0]
        selectRow(next)
    }

    // ⇧↑/⇧↓: grow or shrink a selection of files from where it started
    private func extend(_ d: Int) {
        let start = primaryRow
        guard isFileRow(start) else { return move(d) }
        if table.selectedRowIndexes.count <= 1 || !isFileRow(anchor) { anchor = start }
        var r = start + d
        while lines.indices.contains(r), !isFileRow(r) { r += d }
        guard lines.indices.contains(r) else { return }
        let rows = (min(anchor, r)...max(anchor, r)).filter { isFileRow($0) }
        extending = true
        cursor = r
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        extending = false
        table.scrollRowToVisible(r)
    }

    @discardableResult private func copySelectedFile() -> Bool {
        guard resultsCurrent else { return false }
        let writers = selectedFiles.compactMap { Self.dragWriter($0) }
        guard !writers.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(writers)
        Toast.show("✓ \(writers.count == 1 ? "File" : "\(writers.count) files") copied · paste into another app")
        return true
    }

    @objc private func clicked() { activate(alt: NSEvent.modifierFlags.contains(.command)) }

    // ⌘N: the Nth result, counting only results
    private func openNth(_ n: Int) {
        guard resultsCurrent, hits.indices.contains(n - 1), let r = row(of: n - 1) else { return }
        selectRow(r)
        activate(alt: false)
    }

    private func activate(alt: Bool) {
        guard resultsCurrent else { return }
        let files = selectedFiles
        if files.count > 1 {
            remember(field.stringValue)
            hide()
            if alt { NSWorkspace.shared.activateFileViewerSelecting(files.compactMap(\.path).map { URL(fileURLWithPath: $0) }) }
            else { files.forEach { $0.run(false) } }
            return
        }
        if lines.indices.contains(primaryRow), lines[primaryRow] == .more { return expand() }
        guard let h = selectedHit else { return }
        guard !h.isPending, h.unavailableReason == nil else { return }
        if let key = h.key, chips.isEmpty { Engine.shared.recordPick(field.stringValue, key) }
        remember(field.stringValue)
        if !h.stay { hide() }
        h.run(alt)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .header(let name):
            let id = NSUserInterfaceItemIdentifier("header")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? HeaderView ?? HeaderView(frame: .zero)
            v.identifier = id
            v.label.stringValue = name
            v.setAccessibilityElement(true)
            v.setAccessibilityRole(.staticText)
            v.setAccessibilityLabel(name + " section")
            return v
        case .more:
            let id = NSUserInterfaceItemIdentifier("more")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? MoreView ?? MoreView(frame: .zero)
            v.identifier = id
            v.select(table.selectedRowIndexes.contains(row))
            return v
        case .hit(let i):
            return rowView(hits[i], index: i, row: row)
        }
    }

    private func rowView(_ h: Hit, index: Int, row: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = table.makeView(withIdentifier: id, owner: nil) as? RowView ?? RowView(frame: .zero)
        v.identifier = id
        let group = Self.group(h)
        v.titleText = h.title
        // action titles quote the query already; marking it again is noise
        v.query = group == "Actions" ? "" : appliedQuery
        v.subtitleText = h.path != nil ? RelativeDate.rewrite(h.subtitle, path: h.path, date: h.date) : h.subtitle
        v.why = h.why
        v.showWhy = optionHeld
        v.excerptText = h.excerpt
        v.isFile = h.path != nil
        v.label = grouped ? "" : h.tag
        v.pending = h.isPending
        v.unavailable = h.unavailableReason != nil
        v.shortcut = index < 9 ? index + 1 : 0
        v.showShortcut = commandHeld
        v.select(table.selectedRowIndexes.contains(row))
        v.setAccessibilityElement(true)
        v.setAccessibilityLabel([h.title, h.subtitle, Marked.plain(h.excerpt)].filter { !$0.isEmpty }.joined(separator: ", ")
                                + (index < 9 ? ", Command-\(index + 1)" : ""))
        v.toolTip = h.path ?? h.subtitle
        if let img = RowIcons.image(for: h, loaded: { [weak self] in self?.redrawRows() }) {
            v.icon.contentTintColor = nil
            v.icon.image = img
            return v
        }
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
                    if case .file(let p) = h.icon, p == path, let r = self.row(of: i) {
                        self.table.reloadData(forRowIndexes: [r], columnIndexes: [0])
                    }
                }
            }
        }
    }
}
