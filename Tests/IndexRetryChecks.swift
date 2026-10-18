import AppKit
import AVFoundation
import Foundation
import SQLite3

enum IndexRetryChecks {
    // No model or user files: extraction fixtures and persistence live in this scope.
    static func run(root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("index-retry-checks")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let empty = dir.appendingPathComponent("empty.txt")
            try Data().write(to: empty)
            let noText = Extract.keywordPassagesResult(empty, kind: .doc)
            check("readable empty text completes extraction", noText?.count == 1 && noText?.first?.text == "")
            let missing = dir.appendingPathComponent("missing.txt")
            check("missing text stays retryable", Extract.keywordPassagesResult(missing, kind: .doc) == nil)
            let code = dir.appendingPathComponent("indented.py")
            let source = "def example():\n    if True:\n        return 42\n\n# next section\n"
            try source.write(to: code, atomically: true, encoding: .utf8)
            check("plain-text preview retains line breaks and indentation", FilePreview.plainText(code) == source)
            check("plain-text preview remains bounded", FilePreview.plainText(code, limit: 16) == String(source.prefix(16)))
            check("missing preview reports unavailable", FilePreview.plainText(missing) == nil)
            check("missing document body also keeps its semantic text vector pending",
                  Indexer.describe(Indexer.Cand(path: missing.path, name: "missing.txt", kind: .doc, mtime: 0, size: 0)) == nil)
            let brokenPDF = dir.appendingPathComponent("broken.pdf")
            try Data("not a PDF".utf8).write(to: brokenPDF)
            check("invalid PDF stays retryable in both extraction passes", Extract.keywordPassagesResult(brokenPDF, kind: .doc) == nil && Extract.pdfPagesResult(brokenPDF) == nil)
            let brokenSlides = dir.appendingPathComponent("broken.pptx")
            try Data("not a ZIP".utf8).write(to: brokenSlides)
            check("invalid office archive stays retryable", Extract.keywordPassagesResult(brokenSlides, kind: .doc) == nil)
            let brokenImage = dir.appendingPathComponent("broken.png")
            try Data([0]).write(to: brokenImage)
            check("invalid image stays retryable", Extract.keywordPassagesResult(brokenImage, kind: .image) == nil)
            let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let tiny = dir.appendingPathComponent("tiny.png")
            try pixels.representation(using: .png, properties: [:])!.write(to: tiny)
            check("valid tiny image completes without OCR", Extract.image(tiny, maxPixel: 896) != nil && Extract.keywordPassagesResult(tiny, kind: .image)?.isEmpty == true)
            let pdf = dir.appendingPathComponent("one-page.pdf")
            var box = CGRect(x: 0, y: 0, width: 100, height: 100)
            let context = CGContext(consumer: CGDataConsumer(url: pdf as CFURL)!, mediaBox: &box, nil)!
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            check("valid single-page PDF needs no page vectors", Extract.pdfPagesResult(pdf)?.isEmpty == true)
            let brokenAudio = dir.appendingPathComponent("broken.wav")
            try Data([0]).write(to: brokenAudio)
            check("invalid audio stays retryable", Extract.audioSegmentsResult(brokenAudio) == nil)
            let shortAudio = dir.appendingPathComponent("short.wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
            buffer.frameLength = 800
            for i in 0..<800 { buffer.floatChannelData![0][i] = 0 }
            do {
                let file = try AVAudioFile(forWriting: shortAudio, settings: format.settings)
                try file.write(from: buffer)
            }
            check("valid short audio completes without model input", Extract.audioSegmentsResult(shortAudio)?.isEmpty == true)
            let brokenVideo = dir.appendingPathComponent("broken.mp4")
            try Data([0]).write(to: brokenVideo)
            check("invalid video stays retryable", Extract.videoFramesResult(brokenVideo) == nil)

            guard let store = Store(path: ":memory:") else { check("retry fixture database opens", false); return results }
            store.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,0,?)", ["/fixture", "fixture", Kind.image.rawValue, 0.0, 1, "old snippet"])
            let id = store.lastID
            func count(_ sql: String) -> Int {
                var value = -1
                store.run(sql, [id]) { value = Int(sqlite3_column_int64($0, 0)) }
                return value
            }
            func snippet() -> String {
                var value = ""
                store.run("SELECT snippet FROM files WHERE id=?", [id]) { value = colText($0, 0) }
                return value
            }
            store.addContent(id, "original content")
            check("failed exact-text extraction preserves pending flag and previous text",
                  !Indexer.persistContentExtraction(store, id: id, passages: nil) &&
                  count("SELECT textIndexed FROM files WHERE id=?") == 0 && !store.contentMatches("original").isEmpty)
            let passage = Extract.Passage(text: "replacement content", src: .page, loc: 2)
            _ = Indexer.persistContentExtraction(store, id: id, passages: [passage])
            _ = Indexer.persistContentExtraction(store, id: id, passages: [passage])
            check("successful exact-text retries replace rows without duplicates",
                  count("SELECT textIndexed FROM files WHERE id=?") == 1 && count("SELECT count(*) FROM content WHERE file_id=?") == 1 &&
                  store.contentMatches("original").isEmpty && store.contentMatches("replacement").count == 1)
            _ = Indexer.persistContentExtraction(store, id: id, passages: [])
            check("successful empty exact text completes and clears old content",
                  count("SELECT textIndexed FROM files WHERE id=?") == 1 && count("SELECT count(*) FROM content WHERE file_id=?") == 0)
            for src in [Src.text, .media, .ocr, .page] {
                store.run("INSERT INTO vecs(file_id,src,v,loc) VALUES(?,?,?,?)", [id, src.rawValue, Data([1]), 0.0])
            }
            check("failed media outcome preserves pending flag, vectors and snippet",
                  !Indexer.persistMediaExtraction(store, id: id, vectors: nil, snippet: "failed snippet") &&
                  count("SELECT state FROM files WHERE id=?") == 0 && count("SELECT count(*) FROM vecs WHERE file_id=?") == 4 && snippet() == "old snippet")
            let vectors = [Indexer.MediaVector(src: .media, data: Data([2]), loc: 10),
                           Indexer.MediaVector(src: .media, data: Data([3]), loc: 20)]
            _ = Indexer.persistMediaExtraction(store, id: id, vectors: vectors, snippet: "new snippet")
            store.run("UPDATE files SET state=0 WHERE id=?", [id])
            _ = Indexer.persistMediaExtraction(store, id: id, vectors: vectors)
            check("successful media retries atomically replace all media sources and preserve title vector",
                  count("SELECT state FROM files WHERE id=?") == 1 && count("SELECT count(*) FROM vecs WHERE file_id=?") == 3 &&
                  count("SELECT count(*) FROM vecs WHERE file_id=? AND src=0") == 1 &&
                  count("SELECT count(*) FROM vecs WHERE file_id=? AND src=1 AND loc IN (10,20)") == 2 && snippet() == "new snippet")
            store.run("UPDATE files SET state=0 WHERE id=?", [id])
            _ = Indexer.persistMediaExtraction(store, id: id, vectors: [])
            check("successful empty media completes and clears media vectors",
                  count("SELECT state FROM files WHERE id=?") == 1 && count("SELECT count(*) FROM vecs WHERE file_id=?") == 1)
        } catch {
            check("retry fixtures execute without error: \(error.localizedDescription)", false)
        }
        return results
    }
}
