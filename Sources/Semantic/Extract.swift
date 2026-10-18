import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import PDFKit
import Vision

// Everything that turns a file on disk into something the model can embed.
enum Extract {
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"]
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "caf", "ogg", "opus"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
    static let richExts: Set<String> = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "pptx", "xlsx", "pages", "key", "numbers", "ppt", "xls", "epub"]
    static let plainExts: Set<String> = ["txt", "md", "markdown", "csv", "tex", "org", "rst", "log"]
    static let codeExts: Set<String> = ["py", "js", "ts", "tsx", "jsx", "swift", "c", "h", "cpp", "hpp", "rs", "go", "java", "rb", "sh",
                                        "json", "yaml", "yml", "toml", "html", "css", "ipynb", "sql", "xml", "kt", "m", "mm", "lua"]
    static let junkExts: Set<String> = ["pyc", "o", "a", "class", "lock", "map", "pkf", "tmp", "ds_store", "bak", "dylib", "so"]

    static func kind(ext: String) -> Kind {
        if imageExts.contains(ext) { return .image }
        if audioExts.contains(ext) { return .audio }
        if videoExts.contains(ext) { return .video }
        if richExts.contains(ext) || plainExts.contains(ext) { return .doc }
        return .other
    }

    static func image(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func ocrLines(_ cg: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func ocr(_ cg: CGImage) -> String {
        ocrResult(cg) ?? ""
    }

    // nil means extraction failed; an empty string is a successful no-text result.
    static func ocrResult(_ cg: CGImage) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) }
        catch { return nil }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ")
    }

    // mono 16 kHz float PCM in windows of `seconds`, as (start time, samples)
    static func audioSegments(_ url: URL, seconds: Double = 30, max: Int = 12) -> [(Double, [Float])] {
        audioSegmentsResult(url, seconds: seconds, max: max) ?? []
    }

    static func audioSegmentsResult(_ url: URL, seconds: Double = 30, max: Int = 12) -> [(Double, [Float])]? {
        guard seconds.isFinite, seconds > 0, max > 0, let f = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = f.processingFormat
        guard inFmt.sampleRate.isFinite, inFmt.sampleRate > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return nil }
        let segFrames = AVAudioFramePosition(inFmt.sampleRate * seconds)
        guard segFrames > 0 else { return nil }
        var out: [(Double, [Float])] = []
        var start: AVAudioFramePosition = 0
        while start < f.length, out.count < max {
            let frames = AVAudioFrameCount(min(segFrames, f.length - start))
            guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
            f.framePosition = start
            do { try f.read(into: inBuf, frameCount: frames) } catch { return nil }
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / inFmt.sampleRate) + 4096
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            guard err == nil, status != .error, let ch = outBuf.floatChannelData else { return nil }
            // skip a trailing sliver; it adds nothing the previous window lacks
            if outBuf.frameLength > (out.isEmpty ? 1600 : 48000) {
                out.append((Double(start) / inFmt.sampleRate, Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))))
            }
            start += segFrames
        }
        return out
    }

    // frames spread across the video, as (time, image)
    static func videoFrames(_ url: URL, max: Int = 10) -> [(Double, CGImage)] {
        videoFramesResult(url, max: max) ?? []
    }

    static func videoFramesResult(_ url: URL, max: Int = 10) -> [(Double, CGImage)]? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 896, height: 896)
        guard max > 0, let (duration, readable, tracks) = wait({ try await asset.load(.duration, .isReadable, .tracks) }) else { return nil }
        let dur = CMTimeGetSeconds(duration)
        guard dur.isFinite, dur >= 0, readable else { return nil }
        // A readable audio-only or zero-length container has no video to embed.
        guard dur > 0, tracks.contains(where: { $0.mediaType == .video }) else { return [] }
        let n = Swift.max(1, Swift.min(max, Int(dur / 15) + 1))
        var out: [(Double, CGImage)] = []
        for k in 0..<n {
            let t = n == 1 ? dur * 0.2 : dur * (Double(k) + 0.5) / Double(n)
            guard let cg = wait({ try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image }) else { return nil }
            out.append((t, cg))
        }
        return out
    }

    // text of each page that has any, as (1-based page, text)
    static func pdfPages(_ url: URL, max: Int = 80) -> [(Int, String)] {
        pdfPagesResult(url, max: max) ?? []
    }

    static func pdfPagesResult(_ url: URL, max: Int = 80) -> [(Int, String)]? {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { return nil }
        guard doc.pageCount > 1 else { return [] }
        var out: [(Int, String)] = []
        for i in 0..<Swift.min(doc.pageCount, max) {
            guard let page = doc.page(at: i) else { return nil }
            let t = (page.string ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if t.count >= 80 { out.append((i + 1, String(t.prefix(2000)))) }
        }
        return out
    }

    struct Passage {
        let text: String
        let src: Src
        let loc: Double
    }

    static let passageChars = 3000
    // exact-text cap per file; PDFs are capped by pages instead
    static let contentLimit = 200_000

    static func keywordPassages(_ url: URL, kind: Kind) -> [Passage] {
        keywordPassagesResult(url, kind: kind) ?? []
    }

    // Everything searchable by exact words, read once per file version. Later passes reuse
    // these rows (Indexer.storedPassages) instead of decoding, OCRing or parsing the file again.
    static func keywordPassagesResult(_ url: URL, kind: Kind) -> [Passage]? {
        if kind == .image {
            guard let cg = image(url, maxPixel: 2200) else { return nil }
            guard cg.width >= 48, cg.height >= 48 else { return [] }
            guard let text = ocrResult(cg) else { return nil }
            return [Passage(text: text, src: .ocr, loc: 0)]
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { return nil }
            var passages: [Passage] = []
            for i in 0..<min(doc.pageCount, 80) {
                guard let page = doc.page(at: i) else { return nil }
                var text = page.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
                    let image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
                    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let recognized = ocrResult(cg) else { return nil }
                    text = recognized
                }
                passages.append(Passage(text: String(text.prefix(20000)), src: .page, loc: Double(i + 1)))
            }
            return passages
        }
        guard let body = textResult(url, ext: ext, limit: contentLimit) else { return nil }
        // loc numbers the passages; 0 is the start the file's main text vector also covers
        return split(body).enumerated().map { Passage(text: $1, src: .text, loc: Double($0)) }
    }

    // ~3000-character passages cut at a space; [s] when it is short (including empty)
    static func split(_ s: String, size: Int = passageChars) -> [String] {
        guard s.count > size else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: size, limitedBy: rest.endIndex) ?? rest.endIndex
            if end != rest.endIndex, let space = rest[..<end].lastIndex(of: " "), rest.distance(from: rest.startIndex, to: space) > size / 2 {
                end = rest.index(after: space)
            }
            let part = rest[..<end].trimmingCharacters(in: .whitespaces)
            if !part.isEmpty { out.append(part) }
            rest = rest[end...]
        }
        return out
    }

    static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // the text vector's body from stored passages: the start of the document, as textResult reads it
    static func summary(_ passages: [Passage], limit: Int = 3000) -> String {
        var s = ""
        for p in passages.sorted(by: { $0.loc < $1.loc }) where s.count < limit { s += p.text + " " }
        return String(collapse(s).trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    // page-vector input from stored PDF passages, as pdfPagesResult reads it from the file
    static func pdfPages(_ passages: [Passage]) -> [(Int, String)] {
        let pages = passages.filter { $0.src == .page }.sorted { $0.loc < $1.loc }
        guard pages.count > 1 else { return [] }
        return pages.compactMap { p in
            let t = collapse(p.text)
            return t.count >= 80 ? (Int(p.loc), String(t.prefix(2000))) : nil
        }
    }

    // Cheap change detector: SHA-256 of the first and last 64 KB plus the size. nil for directories and unreadable files.
    static func contentHash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            let size = try h.seekToEnd()
            try h.seek(toOffset: 0)
            var d = try h.read(upToCount: 65536) ?? Data()
            if size > 65536 {
                try h.seek(toOffset: Swift.max(65536, size - 65536))
                d += try h.read(upToCount: 65536) ?? Data()
            }
            d += Data(String(size).utf8)
            return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }

    static func unzipText(_ url: URL, member: String) -> String {
        unzipTextResult(url, member: member) ?? ""
    }

    static func unzipTextResult(_ url: URL, member: String) -> String? {
        unzipData(url, members: [member]).map { markupText(String(decoding: $0, as: UTF8.self)) }
    }

    // Concatenated members (unzip wildcards allowed), at most `cap` bytes. Missing members give
    // empty data; nil means the archive itself could not be read.
    static func unzipData(_ url: URL, members: [String], cap: Int = 200_000) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path] + members
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        do {
            while data.count < cap {
                guard let chunk = try pipe.fileHandleForReading.read(upToCount: cap - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        }
        catch { p.terminate(); p.waitUntilExit(); return nil }
        if data.count >= cap {
            // Keep the extraction cap; stop the producer before its pipe fills.
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        } else {
            p.waitUntilExit()
            // 11 means no matching member, e.g. a workbook with no shared strings.
            guard p.terminationStatus == 0 || p.terminationStatus == 11 else { return nil }
        }
        return data
    }

    static func markupText(_ xml: String) -> String {
        var s = xml.replacingOccurrences(of: "(?is)<(script|style)\\b.*?</\\1>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&#160;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }

    static func captures(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in Range(m.range(at: 1), in: s).map { String(s[$0]) } }
    }

    static func pdfText(_ doc: PDFDocument, limit: Int) -> String? {
        guard !doc.isLocked, doc.pageCount > 0 else { return nil }
        var s = ""
        for i in 0..<min(doc.pageCount, limit > 5000 ? 80 : 4) where s.count < limit {
            guard let page = doc.page(at: i) else { return nil }
            s += (page.string ?? "") + " "
        }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, let page = doc.page(at: 0) {
            // scanned PDF: read the first page with OCR instead
            let img = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let recognized = ocrResult(cg) else { return nil }
            s = recognized
        }
        return s
    }

    // Keynote/Pages/Numbers (a zip file or a package folder): the body is protobuf (.iwa), but the
    // QuickLook preview PDF (older files) or the preview.jpg first page (newer ones) carries readable text.
    static func iworkText(_ url: URL, limit: Int) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        var unreadable = false
        func member(_ m: String) -> Data {
            if isDir.boolValue { return FileManager.default.contents(atPath: url.path + "/" + m) ?? Data() }
            guard let d = unzipData(url, members: [m], cap: 40_000_000) else { unreadable = true; return Data() }
            return d
        }
        let pdf = member("QuickLook/Preview.pdf")
        if unreadable { return nil }
        if !pdf.isEmpty, let doc = PDFDocument(data: pdf) { return pdfText(doc, limit: limit) ?? "" }
        for name in ["preview.jpg", "QuickLook/Thumbnail.jpg"] {
            let jpg = member(name)
            guard !jpg.isEmpty, let src = CGImageSourceCreateWithData(jpg as CFData, nil) else { continue }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2200]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { continue }
            return ocrResult(cg) ?? ""
        }
        return ""
    }

    // best-effort body text, capped
    static func text(_ url: URL, ext: String, limit: Int = 3000) -> String {
        textResult(url, ext: ext, limit: limit) ?? ""
    }

    static func textResult(_ url: URL, ext: String, limit: Int = 3000) -> String? {
        var s = ""
        // raw markup is several times longer than its text
        let cap = Swift.max(200_000, limit * 20)
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url), let t = pdfText(doc, limit: limit) else { return nil }
            s = t
        case "docx", "doc", "rtf", "rtfd", "odt":
            guard let document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
            s = document.string
        case "pptx":
            // every slide, then the speaker notes
            guard let d = unzipData(url, members: ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"], cap: cap) else { return nil }
            s = markupText(String(decoding: d, as: UTF8.self))
        case "xlsx":
            guard let shared = unzipData(url, members: ["xl/sharedStrings.xml"], cap: cap) else { return nil }
            let book = unzipData(url, members: ["xl/workbook.xml"]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            s = captures(book, "<sheet\\b[^>]*\\bname=\"([^\"]*)\"").joined(separator: " ") + " " + markupText(String(decoding: shared, as: UTF8.self))
            // inline strings and formula text live in the sheets, not in sharedStrings
            if let sheets = unzipData(url, members: ["xl/worksheets/sheet*.xml"], cap: cap) {
                let x = String(decoding: sheets, as: UTF8.self)
                s += " " + (captures(x, "(?s)<is>(.*?)</is>") + captures(x, "(?s)t=\"str\"[^>]*>(?:<f[^>]*/>|<f[^>]*>.*?</f>)?<v>(.*?)</v>")).map(markupText).joined(separator: " ")
            }
        case "epub":
            guard let d = unzipData(url, members: ["*.xhtml", "*.html", "*.htm"], cap: cap) else { return nil }
            s = markupText(String(decoding: d, as: UTF8.self))
        case "pages", "key", "numbers":
            guard let t = iworkText(url, limit: limit) else { return nil }
            s = t
        default:
            if plainExts.contains(ext) || codeExts.contains(ext) {
                guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? h.close() }
                let data: Data
                do { data = try h.read(upToCount: limit * 2) ?? Data() }
                catch { return nil }
                s = String(decoding: data, as: UTF8.self)
            } else {
                // Unsupported text formats can complete without text, once readable.
                guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
                try? h.close()
            }
        }
        return String(collapse(s).prefix(limit))
    }
}
