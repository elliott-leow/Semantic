import AppKit
import Foundation
import SQLite3

// Isolated executable: ./build.sh --test. Never opens, modifies or indexes the user's files.
enum SearchTests {
    static func run() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-tests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let temp = tempURL.resolvingSymlinksInPath()
        setenv("SEMANTIC_DATA_DIR", temp.appendingPathComponent("data").path, 1)
        setenv("SEMANTIC_CONFIG_PATH", temp.appendingPathComponent("config.json").path, 1)
        let root = temp.appendingPathComponent("files")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cfg: [String: Any] = ["roots": [root.path], "sources": [], "clipboard": false]
        try! JSONSerialization.data(withJSONObject: cfg).write(to: temp.appendingPathComponent("config.json"))
        var checks = 0, failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if condition() { print("PASS " + label) } else { print("FAIL " + label); failures += 1 }
        }
        let db = Store(path: ":memory:")!
        @discardableResult func add(_ path: String, kind: Kind = .doc, size: Int = 100, time: Double = 100) -> Int64 {
            db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')",
                   [path, (path as NSString).lastPathComponent, kind.rawValue, time, size])
            return db.lastID
        }
        let target = "/fixtures/Work/report.pdf"
        add(target, time: 1)
        for i in 1...12 { add("/fixtures/Work/report draft \(i).pdf", size: 100 + i, time: Double(200 + i)) }
        add("/fixtures/Work/report (1).pdf", time: 2)
        add("/fixtures/Work/chapter 1.pdf")
        add("/fixtures/Work/chapter 2.pdf")
        add("/fixtures/Work/receipt.pdf")
        add("/fixtures/Archive/report.pdf")
        add("/fixtures/sem_bar/Sources/main.swift", kind: .other)
        add("/fixtures/sem_bar/Sources", kind: .folder)
        add("/fixtures/Work/ReportMaker.app", kind: .app)
        let bodyID = add("/fixtures/Work/scan.pdf", time: 5)
        db.addContent(bodyID, "Your invoice number INV-48291 is approved for payment.", src: .page, loc: 7)
        let ocrID = add("/fixtures/Work/screenshot.png", kind: .image)
        db.addContent(ocrID, "Connection failed with ERR_CERT_EXPIRED. Try again.", src: .ocr)
        let ix = Index.load(store: db)
        let e = Engine(index: ix)
        func files(_ q: String) -> [Hit] { e.build(q).hits.filter { $0.path != nil } }
        check(ix.entries.count == 23, "metadata rows load without a single vector")
        check(ix.rows == 0, "metadata-only index does not fabricate embeddings")
        check(files("report.pdf").first?.title == "report.pdf", "exact filename beats drafts and recency")
        check(files("report").count <= 5, "normal search caps file suggestions at five")
        check(files("*.pdf").count == 5, "wildcard listing caps suggestions at five")
        check(files("folder: Sources").allSatisfy { $0.tag == "Folder" } && files("folder: Sources").count == 1, "folder scope is strict")
        check(files("file: report").allSatisfy { $0.tag != "Application" && $0.tag != "Folder" }, "file scope excludes apps and folders")
        check(files("sem_bar main").first?.title == "main.swift", "path and filename terms combine")
        check(files("mian.swift").first?.title == "main.swift", "transposed letters find a filename")
        check(files("reprot").first?.title == "report.pdf", "single-word typo finds a filename")
        check(files("file: zzzzzzz").isEmpty, "no weak matches are invented to fill five slots")
        check(files("ext:swift main").first?.title == "main.swift", "extension filter composes with a name")
        check(files("report in:/fixtures/Archive").map(\.path) == ["/fixtures/Archive/report.pdf"], "folder boundary filter excludes sibling paths")
        check(files("regex:^chapter [12]\\.pdf$").count == 2, "regex searches file names")
        check(e.build("regex:[").note == "Invalid search pattern", "invalid regex has a visible error")
        check(!FileQuery("2*3").explicit && e.build("2*3").hits.first?.tag == "Calculator", "multiplication remains a calculator expression")
        check(Calc.answer("min(1,234)")?.value == 1 && Calc.answer("sum(1,234)")?.value == 235, "function commas remain argument separators before three digits")
        check(Calc.answer("1,234 + 1")?.value == 1235 && Calc.answer("sum(1,max(2,234))")?.value == 235, "thousands grouping and nested function commas remain distinct")
        check(Calc.answer("choose(200,1)")?.value == 200 && Calc.answer("npr(200,1)")?.value == 200 && Calc.answer("choose(5,2)")?.value == 10, "finite combinations and permutations avoid intermediate gamma overflow")
        check(Calc.answer("choose(5,7)") == nil && Calc.answer("choose(5.5,2)") == nil, "combinations reject invalid integer domains")
        check(Calc.answer("what is the time in London")?.tag == "Time", "ordinary world-time question retains its leading article")
        let hours = Commands.when("remind me in 2 HOURS")?.0.timeIntervalSinceNow ?? 0
        let half = Commands.when("remind me in HALF AN HOUR")?.0.timeIntervalSinceNow ?? 0
        check(abs(hours - 7200) < 2 && abs(half - 1800) < 2, "uppercase relative durations retain intended units and fraction")
        Calc.ans = 42
        check(Calc.answer("ans")?.copy == "42", "bare ans recalls the previous calculator result")
        Calc.answer("255 in hex")?.remember()
        check(Calc.answer("ans + 1")?.value == 256, "hex result remains numeric for calculator recall")
        CalcResult(title: "date", detail: "", copy: "October 12, 2026", tag: "Date").remember()
        check(Calc.ans == 255, "copying a nonnumeric result preserves calculator recall")
        let formatQuestion = e.build("What is the difference between PNG and JPEG?", chips: ["/fixtures/image.png"])
        check(formatQuestion.hits.first?.tag == "ChatGPT" && !formatQuestion.hits.contains { $0.title.hasPrefix("Convert") }, "format questions about attachments route to Ask instead of conversion")
        let emailText = "email to test@example.invalid saying Exact requested message"
        let email = Commands.email(emailText, ["body": "Fabricated unrelated content"])
        check(email.subtitle.contains("Exact requested message") && !email.subtitle.contains("Fabricated"), "email refinement preserves requested body instead of invented text")
        check(!FileQuery("what is this?").explicit, "questions are not wildcard searches")
        check(files("INV-48291").first?.path == "/fixtures/Work/scan.pdf", "exact identifier finds content without an embedding")
        check(files("INV-48291").first?.subtitle.contains("Page 7") == true, "content hit points to its PDF page")
        check(files("INV-48291").first?.excerpt.contains("48291") == true, "content hit carries its matching excerpt")
        check(files("grep:ERR_CERT_EXPIRED").first?.path == "/fixtures/Work/screenshot.png", "exact OCR text is searchable")
        check(files("ext:pdf grep:invoice number").first?.title == "scan.pdf", "literal content query composes with extension scope")
        let literalDB = Store(path: ":memory:")!
        for name in ["PDF Guide.txt", "My Screenshot.png"] {
            literalDB.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,4,'')", ["/literal/" + name, name, Kind.doc.rawValue, 1.0, 1])
        }
        let literalEngine = Engine(index: Index.load(store: literalDB))
        for query in ["PDF Guide", "PDF Guide.txt", "My Screenshot", "My Screenshot.png", "/literal/PDF Guide.txt"] {
            let expected = query.contains("Screenshot") ? "My Screenshot.png" : "PDF Guide.txt"
            check(literalEngine.build(query).hits.first?.title == expected, "literal filename bypasses natural filter and reference interpretation: " + query)
            var first: SearchResult?
            literalEngine.search(query) { if first == nil { first = $0 } }
            let deadline = Date().addingTimeInterval(2)
            while first == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            check(first?.hits.first?.title == expected, "quick literal filename remains consistent: " + query)
        }
        check(literalEngine.build("ext:pdf PDF Guide").hits.filter { $0.path != nil }.isEmpty, "explicit filters retain precedence over literal names")
        // Exact tokens anywhere in a filename must survive more than five incidental body hits.
        let discoveryDB = Store(path: ":memory:")!
        func discoveryAdd(_ path: String, content: String? = nil) {
            discoveryDB.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')",
                            [path, (path as NSString).lastPathComponent, Kind.doc.rawValue, 100, 100])
            if let content { discoveryDB.addContent(discoveryDB.lastID, content) }
        }
        let versionPath = "/fixtures/Desktop/cognitive_distortion_sycophancy_presentation_v16.pptx"
        discoveryAdd(versionPath)
        discoveryAdd("/fixtures/Desktop/v160.pptx", content: "The v16 identifier appears here.")
        discoveryAdd("/fixtures/Desktop/v16notes.pptx")
        discoveryAdd("/fixtures/Desktop/presentation_v17.pptx")
        discoveryAdd("/fixtures/Desktop/presentation_v1702.pptx")
        for n in 0..<7 { discoveryAdd("/fixtures/Other/body\(n).txt", content: "The v16 identifier appears here.") }
        let desktopPath = "/fixtures/Desktop"
        discoveryDB.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,'Desktop',?,0,0,4,'')", [desktopPath, Kind.folder.rawValue])
        for n in 0..<7 { discoveryAdd("/fixtures/Other/desktop_shot_\(n).png", content: "Desktop appears in the content too.") }
        let discoveryIndex = Index.load(store: discoveryDB)
        let discoveryEngine = Engine(index: discoveryIndex)
        for (query, expectedPath) in [("v16", versionPath), ("Desktop v16", versionPath), ("Desktop", desktopPath)] {
            let results = discoveryEngine.build(query).hits.filter { $0.path != nil }
            check(results.first?.path == expectedPath && results.count <= 5, "filename token wins content and version prefixes: " + query)
            var preliminary: SearchResult?
            discoveryEngine.search(query) { if preliminary == nil { preliminary = $0 } }
            let deadline = Date().addingTimeInterval(2)
            while preliminary == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            check(preliminary?.hits.first { $0.path != nil }?.path == expectedPath, "preliminary filename token wins content and version prefixes: " + query)
        }
        let grepPaths = discoveryEngine.build("grep:v16").hits.compactMap(\.path)
        check(!grepPaths.isEmpty && !grepPaths.contains(versionPath) && grepPaths.contains("/fixtures/Desktop/v160.pptx"),
              "explicit grep still requires matching content")
        let numericEntry = discoveryIndex.entries.first { $0.name == "presentation_v1702.pptx" }!
        check(Engine.lexForChecks("v1701", ["v1701"], numericEntry) < 0.5, "numeric identifiers are not typo matched")
        let chapters = ix.entries.filter { $0.name.hasPrefix("chapter") }.map(\.dupKey)
        check(Set(chapters).count == 2, "numbered documents are not collapsed as duplicates")
        check(ix.entries.filter { $0.name == "report.pdf" }.map(\.dupKey).count == Set(ix.entries.filter { $0.name == "report.pdf" }.map(\.dupKey)).count, "same-name files in different folders remain distinct")
        let original = ix.entries.first { $0.path == target }!
        check(original.dupKey == ix.entries.first { $0.name == "report (1).pdf" }?.dupKey, "download copies collapse within a folder")
        let ten = (0..<10).map { n in Hit(title: "\(n)", subtitle: "", icon: .symbol("doc"), tag: "File", path: "/\(n)") { _ in } }
        check(SearchResult(hits: ten + ten).hits.count == 5, "central cap also protects resolved and similar results")
        db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [bodyID, 0, Data(repeating: 1, count: DIM), 0])
        db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [bodyID, 99, Data(repeating: 1, count: DIM), 0])
        db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [bodyID, 0, Data([1]), 0])
        db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [99999, 0, Data(repeating: 1, count: DIM), 0])
        let mixed = Index.load(store: db)
        check(mixed.entries.count == ix.entries.count && mixed.rows == 1, "mixed metadata/vector index rejects corrupt and orphan vectors")
        check(mixed.entries[Int(mixed.rowEntry[0])].name == "scan.pdf", "vectors retain correct file mapping")
        db.deleteFile(bodyID)
        check(db.contentMatches("INV-48291").isEmpty, "deleting metadata also removes exact-content matches")
        db.run("INSERT INTO files(id,path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,?,3,'')",
               [bodyID, "/fixtures/Work/replacement.pdf", "replacement.pdf", Kind.doc.rawValue, 100, 100])
        db.addContent(bodyID, "New document REUSED-73128")
        check(files("grep:REUSED-73128").isEmpty, "recycled content ID cannot attribute a new document to stale metadata")
        db.deleteFile(bodyID)

        // Exercise real index publication, changed-file replacement and content backfill with no model installed.
        let repo = root.appendingPathComponent("Project")
        try! FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try! "print(1)".write(to: repo.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let deep = repo.appendingPathComponent("one/two/three/four")
        try! FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try! "An exact receipt RCP-93844".write(to: root.appendingPathComponent("receipt.txt"), atomically: true, encoding: .utf8)
        let fixture = root.appendingPathComponent("Aspirin_Lab_Report_Draft.txt")
        try! "Synthetic aspirin lab report fixture".write(to: fixture, atomically: true, encoding: .utf8)
        add(fixture.path)
        let incidental = add("/fixtures/project/README.md", time: Date().timeIntervalSince1970)
        db.addContent(incidental, "Use the asprin query to test the launcher")
        let aspirinEngine = Engine(index: Index.load(store: db))
        check(aspirinEngine.build("asprin").hits.first { $0.path != nil }?.path == fixture.path, "asprin filename typo outranks an incidental exact body mention")
        let fileHit = Hit(title: "Aspirin", subtitle: "", icon: .file(fixture.path), tag: "Document", path: fixture.path) { _ in }
        let dragBoard = NSPasteboard(name: .init("Semantic.test.drag." + UUID().uuidString))
        dragBoard.clearContents()
        if let writer = BarController.dragWriter(fileHit) { dragBoard.writeObjects([writer]) }
        check((dragBoard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.path == fixture.path, "outbound result drag exposes original file URL")
        check(BarController.dragWriter(Assistant.hit("explain this", files: [])) == nil, "assistant actions cannot be dragged as files")
        check(Assistant.attachmentFiles([fixture.path, fixture.path, root.path, "/missing"]) == [fixture.path], "attachments exclude duplicate missing and directory paths")
        check(Assistant.requestedFiles([fixture.path, "/missing", root.path, fixture.path]) == [fixture.path, "/missing", root.path], "explicit attachment requests retain missing files and folders for recovery")
        check(Assistant.attachmentIssue(root.path)?.contains("Folder") == true && Assistant.attachmentIssue("/missing")?.contains("Missing") == true, "unavailable attachments have distinct recovery reasons")
        check(!AssistantHandoff.attachmentsVerified(["/A/report.pdf", "/B/report.pdf"], cards: [.init(filename: "report.pdf", ready: true)]), "one attachment card cannot verify two same-named files")
        check(AssistantHandoff.attachmentsVerified(["/A/report.pdf", "/B/report.pdf"], cards: [.init(filename: "report.pdf", ready: true), .init(filename: "report.pdf", ready: true)]), "distinct cards verify repeated attachment basenames")
        check(AssistantHandoff.attachmentsVerified(["/A/error.log"], cards: [.init(filename: "error.log", ready: true)]) && !AssistantHandoff.attachmentsVerified(["/A/error.log"], cards: [.init(filename: "error.log", ready: false)]), "attachment names do not imply upload errors and pending cards never verify")
        check(Assistant.rows("explain this", files: [fixture.path]).first?.key == "intent:ask", "actual file attachment precedes text-only alternative")
        check(aspirinEngine.build("ask chatgpt about asprin").hits.first { $0.tag == "ChatGPT" } != nil, "explicit ChatGPT request remains available")
        check(aspirinEngine.build("asprin").hits.contains { $0.tag == "ChatGPT" }, "single-word file search exposes contextual Ask")
        check(aspirinEngine.build("ext:txt aspirin").hits.contains { $0.tag == "ChatGPT" }, "explicit file search exposes contextual Ask")
        let blockedRename = aspirinEngine.build("rename to result", chips: [fixture.path, root.appendingPathComponent("receipt.txt").path]).hits.first
        check(blockedRename?.unavailableReason?.contains("exactly one") == true && blockedRename?.tag == "Unavailable", "blocked batch action displays its reason before activation")
        for (label, passed) in BarController.verifyInteractions(file: fixture.path) { check(passed, label) }
        check(BarController.selectionAfterPromotion(selected: 0, promoted: 2) == 1 && BarController.selectionAfterPromotion(selected: 2, promoted: 2) == 0 && BarController.selectionAfterPromotion(selected: 3, promoted: 2) == 3, "refinement promotion preserves selected item for every position")
        let guidelineID = add(root.appendingPathComponent("Long Guidelines For Writing An Aspirin Lab Report.txt").path)
        db.addContent(guidelineID, "Aspirin lab report guidelines")
        let namesEngine = Engine(index: Index.load(store: db))
        check(namesEngine.build("find my aspirin lab report").hits.first { $0.path != nil }?.path == fixture.path, "natural file lookup favors concise normalized filename over matching guidelines")

        // Hold the model queue indefinitely: preliminary filename and exact-content results
        // must still arrive, using a separate metadata snapshot and SQLite connection.
        let latencyDB = temp.appendingPathComponent("latency.sqlite").path
        let latencyStore = Store(path: latencyDB)!
        for n in 0..<8 {
            let path = root.appendingPathComponent(n == 0 ? "Aspirin_Lab_Report.pdf" : "Aspirin Lab Report Draft \(n).pdf").path
            latencyStore.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')",
                             [path, (path as NSString).lastPathComponent, Kind.doc.rawValue, n == 0 ? 200 : 100, 100 + n])
            if n == 0 {
                let id = latencyStore.lastID
                latencyStore.addContent(id, "Receipt QZX-82749 is approved", src: .page, loc: 3)
                latencyStore.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [id, Src.page.rawValue, Data(repeating: 1, count: DIM), 3])
            }
        }
        let fastSnapshot = Index.load(store: Store(readonly: true, path: latencyDB), vectors: false)
        check(fastSnapshot.entries.count == 8 && fastSnapshot.rows == 0, "quick snapshot loads metadata without vectors")
        let latencyEngine = Engine(index: Index.load(store: latencyStore), quickIndex: fastSnapshot)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            latencyEngine.sync { entered.signal(); release.wait() }
        }
        check(entered.wait(timeout: .now() + 2) == .success, "test holds the model queue before submitting queries")
        func pump(until complete: () -> Bool, timeout: Double = 0.8) {
            let deadline = Date().addingTimeInterval(timeout)
            while !complete(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        var quickResults: [SearchResult] = []
        let quickStart = Date()
        latencyEngine.search("asprin") { quickResults.append($0) }
        pump(until: { !quickResults.isEmpty })
        check(quickResults.first?.hits.first?.title == "Aspirin_Lab_Report.pdf", "typo file result arrives while model queue is blocked")
        check(quickResults.first?.hits.filter { $0.path != nil }.count == 5, "quick search enforces the five-file cap")
        print("QUICK typo callback: \(Int(Date().timeIntervalSince(quickStart) * 1000)) ms with model queue held")
        quickResults = []
        latencyEngine.search("find my aspirin lab report") { quickResults.append($0) }
        pump(until: { !quickResults.isEmpty })
        check(quickResults.first?.hits.first?.title == "Aspirin_Lab_Report.pdf", "natural file lookup arrives while model queue is blocked")
        quickResults = []
        latencyEngine.search("ext:pdf grep:QZX-82749") { quickResults.append($0) }
        pump(until: { !quickResults.isEmpty })
        check(quickResults.first?.hits.first?.subtitle.contains("Page 3") == true && quickResults.first?.hits.first?.excerpt.contains("82749") == true,
              "quick exact-content result preserves page and excerpt while model queue is blocked")
        quickResults = []
        latencyEngine.search("rename my aspirin lab report to new.pdf") { quickResults.append($0) }
        pump(until: { !quickResults.isEmpty }, timeout: 0.1)
        check(quickResults.isEmpty, "local file operations never become provisional executable results")
        var staleDeliveries = 0, latestResults: [SearchResult] = []
        latencyEngine.search("asprin") { _ in staleDeliveries += 1 }
        latencyEngine.search("grep:QZX-82749") { latestResults.append($0) }
        pump(until: { !latestResults.isEmpty })
        check(staleDeliveries == 0 && !latestResults.isEmpty, "superseded quick searches cannot deliver stale callbacks")
        release.signal()
        latencyEngine.sync {}
        pump(until: { latestResults.count >= 2 })
        check(staleDeliveries == 0 && latestResults.count == 2, "only latest generation delivers its full refinement")
        check(latestResults.count == 2 && latestResults.allSatisfy { $0.hits.first?.title == "Aspirin_Lab_Report.pdf" }, "full refinement follows preliminary exact-content result")

        var attachedPaths: [String] = []
        for n in 0..<7 {
            let path = root.appendingPathComponent("attachment-\(n).txt")
            try! "fixture".write(to: path, atomically: true, encoding: .utf8)
            attachedPaths.append(path.path)
        }
        check(Assistant.attachmentFiles(attachedPaths).count == 7, "explicit attachment count is independent of the five-search-result cap")
        check(namesEngine.build("ask chatgpt to rename my aspirin lab report").hits.first { $0.tag == "ChatGPT" }?.refine == nil, "Ask ChatGPT cannot refine into a local file operation")
        // Batch actions only operate on temporary fixtures and never open the run UI.
        let opsRoot = root.appendingPathComponent("batch-operations")
        try! FileManager.default.createDirectory(at: opsRoot, withIntermediateDirectories: true)
        let image = opsRoot.appendingPathComponent("picture.png")
        let image2 = opsRoot.appendingPathComponent("second.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let imageBytes = rep.representation(using: .png, properties: [:])!
        try! imageBytes.write(to: image)
        try! imageBytes.write(to: image2)
        let audio = opsRoot.appendingPathComponent("sound.wav")
        try! Data("audio-type fixture".utf8).write(to: audio)
        let attached = [image.path, audio.path]
        func opFailure(_ op: Op) -> OpError? {
            do { _ = try op.work?(); return nil } catch { return error as? OpError }
        }
        func opNames() -> Set<String> { Set(try! FileManager.default.contentsOfDirectory(atPath: opsRoot.path)) }
        let initialNames = opNames()
        for paths in [attached, attached.reversed().map { $0 }] {
            let suggestions = FileOps.suggestions(paths)
            check(!suggestions.contains { ["resize", "ocr", "convert.jpg", "convert.png", "convert.m4a", "convert.wav"].contains($0.id) }, "mixed image/audio suggestions exclude incompatible media actions in either order")
            check(suggestions.contains { $0.id == "duplicate" } && suggestions.contains { $0.id == "convert.zip" }, "mixed attachments retain common actions")
        }
        let resizeMixed = FileOps.resizeOp(attached, width: 4, height: nil, percent: nil)
        check(resizeMixed.unavailableReason?.contains("sound.wav") == true && opFailure(resizeMixed)?.message.contains("requires images") == true,
              "explicit mixed resize explains its unsupported input")
        check(opFailure(FileOps.convertOp(attached, "jpg"))?.message.contains("sound.wav") == true, "mixed conversion validates every input before execution")
        check(opNames() == initialNames, "mixed resize and conversion create no partial output")
        for request in ["rotate right", "flip horizontal", "grayscale", "copy text", "merge"] {
            let op = FileOps.parse(request, attached).first!
            check(op.unavailableReason != nil && opFailure(op) != nil && opNames() == initialNames, "unsupported mixed \(request) is blocked before output")
        }
        let rename = FileOps.renameOp([image.path, image2.path], "renamed")
        check(rename.unavailableReason?.contains("exactly one") == true && opFailure(rename)?.message.contains("exactly one") == true, "plural rename explains that exactly one file is required")
        check(opNames() == initialNames && (try? Data(contentsOf: image)) == imageBytes && (try? Data(contentsOf: image2)) == imageBytes,
              "plural rename leaves both original files and names unchanged")
        let corrupt = opsRoot.appendingPathComponent("corrupt.png")
        try! Data("invalid image".utf8).write(to: corrupt)
        let beforeCorrupt = opNames()
        check(opFailure(FileOps.resizeOp([image.path, corrupt.path], width: 4, height: nil, percent: nil))?.message.contains("corrupt.png") == true && opNames() == beforeCorrupt,
              "all images are decoded before the first batch resize writes output")
        let sameFormat = opsRoot.appendingPathComponent("already.jpg")
        try! Data("same-format fixture".utf8).write(to: sameFormat)
        let beforeSameFormat = opNames()
        check(opFailure(FileOps.convertOp([image.path, sameFormat.path], "jpg"))?.message.contains("already") == true && opNames() == beforeSameFormat,
              "same-format later input prevents earlier conversion output")
        let duplicate = FileOps.common([image.path, opsRoot.appendingPathComponent("missing.txt").path]).first { $0.id == "duplicate" }!
        check(opFailure(duplicate)?.message.contains("no longer exists") == true && opNames() == beforeSameFormat, "missing later input prevents earlier duplication")
        let resized = try! FileOps.resizeOp([image.path, image2.path], width: 4, height: nil, percent: nil).work!()
        check(resized.count == 2 && resized.allSatisfy { FileOps.pixelSize($0)?.0 == 4 }, "homogeneous image batch resizes every attachment")
        check((try? Data(contentsOf: image)) == imageBytes && (try? Data(contentsOf: image2)) == imageBytes, "batch image transforms preserve original bytes")
        let completedPath = opsRoot.appendingPathComponent("completed.txt").path
        do {
            _ = try FileOps.batch([image.path, image2.path]) { file in
                if file == image2.path { throw OpError("Injected runtime failure") }
                try "completed fixture".write(toFile: completedPath, atomically: true, encoding: .utf8)
                return completedPath
            }
            check(false, "runtime failure retains completed outputs")
        } catch {
            let failure = error as? OpError
            check(failure?.completedOutputs == [completedPath] && failure?.message.contains("Completed 1 of 2") == true && failure?.message.contains("completed.txt") == true,
                  "runtime failure reports completed output paths and batch progress")
        }
        let candidates = Indexer.walk(root.path)
        check(candidates.contains { $0.name == "main.swift" && !$0.semantic }, "repo source files get cheap metadata without content reads")
        check(candidates.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == deep.resolvingSymlinksInPath() && $0.kind == .folder }, "deep folders remain searchable")
        let rc = Indexer.run(full: false)
        check(rc == 1, "missing AI model does not prevent metadata/content publication")
        let disk = Store(readonly: true)!
        let diskIndex = Index.load(store: disk)
        check(diskIndex.entries.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == repo.appendingPathComponent("main.swift").resolvingSymlinksInPath() }, "metadata persists before model initialization")
        check(!disk.contentMatches("RCP-93844").isEmpty, "exact text persists without AI model")
        try! "Replacement receipt NEW-12859".write(to: root.appendingPathComponent("receipt.txt"), atomically: true, encoding: .utf8)
        _ = Indexer.run(full: false)
        check(Store(readonly: true)!.contentMatches("RCP-93844").isEmpty && !Store(readonly: true)!.contentMatches("NEW-12859").isEmpty, "changed content replaces stale matches")
        try! FileManager.default.removeItem(at: root.appendingPathComponent("receipt.txt"))
        _ = Indexer.run(full: false, namesOnly: true)
        check(Store(readonly: true)!.contentMatches("NEW-12859").isEmpty, "removed files are removed from content index")
        for (label, passed) in FileOpsChecks.run(root: root) { check(passed, label) }
        for (label, passed) in IndexRetryChecks.run(root: root) { check(passed, label) }
        for (label, passed) in SemanticChecks.run(root: root) { check(passed, label) }
        for (label, passed) in FunctionalityChecks.run(root: root) { check(passed, label) }
        for (label, passed) in PreviewChecks.run(root: root) { check(passed, label) }
        for (label, passed) in SearchPerfChecks.run(root: root) { check(passed, label) }
        for (label, passed) in IndexerChecks.run(root: root) { check(passed, label) }
        for (label, passed) in PanelChecks.run(root: root) { check(passed, label) }
        for (label, passed) in AppChecks.run(root: root) { check(passed, label) }
        for (label, passed) in HabitChecks.run(root: root) { check(passed, label) }
        print("\(checks - failures)/\(checks) checks passed")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
