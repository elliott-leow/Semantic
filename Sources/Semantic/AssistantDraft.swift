import AppKit

private final class DraftPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Each recoverable question owns its window. Only explicitly closing it releases the draft.
final class AssistantDraft: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var drafts: [UUID: AssistantDraft] = [:]
    private let id = UUID()
    private let prompt = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private var files: [String]
    private let destination: URL?
    private let dest: Dest
    private let retry: ((String, [String]) -> Void)?
    private let settings: (() -> Void)?
    private var copyFilesButton: NSButton?
    private var removeButton: NSButton?

    static func show(question: String, files: [String], destination: URL?, reason: String,
                     retry: ((String, [String]) -> Void)? = nil, settings: (() -> Void)? = nil, to dest: Dest = .chatgpt) {
        let controller = AssistantDraft(question: question, files: files, destination: destination, reason: reason,
                                        retry: retry, settings: settings, dest: dest)
        drafts[controller.id] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // Retry captures exclude retained draft windows without deleting their contents.
    static func withHiddenWindows<T>(_ capture: () throws -> T) rethrows -> T {
        let visible = drafts.values.compactMap(\.window).filter(\.isVisible)
        visible.forEach { $0.orderOut(nil) }
        defer { visible.forEach { $0.orderFront(nil) } }
        return try capture()
    }

    private init(question: String, files: [String], destination: URL?, reason: String,
                 retry: ((String, [String]) -> Void)?, settings: (() -> Void)?, dest: Dest) {
        self.files = files
        self.destination = destination
        self.dest = dest
        self.retry = retry
        self.settings = settings
        let window = DraftPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(dest.name) draft"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        guard let view = window.contentView else { return }
        let heading = NSTextField(wrappingLabelWithString: reason)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 20, y: 506, width: 700, height: 46)
        heading.toolTip = reason
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        instructions.frame = NSRect(x: 20, y: 461, width: 700, height: 40)
        let fileLabel = NSTextField(labelWithString: "Attachments · select a row to remove it")
        fileLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fileLabel.frame = NSRect(x: 20, y: 434, width: 700, height: 20)
        let fileScroll = NSScrollView(frame: NSRect(x: 20, y: 292, width: 700, height: 136))
        fileScroll.borderType = .bezelBorder
        fileScroll.hasVerticalScroller = true
        let fileColumn = NSTableColumn(identifier: .init("file"))
        fileColumn.title = "File"; fileColumn.width = 315
        let stateColumn = NSTableColumn(identifier: .init("state"))
        stateColumn.title = "Status"; stateColumn.width = 355
        table.addTableColumn(fileColumn); table.addTableColumn(stateColumn)
        table.rowHeight = 26
        table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        fileScroll.documentView = table
        let questionLabel = NSTextField(labelWithString: "Question · editable")
        questionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        questionLabel.frame = NSRect(x: 20, y: 268, width: 700, height: 20)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 113, width: 700, height: 149))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        prompt.string = question
        prompt.font = .systemFont(ofSize: 14)
        prompt.isRichText = false
        prompt.textContainerInset = NSSize(width: 10, height: 10)
        prompt.autoresizingMask = [.width]
        prompt.frame = scroll.bounds
        scroll.documentView = prompt
        func button(_ title: String, _ selector: Selector, x: Int, y: Int, key: String = "") -> NSButton {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: CGFloat(x), y: CGFloat(y), width: 228, height: 30)
            button.keyEquivalent = key
            view.addSubview(button)
            return button
        }
        _ = button("Open \(dest.name)  ⌘O", #selector(openDestination), x: 16, y: 75, key: "o")
        copyFilesButton = button("Copy files  ⌘2", #selector(copyAttachments), x: 251, y: 75, key: "2")
        _ = button("Copy question  ⌘1", #selector(copyPrompt), x: 486, y: 75, key: "1")
        let retryButton = button("Retry  ⌘R", #selector(retryHandoff), x: 16, y: 39, key: "r")
        retryButton.isEnabled = retry != nil
        let settingsButton = button("Open System Settings", #selector(openSettings), x: 251, y: 39)
        settingsButton.isEnabled = settings != nil
        removeButton = button("Remove selected files", #selector(removeAttachments), x: 486, y: 39)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Your question and attachment list stay here until you close this window."
        status.frame = NSRect(x: 20, y: 9, width: 700, height: 20)
        for child in [heading, instructions, fileLabel, fileScroll, questionLabel, scroll, status] { view.addSubview(child) }
        refreshFiles()
        window.center()
        if !Self.drafts.isEmpty { window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(Self.drafts.count % 6) * 24, y: window.frame.minY - CGFloat(Self.drafts.count % 6) * 24)) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.drafts.removeValue(forKey: id) }
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard files.indices.contains(row) else { return nil }
        let path = files[row]
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "file" ? (path as NSString).lastPathComponent : (Assistant.attachmentIssue(path) ?? "Ready"))
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = path + "\n" + (Assistant.attachmentIssue(path) ?? "Ready")
        if tableColumn?.identifier.rawValue == "state", Assistant.attachmentIssue(path) != nil { label.textColor = .systemOrange }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty }
    private func refreshFiles() {
        let valid = files.allSatisfy { Assistant.attachmentIssue($0) == nil }
        copyFilesButton?.isEnabled = !files.isEmpty && valid
        removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty
        instructions.stringValue = !valid ? "Restore missing files or access, or remove unsupported attachments below. Retry checks every remaining file before preparing a draft."
            : files.isEmpty ? "Open a new \(dest.name) chat, then copy and paste your question. Send when ready."
            : "Open a new \(dest.name) chat. Paste the files, then copy and paste your question. If files already appear, skip the file paste. Send when ready."
        table.reloadData()
    }
    @objc private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.string, forType: .string)
        status.stringValue = "Question copied. Paste it in \(dest.name)."
    }
    @objc private func copyAttachments() {
        guard files.allSatisfy({ Assistant.attachmentIssue($0) == nil }) else {
            refreshFiles(); status.stringValue = "Attachments need attention. No files were copied."; return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
        NSPasteboard.general.setPropertyList(files, forType: .init("NSFilenamesPboardType"))
        status.stringValue = "Files copied. Paste them in \(dest.name)."
    }
    @objc private func removeAttachments() {
        for row in table.selectedRowIndexes.reversed() where files.indices.contains(row) { files.remove(at: row) }
        table.deselectAll(nil)
        refreshFiles()
        status.stringValue = "Selected attachments removed from this draft. Original files are unchanged."
    }
    @objc private func retryHandoff() {
        refreshFiles()
        status.stringValue = "Retry started. This local draft remains available."
        retry?(prompt.string, files)
    }
    @objc private func openSettings() { settings?() }
    @objc private func openDestination() {
        if let destination { NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration()) }
        else { Sys.open(dest.web) }
    }
}
