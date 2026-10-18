import AppKit
import ServiceManagement

// A list of strings with + and − buttons (indexed folders, excludes).
private final class ListEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var items: [String] { didSet { table.reloadData(); minus.isEnabled = !table.selectedRowIndexes.isEmpty } }
    var onAdd: (() -> Void)?
    var onChange: (([String]) -> Void)?
    private let table = NSTableView()
    private let minus = NSButton()

    init(_ items: [String], height: CGFloat) {
        self.items = items
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: height))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 24, width: 360, height: height - 24))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let col = NSTableColumn(identifier: .init("v"))
        col.width = 340
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        let plus = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(add))
        minus.image = NSImage(named: NSImage.removeTemplateName)
        minus.target = self
        minus.action = #selector(remove)
        minus.isEnabled = false
        for (i, b) in [plus, minus].enumerated() {
            b.bezelStyle = .smallSquare
            b.frame = NSRect(x: CGFloat(i) * 24, y: 0, width: 24, height: 22)
            addSubview(b)
        }
        addSubview(scroll)
        widthAnchor.constraint(equalToConstant: 360).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let l = NSTextField(labelWithString: items[row])
        l.lineBreakMode = .byTruncatingMiddle
        l.toolTip = items[row]
        return l
    }
    func tableViewSelectionDidChange(_ notification: Notification) { minus.isEnabled = !table.selectedRowIndexes.isEmpty }
    @objc private func add() { onAdd?() }
    @objc private func remove() {
        items = items.enumerated().filter { !table.selectedRowIndexes.contains($0.offset) }.map(\.element)
        table.deselectAll(nil)
        onChange?(items)
    }
    func append(_ s: String) {
        guard !items.contains(s) else { return }
        items.append(s)
        onChange?(items)
    }
}

// Native preferences. Every control writes config.json straight away, keeping keys it does not show.
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private static var current: SettingsWindow?

    static func show() {
        let w = current ?? SettingsWindow()
        current = w
        NSApp.activate(ignoringOtherApps: true)
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    static func openConfigFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.config) { updateConfig([:]) }
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.config))
    }

    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private var recorder: Any?
    private var roots: ListEditor!
    private var excludes: ListEditor!
    private let pattern = NSTextField()
    private let login = NSButton(checkboxWithTitle: "Open Semantic at login", target: nil, action: nil)
    private var reindexTimer: Timer?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Semantic Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        stopRecording(save: nil)
        Self.current = nil
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 360
        return l
    }

    private func checkbox(_ title: String, _ on: Bool, _ sel: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: sel)
        b.state = on ? .on : .off
        return b
    }

    private func popup(_ items: [(String, Any)], selected: Int, _ sel: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, (t, v)) in items.enumerated() {
            p.addItem(withTitle: t)
            p.item(at: i)?.representedObject = v
        }
        p.selectItem(at: max(0, selected))
        p.target = self
        p.action = sel
        return p
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func build() {
        guard let view = window?.contentView else { return }
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.target = self
        hotkeyButton.action = #selector(record)
        hotkeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        showHotkey()
        let reset = NSButton(title: "Use ⌘Y", target: self, action: #selector(resetHotkey))
        reset.bezelStyle = .rounded

        roots = ListEditor(config.roots ?? Indexer.roots().map(Paths.tilde), height: 110)
        roots.onAdd = { [weak self] in self?.chooseFolder { self?.roots.append($0) } }
        roots.onChange = { [weak self] in self?.save(["roots": $0], reindex: true) }
        excludes = ListEditor(config.excludes ?? [], height: 80)
        excludes.onAdd = { [weak self] in self?.chooseFolder { self?.excludes.append($0) } }
        excludes.onChange = { [weak self] in self?.save(["excludes": $0], reindex: true) }
        pattern.placeholderString = "pattern, e.g. *.secret"
        pattern.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let addPattern = NSButton(title: "Add", target: self, action: #selector(addPattern))
        addPattern.bezelStyle = .rounded

        let on = Set(config.sources ?? ["web", "calendar", "contacts", "notes"])
        let sources = row([("web", "Browser history"), ("calendar", "Calendar"), ("contacts", "Contacts"), ("notes", "Notes")].map { id, title in
            let b = checkbox(title, on.contains(id), #selector(toggleSource(_:)))
            b.identifier = .init(id)
            return b
        })

        let clip = checkbox("Keep clipboard history", config.clipboard != false, #selector(toggleClipboard(_:)))
        let dayChoices: [(String, Any)] = [("1 day", 1.0), ("7 days", 7.0), ("30 days", 30.0), ("90 days", 90.0), ("1 year", 365.0), ("Forever", 0.0)]
        let days = popup(dayChoices, selected: dayChoices.firstIndex { ($0.1 as! Double) == ClipboardHistory.days } ?? 2, #selector(clipDays(_:)))
        let clear = NSButton(title: "Clear Clipboard History", target: self, action: #selector(clearClipboard))
        clear.bezelStyle = .rounded

        let dests: [(String, Any)] = [("ChatGPT (app when installed)", "chatgpt"), ("ChatGPT website", "web"), ("Claude", "claude"), ("Gemini (website)", "gemini")]
        let current = ["app": 0, "chatgpt": 0, "web": 1, "claude": 2, "gemini": 3][config.assistant ?? "chatgpt"] ?? 0
        let assistant = popup(dests, selected: current, #selector(assistant(_:)))

        var unloads: [(String, Any)] = [("1 minute", 60.0), ("5 minutes", 300.0), ("15 minutes", 900.0), ("1 hour", 3600.0)]
        let u = config.unloadAfter ?? 300
        if !unloads.contains(where: { ($0.1 as! Double) == u }) { unloads.append(("\(Int(u)) seconds", u)) }
        let unload = popup(unloads, selected: unloads.firstIndex { ($0.1 as! Double) == u } ?? 1, #selector(unload(_:)))

        login.target = self
        login.action = #selector(toggleLogin)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let menu = checkbox("Show in menu bar", config.menuBar != false, #selector(toggleMenuBar(_:)))
        let perms = NSButton(title: "Permissions…", target: self, action: #selector(permissions))
        perms.bezelStyle = .rounded
        let file = NSButton(title: "Open Config File", target: self, action: #selector(openFile))
        file.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [label("Shortcut:"), row([hotkeyButton, reset])],
            [label("General:"), column([menu, login])],
            [label("Indexed folders:"), column([roots, note("Folders and subfolders that are searched. Changes start an index pass.")])],
            [label("Never index:"), column([excludes, row([pattern, addPattern]), note("Folders, or glob patterns matched against names and paths.")])],
            [label("Sources:"), sources],
            [label("Clipboard:"), column([clip, row([NSTextField(labelWithString: "Keep for"), days]), clear])],
            [label("Ask:"), column([assistant, note("Where Ask rows prepare a draft. Nothing is sent for you.")])],
            [label("Free the model:"), row([unload, NSTextField(labelWithString: "after the bar is hidden")])],
            [NSView(), row([perms, file])],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for i in [2, 3, 5, 6] { grid.row(at: i).yPlacement = .top }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        let size = grid.fittingSize
        window?.setContentSize(NSSize(width: max(560, size.width + 40), height: size.height + 40))
    }

    private func save(_ changes: [String: Any?], reindex: Bool = false) {
        guard updateConfig(changes) else { return Toast.show("✗ Could not save config.json; check that it is valid JSON", seconds: 5) }
        guard reindex else { return }
        // several quick edits make one pass
        reindexTimer?.invalidate()
        reindexTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            guard let d = AppDelegate.shared else { return }
            if changes["roots"] != nil { d.watchFiles() } // new roots need a new FSEvents stream
            guard !d.indexingPaused else { return }
            d.pendingIndex = d.indexer != nil
            d.startIndexer()
        }
    }

    private func chooseFolder(_ then: @escaping (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: Paths.home)
        guard let window else { return }
        p.beginSheetModal(for: window) { r in
            if r == .OK, let u = p.url { then(Paths.tilde(u.path)) }
        }
    }

    // MARK: shortcut recorder

    private func showHotkey() {
        hotkeyButton.title = (AppDelegate.shared?.activeHotkey ?? .configured).display
    }

    @objc private func record() {
        if recorder != nil { return stopRecording(save: nil) }
        hotkeyButton.title = "Type a shortcut…"
        // the current shortcut must reach this window, not toggle the bar
        AppDelegate.shared?.unregisterHotKey()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            if ev.keyCode == 53, ev.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { self.stopRecording(save: nil); return nil }
            guard let key = Hotkey(event: ev) else { NSSound.beep(); return nil }
            self.stopRecording(save: key)
            return nil
        }
    }

    private func stopRecording(save key: Hotkey?) {
        guard let r = recorder else { return }
        NSEvent.removeMonitor(r)
        recorder = nil
        apply(key)
    }

    private func apply(_ key: Hotkey?) {
        guard let d = AppDelegate.shared else { return }
        let previous = d.activeHotkey ?? .configured
        if let key, d.registerHotKey(key, announce: true) {
            save(["hotkey": key.spec])
        } else {
            d.registerHotKey(previous)
        }
        showHotkey()
    }

    @objc private func resetHotkey() { stopRecording(save: nil); apply(.fallback) }

    // MARK: actions

    @objc private func addPattern() {
        let p = pattern.stringValue.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        excludes.append(p)
        pattern.stringValue = ""
    }

    @objc private func toggleSource(_ b: NSButton) {
        var on = config.sources ?? ["web", "calendar", "contacts", "notes"]
        guard let id = b.identifier?.rawValue else { return }
        if b.state == .on { if !on.contains(id) { on.append(id) } } else { on.removeAll { $0 == id } }
        save(["sources": on], reindex: true)
    }

    @objc private func toggleClipboard(_ b: NSButton) { save(["clipboard": b.state == .on]) }
    @objc private func clipDays(_ p: NSPopUpButton) {
        save(["clipboardDays": p.selectedItem?.representedObject])
        ioQueue.async { Store().map { ClipboardHistory.prune($0) } }
    }
    @objc private func clearClipboard() {
        Sys.confirm("Delete all clipboard history kept by Semantic?") { ClipboardHistory.clearAll() }
    }
    @objc private func assistant(_ p: NSPopUpButton) { save(["assistant": p.selectedItem?.representedObject]) }
    @objc private func unload(_ p: NSPopUpButton) { save(["unloadAfter": p.selectedItem?.representedObject]) }
    @objc private func toggleMenuBar(_ b: NSButton) {
        save(["menuBar": b.state == .on])
        MenuBar.apply()
    }
    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Toast.show("✗ Login item: \(error.localizedDescription)", seconds: 5)
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func permissions() { PermissionsWindow.show() }
    @objc private func openFile() { Self.openConfigFile() }
}
