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
    static func app(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var browserName: String {
        guard let u = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return "browser" }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
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
        let s = q.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
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
        command("reindex", "Reindex Files", "arrow.triangle.2.circlepath", ["sembar reindex", "rebuild the search index", "rescan my files"]) {
            AppDelegate.shared?.startIndexer()
        },
command("autopaste", "Let SemBar Paste into ChatGPT", "hand.tap", ["enable automatic paste into chatgpt", "allow sembar accessibility",
                                                                            "attach images to chatgpt automatically"]) {
            if AXIsProcessTrusted() { Toast.show("Already allowed") } else {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        },
                command("quit", "Quit SemBar", "xmark.circle", ["exit sembar", "close the search bar app"]) { NSApp.terminate(nil) },

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
    ]
}
