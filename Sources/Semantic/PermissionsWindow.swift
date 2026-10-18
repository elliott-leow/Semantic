import AppKit
import ApplicationServices
import Contacts
import EventKit
import Speech

// What Semantic may use, whether it is allowed, and the way to change it. Every check is a read-only probe.
enum Permission: CaseIterable {
    case fullDisk, accessibility, screen, calendar, reminders, contacts, automation, speech

    enum State { case granted, missing, unknown }

    var title: String {
        switch self {
        case .fullDisk: return "Full Disk Access"
        case .accessibility: return AssistantHandoff.controlPermissionName
        case .screen: return "Screen Recording"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .automation: return "Automation (Finder)"
        case .speech: return "Speech Recognition"
        }
    }

    var why: String {
        switch self {
        case .fullDisk: return "Safari history and bookmarks, files in protected folders"
        case .accessibility: return "attaching files in ChatGPT, raising a specific window"
        case .screen: return "“what's on my screen”, window titles in the switcher"
        case .calendar: return "finding events, adding the ones you ask for"
        case .reminders: return "“remind me to …”"
        case .contacts: return "finding people, email addresses for drafts"
        case .automation: return "attaching the Finder selection when the bar opens over Finder"
        case .speech: return "on-device transcription of audio and video, so speech is searchable"
        }
    }

    var symbol: String {
        switch self {
        case .fullDisk: return "internaldrive"
        case .accessibility: return "hand.tap"
        case .screen: return "rectangle.dashed.badge.record"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .automation: return "gearshape.2"
        case .speech: return "waveform"
        }
    }

    // Privacy & Security anchors
    var anchor: String {
        switch self {
        case .fullDisk: return "Privacy_AllFiles"
        case .accessibility: return "Privacy_Accessibility"
        case .screen: return "Privacy_ScreenCapture"
        case .calendar: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        case .automation: return "Privacy_Automation"
        case .speech: return "Privacy_SpeechRecognition"
        }
    }

    // TCC-protected files: opening one fails with EPERM unless Full Disk Access is granted
    static func fullDiskProbe(_ paths: [String] = ["/Library/Application Support/com.apple.TCC/TCC.db",
                                                   Paths.home + "/Library/Safari/History.db", Paths.home + "/Library/Safari/Bookmarks.plist"]) -> State {
        var sawDenied = false
        for p in paths {
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        return sawDenied ? .missing : .unknown
    }

    var state: State {
        switch self {
        case .fullDisk: return Self.fullDiskProbe()
        case .accessibility: return AXIsProcessTrusted() ? .granted : .missing
        case .screen: return CGPreflightScreenCaptureAccess() ? .granted : .missing
        case .calendar: return Self.ek(.event)
        case .reminders: return Self.ek(.reminder)
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return CNContactStore.authorizationStatus(for: .contacts).rawValue == 4 ? .granted : .missing // .limited
            }
        case .automation: return Self.finderAutomation(ask: false)
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .missing
            }
        }
    }

    private static func ek(_ t: EKEntityType) -> State {
        switch EKEventStore.authorizationStatus(for: t) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .missing
        }
    }

    // AEDeterminePermissionToAutomateTarget blocks while asking, so `ask` runs off the main thread
    static func finderAutomation(ask: Bool) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return .unknown }
        let rc = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch rc {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .unknown
        case OSStatus(errAEEventNotPermitted): return .missing
        default: return .unknown // Finder not running, or another error: nothing to show
        }
    }

    // ask in-app when macOS still can; otherwise open the right Settings pane
    func request(_ done: @escaping () -> Void) {
        let back = { DispatchQueue.main.async(execute: done) }
        let s = state
        switch self {
        case .accessibility:
            if s != .granted { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            AssistantHandoff.openControlSettings()
            back()
        case .screen:
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            AssistantHandoff.openScreenSettings()
            back()
        case .calendar where s == .unknown: Commands.store.requestFullAccessToEvents { _, _ in back() }
        case .reminders where s == .unknown: Commands.store.requestFullAccessToReminders { _, _ in back() }
        case .contacts where s == .unknown: CNContactStore().requestAccess(for: .contacts) { _, _ in back() }
        case .speech where s == .unknown: SFSpeechRecognizer.requestAuthorization { _ in back() }
        case .automation where s == .unknown: DispatchQueue.global().async { _ = Self.finderAutomation(ask: true); back() }
        default:
            AssistantHandoff.openPrivacySettings(anchor)
            back()
        }
    }
}

final class PermissionsWindow: NSWindowController, NSWindowDelegate {
    private static var current: PermissionsWindow?
    private var rows: [(Permission, NSImageView, NSTextField, NSButton)] = []
    private var timer: Timer?

    static func show() {
        let w = current ?? PermissionsWindow()
        current = w
        NSApp.activate(ignoringOtherApps: true)
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
        w.refresh()
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Semantic Permissions"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
        // a permission granted in System Settings shows up here without reopening
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        Self.current = nil
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func build() {
        guard let view = window?.contentView else { return }
        let intro = NSTextField(wrappingLabelWithString: "Semantic works without any of these; each one turns on the features listed. Everything stays on this Mac.")
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 560
        var gridRows: [[NSView]] = []
        for p in Permission.allCases {
            let icon = NSImageView(image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil) ?? NSImage())
            let title = NSTextField(labelWithString: p.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let why = NSTextField(labelWithString: p.why)
            why.font = .systemFont(ofSize: 11)
            why.textColor = .secondaryLabelColor
            let text = NSStackView(views: [title, why])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let state = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            let button = NSButton(title: "Open Settings", target: self, action: #selector(act(_:)))
            button.bezelStyle = .rounded
            button.tag = rows.count
            rows.append((p, state, label, button))
            let status = NSStackView(views: [state, label])
            status.spacing = 4
            status.widthAnchor.constraint(equalToConstant: 110).isActive = true
            gridRows.append([icon, text, status, button])
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        grid.column(at: 3).xPlacement = .trailing
        let stack = NSStackView(views: [intro, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        let size = stack.fittingSize
        window?.setContentSize(NSSize(width: max(600, size.width + 40), height: size.height + 40))
    }

    func refresh() {
        for (p, icon, label, button) in rows {
            let s = p.state
            let (sym, color, text): (String, NSColor, String) = s == .granted ? ("checkmark.circle.fill", .systemGreen, "Allowed")
                : s == .missing ? ("exclamationmark.circle.fill", .systemOrange, "Not allowed") : ("circle.dashed", .secondaryLabelColor, "Not asked yet")
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: text)
            icon.contentTintColor = color
            label.stringValue = text
            let asks: Set<Permission> = [.calendar, .reminders, .contacts, .speech, .automation]
            button.title = s == .unknown && asks.contains(p) ? "Allow…" : (s == .granted ? "Settings" : "Open Settings")
        }
    }

    @objc private func act(_ b: NSButton) {
        guard rows.indices.contains(b.tag) else { return }
        rows[b.tag].0.request { [weak self] in
            self?.refresh()
            // newly readable sources are picked up by the next index pass
            if let d = AppDelegate.shared, !d.indexingPaused { d.pendingIndex = d.indexer != nil; d.startIndexer() }
        }
    }
}
