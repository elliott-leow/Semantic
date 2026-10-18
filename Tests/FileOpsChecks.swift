import AppKit
import CoreText
import PDFKit

// Called by SearchTests with its isolated temporary root. No run UI or user paths.
enum FileOpsChecks {
    static func run(root: URL) -> [(String, Bool)] {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("fileops-checks-" + UUID().uuidString)
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        func rejected(_ op: Op?) -> Bool {
            guard let op, op.unavailableReason != nil, let work = op.work else { return false }
            do { _ = try work(); return false } catch { return error is OpError }
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: dir) }
            let left = dir.appendingPathComponent("left"), right = dir.appendingPathComponent("right")
            let bundleA = left.appendingPathComponent("bundle"), bundleB = right.appendingPathComponent("bundle")
            try fm.createDirectory(at: bundleA.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try fm.createDirectory(at: bundleB.appendingPathComponent("deep/more"), withIntermediateDirectories: true)
            let treeA = bundleA.appendingPathComponent("nested/shared.txt"), treeB = bundleB.appendingPathComponent("deep/more/shared.txt")
            let fileA = left.appendingPathComponent("shared.txt"), fileB = right.appendingPathComponent("shared.txt")
            let fixtures = [(treeA, "first tree"), (treeB, "second tree"), (fileA, "first file"), (fileB, "second file")]
            for (url, value) in fixtures { try value.write(to: url, atomically: true, encoding: .utf8) }
            let destination = dir.appendingPathComponent("CaseSensitiveDestination")
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            let copy = FileOps.parse("COPY to " + destination.path, [fileA.path]).first!
            let copied = try copy.work!()
            check("copy command preserves destination case and original source", copied == [destination.appendingPathComponent("shared.txt").path] && fm.fileExists(atPath: fileA.path))
            let archive = try FileOps.zip([bundleA.path, bundleB.path, fileA.path, fileB.path])
            let extracted = dir.appendingPathComponent("extracted")
            try FileOps.sh("/usr/bin/ditto", ["-x", "-k", archive, extracted.path])
            let expected = [("bundle/nested/shared.txt", "first tree"), ("bundle 2/deep/more/shared.txt", "second tree"),
                            ("shared.txt", "first file"), ("shared 2.txt", "second file")]
            check("ZIP preserves nested trees and disambiguates duplicate attachment names", expected.allSatisfy { path, value in
                (try? String(contentsOf: extracted.appendingPathComponent(path), encoding: .utf8)) == value
            })
            check("ZIP preserves original attachment contents", fixtures.allSatisfy { url, value in
                (try? String(contentsOf: url, encoding: .utf8)) == value
            })
            do { _ = try FileOps.zip([]); check("empty ZIP input has an explicit error", false) }
            catch { check("empty ZIP input has an explicit error", error is OpError) }

            // Force failure after staging/compression, entirely within this fixture root.
            let locked = dir.appendingPathComponent("locked")
            try fm.createDirectory(at: locked, withIntermediateDirectories: false)
            let lockedFile = locked.appendingPathComponent("source.txt")
            try "locked fixture".write(to: lockedFile, atomically: true, encoding: .utf8)
            func stagingNames() -> Set<String> {
                Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("Semantic-archive-") })
            }
            let beforeStaging = stagingNames()
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            var archiveFailed = false
            do { _ = try FileOps.zip([lockedFile.path]) } catch { archiveFailed = true }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            check("failed ZIP leaves no staging directory or partial destination", archiveFailed && stagingNames() == beforeStaging && !fm.fileExists(atPath: locked.appendingPathComponent("source.zip").path))

            let image = dir.appendingPathComponent("image.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 3,
                                      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let bytes = rep.representation(using: .png, properties: [:])!
            try bytes.write(to: image)
            for (degrees, title) in [(-90, "Rotate 90° left"), (-270, "Rotate 90° right"), (90, "Rotate 90° right"), (270, "Rotate 90° left")] {
                let rotation = FileOps.parse("rotate \(degrees)", [image.path]).first
                check("rotation preserves signed degrees \(degrees)", rotation?.title == title)
            }
            check("hyphenated counter-clockwise rotation stays left", FileOps.parse("rotate counter-clockwise", [image.path]).first?.title == "Rotate 90° left")
            let huge = String(repeating: "9", count: 400)
            let requests = ["resize to " + huge + " px", "resize " + huge + "%", huge + " pixels wide", huge + " x 100",
                            "resize 1e999 px", "resize NaN%", "resize infinity px", "resize -10 px", "resize 1.5 px", "resize 0 px"]
            let beforeResize = Set(try fm.contentsOfDirectory(atPath: dir.path))
            for request in requests {
                check("invalid resize query is explained without a trap: " + String(request.prefix(45)), rejected(FileOps.parse(request, [image.path]).first))
            }
            for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, -1, 0, 1.5] {
                check("invalid JSON resize dimension is rejected: " + String(value), rejected(FileOps.from(["action": "resize", "width": value], [image.path])))
            }
            for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, -1, 0] {
                check("invalid JSON resize percent is rejected: " + String(value), rejected(FileOps.from(["action": "resize", "percent": value], [image.path])))
            }
            check("scientific notation with units retains its numeric value", rejected(FileOps.from(["action": "resize", "width": "1e999 px"], [image.path])))
            check("oversized output area is rejected", rejected(FileOps.resizeOp([image.path], width: 10_000, height: 10_000, percent: nil)))
            check("subpixel percentage output is rejected", rejected(FileOps.resizeOp([image.path], width: nil, height: nil, percent: 0.01)))
            check("invalid resize operations create no files and preserve originals", beforeResize == Set(try fm.contentsOfDirectory(atPath: dir.path)) && (try? Data(contentsOf: image)) == bytes)
            let valid = FileOps.from(["action": "resize", "width": "4 px"], [image.path])!
            let outputs = try valid.work!()
            check("valid numeric resize preserves aspect ratio and original bytes", outputs.count == 1 && FileOps.pixelSize(outputs[0])?.0 == 4 && FileOps.pixelSize(outputs[0])?.1 == 3 && (try? Data(contentsOf: image)) == bytes)

            // A real text-layer cover followed by an image-only PDF page.
            let data = NSMutableData()
            var pageBounds = CGRect(x: 0, y: 0, width: 900, height: 300)
            let consumer = CGDataConsumer(data: data as CFMutableData)!
            let pdf = CGContext(consumer: consumer, mediaBox: &pageBounds, nil)!
            pdf.beginPDFPage(nil)
            let cover = NSAttributedString(string: "Text cover retained in mixed PDF document", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
            pdf.textPosition = CGPoint(x: 40, y: 160)
            CTLineDraw(CTLineCreateWithAttributedString(cover as CFAttributedString), pdf)
            pdf.endPDFPage(); pdf.closePDF()
            let mixed = PDFDocument(data: data as Data)!
            let raster = CGContext(data: nil, width: 900, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            raster.setFillColor(CGColor(gray: 1, alpha: 1)); raster.fill(pageBounds)
            let rasterText = NSAttributedString(string: "RASTER CHECK 48291", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 54, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            raster.textPosition = CGPoint(x: 40, y: 120)
            CTLineDraw(CTLineCreateWithAttributedString(rasterText as CFAttributedString), raster)
            let rasterImage = NSImage(cgImage: raster.makeImage()!, size: NSSize(width: 900, height: 300))
            mixed.insert(PDFPage(image: rasterImage)!, at: 1)
            let mixedPath = dir.appendingPathComponent("mixed.pdf")
            guard mixed.write(to: mixedPath) else { throw OpError("Can't write mixed PDF fixture") }
            check("mixed PDF fixture has text cover and image-only second page", (mixed.page(at: 0)?.string?.count ?? 0) > 20 && (mixed.page(at: 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            for _ in 0..<19 { mixed.insert(mixed.page(at: 0)!.copy() as! PDFPage, at: 1) }
            guard mixed.write(to: mixedPath) else { throw OpError("Can't write long mixed PDF fixture") }
            let recognized = try FileOps.recognise([mixedPath.path]).lowercased()
            check("mixed PDF OCR retains text cover and scanned text after page 20", recognized.contains("text cover retained") && recognized.contains("raster check 48291"))
        } catch { check("FileOps fixture setup/execution: " + error.localizedDescription, false) }
        return results
    }
}
