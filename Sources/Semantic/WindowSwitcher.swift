import AppKit
import ApplicationServices

// "switch to the figma window": open windows from the window server. Titles need Screen Recording;
// without it each app's windows collapse into one row per app. Raising one window needs Accessibility.
enum WindowSwitcher {
    struct Window {
        let pid: pid_t
        let app: String
        let title: String
        let appPath: String?
    }

    static func windows() -> [Window] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Window] = [], seenApps = Set<pid_t>()
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let owner = w[kCGWindowOwnerName as String] as? String,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            guard (b["Width"] ?? 0) >= 80, (b["Height"] ?? 0) >= 60 else { continue }
            let title = (w[kCGWindowName as String] as? String) ?? ""
            if title.isEmpty { if !seenApps.insert(pid).inserted { continue } }
            out.append(Window(pid: pid, app: app.localizedName ?? owner, title: title, appPath: app.bundleURL?.path))
        }
        // apps hidden or on another Space still count, as app rows
        let shown = Set(out.map(\.pid))
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !shown.contains(app.processIdentifier) && app.processIdentifier != me {
            out.append(Window(pid: app.processIdentifier, app: app.localizedName ?? "", title: "", appPath: app.bundleURL?.path))
        }
        return out
    }

    static func query(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "^(switch|go|jump|change)( over)? to |^(focus|show|bring up|raise|activate)\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b(the|my|window|windows|app)\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // every query word must start a word of the app name or the title
    static func matches(_ q: String, app: String, title: String) -> Bool {
        let words = nameTokens(q)
        guard !words.isEmpty else { return true }
        let have = nameTokens(app + " " + title)
        return words.allSatisfy { w in have.contains { $0.hasPrefix(w) } }
    }

    static func hits(_ text: String) -> [Hit] {
        let q = query(text)
        let all = windows()
        let found = all.filter { matches(q, app: $0.app, title: $0.title) }
        let titled = all.contains { !$0.title.isEmpty }
        let note = titled ? "" : " · window titles need Screen Recording"
        return found.prefix(8).map { w in
            let name = w.title.isEmpty ? w.app : "\(w.title) — \(w.app)"
            return Hit(title: "Switch to \(name)", subtitle: (w.title.isEmpty ? "App" : "Window") + note,
                       icon: w.appPath.map { .file($0) } ?? .symbol("macwindow"), tag: "Window", key: "window:" + w.app) { _ in
                activate(w)
            }
        }
    }

    static func activate(_ w: Window) {
        guard let app = NSRunningApplication(processIdentifier: w.pid) else { return }
        if app.isHidden { app.unhide() }
        app.activate()
        guard !w.title.isEmpty, AXIsProcessTrusted() else { return }
        let ax = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] else { return }
        for win in list {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
            guard (t as? String) == w.title else { continue }
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            break
        }
    }
}

// "quit spotify", "force quit chrome"
enum AppQuitter {
    static func parse(_ text: String) -> (name: String, force: Bool) {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let force = Calc.rx(t, "^(force[ -]?quit|force[ -]?close|kill)\\b.*") != nil
        let name = t.replacingOccurrences(of: "^(force[ -]?quit|force[ -]?close|kill|quit|close|exit)\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b(the|app|application|all|frozen|stuck)\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (name, force)
    }

    // whole name first, then a word of it: "chrome" finds Google Chrome
    static func rank(_ name: String, among names: [String]) -> [Int] {
        let q = name.lowercased(), words = nameTokens(q)
        guard !words.isEmpty else { return [] }
        func score(_ n: String) -> Int {
            let l = n.lowercased()
            if l == q { return 3 }
            if l.hasPrefix(q) { return 2 }
            let have = nameTokens(l)
            return words.allSatisfy { w in have.contains { $0.hasPrefix(w) } } ? 1 : 0
        }
        return names.indices.map { ($0, score(names[$0])) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func hits(_ text: String) -> [Hit] {
        let (name, force) = parse(text)
        let me = NSRunningApplication.current
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != me }
        let order = rank(name, among: apps.map { $0.localizedName ?? "" })
        return order.prefix(4).map { i in
            let app = apps[i], n = app.localizedName ?? "app"
            let icon: Icon = app.bundleURL.map { .file($0.path) } ?? .symbol("xmark.app")
            return Hit(title: force ? "Force Quit \(n)" : "Quit \(n)", subtitle: force ? "Unsaved changes are lost" : "Running app · ⌘↩ to force quit",
                       icon: icon, tag: "App", key: "quit:" + n) { alt in
                if force || alt {
                    Sys.confirm("Force quit \(n)? Unsaved changes will be lost.") { _ = app.forceTerminate() }
                } else if !app.terminate() { Toast.show("✗ \(n) did not quit", seconds: 3) }
            }
        }
    }
}

// Shortcuts.app shortcuts, by name. The list is cached briefly: `shortcuts list` takes a moment.
enum Shortcuts {
    private static var cache: (Date, [String])?
    private static let lock = NSLock()

    static func names() -> [String] {
        lock.lock()
        if let (t, n) = cache, Date().timeIntervalSince(t) < 120 { lock.unlock(); return n }
        lock.unlock()
        let out = (try? FileOps.sh("/usr/bin/shortcuts", ["list"])) ?? ""
        let n = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lock.lock(); cache = (Date(), n); lock.unlock()
        return n
    }

    static func query(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "^(run|start|do|launch|open)( the| my)? (shortcut|shortcuts)( called| named)?\\s*|^(shortcut|shortcuts)\\s+|\\s+shortcut$", with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func hits(_ text: String) -> [Hit] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts") else { return [] }
        let q = query(text), all = names()
        let order = q.isEmpty ? Array(all.indices) : AppQuitter.rank(q, among: all)
        return order.prefix(5).map { i in
            let name = all[i]
            return Hit(title: "Run shortcut “\(name)”", subtitle: "Shortcuts", icon: .symbol("square.2.layers.3d"), tag: "Shortcut", key: "shortcut:" + name) { _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try FileOps.sh("/usr/bin/shortcuts", ["run", name])
                        DispatchQueue.main.async { Toast.show("✓ Ran \(name)") }
                    } catch { DispatchQueue.main.async { Toast.show("✗ \(name): \(error.localizedDescription)", seconds: 4) } }
                }
            }
        }
    }
}
