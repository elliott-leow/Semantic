import CoreGraphics
import Foundation

enum SemanticChecks {
    // Default checks use normalized synthetic vectors and an in-memory store.
    // Set SEMANTIC_MODELS to a model directory to also run real embeddings.
    static func run(root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        func signals(_ cosines: [Float], gate: Float = 3.4, src: Src = .media) -> [Engine.SemanticSignal] {
            Engine.semanticSignals(raw: cosines.map { $0 * QSCALE }, sources: Array(repeating: UInt8(src.rawValue), count: cosines.count), gate: gate)
        }
        for n in 1...12 {
            let good = signals([0.80] + Array(repeating: 0.55, count: n - 1))
            let weak = signals([0.65] + Array(repeating: 0.50, count: n - 1))
            check("semantic population \(n) admits an absolute match and excludes distractors", good.filter(\.admitted).count == 1 && good[0].admitted)
            check("semantic population \(n) does not invent an unrelated top result", weak.allSatisfy { !$0.admitted })
        }
        check("singleton semantic score stays bounded instead of using a scaled raw dot product", signals([0.80])[0].score < 6)
        check("normal small-population floor is inclusive at 0.70", signals([0.699, 0.70]).map(\.admitted) == [false, true])
        check("leading action retains a stricter absolute floor", signals([0.77, 0.78], gate: 4.5).map(\.admitted) == [false, true])
        check("equal weak similarities never force an admission", signals(Array(repeating: 0.55, count: 12)).allSatisfy { !$0.admitted })
        let large = signals([0.65] + Array(repeating: 0.50, count: 12))
        check("reachable normal z gate preserves the prior 13-row behavior", large[0].admitted && abs(large[0].score - sqrt(12)) < 0.001)
        let strictSmall = signals([0.80] + Array(repeating: 0.55, count: 20), gate: 4.5)
        let strictLarge = signals([0.65] + Array(repeating: 0.50, count: 21), gate: 4.5)
        check("stricter z gate switches at its mathematical population boundary", strictSmall[0].admitted && strictLarge[0].admitted && abs(strictLarge[0].score - sqrt(21)) < 0.001)
        let mixed = Engine.semanticSignals(raw: ([0.80] + Array(repeating: 0.55, count: 4) + Array(repeating: 0.55, count: 40)).map { $0 * QSCALE },
                                           sources: Array(repeating: UInt8(Src.media.rawValue), count: 5) + Array(repeating: UInt8(Src.text.rawValue), count: 40), gate: 3.4)
        check("a small media source remains searchable beside a large text source", mixed[0].admitted && mixed.filter(\.admitted).count == 1)

        let q = Array(repeating: 1 / sqrt(Float(DIM)), count: DIM)
        func vector(_ cosine: Float) -> [Float] {
            q.indices.map { q[$0] * (cosine + ($0.isMultiple(of: 2) ? 1 : -1) * sqrt(1 - cosine * cosine)) }
        }
        let db = Store(path: ":memory:")!
        func add(_ name: String, cosine: Float, loc: Float = 0) {
            db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')", ["/semantic-fixtures/" + name, name, Kind.image.rawValue, 1.0, 1])
            db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [db.lastID, Src.media.rawValue, quantize(vector(cosine)), Double(loc)])
        }
        add("asset_a.png", cosine: 0.84, loc: 12)
        add("asset_b.png", cosine: 0.73)
        add("asset_c.png", cosine: 0.64)
        add("asset_d.png", cosine: 0.55)
        add("asset_e.png", cosine: 0.50)
        let ix = Index.load(store: db), engine = Engine(index: Index.load(store: db))
        let ranked = engine.semanticRanksForChecks("red circle", vector: q)
        check("five generic filenames rank by meaning and exclude weak matches", ranked.map { ix.entries[$0.i].name } == ["asset_a.png", "asset_b.png"])
        check("semantic ranking retains the matching media location", ranked.first?.loc == 12 && ranked.first?.src == Src.media.rawValue)
        check("leading action excludes borderline semantic results", engine.semanticRanksForChecks("red circle", vector: q, gate: 4.5).map { ix.entries[$0.i].name } == ["asset_a.png"])
        check("numeric identifiers retain exact-match admission", engine.semanticRanksForChecks("INV-48291", vector: q).isEmpty)
        add("red circle", cosine: 0.50)
        let exactIndex = Index.load(store: db)
        let exact = Engine(index: exactIndex).semanticRanksForChecks("red circle", vector: q)
        check("exact filename stays above small-population meaning matches", exact.first.map { exactIndex.entries[$0.i].name } == "red circle")

        let passageDB = Store(path: ":memory:")!
        for i in 0..<13 {
            passageDB.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')", ["/passage-fixtures/asset_\(i).pdf", "asset_\(i).pdf", Kind.doc.rawValue, 1.0, 1])
            let id = passageDB.lastID
            passageDB.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,7)", [id, Src.page.rawValue, quantize(vector(i == 0 ? 0.65 : 0.50))])
            if i == 0 { passageDB.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,12)", [id, Src.media.rawValue, quantize(vector(0.69))]) }
        }
        let passageRank = Engine(index: Index.load(store: passageDB)).semanticRanksForChecks("red circle", vector: q)
        check("an admitted passage beats a higher but unqualified score from another source", passageRank.first?.loc == 7 && passageRank.first?.src == Src.page.rawValue)

        let similarDB = Store(path: ":memory:")!
        @discardableResult func similarFixture(_ name: String, cosine: Float, kind: Kind = .image, src: Src = .media) -> Int64 {
            similarDB.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')", ["/similar-fixtures/" + name, name, kind.rawValue, 1.0, 1])
            let id = similarDB.lastID
            similarDB.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,0)", [id, src.rawValue, quantize(vector(cosine))])
            return id
        }
        let source = "/similar-fixtures/source.png"
        similarFixture("source.png", cosine: 1)
        similarFixture("weak.png", cosine: 0.84)
        similarFixture("unrelated.png", cosine: 0.55)
        similarFixture("document.pdf", cosine: 1, kind: .doc)
        similarFixture("text-only.png", cosine: 1, src: .text)
        func similar(_ kind: Kind = .image, vector query: [Float]? = nil) -> [Engine.Ranked] {
            Engine.similarRanks(in: Index.load(store: similarDB), to: source, vector: query ?? q, kind: kind)
        }
        check("Similar leaves an all-weak image corpus empty", similar().isEmpty)
        similarFixture("good.png", cosine: 0.96)
        similarFixture("good (1).png", cosine: 0.94)
        let oneIndex = Index.load(store: similarDB)
        let one = Engine.similarRanks(in: oneIndex, to: source, vector: q, kind: .image)
        check("Similar admits a strong image without filling weak extra slots", one.count == 1 && oneIndex.entries[one[0].i].name == "good.png")
        similarFixture("related.wav", cosine: 0.78, kind: .audio)
        similarFixture("weak.wav", cosine: 0.65, kind: .audio)
        let audioIndex = Index.load(store: similarDB)
        let audio = Engine.similarRanks(in: audioIndex, to: source, vector: q, kind: .audio)
        check("Similar audio uses its own evidence floor and stays within audio", audio.count == 1 && audioIndex.entries[audio[0].i].name == "related.wav")
        let videoID = similarFixture("clip.mp4", cosine: 0.84, kind: .video)
        similarDB.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,20)", [videoID, Src.media.rawValue, quantize(vector(0.98))])
        let videoIndex = Index.load(store: similarDB)
        let video = Engine.similarRanks(in: videoIndex, to: source, vector: q, kind: .video)
        check("Similar video retains its strongest qualifying frame and location", video.first.map { videoIndex.entries[$0.i].name } == "clip.mp4" && video.first?.loc == 20)
        check("Similar image scope excludes video and audio", similar().count == 1)
        let scaled = similar(vector: q.map { $0 * 10 })
        check("Similar normalizes query length rather than inflating evidence", scaled.count == 1 && abs(scaled[0].score - one[0].score) < 0.0001)
        check("Similar rejects zero and nonfinite query vectors", similar(vector: Array(repeating: 0, count: DIM)).isEmpty && similar(vector: Array(repeating: .nan, count: DIM)).isEmpty)
        for i in 0..<7 { similarFixture("strong_\(i).png", cosine: 0.93) }
        let cappedIndex = Index.load(store: similarDB)
        let capped = Engine.similarRanks(in: cappedIndex, to: source, vector: q, kind: .image)
        check("Similar applies admission and duplicate collapse before its five-result cap", capped.count == 5 && capped.filter { cappedIndex.entries[$0.i].name.hasPrefix("good") }.count == 1 && capped.allSatisfy { !["weak.png", "unrelated.png", "source.png", "text-only.png"].contains(cappedIndex.entries[$0.i].name) })

        if let modelDir = ProcessInfo.processInfo.environment["SEMANTIC_MODELS"] {
            results += modelChecks(modelDir: modelDir, root: root)
        }
        return results
    }

    private static func modelChecks(modelDir: String, root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        // Links live only in SearchTests' isolated data directory. Never point
        // SEMANTIC_DATA_DIR at the user's support directory or open their index.
        let fm = FileManager.default
        let models = URL(fileURLWithPath: Paths.support).appendingPathComponent("models")
        var links: [URL] = []
        defer { for link in links { try? fm.removeItem(at: link) } }
        do {
            for name in ["embeddinggemma-2-Q4.gguf", "mmproj-Q8_0.gguf"] {
                let link = models.appendingPathComponent(name)
                try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: modelDir).appendingPathComponent(name))
                links.append(link)
            }
            guard let embedder = Embedder(multimodal: true, nCtx: 2048) else { check("synthetic semantic model initializes", false); return results }
            let bodies = ["A family dog catches a frisbee while running across a grassy park.",
                          "The monthly finance summary covers expenses, income, and the remaining budget.",
                          "A recipe for chocolate cake with flour, eggs, butter, sugar, and cocoa powder.",
                          "Instructions for configuring a wireless internet router and network password.",
                          "An astronomy lesson explains how planets orbit the sun and stars form in galaxies."]
            let textQueries = ["a puppy playing outdoors", "household spending plan", "baking a dessert", "setting up wifi", "the solar system"]
            let shapes = ["red circle", "blue square", "green triangle", "yellow star", "black and white stripes"]
            let unrelated = [["operating on a broken arm", "volcanic lava flows", "ancient Roman emperor", "buy a train ticket", "underwater coral reef"],
                             ["a dog playing outside", "an invoice for electricity", "snowy mountain landscape", "fried chicken dinner", "a portrait of a woman"]]
            for media in [false, true] {
                let db = Store(path: ":memory:")!
                var valid = true
                for i in 0..<5 {
                    let name = "asset_\(Character(UnicodeScalar(97 + i)!))." + (media ? "png" : "txt")
                    let v = media ? shape(i).flatMap { embedder.image($0) } : embedder.document(title: "none", body: bodies[i])
                    guard let v else { valid = false; continue }
                    db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')", ["/model-fixtures/" + name, name, (media ? Kind.image : Kind.doc).rawValue, 1.0, 1])
                    db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,0)", [db.lastID, (media ? Src.media : Src.page).rawValue, quantize(v)])
                }
                let ix = Index.load(store: db), engine = Engine(index: ix, embedder: embedder)
                check("synthetic \(media ? "image" : "text") embeddings all succeed", valid && ix.rows == 5)
                for (i, query) in (media ? shapes : textQueries).enumerated() {
                    let hits = engine.build("file: " + query).hits.filter { $0.path != nil }
                    check("model meaning finds generic \(media ? "image" : "text") fixture: " + query,
                          hits.count == 1 && hits.first?.path == ix.entries[i].path)
                }
                for query in unrelated[media ? 1 : 0] {
                    check("model excludes unrelated \(media ? "image" : "text") query: " + query,
                          engine.build("file: " + query).hits.allSatisfy { $0.path == nil })
                }
                if media {
                    for i in 0..<5 {
                        guard let image = shape(i, shifted: true), let v = embedder.image(image) else { valid = false; continue }
                        let name = "variant_\(i).png"
                        db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')", ["/model-fixtures/" + name, name, Kind.image.rawValue, 1.0, 1])
                        db.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,0)", [db.lastID, Src.media.rawValue, quantize(v)])
                    }
                    let similarIndex = Index.load(store: db)
                    check("synthetic Similar image variants embed", valid && similarIndex.rows == 10)
                    for i in 0..<5 {
                        let source = similarIndex.entries[i].path
                        let ranked = Engine.similarRanks(in: similarIndex, to: source, vector: similarIndex.vector(row: i), kind: .image)
                        check("model Similar image excludes different shapes: " + shapes[i], ranked.count == 1 && similarIndex.entries[ranked[0].i].name == "variant_\(i).png")
                    }
                }
            }
            let speech = ["A friendly dog is playing in the grassy park.",
                          "The budget report lists income, expenses, and the money left in the bank.",
                          "Mix flour, eggs, sugar, butter, and cocoa to bake a chocolate cake.",
                          "Set the wireless router password to connect your laptop to the internet.",
                          "The planets travel around the sun while distant stars form in galaxies.",
                          "A friendly dog is playing in the grassy park.",
                          "A puppy is running outside and catching a frisbee."]
            let audioDB = Store(path: ":memory:")!
            for (i, phrase) in speech.enumerated() {
                let file = root.appendingPathComponent("synthetic-speech-\(i).wav")
                defer { try? fm.removeItem(at: file) }
                // -o synthesizes directly to a fixture file; no device or playback.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["--file-format=WAVE", "--data-format=LEI16@16000", "-o", file.path] + (i == 5 ? ["-r", "205"] : []) + [phrase]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0, let pcm = Extract.audioSegmentsResult(file)?.first?.1, let v = embedder.audio(pcm) else { check("synthetic speech embeds \(i)", false); continue }
                let name = "speech_\(i).wav"
                audioDB.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')", ["/model-fixtures/" + name, name, Kind.audio.rawValue, 1.0, 1])
                audioDB.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,0)", [audioDB.lastID, Src.media.rawValue, quantize(v)])
            }
            let audioIndex = Index.load(store: audioDB)
            check("synthetic Similar speech embeddings all succeed", audioIndex.rows == 7)
            if audioIndex.rows == 7 {
                let ranked = Engine.similarRanks(in: audioIndex, to: audioIndex.entries[0].path, vector: audioIndex.vector(row: 0), kind: .audio)
                check("model Similar audio admits a paraphrase and speed variant while excluding other topics", Set(ranked.map { audioIndex.entries[$0.i].name }) == ["speech_5.wav", "speech_6.wav"])
                let unrelatedRank = Engine.similarRanks(in: audioIndex, to: audioIndex.entries[1].path, vector: audioIndex.vector(row: 1), kind: .audio)
                check("model Similar unrelated audio corpus stays empty", unrelatedRank.isEmpty)
            }
        } catch { check("synthetic model fixtures execute: \(error.localizedDescription)", false) }
        return results
    }

    // Simple programmatic drawings: no network, personal images, OCR or files.
    private static func shape(_ shape: Int, shifted: Bool = false) -> CGImage? {
        let w = 448, h = 448
        var rgb = [UInt8](repeating: 255, count: w * h * 3)
        let colors: [[UInt8]] = [[230, 10, 20], [10, 30, 230], [0, 160, 30], [255, 205, 0], [0, 0, 0]]
        for y in 0..<h { for x in 0..<w {
            let dx = Float(x - w / 2 - (shifted ? 15 : 0)), dy = Float(y - h / 2 - (shifted ? 10 : 0))
            let inside: Bool
            switch shape {
            case 0: inside = dx * dx + dy * dy < 140 * 140
            case 1: inside = abs(dx) < 130 && abs(dy) < 130
            case 2: inside = dy > -140 && dy < 140 && abs(dx) < (dy + 140) * 0.5
            case 3:
                let sector = (atan2(dy, dx) + Float.pi / 2).remainder(dividingBy: 2 * Float.pi / 5)
                inside = sqrt(dx * dx + dy * dy) < (abs(sector) < Float.pi / 10 ? 145 : 70)
            default: inside = (x / 35).isMultiple(of: 2)
            }
            if inside { for k in 0..<3 { rgb[(y * w + x) * 3 + k] = colors[shape][k] } }
        } }
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
