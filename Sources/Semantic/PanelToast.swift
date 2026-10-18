import AppKit

// A short confirmation that outlives the bar ("Converted to JPEG → photo.jpg").
// With an action ("Undo"), the toast takes clicks on its button and stays a little longer.
// Callers may still prefix "✓ " or "✗ "/"⚠ ": the prefix becomes an icon, and errors stay up longer.
enum Toast {
    struct Action {
        let title: String
        let run: () -> Void
    }

    enum Style: Equatable { case plain, ok, error, working }

    private final class Target: NSObject {
        var action: Action?
        @objc func fire() {
            let a = action
            action = nil
            Toast.hide()
            a?.run()
        }
    }

    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var button: NSButton?
    private static var icon: NSImageView?
    private static var spinner: NSProgressIndicator?
    private static let target = Target()
    private static var timer: Timer?

    static func parse(_ text: String, sticky: Bool) -> (Style, String) {
        for (p, s) in [("✓ ", Style.ok), ("✔ ", .ok), ("✗ ", .error), ("✕ ", .error), ("⚠ ", .error), ("⚠️ ", .error)] where text.hasPrefix(p) {
            return (s, String(text.dropFirst(p.count)))
        }
        if sticky && text.hasSuffix("…") { return (.working, text) }
        return (.plain, text)
    }

    static func hide() {
        timer?.invalidate()
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    static func show(_ text: String, seconds: Double = 2.4, sticky: Bool = false, action: Action? = nil) {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
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
            let i = NSImageView()
            i.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
            fx.addSubview(i)
            let s = NSProgressIndicator()
            s.style = .spinning
            s.controlSize = .small
            s.isDisplayedWhenStopped = false
            fx.addSubview(s)
            let b = NSButton(title: "", target: target, action: #selector(Target.fire))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            fx.addSubview(b)
            p.contentView = fx
            (panel, label, button, icon, spinner) = (p, l, b, i, s)
        }
        guard let panel, let label, let button, let icon, let spinner else { return }
        let (style, body) = parse(text, sticky: sticky)
        target.action = action
        label.stringValue = body
        button.title = action?.title ?? ""
        button.isHidden = action == nil
        panel.ignoresMouseEvents = action == nil
        switch style {
        case .ok:
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
            icon.contentTintColor = .systemGreen
        case .error:
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Problem")
            icon.contentTintColor = .systemOrange
        default: icon.image = nil
        }
        icon.isHidden = icon.image == nil
        if style == .working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let lead: CGFloat = style == .plain ? 18 : 40
        let buttonW: CGFloat = action == nil ? 0 : max(56, button.intrinsicContentSize.width + 12)
        let w = min(600, label.intrinsicContentSize.width + lead + 18 + (action == nil ? 0 : buttonW + 10))
        let mouse = NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.maxY - vf.height * 0.2 - 40, width: w, height: 38), display: true)
        icon.frame = NSRect(x: 14, y: 9, width: 20, height: 20)
        spinner.frame = NSRect(x: 15, y: 11, width: 16, height: 16)
        label.frame = NSRect(x: lead, y: 10, width: w - lead - 18 - (action == nil ? 0 : buttonW + 10), height: 18)
        button.frame = NSRect(x: w - 14 - buttonW, y: 7, width: buttonW, height: 24)
        panel.contentView?.setAccessibilityLabel(body)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: body, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        timer?.invalidate()
        // errors need reading time; an action needs time to reach for it
        let shown = max(seconds, style == .error ? 6 : 0, action == nil ? 0 : 6)
        timer = sticky ? nil : Timer.scheduledTimer(withTimeInterval: shown, repeats: false) { _ in
            target.action = nil
            spinner.stopAnimation(nil)
            panel.orderOut(nil)
        }
    }
}
