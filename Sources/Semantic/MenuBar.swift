import AppKit
import SQLite3

// The menu bar item. The status line is read from the index only while the menu is open.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let show = NSMenuItem(title: "Show Semantic", action: #selector(showBar), keyEquivalent: "")
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pause = NSMenuItem(title: "Pause Indexing", action: #selector(togglePause), keyEquivalent: "")
    private var timer: Timer?

    // config `"menuBar": false` hides it; the bar's "settings" command still reaches everything
    static func apply() {
        guard let d = AppDelegate.shared else { return }
        if config.menuBar == false { d.menuBar?.remove(); d.menuBar = nil } else if d.menuBar == nil { d.menuBar = MenuBar() }
    }

    override init() {
        super.init()
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Semantic")
                ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Semantic")
            b.image?.isTemplate = true
            b.toolTip = "Semantic"
        }
        status.isEnabled = false
        func add(_ title: String, _ sel: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        show.target = self
        pause.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(status)
        menu.addItem(pause)
        add("Rebuild Index", #selector(rebuild))
        menu.addItem(.separator())
        add("Settings…", #selector(settings), ",")
        add("Permissions…", #selector(permissions))
        add("Open Config File", #selector(openConfig))
        menu.addItem(.separator())
        add("Quit Semantic", #selector(quit), "q")
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func refresh() {
        let key = AppDelegate.shared?.activeHotkey ?? .configured
        show.title = "Show Semantic    \(key.display)"
        pause.title = AppDelegate.shared?.indexingPaused == true ? "Resume Indexing" : "Pause Indexing"
        status.title = Self.statusLine()
    }

    static func statusLine() -> String {
        guard let d = AppDelegate.shared else { return "" }
        if d.indexingPaused { return d.indexer == nil ? "Indexing paused" : "Pausing…" }
        let store = Store(readonly: true)
        if d.indexer != nil { return "Indexing " + (store?.metaString("progress") ?? "…") }
        var n = 0
        store?.run("SELECT count(*) FROM files WHERE kind <= ?", [Kind.folder.rawValue]) { n = Int(sqlite3_column_int64($0, 0)) }
        return n == 0 ? "Index is empty" : "Index up to date · \(n.formatted()) items"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.status.title = Self.statusLine() }
        RunLoop.main.add(t, forMode: .common) // menus track in their own run loop mode
        timer = t
    }

    func menuDidClose(_ menu: NSMenu) { timer?.invalidate(); timer = nil }

    @objc private func showBar() {
        guard let d = AppDelegate.shared, !d.bar.isVisible else { return }
        d.toggle()
    }
    @objc private func togglePause() { AppDelegate.shared?.setIndexingPaused(!(AppDelegate.shared?.indexingPaused ?? false)) }
    @objc private func rebuild() { AppDelegate.shared?.rebuildIndex() }
    @objc private func settings() { SettingsWindow.show() }
    @objc private func permissions() { PermissionsWindow.show() }
    @objc private func openConfig() { SettingsWindow.openConfigFile() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate {
    func setIndexingPaused(_ paused: Bool) {
        indexingPaused = paused
        if paused {
            // a running pass is stopped; SQLite keeps what was already committed
            pendingIndex = false
            indexer?.terminate()
            Toast.show("Indexing paused")
        } else {
            Toast.show("Indexing resumed")
            startIndexer()
        }
        menuBar?.refresh()
    }

    // `--index --full`, after any running pass has exited (the indexer lock admits one at a time)
    func rebuildIndex() {
        indexingPaused = false
        if let running = indexer {
            pendingIndex = false
            running.terminationHandler = nil
            running.terminate()
            DispatchQueue.global(qos: .utility).async {
                running.waitUntilExit()
                DispatchQueue.main.async {
                    self.indexer = nil
                    self.progressTimer?.invalidate()
                    self.rebuildIndex()
                }
            }
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        lastIndexRun = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--index", "--full"]
        p.qualityOfService = .utility
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexer = nil
                self.progressTimer?.invalidate()
                self.bar.status = ""
                Engine.shared.reloadIndex()
                if self.pendingIndex { self.pendingIndex = false; self.startIndexer() }
            }
        }
        guard (try? p.run()) != nil else { return Toast.show("✗ Could not start the indexer", seconds: 4) }
        indexer = p
        Toast.show("Rebuilding the index…")
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let s = Store(readonly: true)?.metaString("progress") else { return }
            self.bar.status = "Indexing \(s)"
        }
        menuBar?.refresh()
    }
}
