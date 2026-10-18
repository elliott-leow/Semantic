import AppKit

// The preview never claims a file is unpreviewable when it has something honest to show.
enum PreviewChecks {
    static func run(root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        let dir = root.appendingPathComponent("previews")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("Folder/Inner"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("Folder/notes.txt").path, contents: Data("hi".utf8))
        fm.createFile(atPath: dir.appendingPathComponent("latin.txt").path, contents: "café crème".data(using: .isoLatin1))
        fm.createFile(atPath: dir.appendingPathComponent("blob.qqq").path, contents: Data((0..<512).map { UInt8($0 % 256) }))
        fm.createFile(atPath: dir.appendingPathComponent("empty.txt").path, contents: Data())

        let preview = FilePreview(frame: NSRect(x: 0, y: 0, width: 488, height: 370))
        func show(_ name: String) -> (String, String?) {
            let path = dir.appendingPathComponent(name).path
            preview.show(Hit(title: name, subtitle: "", icon: .file(path), tag: "File", path: path) { _ in })
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if preview.textForChecks != nil || (preview.statusForChecks.isEmpty && Date() > deadline - 2.4) { break }
            }
            return (preview.statusForChecks, preview.textForChecks)
        }
        let app = show("Tool.app")
        check("a one-line name is centred on its icon", preview.nameOffsetForChecks < 0.5)
        check("an app shows its icon without an error", app.0.isEmpty && app.1 == nil)
        let folder = show("Folder")
        check("a folder lists what is inside it", folder.1?.contains("Inner/") == true && folder.1?.contains("notes.txt") == true)
        check("non-UTF-8 text still previews", show("latin.txt").1?.contains("café") == true)
        check("an empty file says so", show("empty.txt").1 == "Empty file")
        let blob = show("blob.qqq")
        check("an unrenderable file keeps its icon without an error", !blob.0.contains("unavailable"))
        check("a file that disappeared says so", show("gone.pdf").0 == "This file is no longer here")
        preview.show(nil)
        return results
    }
}
