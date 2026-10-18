import AppKit
import ApplicationServices
import Foundation

enum Icon {
    case file(String)    // icon / thumbnail of the file at this path
    case symbol(String)  // SF Symbol
}

struct Hit {
    let title: String
    let subtitle: String
    let icon: Icon
    let tag: String
    var score: Float = 0
    var key: String?      // identity for learning from what the user picks
    var selectionID: String? // execution identity may differ from the learning key
    var selectionIdentity: String { selectionID ?? key ?? path ?? title }
    var path: String?     // a real file: can be attached to the bar or previewed
    var excerpt = ""    // matched content, shown separately from its path
    var previewPage = 1
    var isPending = false
    var unavailableReason: String?
    var stay = false      // keep the bar open after running
    var promote = false   // a refined row that should move to the top
    var why = ""          // how the score was made up ("name 16 · meaning 2.1 · habit 1"), shown while ⌥ is held
    var date: Double? = nil  // modification/start time, formatted relatively by the panel
    // asks the language model for a better version of this row; nil means keep it
    var refine: ((@escaping (Hit?) -> Void) -> Void)?
    let run: (_ alt: Bool) -> Void
}

// An intent is recognised by embedding similarity to its exemplars, then turned into rows.
struct Intent {
    let id: String
    let exemplars: [String]
    let hits: (String) -> [Hit]
}

enum Sys {
    // Launch Services lookups run on every keystroke; remembered briefly, so a newly installed app or
    // a changed default browser still shows up within half a minute.
    private static let lookupLock = NSLock()
    private static var apps: [String: (URL?, Date)] = [:]
    private static var browser: (String, Date)?

    static func app(_ bundleID: String) -> URL? {
        lookupLock.lock()
        if let (u, t) = apps[bundleID], Date().timeIntervalSince(t) < 30 { lookupLock.unlock(); return u }
        lookupLock.unlock()
        let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        lookupLock.lock(); apps[bundleID] = (u, Date()); lookupLock.unlock()
        return u
    }

    static var browserName: String {
        lookupLock.lock()
        if let (n, t) = browser, Date().timeIntervalSince(t) < 30 { lookupLock.unlock(); return n }
        lookupLock.unlock()
        let n = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        } ?? "browser"
        lookupLock.lock(); browser = (n, Date()); lookupLock.unlock()
        return n
    }

    static func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    static func enc(_ s: String) -> String {
        var ok = CharacterSet.urlQueryAllowed
        ok.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }

    static func script(_ src: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", src]
        try? p.run()
    }

    static func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    static func lock() {
        typealias Fn = @convention(c) () -> Int32
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return shell("/usr/bin/pmset", ["displaysleepnow"]) }
        _ = unsafeBitCast(sym, to: Fn.self)()
    }

    static func confirm(_ text: String, _ then: () -> Void) {
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Continue")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { then() }
    }

    static func webSearchURL(_ q: String) -> String {
        (config.searchURL ?? "https://www.google.com/search?q=%s").replacingOccurrences(of: "%s", with: enc(q))
    }
}

enum Actions {
    static func strip(_ q: String, _ pattern: String) -> String {
        let s = Rx.replace(q, pattern, "", .caseInsensitive)
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? q : t
    }

    static func web(_ q: String) -> Hit {
        Hit(title: "Search the web for “\(q)”", subtitle: Sys.browserName, icon: .symbol("magnifyingglass"), tag: "Web") { _ in
            Sys.open(Sys.webSearchURL(q))
        }
    }

    static func command(_ id: String, _ title: String, _ symbol: String, _ aliases: [String], _ run: @escaping () -> Void) -> Intent {
        Intent(id: id, exemplars: [title.lowercased()] + aliases) { _ in
            [Hit(title: title, subtitle: "System command", icon: .symbol(symbol), tag: "Command") { _ in run() }]
        }
    }

    static func settings(_ name: String, _ pane: String, _ symbol: String, _ aliases: [String]) -> Intent {
        Intent(id: "settings." + name, exemplars: ["\(name.lowercased()) settings"] + aliases) { _ in
            [Hit(title: "\(name) Settings", subtitle: "System Settings", icon: .symbol(symbol), tag: "Settings") { _ in
                Sys.open("x-apple.systempreferences:" + pane)
            }]
        }
    }

    static let all: [Intent] = [
        // "file" produces no rows: when it wins, the query is a file/app lookup
        Intent(id: "file", exemplars: [
            "ifp syllabus", "screenshot with bar receipt", "photo of my dog at the beach", "tax return pdf", "lecture recording audio",
            "the video from graduation", "my resume", "invoice from march", "chemistry lab report", "picture of a whiteboard",
            "presentation slides for the pitch", "spreadsheet with the budget", "that song i recorded", "notes on organic chemistry",
            "downloads folder", "passport scan", "screenshot of an error message", "podcast episode draft",
        ]) { _ in [] },

        Intent(id: "places", exemplars: [
            "seafood restaurants near me", "coffee shops nearby", "nearest pharmacy", "directions to the airport", "gas station near me",
            "best ramen in tokyo", "how do i get to central park", "hotels in barcelona", "atm around here", "bars open now near me",
            "map of singapore", "gym close to me", "directions to changi airport", "route from home to the office",
            "how far is the nearest hospital", "where can i eat around here",
        ]) { q in
            let browser = Hit(title: "Find “\(q)” on Google Maps", subtitle: Sys.browserName, icon: .symbol("map"), tag: "Maps") { _ in
                Sys.open("https://www.google.com/maps/search/" + Sys.enc(q))
            }
            // only offered when a native maps app is actually installed
            let native = Sys.app("com.apple.Maps").map { _ in
                Hit(title: "Find “\(q)” in Apple Maps", subtitle: "Maps", icon: .file("/System/Applications/Maps.app"), tag: "Maps") { _ in
                    Sys.open("maps://?q=" + Sys.enc(q))
                }
            }
            let rows = config.maps == "apple" ? [native, browser] : [browser, native]
            return rows.compactMap { $0 }
        },

        Intent(id: "web", exemplars: [
            "how do i center a div", "what is the capital of australia", "weather tomorrow", "latest news about the election",
            "python list comprehension syntax", "buy noise cancelling headphones", "who won the world cup", "convert usd to sgd",
            "symptoms of the flu", "reviews of the new macbook", "how to tie a tie", "flight status", "stock price of apple",
            "why is the sky blue", "recipe for carbonara", "weather", "news", "translate hello to french",
            "wikipedia alan turing", "nba scores", "bitcoin price", "time in london",
        ]) { q in [web(q)] },

        Intent(id: "youtube", exemplars: ["youtube lofi beats", "watch a video about black holes", "youtube tutorial for blender",
                                          "search youtube for cooking videos"]) { q in
            let t = strip(q, "^(search\\s+)?(on\\s+)?youtube(\\s+for)?\\s+|\\s+on youtube$")
            return [Hit(title: "Search YouTube for “\(t)”", subtitle: Sys.browserName, icon: .symbol("play.rectangle"), tag: "Web") { _ in
                Sys.open("https://www.youtube.com/results?search_query=" + Sys.enc(t))
            }]
        },

        Intent(id: "music", exemplars: ["play radiohead", "play some jazz music", "play the new taylor swift album", "listen to daft punk",
                                        "put on a workout playlist"]) { q in
            let t = strip(q, "^(play|listen to|put on)\\s+(some\\s+)?")
            if Sys.app("com.spotify.client") != nil {
                return [Hit(title: "Play “\(t)” in Spotify", subtitle: "Spotify", icon: .file(Sys.app("com.spotify.client")!.path), tag: "Music") { _ in
                    Sys.open("spotify:search:" + Sys.enc(t))
                }]
            }
            if Sys.app("com.apple.Music") != nil {
                return [Hit(title: "Search Apple Music for “\(t)”", subtitle: "Music", icon: .symbol("music.note"), tag: "Music") { _ in
                    Sys.open("music://music.apple.com/search?term=" + Sys.enc(t))
                }]
            }
            return [Hit(title: "Play “\(t)” on YouTube", subtitle: Sys.browserName, icon: .symbol("music.note"), tag: "Music") { _ in
                Sys.open("https://www.youtube.com/results?search_query=" + Sys.enc(t))
            }]
        },

        Intent(id: "define", exemplars: ["define serendipity", "meaning of ephemeral", "definition of ubiquitous", "what does obsequious mean",
                                         "synonym for happy"]) { q in
            let t = strip(q, "^(define|meaning of|definition of|synonyms? for|what does)\\s+|\\s+mean\\??$")
            if Sys.app("com.apple.Dictionary") != nil {
                return [Hit(title: "Look up “\(t)”", subtitle: "Dictionary", icon: .symbol("character.book.closed"), tag: "Dictionary") { _ in
                    Sys.open("dict://" + Sys.enc(t))
                }]
            }
            return [web("define " + t)]
        },

        command("lock", "Lock Screen", "lock", ["lock my mac", "lock the computer"]) { Sys.lock() },
        command("sleep", "Sleep", "moon.zzz", ["put the mac to sleep", "go to sleep"]) { Sys.shell("/usr/bin/pmset", ["sleepnow"]) },
        command("displayoff", "Turn Display Off", "display", ["sleep the display", "screen off"]) { Sys.shell("/usr/bin/pmset", ["displaysleepnow"]) },
        command("dark", "Toggle Dark Mode", "circle.lefthalf.filled", ["switch to dark mode", "light mode", "change appearance to dark"]) {
            Sys.script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        },
        command("mute", "Toggle Mute", "speaker.slash", ["mute the sound", "unmute audio", "silence the volume"]) {
            Sys.script("set volume output muted not (output muted of (get volume settings))")
        },
        command("trash", "Empty Trash", "trash", ["empty the bin", "delete everything in the trash"]) {
            Sys.confirm("Permanently delete everything in the Trash?") { Sys.script("tell application \"Finder\" to empty trash") }
        },
        // loginwindow shows its own confirmation dialog for these three
        command("restart", "Restart…", "restart", ["reboot the mac", "restart computer"]) {
            Sys.script("tell application \"loginwindow\" to «event aevtrrst»")
        },
        command("shutdown", "Shut Down…", "power", ["turn off the mac", "power off computer"]) {
            Sys.script("tell application \"loginwindow\" to «event aevtrsdn»")
        },
        command("logout", "Log Out…", "rectangle.portrait.and.arrow.right", ["sign out of my account"]) {
            Sys.script("tell application \"loginwindow\" to «event aevtrlgo»")
        },
        command("reindex", "Reindex Files", "arrow.triangle.2.circlepath", ["semantic reindex", "rebuild the search index", "rescan my files"]) {
            guard let d = AppDelegate.shared else { return }
            if d.indexingPaused { d.setIndexingPaused(false) } else { d.startIndexer() }
        },
        command("autopaste", "Let Semantic Paste into ChatGPT", "hand.tap", ["enable automatic paste into chatgpt", "allow semantic accessibility",
                                                                            "attach images to chatgpt automatically"]) {
            if AXIsProcessTrusted() { Toast.show("Already allowed") } else {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        },
        command("quit", "Quit Semantic", "xmark.circle", ["exit semantic", "close the search bar app"]) { NSApp.terminate(nil) },
        Intent(id: "semantic.settings", exemplars: ["semantic settings", "preferences", "settings", "change the semantic hotkey",
                                                    "semantic preferences", "change which folders are indexed", "configure semantic"]) { _ in
            [Hit(title: "Semantic Settings…", subtitle: "Shortcut, folders, sources, clipboard, Ask destination", icon: .symbol("gearshape"), tag: "Semantic") { _ in
                SettingsWindow.show()
            }]
        },
        Intent(id: "semantic.permissions", exemplars: ["semantic permissions", "permissions", "grant semantic access", "what can semantic access",
                                                       "allow full disk access for semantic"]) { _ in
            [Hit(title: "Semantic Permissions…", subtitle: "What is allowed, and where to change it", icon: .symbol("hand.raised"), tag: "Semantic") { _ in
                PermissionsWindow.show()
            }]
        },
        Intent(id: "clipboard.clear", exemplars: ["clear clipboard history", "delete my clipboard history", "forget everything i copied",
                                                  "erase clipboard history"]) { _ in
            [Hit(title: "Clear Clipboard History", subtitle: "Deletes the copies Semantic kept", icon: .symbol("clipboard"), tag: "Command") { _ in
                Sys.confirm("Delete all clipboard history kept by Semantic?") { ClipboardHistory.clearAll() }
            }]
        },
        Intent(id: "window", exemplars: ["switch to the safari window", "go to my figma window", "switch to chrome", "focus the terminal window",
                                         "bring up the mail window", "show my open windows", "jump to the notes window"]) { q in
            WindowSwitcher.hits(q)
        },
        Intent(id: "quitapp", exemplars: ["quit spotify", "force quit chrome", "close the safari app", "kill the frozen app", "quit slack",
                                          "force quit xcode", "exit zoom"]) { q in
            AppQuitter.hits(q)
        },
        Intent(id: "emoji", exemplars: ["emoji party", "smile emoji", "heart emoji", "thumbs up emoji", "crying laughing emoji", "fire emoji",
                                        "emoji for celebration"]) { q in
            AppEmoji.hits(q)
        },
        Intent(id: "shortcut", exemplars: ["run shortcut morning routine", "run the shortcut called resize images", "start my shortcut",
                                           "shortcuts log water", "run shortcut"]) { q in
            Shortcuts.hits(q)
        },

        settings("Wi-Fi", "com.apple.wifi-settings-extension", "wifi", ["connect to a wireless network", "wifi"]),
        settings("Bluetooth", "com.apple.BluetoothSettings", "dot.radiowaves.left.and.right", ["pair bluetooth headphones", "bluetooth"]),
        settings("Displays", "com.apple.Displays-Settings.extension", "display.2", ["screen resolution", "arrange monitors", "night shift"]),
        settings("Sound", "com.apple.Sound-Settings.extension", "speaker.wave.2", ["audio output device", "change microphone input"]),
        settings("Battery", "com.apple.Battery-Settings.extension", "battery.75", ["low power mode", "battery health"]),
        settings("Keyboard", "com.apple.Keyboard-Settings.extension", "keyboard", ["keyboard shortcuts", "key repeat rate"]),
        settings("Network", "com.apple.Network-Settings.extension", "network", ["vpn settings", "ethernet dns"]),
        settings("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", "hand.raised", ["app permissions", "accessibility permissions", "full disk access"]),
        settings("Software Update", "com.apple.Software-Update-Settings.extension", "gear.badge", ["update macos", "check for updates"]),
        settings("Storage", "com.apple.settings.Storage", "internaldrive", ["free disk space", "how much storage is left"]),
        settings("Wallpaper", "com.apple.Wallpaper-Settings.extension", "photo", ["change desktop background"]),
        settings("Login Items", "com.apple.LoginItems-Settings.extension", "person.badge.key", ["apps that open at startup", "launch at login"]),
        settings("Notifications", "com.apple.Notifications-Settings.extension", "bell.badge", ["turn off notifications", "notification banners"]),
        settings("Focus", "com.apple.Focus-Settings.extension", "moon", ["do not disturb", "focus modes"]),
        settings("Trackpad", "com.apple.Trackpad-Settings.extension", "rectangle.and.hand.point.up.left", ["tap to click", "trackpad gestures", "scroll direction"]),
        settings("Mouse", "com.apple.Mouse-Settings.extension", "computermouse", ["mouse speed", "mouse tracking"]),
        settings("Desktop & Dock", "com.apple.Desktop-Settings.extension", "dock.rectangle", ["hide the dock", "dock size", "hot corners", "stage manager"]),
        settings("Control Center", "com.apple.ControlCenter-Settings.extension", "switch.2", ["menu bar icons", "show battery percentage"]),
        settings("Appearance", "com.apple.Appearance-Settings.extension", "paintpalette", ["accent color", "scroll bar visibility"]),
        settings("Accessibility", "com.apple.Accessibility-Settings.extension", "accessibility", ["zoom the screen", "voiceover", "reduce motion"]),
        settings("Lock Screen", "com.apple.Lock-Screen-Settings.extension", "lock.display", ["screen saver delay", "require password after sleep"]),
        settings("Users & Groups", "com.apple.Users-Groups-Settings.extension", "person.2", ["add a user account", "guest user"]),
        settings("Passwords", "com.apple.Passwords-Settings.extension", "key", ["saved passwords", "password manager"]),
        settings("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", "touchid", ["add a fingerprint", "change login password"]),
        settings("Date & Time", "com.apple.Date-Time-Settings.extension", "clock", ["change time zone", "24 hour clock"]),
        settings("Language & Region", "com.apple.Localization-Settings.extension", "globe", ["change language", "date format", "temperature units"]),
        settings("Time Machine", "com.apple.Time-Machine-Settings.extension", "clock.arrow.circlepath", ["back up my mac", "backup disk"]),
        settings("Sharing", "com.apple.Sharing-Settings.extension", "person.2.wave.2", ["airdrop settings", "file sharing", "computer name"]),
        settings("Screen Time", "com.apple.Screen-Time-Settings.extension", "hourglass", ["app limits", "downtime"]),
        settings("Printers & Scanners", "com.apple.Print-Scanner-Settings.extension", "printer", ["add a printer", "default printer"]),
        settings("Spotlight", "com.apple.Spotlight-Settings.extension", "magnifyingglass", ["spotlight privacy", "exclude folders from spotlight"]),
        settings("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension", "at", ["add an email account", "google account"]),
        settings("Siri", "com.apple.Siri-Settings.extension", "mic", ["apple intelligence", "voice assistant"]),
        settings("About This Mac", "com.apple.SystemProfiler.AboutExtension", "info.circle", ["mac serial number", "which macos version", "about my mac"]),
    ]
}
