import AppKit

// The search panel: sections, stable layout while typing, multi-select, history, and the small text helpers.
enum PanelChecks {
    static func run(root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        let dir = root.appendingPathComponent("panel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ["invoice march.pdf", "invoice april.txt", "receipts.txt"].map { name -> String in
            let p = dir.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: p, contents: Data("invoice number 48291\nsecond line".utf8))
            return p
        }

        // a real one-page PDF in place of the first fixture
        let pdfURL = URL(fileURLWithPath: files[0]) as CFURL
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        if let ctx = CGContext(pdfURL, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: "Total due: invoice number 48291", attributes: [.font: NSFont.systemFont(ofSize: 18)]).draw(at: NSPoint(x: 30, y: 200))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()
        }
        let preview = FilePreview(frame: NSRect(x: 0, y: 0, width: 488, height: 370))
        preview.show(Hit(title: "invoice march.pdf", subtitle: "", icon: .file(files[0]), tag: "Document", path: files[0], excerpt: "the «invoice» number") { _ in })
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !(preview.pdfShownForChecks && !preview.metaForChecks.isEmpty) { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check("a PDF previews as its page with the excerpt's words marked", preview.pdfShownForChecks && preview.pdfMarksForChecks == 1)
        check("a PDF preview lists its pages and size", preview.metaForChecks.hasPrefix("1 page · "))
        preview.show(Hit(title: "invoice april.txt", subtitle: "", icon: .file(files[1]), tag: "Document", path: files[1], excerpt: "«number»") { _ in })
        let until = Date().addingTimeInterval(3)
        while Date() < until, preview.textForChecks == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check("a text preview marks the matched words", preview.markedForChecks == 1)
        preview.show(nil)

        check("excerpt marks are removed from plain text", Marked.plain("the «invoice» number") == "the invoice number")
        let a = Marked.attributed("a «bc» d", font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                                  strong: .boldSystemFont(ofSize: 12), strongColor: .labelColor)
        check("excerpt marks become emphasis without the guillemets", a.string == "a bc d"
              && (a.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("marked terms are listed once", Marked.terms("«tax» and «Tax» and «tax»") == ["tax", "Tax"])
        check("title highlighting matches word starts", Marked.ranges(of: "inv mar", in: "Invoice March.pdf").map(\.location) == [0, 8])
        check("title highlighting ignores filters and mid-word hits", Marked.ranges(of: "ext:pdf voice", in: "Invoice.pdf").isEmpty)
        check("camelCase counts as a word start", Marked.ranges(of: "bar", in: "FooBar.swift").map(\.location) == [3])

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check("relative dates: minutes", RelativeDate.text(now.addingTimeInterval(-120), now: now) == "2 min ago")
        check("relative dates: yesterday", RelativeDate.text(Calendar.current.date(byAdding: .day, value: -1, to: now)!, now: now) == "Yesterday")
        let old = Calendar.current.date(from: DateComponents(year: 2025, month: 3, day: 12, hour: 12))!
        check("relative dates: older years keep the full date", RelativeDate.text(old, now: now) == "12 Mar 2025")
        let fresh = files[0]
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        let stamp = f.string(from: (try? FileManager.default.attributesOfItem(atPath: fresh))?[.modificationDate] as? Date ?? Date())
        check("a subtitle's modification date reads relatively", RelativeDate.rewrite("~/x · \(stamp)", path: fresh).hasSuffix("Just now"))
        check("other dates in a subtitle are left alone", RelativeDate.rewrite("~/x · 1 Jan 2001", path: fresh) == "~/x · 1 Jan 2001")

        check("toast success prefix becomes an icon", Toast.parse("✓ Converted", sticky: false) == (.ok, "Converted"))
        check("toast failure prefix becomes a warning", Toast.parse("✗ Could not convert", sticky: false) == (.error, "Could not convert"))
        check("sticky working toast gets a spinner", Toast.parse("Working…", sticky: true).0 == .working)
        check("progress reads the indexer's status", BarController.parseProgress("Indexing contents 25/7000")! == (25, 7000, nil))
        check("progress reads JSON", BarController.parseProgress("Indexing {\"stage\":\"contents\",\"done\":3,\"total\":9,\"eta\":120}").map { $0.done == 3 && $0.total == 9 && $0.eta == 120 } == true)
        check("progress text", BarController.progressText((25, 7000, 120)) == "Indexing 25/7,000 · ~2 min")
        check("media subtitles give the matched time", FilePreview.time(in: "At 3:20 · ~/Movies") == 200 && FilePreview.time(in: "~/Movies") == nil)

        for (label, passed) in BarController.verifyPanel(files: files) { check(label, passed) }
        if let out = ProcessInfo.processInfo.environment["SEMANTIC_PANEL_SNAPSHOTS"] { BarController.snapshots(files: files, to: out) }
        return results
    }
}
