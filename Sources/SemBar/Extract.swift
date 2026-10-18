import AVFoundation
import AppKit
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
        let dur = CMTimeGetSeconds(asset.duration)
        guard max > 0, dur.isFinite, dur >= 0, asset.isReadable else { return nil }
        // A readable audio-only or zero-length container has no video to embed.
        guard dur > 0, !asset.tracks(withMediaType: .video).isEmpty else { return [] }
        let n = Swift.max(1, Swift.min(max, Int(dur / 15) + 1))
        var out: [(Double, CGImage)] = []
        for k in 0..<n {
            let t = n == 1 ? dur * 0.2 : dur * (Double(k) + 0.5) / Double(n)
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return nil }
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

    static func keywordPassages(_ url: URL, kind: Kind) -> [Passage] {
        keywordPassagesResult(url, kind: kind) ?? []
    }

    static func keywordPassagesResult(_ url: URL, kind: Kind) -> [Passage]? {
        if kind == .image {
            guard let cg = image(url, maxPixel: 2200) else { return nil }
            guard cg.width >= 48, cg.height >= 48 else { return [] }
            guard let text = ocrResult(cg) else { return nil }
            return [Passage(text: text, src: .ocr, loc: 0)]
        }
        if url.pathExtension.lowercased() == "pdf" {
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
        guard let body = textResult(url, ext: url.pathExtension.lowercased(), limit: 60000) else { return nil }
        return [Passage(text: body, src: .text, loc: 0)]
    }

    static func unzipText(_ url: URL, member: String) -> String {
        unzipTextResult(url, member: member) ?? ""
    }

    static func unzipTextResult(_ url: URL, member: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, member]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        do {
            while data.count < 200_000 {
                guard let chunk = try pipe.fileHandleForReading.read(upToCount: 200_000 - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        }
        catch { p.terminate(); p.waitUntilExit(); return nil }
        if data.count == 200_000 {
            // Keep the existing extraction cap; stop the producer before its pipe fills.
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        } else {
            p.waitUntilExit()
            // 11 means no matching member, e.g. a workbook with no shared strings.
            guard p.terminationStatus == 0 || p.terminationStatus == 11 else { return nil }
        }
        let xml = String(decoding: data, as: UTF8.self)
        return xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    // best-effort body text, capped
    static func text(_ url: URL, ext: String, limit: Int = 3000) -> String {
        textResult(url, ext: ext, limit: limit) ?? ""
    }

    static func textResult(_ url: URL, ext: String, limit: Int = 3000) -> String? {
        var s = ""
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { return nil }
            for i in 0..<min(doc.pageCount, 4) where s.count < limit {
                guard let page = doc.page(at: i) else { return nil }
                s += (page.string ?? "") + " "
            }
            if s.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, let page = doc.page(at: 0) {
                // scanned PDF: read the first page with OCR instead
                let img = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
                guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let recognized = ocrResult(cg) else { return nil }
                s = recognized
            }
        case "docx", "doc", "rtf", "rtfd", "odt":
            guard let document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
            s = document.string
        case "pptx":
            guard let extracted = unzipTextResult(url, member: "ppt/slides/slide[1-4].xml") else { return nil }
            s = extracted
        case "xlsx":
            guard let extracted = unzipTextResult(url, member: "xl/sharedStrings.xml") else { return nil }
            s = extracted
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
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(s.prefix(limit))
    }
}
