# Native AppKit components
Sources/Semantic/Panel.swift: RowView, ChipView, DropView, BarEditor, Toast. No web framework.
```swift
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

    static func accept(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            handler?(urls.map(\.path))
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = URL(fileURLWithPath: Paths.tmp)
            var got: [String] = []
            let group = DispatchGroup()
            for p in promises {
                for _ in 0..<max(1, p.fileTypes.count) { group.enter() }
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    if error == nil { got.append(url.path) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !got.isEmpty { handler?(got) } }
            return true
        }
        let paths = BarController.files(from: pb, imageEvenWithText: true)
        if !paths.isEmpty { handler?(paths) }
        return !paths.isEmpty
    }
}

final class DropView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Drops.types)
    }

    required init?(coder: NSCoder) { fatalError() }

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

final class RowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let tagLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        tagLabel.font = .systemFont(ofSize: 11.5)
        tagLabel.textColor = .tertiaryLabelColor
        tagLabel.alignment = .right
        for v in [icon, title, subtitle, tagLabel] { addSubview(v) }
        imageView = icon
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 12, y: 7, width: 30, height: 30)
        tagLabel.frame = NSRect(x: w - 112, y: 14, width: 100, height: 16)
        title.frame = NSRect(x: 52, y: 21, width: w - 172, height: 19)
        subtitle.frame = NSRect(x: 52, y: 5, width: w - 172, height: 15)
    }
}

// The attached file(s), shown as a pill in front of the text.
final class ChipView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    // returns the width the chip wants
    func set(_ files: [String]) -> CGFloat {
        guard let first = files.first else { return 0 }
        icon.image = NSWorkspace.shared.icon(forFile: first)
        label.stringValue = files.count == 1 ? (first as NSString).lastPathComponent : "\(files.count) files"
        let w = min(230, label.intrinsicContentSize.width + 4)
        icon.frame = NSRect(x: 7, y: 5, width: 20, height: 20)
        label.frame = NSRect(x: 31, y: 6, width: w, height: 18)
        return w + 40
    }
}

// A short confirmation that outlives the bar ("✓ Converted to JPEG → photo.jpg").
enum Toast {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var timer: Timer?

    static func show(_ text: String, seconds: Double = 2.4, sticky: Bool = false) {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 12
            fx.layer?.masksToBounds = true
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 13.5, weight: .medium)
            l.lineBreakMode = .byTruncatingMiddle
            fx.addSubview(l)
            p.contentView = fx
            (panel, label) = (p, l)
        }
        guard let panel, let label else { return }
        label.stringValue = text
        let w = min(560, label.intrinsicContentSize.width + 36)
        let mouse = NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.maxY - vf.height * 0.2 - 40, width: w, height: 38), display: true)
        label.frame = NSRect(x: 18, y: 10, width: w - 36, height: 18)
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = sticky ? nil : Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in panel.orderOut(nil) }
    }
}


```
