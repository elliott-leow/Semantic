import AppKit
import Carbon.HIToolbox

// "cmd+shift+space" <-> Carbon key code and modifiers.
struct Hotkey: Equatable {
    let code: UInt32
    let mods: UInt32   // Carbon cmdKey | shiftKey | optionKey | controlKey

    static let fallback = Hotkey(code: UInt32(kVK_ANSI_Y), mods: UInt32(cmdKey))

    static let keys: [String: Int] = {
        var k: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "delete": kVK_Delete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, c) in f.enumerated() { k["f\(i + 1)"] = c }
        return k
    }()
    static let aliases = ["enter": "return", "esc": "escape", "backspace": "delete", "comma": ",", "period": ".", "slash": "/",
                          "minus": "-", "equal": "=", "equals": "=", "grave": "`", "backtick": "`", "semicolon": ";", "quote": "'"]
    static let names: [Int: String] = Dictionary(keys.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })

    var isFunctionKey: Bool { Hotkey.names[Int(code)].map { $0.count > 1 && $0.hasPrefix("f") } ?? false }

    // nil for anything that is not a usable shortcut: unknown keys, or a plain key without a modifier
    init?(_ spec: String) {
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var mods: UInt32 = 0, key: String?
        for (i, p) in parts.enumerated() {
            // "cmd++" ends in an empty part that means the plus key itself, which has no ANSI code: reject
            guard !p.isEmpty else { return nil }
            switch p {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            default:
                guard i == parts.count - 1, key == nil else { return nil }
                key = Hotkey.aliases[p] ?? p
            }
        }
        guard let key, let code = Hotkey.keys[key] else { return nil }
        self.init(code: UInt32(code), mods: mods)
        guard mods != 0 || isFunctionKey else { return nil }
    }

    init(code: UInt32, mods: UInt32) { self.code = code; self.mods = mods }

    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        guard Hotkey.names[Int(event.keyCode)] != nil else { return nil }
        self.init(code: UInt32(event.keyCode), mods: m)
        guard m != 0 || isFunctionKey else { return nil }
    }

    static var configured: Hotkey { config.hotkey.flatMap(Hotkey.init) ?? fallback }

    // the form written to config.json
    var spec: String {
        var p: [String] = []
        if mods & UInt32(controlKey) != 0 { p.append("ctrl") }
        if mods & UInt32(optionKey) != 0 { p.append("alt") }
        if mods & UInt32(shiftKey) != 0 { p.append("shift") }
        if mods & UInt32(cmdKey) != 0 { p.append("cmd") }
        return (p + [Hotkey.names[Int(code)] ?? "?"]).joined(separator: "+")
    }

    // "⌃⌥⇧⌘Y", in the order macOS menus use
    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        let n = Hotkey.names[Int(code)] ?? "?"
        let shown = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫", "up": "↑", "down": "↓", "left": "←", "right": "→"]
        return s + (shown[n] ?? n.uppercased())
    }
}

extension AppDelegate {
    // Carbon hot keys need no Accessibility permission. The handler is installed once; the key can be swapped.
    @discardableResult
    func registerHotKey(_ key: Hotkey = .configured, announce: Bool = false) -> Bool {
        if !hotKeyHandlerInstalled {
            hotKeyHandlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { AppDelegate.shared?.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let old = hotKey
        unregisterHotKey()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x53454D42), id: 1) // 'SEMB'
        let rc = RegisterEventHotKey(key.code, key.mods, id, GetApplicationEventTarget(), 0, &ref)
        guard rc == noErr, let ref else {
            let why = rc == eventHotKeyExistsErr ? "another app already uses it" : "error \(rc)"
            log("could not register hotkey \(key.spec): \(why)")
            Toast.show("✗ Could not use \(key.display) as the Semantic shortcut: \(why)", seconds: 6)
            // keep whatever worked before
            if old != nil, let prev = activeHotkey, prev != key { _ = RegisterEventHotKey(prev.code, prev.mods, id, GetApplicationEventTarget(), 0, &hotKey) }
            return false
        }
        hotKey = ref
        activeHotkey = key
        if announce { Toast.show("✓ Semantic opens with \(key.display)") }
        menuBar?.refresh()
        return true
    }

    func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
