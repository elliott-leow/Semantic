import AppKit
import AVFoundation
import CoreText
import Foundation
import SQLite3

enum IndexerChecks {
    // Runs inside the isolated test environment: `root` is the configured index root, the data dir is temporary.
    static func run(root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("indexer-checks")
        defer {
            try? fm.removeItem(at: dir)
            _ = Indexer.run(full: false, namesOnly: true, paths: nil) // leave the shared index as other checks expect it
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            func write(_ rel: String, _ text: String) throws {
                let u = dir.appendingPathComponent(rel)
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: u, atomically: true, encoding: .utf8)
            }
            func zip(_ name: String, _ members: [String: String]) throws -> URL {
                let src = dir.appendingPathComponent("zip-src-" + name)
                for (rel, text) in members {
                    let u = src.appendingPathComponent(rel)
                    try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: u, atomically: true, encoding: .utf8)
                }
                let out = dir.appendingPathComponent("archives/" + name)
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = src
                p.arguments = ["-qr", out.path, "."]
                try p.run()
                p.waitUntilExit()
                try fm.removeItem(at: src)
                return out
            }

            // excludes and .semanticignore
            let rules = IndexRules(["~/Private", "*.secret", dir.path + "/walk/private", dir.path + "/walk/*/deep"])
            check("excluded folder prefix covers its subtree", rules.excluded(Paths.home + "/Private/a.txt") && !rules.excluded(Paths.home + "/PrivateNot/a.txt"))
            check("excluded name glob matches anywhere", rules.excluded("/x/y/keys.secret") && !rules.excluded("/x/y/keys.txt"))
            let walkDir = dir.appendingPathComponent("walk")
            try write("walk/.semanticignore", "# comment\n*.log\nsecret/\n/sub/skip.txt\n")
            for f in ["a.txt", "b.log", "secret/x.txt", "sub/skip.txt", "sub/keep.txt", "sub/n.md", "other.md", "private/p.txt", "z.secret", "sub/inner/deep/d.txt", "node_modules/m.js"] {
                try write("walk/" + f, "fixture " + f)
            }
            try write("walk/sub/.semanticignore", "*.md\n")
            let found = Set(Indexer.walk(walkDir.path, rules: rules).map { String($0.path.dropFirst(walkDir.path.count + 1)) })
            check(".semanticignore and excludes are respected by the walk",
                  found.isSuperset(of: ["a.txt", "other.md", "sub", "sub/keep.txt", "sub/inner"]) &&
                  found.isDisjoint(with: ["b.log", "secret", "secret/x.txt", "sub/skip.txt", "sub/n.md", "private", "private/p.txt", "z.secret",
                                          "sub/inner/deep", "sub/inner/deep/d.txt", "node_modules", "node_modules/m.js"]))
            let shallow = Set(Indexer.walk(walkDir.path, recursive: false, rules: rules).map { String($0.path.dropFirst(walkDir.path.count + 1)) })
            check("an incremental listing stays one level deep", shallow.contains("sub") && shallow.contains("a.txt") && !shallow.contains("sub/keep.txt"))
            let subOnly = Set(Indexer.walk(walkDir.path + "/sub", rules: rules).map { String($0.path.dropFirst(walkDir.path.count + 1)) })
            check("a walk below the root inherits ignore rules from above", subOnly.contains("sub/keep.txt") && !subOnly.contains("sub/skip.txt") && !subOnly.contains("sub/n.md"))
            check("folders inside skipped or ignored folders are never scanned",
                  Indexer.start(walkDir.path + "/node_modules", roots: [walkDir.path]) == nil && Indexer.start(walkDir.path + "/secret", roots: [walkDir.path]) == nil &&
                  Indexer.start(walkDir.path + "/sub", roots: [walkDir.path]) != nil)
            check("the watcher ignores hidden and dependency folders", Indexer.ignorable(walkDir.path + "/.git/index", roots: [walkDir.path]) &&
                  Indexer.ignorable(walkDir.path + "/node_modules/x/y.js", roots: [walkDir.path]) && !Indexer.ignorable(walkDir.path + "/sub/a.txt", roots: [walkDir.path]) &&
                  Indexer.ignorable("/elsewhere/a.txt", roots: [walkDir.path]))

            // attempts and backoff
            guard let mem = Store(path: ":memory:") else { check("attempt fixture database opens", false); return results }
            Indexer.migrate(mem)
            Indexer.migrate(mem)
            var cols: [String] = []
            mem.run("PRAGMA table_info(files)") { cols.append(colText($0, 1)) }
            check("indexer columns migrate idempotently", cols.filter { ["attempts", "retryAt", "contentHash"].contains($0) }.count == 3)
            mem.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES('/locked.pdf','locked.pdf',?,0,1,3,'')", [Kind.doc.rawValue])
            let locked = mem.lastID
            mem.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet,textIndexed) VALUES('/bad.png','bad.png',?,0,1,0,'',1)", [Kind.image.rawValue])
            let bad = mem.lastID
            func row(_ id: Int64) -> (attempts: Int, retryAt: Double, state: Int, text: Int) {
                var r = (0, 0.0, -1, -1)
                mem.run("SELECT attempts,retryAt,state,textIndexed FROM files WHERE id=?", [id]) {
                    r = (Int(sqlite3_column_int($0, 0)), sqlite3_column_double($0, 1), Int(sqlite3_column_int($0, 2)), Int(sqlite3_column_int($0, 3)))
                }
                return r
            }
            let first = Indexer.recordFailure(mem, id: locked, now: 1000)
            check("a first failure backs off and stays pending", !first && row(locked) == (1, 1900, 3, 0))
            let second = Indexer.recordFailure(mem, id: locked, now: 2000)
            check("a second failure backs off longer", !second && row(locked).attempts == 2 && row(locked).retryAt == 2000 + 3600)
            let third = Indexer.recordFailure(mem, id: locked, now: 9000)
            check("the third failure gives up on content and keeps one pass for a name vector", third && row(locked) == (3, 0, 3, 1))
            Indexer.recordFailure(mem, id: locked, now: 9100)
            check("a failure after giving up completes the file", row(locked).state == 1)
            for t in [1.0, 2, 3] { Indexer.recordFailure(mem, id: bad, now: t) }
            check("media that never decodes is marked complete after three runs", row(bad).state == 1)
            check("a given-up file still gets a name-only description",
                  Indexer.placeholder(Indexer.Cand(path: "/x/locked.pdf", name: "locked.pdf", kind: .doc, mtime: 0, size: 0)).1 == "pdf file in x")

            // passage vectors and their replacement
            mem.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,0),(?,?,?,2)", [locked, Src.text.rawValue, Data([1]), locked, Src.text.rawValue, Data([2])])
            Indexer.persistMediaExtraction(mem, id: locked, vectors: [Indexer.MediaVector(src: .text, data: Data([3]), loc: 1)])
            var vecs: [Double] = []
            mem.run("SELECT loc FROM vecs WHERE file_id=? AND src=? ORDER BY loc", [locked, Src.text.rawValue]) { vecs.append(sqlite3_column_double($0, 0)) }
            check("passage vectors are replaced while the file's own text vector stays", vecs == [0, 1])

            // long text into passages
            let words = (0..<2500).map { "word\($0)" }.joined(separator: " ")
            let parts = Extract.split(words)
            check("long text splits at spaces into bounded passages", parts.count >= 6 && parts.allSatisfy { $0.count <= 3000 } && parts.joined(separator: " ") == words)
            try write("long.md", words + " ZEBRAMARKER")
            let longPassages = Extract.keywordPassagesResult(dir.appendingPathComponent("long.md"), kind: .doc) ?? []
            check("text beyond the first 3000 characters lands in a numbered passage",
                  longPassages.count == parts.count && longPassages.last?.text.contains("ZEBRAMARKER") == true && longPassages.last?.loc == Double(parts.count - 1))
            check("the text vector body comes from stored passages", Extract.summary(longPassages).count == 3000 && Extract.summary(longPassages).hasPrefix("word0 word1"))
            let stored = [Extract.Passage(text: String(repeating: "page one text ", count: 10), src: .page, loc: 1),
                          Extract.Passage(text: "short", src: .page, loc: 2),
                          Extract.Passage(text: String(repeating: "page three text ", count: 10), src: .page, loc: 3)]
            check("PDF page vectors come from stored page passages", Extract.pdfPages(stored).map(\.0) == [1, 3] && Extract.pdfPages(Array(stored.prefix(1))).isEmpty)

            // formats
            let epub = try zip("book.epub", ["mimetype": "application/epub+zip", "OEBPS/ch1.xhtml": "<html><body><p>Zanzibar &amp; marmalade</p></body></html>",
                                             "OEBPS/ch2.xhtml": "<html><head><style>p{}</style></head><body><p>second chapter quokka</p></body></html>"])
            let epubText = Extract.textResult(epub, ext: "epub", limit: 10000) ?? ""
            check("EPUB chapters are read", epubText.contains("Zanzibar & marmalade") && epubText.contains("quokka") && !epubText.contains("p{}"))
            var slides: [String: String] = [:]
            for i in 1...6 { slides["ppt/slides/slide\(i).xml"] = "<p:sld><a:t>slide\(i) text</a:t></p:sld>" }
            slides["ppt/notesSlides/notesSlide1.xml"] = "<a:t>speaker notes wombat</a:t>"
            let pptx = try zip("deck.pptx", slides)
            let pptxText = Extract.textResult(pptx, ext: "pptx", limit: 10000) ?? ""
            check("every PowerPoint slide and the notes are read", pptxText.contains("slide6 text") && pptxText.contains("slide1 text") && pptxText.contains("wombat"))
            let xlsx = try zip("book.xlsx", ["xl/sharedStrings.xml": "<sst><si><t>SharedWord</t></si></sst>",
                                             "xl/workbook.xml": "<workbook><sheets><sheet name=\"Budget2026\" sheetId=\"1\"/></sheets></workbook>",
                                             "xl/worksheets/sheet1.xml": "<worksheet><c r=\"A1\" t=\"inlineStr\"><is><t>InlineWord</t></is></c><c r=\"A2\"><v>3</v></c></worksheet>"])
            let xlsxText = Extract.textResult(xlsx, ext: "xlsx", limit: 10000) ?? ""
            check("spreadsheets add sheet names and inline strings to shared strings",
                  xlsxText.contains("SharedWord") && xlsxText.contains("Budget2026") && xlsxText.contains("InlineWord"))
            // iWork: preview PDF inside a package folder and inside a zip file
            let pdfData = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 400, height: 200)
            let ctx = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Keynote preview platypus", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            ctx.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            let bundle = dir.appendingPathComponent("talk.key")
            try fm.createDirectory(at: bundle.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
            try (pdfData as Data).write(to: bundle.appendingPathComponent("QuickLook/Preview.pdf"))
            check("a Keynote package is read through its preview PDF", Extract.textResult(bundle, ext: "key")?.contains("platypus") == true)
            let src = dir.appendingPathComponent("zip-src-pages")
            try fm.createDirectory(at: src.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
            try (pdfData as Data).write(to: src.appendingPathComponent("QuickLook/Preview.pdf"))
            let pages = dir.appendingPathComponent("archives/letter.pages")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = src
            p.arguments = ["-qr", pages.path, "."]
            try p.run()
            p.waitUntilExit()
            check("a zipped Pages file is read through its preview PDF", Extract.textResult(pages, ext: "pages")?.contains("platypus") == true)
            let noPreview = try zip("empty.numbers", ["Index/Document.iwa": "binary"])
            check("an iWork file without a preview completes with no text", Extract.textResult(noPreview, ext: "numbers") == "")
            try Data("not a zip".utf8).write(to: dir.appendingPathComponent("broken.key"))
            check("a broken iWork file stays retryable", Extract.textResult(dir.appendingPathComponent("broken.key"), ext: "key") == nil)

            // content hash
            try write("hash/a.bin", String(repeating: "x", count: 200_000))
            let h1 = Extract.contentHash(dir.path + "/hash/a.bin")
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: dir.path + "/hash/a.bin")
            let h2 = Extract.contentHash(dir.path + "/hash/a.bin")
            try write("hash/a.bin", String(repeating: "x", count: 199_999) + "y")
            check("content hash ignores mtime and sees a changed tail", h1 != nil && h1 == h2 && Extract.contentHash(dir.path + "/hash/a.bin") != h1 &&
                  Extract.contentHash(dir.path + "/hash") == nil)

            // media helpers
            let wav = dir.appendingPathComponent("tone.wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
            buffer.frameLength = 32000
            for i in 0..<32000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.2 }
            do { try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer) }
            check("an audio-only container has no video frames, without failing", Extract.videoFramesResult(wav)?.isEmpty == true)
            let pcm = Extract.soundtrack(wav, seconds: 1)
            check("a soundtrack decodes to 16 kHz mono and respects the duration cap", pcm.map { abs($0.count - 16000) < 1600 } == true)
            check("an undecodable soundtrack is a retryable failure", Extract.soundtrack(dir.appendingPathComponent("broken.key"), seconds: 5) == nil)

            // source cadence
            check("sources are re-read hourly, on --full, and when a browser database changed",
                  !Indexer.sourceDue(full: false, enabled: true, now: 5000, last: 4000, signature: "a", previous: "a") &&
                  Indexer.sourceDue(full: false, enabled: true, now: 8000, last: 4000, signature: "a", previous: "a") &&
                  Indexer.sourceDue(full: true, enabled: true, now: 4001, last: 4000, signature: "a", previous: "a") &&
                  Indexer.sourceDue(full: false, enabled: true, now: 4400, last: 4000, signature: "b", previous: "a") &&
                  !Indexer.sourceDue(full: false, enabled: true, now: 4100, last: 4000, signature: "b", previous: "a") &&
                  Indexer.sourceDue(full: false, enabled: false, now: 4001, last: 4000, signature: "off", previous: "on") &&
                  Indexer.sourceDue(full: false, enabled: true, now: 4001, last: 4000, signature: "on", previous: "off") &&
                  !Indexer.sourceDue(full: false, enabled: true, now: 4400, last: 4000, signature: "on", previous: "on"))
            let safari: [String: Any] = ["Children": [["Title": "BookmarksBar", "Children": [["URLString": "https://example.com/a", "URIDictionary": ["title": "Example A"]]]],
                                                      ["URLString": "https://example.com/b", "URIDictionary": ["title": "Example B"]]]]
            check("Safari bookmarks are read from nested folders", Sources.safariBookmarkList(safari).map(\.1) == ["Example A", "Example B"])

            // progress
            let progress = IndexProgress(mem)
            progress.begin("contents", total: 10)
            progress.tick(5, force: true)
            let json = mem.meta("progress.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check("progress is published as text and as JSON with an ETA", mem.metaString("progress") == "contents 5/10" &&
                  json?["stage"] as? String == "contents" && json?["done"] as? Int == 5 && json?["total"] as? Int == 10 && json?["eta"] is Int)
            progress.clear()
            check("finished progress is cleared", mem.meta("progress") == nil && mem.meta("progress.json") == nil)

            // end to end on the test index: incremental runs and in-place updates
            let inc = dir.appendingPathComponent("inc")
            try write("inc/a.txt", "alpha receipt QQ-1111")
            try write("inc/keep/k.txt", "kept KK-5555")
            try write("outside.txt", "outside OO-7777")
            _ = Indexer.run(full: false, paths: nil)
            func fileRow(_ path: String) -> (id: Int64, text: Int)? {
                var r: (Int64, Int)?
                Store(readonly: true)?.run("SELECT id,textIndexed FROM files WHERE path=?", [path]) { r = (sqlite3_column_int64($0, 0), Int(sqlite3_column_int($0, 1))) }
                return r
            }
            func has(_ term: String) -> Bool { !(Store(readonly: true)?.contentMatches(term).isEmpty ?? true) }
            let a = inc.appendingPathComponent("a.txt").path
            let firstID = fileRow(a)?.id
            check("a full run indexes the fixture", firstID != nil && fileRow(a)?.text == 1 && has("QQ-1111") && has("KK-5555"))
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: a)
            _ = Indexer.run(full: false, paths: [inc.path])
            check("a touched file with the same bytes keeps its id and its extracted text", fileRow(a)?.id == firstID && fileRow(a)?.text == 1 && has("QQ-1111"))
            try write("inc/a.txt", "beta receipt QQ-2222 longer")
            _ = Indexer.run(full: false, paths: [inc.path])
            check("a changed file is updated in place and its text replaced", fileRow(a)?.id == firstID && has("QQ-2222") && !has("QQ-1111"))
            try fm.removeItem(at: inc.appendingPathComponent("keep"))
            try write("inc/fresh/deeper/n.txt", "new NN-3333")
            try write("outside.txt", "outside changed OO-8888")
            _ = Indexer.run(full: false, paths: [inc.path, inc.path + "/node_modules"])
            check("an incremental run adds new folders whole and drops vanished ones", fileRow(inc.path + "/fresh/deeper/n.txt") != nil && has("NN-3333") &&
                  fileRow(inc.path + "/keep") == nil && fileRow(inc.path + "/keep/k.txt") == nil && !has("KK-5555"))
            check("an incremental run leaves folders it was not given alone", fileRow(dir.path + "/outside.txt") != nil && has("OO-7777") && !has("OO-8888"))
            _ = Indexer.run(full: false, paths: nil)
            check("the next full walk catches up", has("OO-8888"))
        } catch {
            check("indexer fixtures execute without error: \(error.localizedDescription)", false)
        }
        return results
    }
}
