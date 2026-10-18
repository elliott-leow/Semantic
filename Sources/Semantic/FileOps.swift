import AVFoundation
import AppKit
import PDFKit

struct OpError: LocalizedError {
    let message: String
    let completedOutputs: [String]
    init(_ m: String, completedOutputs: [String] = []) { message = m; self.completedOutputs = completedOutputs }
    var errorDescription: String? { message }
}

// One thing that can be done to the attached file(s).
struct Op {
    let id: String
    let title: String
    let symbol: String
    var detail = ""
    var stay = false                         // keep the bar open (the op changes what it shows)
    var ui: (() -> Void)?                    // runs on the main thread instead of `work`
    var work: (() throws -> [String])?       // runs in the background; returns paths to reveal
    var done = "Done"
    var unavailableReason: String?
    var preflightInstalled = false
}

enum FileOps {
    static let maxResizeDimension = 16_384
    static let maxResizePixels = 40_000_000

    static let imageFormats: [String: String] = ["jpg": "jpeg", "png": "png", "heic": "heic", "tiff": "tiff", "gif": "gif", "bmp": "bmp"]
    static let audioFormats: [String: [String]] = [
        "m4a": ["-f", "m4af", "-d", "aac"], "wav": ["-f", "WAVE", "-d", "LEI16"], "aiff": ["-f", "AIFF", "-d", "BEI16"],
        "flac": ["-f", "flac", "-d", "flac"], "caf": ["-f", "caff", "-d", "LEI16"],
    ]
    static let formatWords: [(String, String)] = [
        ("jpe?gs?", "jpg"), ("pngs?", "png"), ("heic", "heic"), ("tiff?s?", "tiff"), ("gifs?", "gif"), ("bmp", "bmp"), ("pdfs?", "pdf"),
        ("txt|plain text|text file", "txt"), ("m4a|aac", "m4a"), ("wavs?", "wav"), ("aiff?", "aiff"), ("flac", "flac"),
        ("mp4", "mp4"), ("mov", "mov"), ("mp3", "mp3"), ("webp", "webp"), ("zip", "zip"),
        ("images?|pictures?|photos?", "png"), ("audio|sound ?track", "m4a"),
    ]
    static let names = ["jpg": "JPEG", "png": "PNG", "heic": "HEIC", "tiff": "TIFF", "gif": "GIF", "bmp": "BMP", "pdf": "PDF", "txt": "text",
                        "m4a": "M4A", "wav": "WAV", "aiff": "AIFF", "flac": "FLAC", "mp4": "MP4", "mov": "MOV", "zip": "ZIP"]

    // MARK: helpers

    static func ext(_ p: String) -> String {
        let e = (p as NSString).pathExtension.lowercased()
        return e == "jpeg" ? "jpg" : (e == "tif" ? "tiff" : e)
    }

    static func kind(_ p: String) -> Kind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, !p.hasSuffix(".app") { return .folder }
        return Extract.kind(ext: (p as NSString).pathExtension.lowercased())
    }

    static func unique(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let e = (path as NSString).pathExtension, base = (path as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: "\(base) \(n)" + (e.isEmpty ? "" : "." + e)) { n += 1 }
        return "\(base) \(n)" + (e.isEmpty ? "" : "." + e)
    }

    // sibling of `src` with a new extension and optional name suffix
    static func sibling(_ src: String, ext: String, suffix: String = "") -> String {
        unique((src as NSString).deletingPathExtension + suffix + (ext.isEmpty ? "" : "." + ext))
    }

    @discardableResult
    static func sh(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: edata, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpError(msg.isEmpty ? "\((tool as NSString).lastPathComponent) failed" : String(msg.suffix(300)))
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Capability checks are cheap enough for result rows. Repeat them at execution time,
    // then read every input before any batch member can write or mutate a file.
    static func unavailableReason(_ op: Op, _ files: [String]) -> String? {
        guard !files.isEmpty else { return "Attach a file first" }
        if op.id == "rename", files.count != 1 { return "Rename requires exactly one file; attach one file at a time" }
        let imageOnly = ["resize", "rotate", "flip", "gray"]
        for file in files {
            let k = kind(file), e = ext(file), name = (file as NSString).lastPathComponent
            var reason: String?
            if imageOnly.contains(op.id), k != .image { reason = "requires images" }
            if op.id == "ocr", k != .image && e != "pdf" { reason = "requires images or PDFs" }
            if op.id == "merge", !files.allSatisfy({ kind($0) == .image }) && !files.allSatisfy({ ext($0) == "pdf" }) {
                return "Merge requires all images or all PDFs"
            }
            if op.id.hasPrefix("convert.") { reason = conversionReason(file, to: String(op.id.dropFirst(8))) }
            if let reason { return "\(name): \(reason)" }
        }
        return nil
    }

    static func conversionReason(_ file: String, to fmt: String) -> String? {
        let k = kind(file), e = ext(file)
        if fmt == "zip" { return nil }
        if e == fmt { return "is already \(names[fmt] ?? fmt.uppercased())" }
        if fmt == "webp" { return "macOS can't write WebP; try PNG or JPEG" }
        if fmt == "mp3" { return "macOS has no MP3 encoder; try M4A" }
        switch k {
        case .image:
            if imageFormats[fmt] != nil || ["pdf", "txt"].contains(fmt) { return nil }
        case .audio:
            if audioFormats[fmt] != nil { return nil }
        case .video:
            if ["mp4", "mov", "m4a"].contains(fmt) || audioFormats[fmt] != nil { return nil }
            if fmt == "gif" { return "Video to GIF needs ffmpeg, which isn't installed" }
        default:
            if e == "pdf", ["png", "jpg", "tiff", "txt"].contains(fmt) { return nil }
            let documents = Extract.plainExts.union(Extract.codeExts).union(["doc", "docx", "rtf", "rtfd", "odt"])
            if documents.contains(e), ["pdf", "txt"].contains(fmt) { return nil }
        }
        return "Can't turn \(e.isEmpty ? "this file" : e.uppercased()) into \(names[fmt] ?? fmt.uppercased())"
    }

    static func preflight(_ op: Op, _ files: [String]) throws {
        if let reason = unavailableReason(op, files) { throw OpError(reason) }
        for file in files {
            let name = (file as NSString).lastPathComponent
            guard FileManager.default.fileExists(atPath: file) else { throw OpError("\(name): file no longer exists") }
            guard FileManager.default.isReadableFile(atPath: file) else { throw OpError("\(name): file isn't readable") }
            let transforming = ["resize", "rotate", "flip", "gray", "ocr", "merge"].contains(op.id) || (op.id.hasPrefix("convert.") && op.id != "convert.zip")
            guard transforming else { continue }
            if kind(file) == .image, Extract.image(URL(fileURLWithPath: file), maxPixel: 32) == nil {
                throw OpError("\(name): can't read the image")
            }
            if ext(file) == "pdf" {
                guard let doc = PDFDocument(url: URL(fileURLWithPath: file)), doc.pageCount > 0 else { throw OpError("\(name): can't open the PDF") }
                if op.id == "convert.txt", doc.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    throw OpError("\(name): the PDF has no text layer; try “copy text” to OCR it")
                }
            } else if kind(file) == .audio || kind(file) == .video {
                let asset = AVURLAsset(url: URL(fileURLWithPath: file))
                guard !asset.tracks.isEmpty else { throw OpError("\(name): can't read the media") }
                if op.id == "convert.m4a" || audioFormats[String(op.id.dropFirst(8))] != nil {
                    guard !asset.tracks(withMediaType: .audio).isEmpty else { throw OpError("\(name): no audio track") }
                }
            } else if kind(file) != .image, ext(file) != "pdf", op.id.hasPrefix("convert.") {
                let url = URL(fileURLWithPath: file)
                guard (try? NSAttributedString(url: url, options: [:], documentAttributes: nil)) != nil || (try? String(contentsOf: url, encoding: .utf8)) != nil else {
                    throw OpError("\(name): can't read the document")
                }
            }
        }
    }

    static func checked(_ op: Op, _ files: [String]) -> Op {
        if op.preflightInstalled { return op }
        var result = op
        result.preflightInstalled = true
        result.unavailableReason = op.unavailableReason ?? unavailableReason(op, files)
        if let work = op.work {
            result.work = {
                if let reason = op.unavailableReason { throw OpError(reason) }
                try preflight(op, files)
                return try work()
            }
        }
        return result
    }

    // Keep completed outputs when a later file fails so the run UI can reveal them.
    static func batch(_ files: [String], _ work: (String) throws -> String) throws -> [String] {
        var outputs: [String] = []
        for file in files {
            do { outputs.append(try work(file)) }
            catch {
                let extra = (error as? OpError)?.completedOutputs ?? []
                let completed = outputs + extra
                let detail = "Failed on \((file as NSString).lastPathComponent): \(error.localizedDescription)"
                guard !completed.isEmpty else { throw OpError(detail) }
                let names = completed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                throw OpError("Completed \(outputs.count) of \(files.count) files. \(detail). Outputs: \(names)", completedOutputs: completed)
            }
        }
        return outputs
    }

    static func pixelSize(_ path: String) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? (h, w) : (w, h)
    }

    // MARK: primitives

    static func convertImage(_ src: String, _ fmt: String) throws -> String {
        guard let sipsFmt = imageFormats[fmt] else { throw OpError("Can't write \(fmt.uppercased()) images") }
        let dst = sibling(src, ext: fmt)
        try sh("/usr/bin/sips", ["-s", "format", sipsFmt, src, "--out", dst])
        return dst
    }

    // Bounds apply to the resulting image as well as the entered dimension, including
    // the other dimension derived from aspect ratio. Check in Double before using Int.
    static func resizeDimensions(_ src: String, width: Int?, height: Int?, percent: Double?) throws -> (Int, Int) {
        guard let (w, h) = pixelSize(src), w > 0, h > 0 else { throw OpError("Can't read the image size") }
        let nw: Double, nh: Double
        if let width, let height { (nw, nh) = (Double(width), Double(height)) }
        else if let width { (nw, nh) = (Double(width), (Double(h) * Double(width) / Double(w)).rounded()) }
        else if let height { (nw, nh) = ((Double(w) * Double(height) / Double(h)).rounded(), Double(height)) }
        else if let percent, percent.isFinite, percent > 0 {
            (nw, nh) = ((Double(w) * percent / 100).rounded(), (Double(h) * percent / 100).rounded())
        } else { throw OpError("Give a finite resize value greater than zero") }
        guard nw.isFinite, nh.isFinite, nw >= 1, nh >= 1, nw <= Double(maxResizeDimension), nh <= Double(maxResizeDimension),
              nw * nh <= Double(maxResizePixels) else {
            throw OpError("Resize output must be 1–\(maxResizeDimension) pixels per side and at most 40 million pixels")
        }
        return (Int(nw), Int(nh))
    }

    static func resize(_ src: String, width: Int?, height: Int?, percent: Double?) throws -> String {
        let (w, h) = try resizeDimensions(src, width: width, height: height, percent: percent)
        let label = width != nil && height != nil ? "\(w)x\(h)" : (height != nil ? "\(h)h" : "\(w)w")
        let dst = sibling(src, ext: (src as NSString).pathExtension, suffix: "-" + label)
        try sh("/usr/bin/sips", ["-z", String(h), String(w), src, "--out", dst])
        return dst
    }

    static func transform(_ src: String, _ args: [String], suffix: String) throws -> String {
        let dst = sibling(src, ext: (src as NSString).pathExtension, suffix: suffix)
        try sh("/usr/bin/sips", args + [src, "--out", dst])
        return dst
    }

    static func grayscale(_ src: String) throws -> String {
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw OpError("Can't read the image") }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let e = ["jpg", "png", "tiff"].contains(ext(src)) ? ext(src) : "png"
        let dst = sibling(src, ext: e, suffix: "-gray")
        let type = (e == "jpg" ? "public.jpeg" : (e == "png" ? "public.png" : "public.tiff")) as CFString
        guard let out = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, type, 1, nil) else { throw OpError("Can't write the image") }
        CGImageDestinationAddImage(d, out, CGImageSourceCopyPropertiesAtIndex(s, 0, nil))
        guard CGImageDestinationFinalize(d) else { throw OpError("Can't write the image") }
        return dst
    }

    // every page rendered at 2x; many pages go into a folder next to the PDF
    static func pdfToImages(_ src: String, _ fmt: String) throws -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: src)), doc.pageCount > 0 else { throw OpError("Can't open the PDF") }
        guard ["png", "jpg", "tiff"].contains(fmt) else { throw OpError("Pages can be exported as PNG, JPEG or TIFF") }
        let type: NSBitmapImageRep.FileType = fmt == "jpg" ? .jpeg : (fmt == "png" ? .png : .tiff)
        func render(_ i: Int, to path: String) throws {
            guard let page = doc.page(at: i) else { return }
            let b = page.bounds(for: .cropBox)
            let rot = page.rotation % 180 != 0
            let size = CGSize(width: (rot ? b.height : b.width) * 2, height: (rot ? b.width : b.height) * 2)
            let img = page.thumbnail(of: size, for: .cropBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: type, properties: [.compressionFactor: 0.9]) else { throw OpError("Can't render page \(i + 1)") }
            try data.write(to: URL(fileURLWithPath: path))
        }
        if doc.pageCount == 1 {
            let dst = sibling(src, ext: fmt)
            try render(0, to: dst)
            return dst
        }
        let dir = unique((src as NSString).deletingPathExtension + " pages")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        do {
            for i in 0..<doc.pageCount {
                try autoreleasepool { try render(i, to: dir + "/page-" + String(format: "%0\(digits)d", i + 1) + "." + fmt) }
            }
        } catch {
            let saved = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if !saved.isEmpty { throw OpError("Saved \(saved.count) partial pages in \((dir as NSString).lastPathComponent): \(error.localizedDescription)", completedOutputs: [dir]) }
            try? FileManager.default.removeItem(atPath: dir)
            throw error
        }
        return dir
    }

    static func imagesToPDF(_ srcs: [String]) throws -> String {
        let doc = PDFDocument()
        for s in srcs {
            guard let img = NSImage(contentsOfFile: s), let page = PDFPage(image: img) else { throw OpError("Can't read \((s as NSString).lastPathComponent)") }
            doc.insert(page, at: doc.pageCount)
        }
        let dst = sibling(srcs[0], ext: "pdf", suffix: srcs.count > 1 ? " combined" : "")
        guard doc.write(toFile: dst) else { throw OpError("Can't write the PDF") }
        return dst
    }

    static func mergePDFs(_ srcs: [String]) throws -> String {
        let out = PDFDocument()
        for s in srcs {
            guard let d = PDFDocument(url: URL(fileURLWithPath: s)) else { throw OpError("Can't open \((s as NSString).lastPathComponent)") }
            for i in 0..<d.pageCount { if let p = d.page(at: i) { out.insert(p, at: out.pageCount) } }
        }
        let dst = sibling(srcs[0], ext: "pdf", suffix: " merged")
        guard out.write(toFile: dst) else { throw OpError("Can't write the PDF") }
        return dst
    }

    // Word, RTF, text and Markdown laid out on Letter/A4 pages by the text system
    static func documentToPDF(_ src: String) throws -> String {
        let url = URL(fileURLWithPath: src)
        let attr: NSAttributedString
        if let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { attr = a } else if let t = try? String(contentsOf: url, encoding: .utf8) {
            attr = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        } else { throw OpError("Can't read the document") }
        let dst = sibling(src, ext: "pdf")
        var failed = false
        DispatchQueue.main.sync {
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: dst)
            info.topMargin = 64; info.bottomMargin = 64; info.leftMargin = 64; info.rightMargin = 64
            info.isVerticallyCentered = false
            let width = info.paperSize.width - 128
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            view.textStorage?.setAttributedString(attr)
            view.sizeToFit()
            let op = NSPrintOperation(view: view, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            failed = !op.run()
        }
        if failed { throw OpError("Can't lay out the document") }
        return dst
    }

    static func toText(_ src: String) throws -> String {
        let dst = sibling(src, ext: "txt")
        if ext(src) == "pdf" {
            guard let s = PDFDocument(url: URL(fileURLWithPath: src))?.string, !s.isEmpty else { throw OpError("The PDF has no text layer; try “copy text” to OCR it") }
            try s.write(toFile: dst, atomically: true, encoding: .utf8)
        } else if kind(src) == .image {
            try recognise([src]).write(toFile: dst, atomically: true, encoding: .utf8)
        } else {
            try sh("/usr/bin/textutil", ["-convert", "txt", "-output", dst, src])
        }
        return dst
    }

    static func convertAudio(_ src: String, _ fmt: String) throws -> String {
        guard let args = audioFormats[fmt] else { throw OpError(fmt == "mp3" ? "macOS has no MP3 encoder; try M4A" : "Can't write \(fmt.uppercased()) audio") }
        let dst = sibling(src, ext: fmt)
        try sh("/usr/bin/afconvert", args + [src, dst])
        return dst
    }

    static func exportVideo(_ src: String, _ fmt: String) throws -> String {
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        let audio = fmt == "m4a"
        guard let s = AVAssetExportSession(asset: asset, presetName: audio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality) else {
            throw OpError("Can't read the video")
        }
        let dst = sibling(src, ext: fmt)
        s.outputURL = URL(fileURLWithPath: dst)
        s.outputFileType = audio ? .m4a : (fmt == "mov" ? .mov : .mp4)
        let sem = DispatchSemaphore(value: 0)
        s.exportAsynchronously { sem.signal() }
        sem.wait()
        guard s.status == .completed else { throw OpError(s.error?.localizedDescription ?? "Export failed") }
        return dst
    }

    static func zip(_ srcs: [String]) throws -> String {
        guard !srcs.isEmpty else { throw OpError("Attach a file to compress first") }
        try preflight(Op(id: "convert.zip", title: "Compress", symbol: ""), srcs)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Semantic-archive-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: false)
        for src in srcs {
            // Preserve directory trees and disambiguate collisions at the archive root.
            let name = (src as NSString).lastPathComponent
            guard !name.isEmpty else { throw OpError("Can't archive an unnamed attachment") }
            try fm.copyItem(atPath: src, toPath: unique(contents.appendingPathComponent(name).path))
        }
        let stagedZip = staging.appendingPathComponent("archive.zip").path
        let args: [String]
        if srcs.count == 1 {
            args = ["-c", "-k", "--sequesterRsrc", "--keepParent", contents.appendingPathComponent((srcs[0] as NSString).lastPathComponent).path, stagedZip]
        } else { args = ["-c", "-k", "--sequesterRsrc", contents.path, stagedZip] }
        try sh("/usr/bin/ditto", args)
        let dst = unique((srcs.count == 1 ? (srcs[0] as NSString).deletingPathExtension : (srcs[0] as NSString).deletingLastPathComponent + "/Archive") + ".zip")
        try fm.moveItem(atPath: stagedZip, toPath: dst)
        return dst
    }

    static func recognise(_ srcs: [String]) throws -> String {
        var parts: [String] = []
        for s in srcs {
            let url = URL(fileURLWithPath: s)
            if ext(s) == "pdf", let doc = PDFDocument(url: url) {
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.count > 20 { if !text.isEmpty { parts.append(text) }; continue }
                    let img = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
                    if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let ocr = Extract.ocrLines(cg)
                        parts.append(ocr.isEmpty ? text : ocr)
                    } else if !text.isEmpty { parts.append(text) }
                }
            } else if let cg = Extract.image(url, maxPixel: 3000) { parts.append(Extract.ocrLines(cg)) }
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpError("No text found") }
        return text
    }

    static func convert(_ files: [String], to fmt: String) throws -> [String] {
        try preflight(Op(id: "convert." + fmt, title: "Convert", symbol: ""), files)
        if fmt == "zip" { return [try zip(files)] }
        if fmt == "webp" { throw OpError("macOS can't write WebP; try PNG or JPEG") }
        if fmt == "pdf", files.count > 1, files.allSatisfy({ kind($0) == .image }) { return [try imagesToPDF(files)] }
        return try batch(files) { f in
            let k = kind(f), e = ext(f)
            if e == fmt { throw OpError("\((f as NSString).lastPathComponent) is already \(names[fmt] ?? fmt)") }
            switch k {
            case .image:
                if fmt == "pdf" { return try imagesToPDF([f]) }
                if fmt == "txt" { return try toText(f) }
                return try convertImage(f, fmt)
            case .audio: return try convertAudio(f, fmt)
            case .video:
                if ["mp4", "mov", "m4a"].contains(fmt) { return try exportVideo(f, fmt) }
                if audioFormats[fmt] != nil { return try convertAudio(f, fmt) }
                if fmt == "gif" { throw OpError("Video to GIF needs ffmpeg, which isn't installed") }
            default:
                if e == "pdf" {
                    if fmt == "txt" { return try toText(f) }
                    return try pdfToImages(f, fmt)
                }
                if fmt == "pdf" { return try documentToPDF(f) }
                if fmt == "txt" { return try toText(f) }
            }
            throw OpError("Can't turn \(e.isEmpty ? "this" : e.uppercased()) into \(names[fmt] ?? fmt.uppercased())")
        }
    }

    static func folder(named raw: String) -> String? {
        let name = raw.lowercased().replacingOccurrences(of: "^(my|the) ", with: "", options: .regularExpression)
            .replacingOccurrences(of: " folder$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let std = ["desktop": "Desktop", "documents": "Documents", "docs": "Documents", "downloads": "Downloads", "pictures": "Pictures",
                   "movies": "Movies", "music": "Music", "home": ""]
        if let s = std[name] { return Paths.home + (s.isEmpty ? "" : "/" + s) }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue { return expanded }
        return Engine.shared.findFolder(name)
    }

    // MARK: building ops

    static func plural(_ files: [String]) -> String { files.count > 1 ? " (\(files.count) files)" : "" }

    static func convertOp(_ files: [String], _ fmt: String) -> Op {
        let isPDF = files.allSatisfy { ext($0) == "pdf" }
        let name = names[fmt] ?? fmt.uppercased()
        let title: String
        if fmt == "zip" { title = "Compress to ZIP" } else if isPDF, imageFormats[fmt] != nil { title = "Export pages as \(name)" } else if fmt == "m4a", files.allSatisfy({ kind($0) == .video }) {
            title = "Extract audio (M4A)"
        } else { title = "Convert to \(name)" }
        return checked(Op(id: "convert." + fmt, title: title + plural(files), symbol: "arrow.triangle.2.circlepath", work: { try convert(files, to: fmt) },
                  done: fmt == "zip" ? "Compressed" : "Converted to \(name)"), files)
    }

    static func blockedResize(_ files: [String], _ reason: String) -> Op {
        var op = Op(id: "resize", title: "Resize image" + plural(files), symbol: "arrow.up.left.and.arrow.down.right", work: { throw OpError(reason) })
        op.unavailableReason = reason
        return checked(op, files)
    }

    static func resizeNumbers(_ files: [String], width: Double?, height: Double?, percent: Double?) -> Op {
        for value in [width, height].compactMap({ $0 }) {
            guard value.isFinite, value >= 1, value <= Double(maxResizeDimension), value == value.rounded() else {
                return blockedResize(files, "Resize dimensions must be whole pixels from 1 to \(maxResizeDimension)")
            }
        }
        if let percent, !percent.isFinite || percent <= 0 { return blockedResize(files, "Resize percent must be finite and greater than zero") }
        return resizeOp(files, width: width.map { Int($0) }, height: height.map { Int($0) }, percent: percent)
    }

    static func resizeOp(_ files: [String], width: Int?, height: Int?, percent: Double?) -> Op {
        guard width != nil || height != nil || percent != nil else { return blockedResize(files, "Give a resize size or percent") }
        if let percent, !percent.isFinite || percent <= 0 { return blockedResize(files, "Resize percent must be finite and greater than zero") }
        for value in [width, height].compactMap({ $0 }) where value < 1 || value > maxResizeDimension {
            return blockedResize(files, "Resize dimensions must be whole pixels from 1 to \(maxResizeDimension)")
        }
        // Validate every resulting image size before the first image can be written.
        for file in files where kind(file) == .image {
            do { _ = try resizeDimensions(file, width: width, height: height, percent: percent) }
            catch { return blockedResize(files, "\((file as NSString).lastPathComponent): \(error.localizedDescription)") }
        }
        let label = width != nil && height != nil ? "\(width!) × \(height!) px" : (width.map { "\($0) px wide" } ?? height.map { "\($0) px tall" } ?? "\(Calc.plain(percent ?? 0))%")
        return checked(Op(id: "resize", title: "Resize to \(label)" + plural(files), symbol: "arrow.up.left.and.arrow.down.right",
                  work: {
                      // Files may have changed after the result row was constructed.
                      for file in files { _ = try resizeDimensions(file, width: width, height: height, percent: percent) }
                      return try batch(files) { try resize($0, width: width, height: height, percent: percent) }
                  }, done: "Resized to \(label)"), files)
    }

    static func simple(_ id: String, _ title: String, _ symbol: String, done: String, _ work: @escaping () throws -> [String]) -> Op {
        Op(id: id, title: title, symbol: symbol, work: work, done: done)
    }

    static func rotateOp(_ files: [String], _ degrees: Int) -> Op {
        let d = ((degrees % 360) + 360) % 360
        return checked(simple("rotate", "Rotate \(d == 270 ? "90° left" : (d == 90 ? "90° right" : "\(d)°"))" + plural(files), "rotate.right", done: "Rotated") {
            try batch(files) { try transform($0, ["-r", String(d)], suffix: "-rotated") }
        }, files)
    }

    static func renameOp(_ files: [String], _ raw: String) -> Op {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
        return checked(simple("rename", "Rename to “\(name)”", "pencil", done: "Renamed") {
            guard files.count == 1 else { throw OpError("Rename requires exactly one file; attach one file at a time") }
            guard let f = files.first, !name.isEmpty, !name.contains("/") else { throw OpError("Not a usable name") }
            let e = (f as NSString).pathExtension
            let full = (name as NSString).pathExtension.isEmpty && !e.isEmpty ? name + "." + e : name
            let dst = (f as NSString).deletingLastPathComponent + "/" + full
            guard !FileManager.default.fileExists(atPath: dst) else { throw OpError("“\(full)” already exists there") }
            try FileManager.default.moveItem(atPath: f, toPath: dst)
            return [dst]
        }, files)
    }

    static func relocateOp(_ files: [String], _ raw: String, copy: Bool) -> Op {
        let dir = folder(named: raw)
        let shown = dir.map(Paths.tilde) ?? "“\(raw)”"
        return checked(simple(copy ? "copy" : "move", "\(copy ? "Copy" : "Move") to \(shown)" + plural(files), copy ? "doc.on.doc" : "folder", done: copy ? "Copied" : "Moved") {
            guard let dir else { throw OpError("No folder named “\(raw)”") }
            return try batch(files) { f in
                let dst = unique(dir + "/" + (f as NSString).lastPathComponent)
                if copy { try FileManager.default.copyItem(atPath: f, toPath: dst) } else { try FileManager.default.moveItem(atPath: f, toPath: dst) }
                return dst
            }
        }, files)
    }

    static func ocrOp(_ files: [String]) -> Op {
        checked(Op(id: "ocr", title: "Copy text" + plural(files), symbol: "text.viewfinder", work: {
            let t = try recognise(files)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
            return []
        }, done: "Text copied"), files)
    }

    static func trashOp(_ files: [String]) -> Op {
        checked(simple("trash", "Move to Trash" + plural(files), "trash", done: "Moved to Trash") {
            _ = try batch(files) { f in
                var result: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: &result)
                return result?.path ?? f
            }
            return []
        }, files)
    }

    static func similarOp(_ file: String) -> Op {
        Op(id: "similar", title: "Find similar \(kind(file) == .audio ? "audio" : "images")", symbol: "square.stack.3d.down.right", stay: true,
           ui: { AppDelegate.shared?.bar.showSimilar(to: file) })
    }

    static func common(_ files: [String]) -> [Op] {
        [
            Op(id: "quicklook", title: "Quick Look", symbol: "eye", ui: { Sys.shell("/usr/bin/qlmanage", ["-p"] + files) }),
            Op(id: "reveal", title: "Reveal in Finder", symbol: "folder", ui: {
                NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: $0) })
            }),
            Op(id: "copypath", title: "Copy path", symbol: "link", ui: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(files.joined(separator: "\n"), forType: .string)
                Toast.show("Path copied")
            }),
            convertOp(files, "zip"),
            simple("duplicate", "Duplicate" + plural(files), "plus.square.on.square", done: "Duplicated") {
                try batch(files) { f in
                    let dst = sibling(f, ext: (f as NSString).pathExtension, suffix: " copy")
                    try FileManager.default.copyItem(atPath: f, toPath: dst)
                    return dst
                }
            },
            trashOp(files),
        ].map { checked($0, files) }
    }

    // shown when a file is attached and nothing has been typed yet
    static func suggestions(_ files: [String]) -> [Op] {
        guard let first = files.first else { return [] }
        let k = kind(first), e = ext(first)
        var ops: [Op] = []
        switch k {
        case .image:
            for f in ["jpg", "png"] where f != e { ops.append(convertOp(files, f)) }
            ops.append(resizeOp(files, width: nil, height: nil, percent: 50))
            ops.append(ocrOp(files))
            ops.append(convertOp(files, "pdf"))
            if files.count == 1 { ops.append(similarOp(first)) }
        case .audio:
            for f in ["m4a", "wav"] where f != e { ops.append(convertOp(files, f)) }
            if files.count == 1 { ops.append(similarOp(first)) }
        case .video:
            ops.append(convertOp(files, "m4a"))
            if e != "mp4" { ops.append(convertOp(files, "mp4")) }
            if files.count == 1 { ops.append(similarOp(first)) }
        case .doc where e == "pdf":
            ops.append(convertOp(files, "png"))
            ops.append(convertOp(files, "txt"))
            ops.append(ocrOp(files))
            if files.count > 1 { ops.append(simple("merge", "Merge into one PDF", "doc.on.doc", done: "Merged") { [try mergePDFs(files)] }) }
        case .doc:
            ops.append(convertOp(files, "pdf"))
            if e != "txt" { ops.append(convertOp(files, "txt")) }
        default: break
        }
        if files.allSatisfy({ [.image, .doc].contains(kind($0)) }) {
            ops.append(Op(id: "ask", title: "Ask ChatGPT about this", symbol: "bubble.left.and.text.bubble.right",
                          ui: { Assistant.ask("", files: files, app: Assistant.prefersApp) }))
        }
        return (ops + common(files)).map { checked($0, files) }.filter { $0.unavailableReason == nil }
    }

    static func match(_ t: String, _ pattern: String) -> [String]? { Calc.rx(t, pattern) }

    // natural-language request about the attached files -> ops, most specific first
    static func parse(_ text: String, _ files: [String]) -> [Op] {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard let first = files.first, !t.isEmpty else { return [] }
        var ops: [Op] = []

        if let m = match(text, "^(?:rename|name|call)(?: (?:it|this|that|them))?(?: (?:to|as))?\\s+(.+)$") { return [renameOp(files, m[1])] }
        if let m = match(text, "^(move|copy|put|send)(?: (?:it|this|that|them))?\\s+(?:to|into|in|onto)\\s+(.+)$") {
            return [relocateOp(files, m[2], copy: m[1].lowercased() == "copy")]
        }
        if let m = match(t, "^open (?:it |this )?(?:with|in|using)\\s+(.+)$"), let app = Engine.shared.findApp(m[1]) {
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            return [Op(id: "openwith", title: "Open with \(name)", symbol: "arrow.up.forward.app", ui: {
                NSWorkspace.shared.open(files.map { URL(fileURLWithPath: $0) }, withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
            })]
        }

        // Capture the entire number so oversized inputs cannot become a suffix size.
        let resizeNumber = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?|[-+]?(?:nan|inf(?:inity)?)"#
        if let m = match(t, ".*?(\(resizeNumber))\\s*(?:px)?\\s*(?:x|×|by)\\s*(\(resizeNumber)).*") {
            ops.append(resizeNumbers(files, width: Double(m[1]), height: Double(m[2]), percent: nil))
        } else if let m = match(t, ".*?(\(resizeNumber))\\s*(?:px|pixels?)?\\s*(wide|width|across|tall|high|height).*") {
            let tall = ["tall", "high", "height"].contains(m[2])
            ops.append(resizeNumbers(files, width: tall ? nil : Double(m[1]), height: tall ? Double(m[1]) : nil, percent: nil))
        } else if let m = match(t, ".*?(?:resize|scale|shrink|enlarge|reduce|downscale|upscale).*?(\(resizeNumber))\\s*(%|percent|px|pixels?)?.*") {
            let value = Double(m[1])
            if m[2].hasPrefix("p") && m[2] != "percent" || (m[2].isEmpty && (value ?? .infinity) > 200) {
                ops.append(resizeNumbers(files, width: value, height: nil, percent: nil))
            } else { ops.append(resizeNumbers(files, width: nil, height: nil, percent: value)) }
        } else if let m = match(t, ".*?(\(resizeNumber))\\s*(?:%|percent).*"), t.contains("size") || t.contains("small") || t.contains("big") {
            ops.append(resizeNumbers(files, width: nil, height: nil, percent: Double(m[1])))
        } else if match(t, ".*\\bhalf\\b.*") != nil, kind(first) == .image {
            ops.append(resizeOp(files, width: nil, height: nil, percent: 50))
        } else if match(t, ".*\\b(double|twice)\\b.*") != nil, kind(first) == .image {
            ops.append(resizeOp(files, width: nil, height: nil, percent: 200))
        }

        if match(t, ".*\\b(rotate|turn (it )?(left|right|sideways|upside down))\\b.*") != nil {
            let w = match(t, ".*?(?<![a-z0-9.+-])(left|counter[ -]?clockwise|anti[ -]?clockwise|upside down|right|clockwise|[+-]?\\d+)(?![a-z0-9.]).*")?[1] ?? ""
            let d = w == "left" || w.hasPrefix("counter") || w.hasPrefix("anti") ? -90 : (w == "upside down" ? 180 : (Int(w) ?? 90))
            ops.append(rotateOp(files, d))
        }
        if match(t, ".*\\b(flip|mirror)\\b.*") != nil {
            let dir = t.contains("vertical") || t.contains("upside") ? "vertical" : "horizontal"
            ops.append(simple("flip", "Flip \(dir)ly", "arrow.left.and.right.righttriangle.left.righttriangle.right", done: "Flipped") {
                try batch(files) { try transform($0, ["-f", dir], suffix: "-flipped") }
            })
        }
        if match(t, ".*\\b(gr[ae]yscale|black and white|b&w|monochrome|desaturate)\\b.*") != nil {
            ops.append(simple("gray", "Convert to grayscale" + plural(files), "circle.lefthalf.filled", done: "Converted to grayscale") { try batch(files, grayscale) })
        }
        if match(t, ".*\\b(ocr|copy (the )?text|extract (the )?text|grab (the )?text|read (the )?text|get (the )?text|transcribe)\\b.*") != nil { ops.append(ocrOp(files)) }
        if match(t, ".*\\b(merge|combine|join|stitch)\\b.*") != nil, files.count > 1 {
            if files.allSatisfy({ ext($0) == "pdf" }) { ops.append(simple("merge", "Merge into one PDF", "doc.on.doc", done: "Merged") { [try mergePDFs(files)] }) } else if files.allSatisfy({ kind($0) == .image }) {
                ops.append(simple("merge", "Combine into one PDF", "doc.on.doc", done: "Combined") { [try imagesToPDF(files)] })
            } else {
                ops.append(simple("merge", "Merge into one PDF", "doc.on.doc", done: "Merged") { throw OpError("Merge requires all images or all PDFs") })
            }
        }
        if match(t, ".*\\b(compress|zip|archive)\\b.*") != nil { ops.append(convertOp(files, "zip")) }
        if match(t, ".*\\b(similar|like this|look alike|lookalike|more like|sounds? like)\\b.*") != nil, files.count == 1 { ops.append(similarOp(first)) }
        if match(t, "^(trash|delete|remove|bin|get rid of)\\b.*") != nil { ops.append(trashOp(files)) }

        // a format name anywhere: "turn into jpg", "as pngs", "pdf"
        if !ops.contains(where: { $0.id.hasPrefix("convert") }) {
            for (pattern, fmt) in formatWords where match(t, "^(?:.*[^a-z0-9])?(?:\(pattern))(?:[^a-z0-9].*)?$") != nil {
                if fmt == ext(first) && files.count == 1 { continue }
                // "images" from a PDF means pages; from anything else it is not a conversion request
                if pattern.hasPrefix("images"), ext(first) != "pdf" { continue }
                if pattern.hasPrefix("audio"), kind(first) != .video { continue }
                ops.append(convertOp(files, fmt))
                break
            }
        }
        // the generic verbs, when nothing more specific matched
        if ops.isEmpty {
            let generic = common(files).filter { op in
                switch op.id {
                case "quicklook": return match(t, ".*\\b(quick ?look|preview|peek)\\b.*") != nil
                case "reveal": return match(t, ".*\\b(reveal|show in finder|where is)\\b.*") != nil
                case "copypath": return match(t, ".*\\b(copy )?(the )?path\\b.*") != nil
                case "duplicate": return match(t, ".*\\b(duplicate|clone|make a copy)\\b.*") != nil
                default: return false
                }
            }
            ops += generic
        }
        return ops.map { checked($0, files) }
    }

    // the language model's flat JSON command -> op
    static func from(_ j: [String: Any], _ files: [String]) -> Op? {
        func str(_ k: String) -> String? { (j[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func num(_ k: String) -> Double? {
            (j[k] as? Double) ?? (j[k] as? String).flatMap { value in
                Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Double(value.filter { "0123456789.-".contains($0) })
            }
        }
        func resizeValue(_ key: String) -> Double? {
            if let value = j[key] as? Double { return value }
            guard let raw = j[key] as? String else { return nil }
            let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?|[-+]?(?:nan|inf(?:inity)?)"#
            guard let m = match(raw.lowercased(), "^\\s*(\(number))\\s*(?:px|pixels?|%|percent)?\\s*$") else { return nil }
            return Double(m[1])
        }
        switch j["action"] as? String {
        case "convert":
            guard var f = str("format")?.lowercased() else { return nil }
            f = f == "jpeg" ? "jpg" : (f == "tif" ? "tiff" : (f == "text" ? "txt" : f))
            return names[f] != nil || f == "mp3" || f == "webp" ? convertOp(files, f) : nil
        case "resize":
            let keys = ["width", "height", "percent"]
            guard keys.contains(where: { j[$0] != nil }) else { return nil }
            if keys.contains(where: { j[$0] != nil && resizeValue($0) == nil }) { return blockedResize(files, "Give a valid finite resize number") }
            return resizeNumbers(files, width: resizeValue("width"), height: resizeValue("height"), percent: resizeValue("percent"))
        case "rotate":
            let value = num("degrees") ?? 90
            guard value.isFinite else {
                let reason = "Rotation degrees must be finite"
                var op = simple("rotate", "Rotate image", "rotate.right", done: "Rotated") { throw OpError(reason) }
                op.unavailableReason = reason
                return checked(op, files)
            }
            return rotateOp(files, Int(value.truncatingRemainder(dividingBy: 360)))
        case "rename": return str("name").map { renameOp(files, $0) }
        case "move": return str("folder").map { relocateOp(files, $0, copy: false) }
        case "copy": return str("folder").map { relocateOp(files, $0, copy: true) }
        case "ocr": return ocrOp(files)
        case "trash": return trashOp(files)
        case "zip": return convertOp(files, "zip")
        default: return nil
        }
    }

    // run an op the way the bar does: in the background, then show what was made
    static func run(_ op: Op) {
        if let ui = op.ui { ui(); return }
        guard let work = op.work else { return }
        Toast.show("Working…", sticky: true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outs = try work()
                DispatchQueue.main.async {
                    Toast.show("✓ " + op.done + (outs.first.map { " → " + ($0 as NSString).lastPathComponent } ?? ""))
                    if !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs.map { URL(fileURLWithPath: $0) }) }
                }
            } catch {
                let outputs = (error as? OpError)?.completedOutputs ?? []
                DispatchQueue.main.async {
                    Toast.show("✗ " + error.localizedDescription, seconds: outputs.isEmpty ? 4 : 8)
                    if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs.map { URL(fileURLWithPath: $0) }) }
                }
            }
        }
    }
}
