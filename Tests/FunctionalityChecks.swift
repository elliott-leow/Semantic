import AppKit
import Foundation
import SQLite3

enum FunctionalityChecks {
    // Runs last: root is the isolated test fixture directory, never a user directory.
    static func run(root: URL) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let fm = FileManager.default
        let db = Store(path: ":memory:")!
        for path in ["/fixtures/Archive/report.pdf", "/backup/fixtures/Archive/report.pdf"] {
            db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,4,'')", [path, "report.pdf", Kind.doc.rawValue, 0.0, 10])
        }
        let index = Index.load(store: db)
        var filter = Filters(); filter.pathPrefix = "/fixtures/Archive"
        out.append(("absolute folder filter excludes the same suffix under another root", index.entries.filter(filter.matches).map(\.path) == ["/fixtures/Archive/report.pdf"]))
        filter.pathPrefix = "Archive"
        out.append(("relative folder filter can match the folder at either location", index.entries.filter(filter.matches).count == 2))
        let (large, _) = Filters.parse("images larger than 99999999999999999999999999 gb", folderExists: { _ in false })
        out.append(("oversized file-size filters saturate without integer overflow", large.minSize == Int.max))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        let now = calendar.date(byAdding: .hour, value: 2, to: morning)!
        let explicitAM = Commands.nextDetectedTime(morning, matched: "9am", now: now, calendar: calendar)
        out.append(("past explicit AM rolls to next morning rather than evening", calendar.component(.hour, from: explicitAM) == 9 && calendar.component(.day, from: explicitAM) == 13))
        out.append(("explicit today date constraint remains unchanged", Commands.nextDetectedTime(morning, matched: "today at 9am", now: now, calendar: calendar) == morning))
        out.append(("bare hour can still infer the next evening occurrence", calendar.component(.hour, from: Commands.nextDetectedTime(morning, matched: "9", now: now, calendar: calendar)) == 21))
        let earlierDownload = Resolver.referenceTime(modified: Date(timeIntervalSince1970: 300), added: Date(timeIntervalSince1970: 100), preferArrival: true)
        let laterDownload = Resolver.referenceTime(modified: Date(timeIntervalSince1970: 200), added: Date(timeIntervalSince1970: 200), preferArrival: true)
        out.append(("editing an older download does not make it the latest arrival", earlierDownload < laterDownload))
        out.append(("download ordering falls back to modification when arrival is unavailable", Resolver.referenceTime(modified: Date(timeIntervalSince1970: 200), added: nil, preferArrival: true) == 200))
        for (start, end) in [("2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z"), ("2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z")] {
            let first = iso.date(from: start)!, next = iso.date(from: end)!
            for (word, now) in [("today", first.addingTimeInterval(3600)), ("tomorrow", first.addingTimeInterval(-3600)), ("yesterday", next.addingTimeInterval(3600))] {
                let (filter, _) = Filters.parse(word, now: now, calendar: calendar, folderExists: { _ in false })
                out.append(("\(word) respects DST day boundaries at \(start)", filter.after == first.timeIntervalSince1970 && filter.before == next.timeIntervalSince1970))
            }
        }
        let old = Indexer.Cand(path: "contact:test", name: "Test Contact", kind: .contact, mtime: 0, size: 0, body: "old@example.invalid")
        var edited = old; edited.body = "new@example.invalid"
        out.append(("source revision changes when body changes despite constant timestamp", old.sourceRevision != edited.sourceRevision && old.sourceRevision == old.sourceRevision))
        let renamed = Indexer.Cand(path: old.path, name: "Renamed Contact", kind: .contact, mtime: 0, size: 0, body: old.body)
        out.append(("source revision includes display name", old.sourceRevision != renamed.sourceRevision))
        let scope = root.appendingPathComponent("explicit-scope")
        try! fm.createDirectory(at: scope, withIntermediateDirectories: true)
        let shot = scope.appendingPathComponent("Screenshot fixture.png")
        try! Data([0]).write(to: shot)
        out.append(("latest screenshot honors an explicit folder", Resolver.newest("screenshot", count: 1, folder: scope.path).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == [shot.resolvingSymlinksInPath()]))
        let rapid = root.appendingPathComponent("rapid.txt")
        try! "Rapid original ALPHA123".write(to: rapid, atomically: true, encoding: .utf8)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try! fm.setAttributes([.modificationDate: stamp], ofItemAtPath: rapid.path)
        _ = Indexer.run(full: false)
        try! "Rapid replaced BRAVO456".write(to: rapid, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: stamp.addingTimeInterval(0.2)], ofItemAtPath: rapid.path)
        _ = Indexer.run(full: false)
        let current = Store(readonly: true)!
        out.append(("subsecond same-size edits replace indexed text", current.contentMatches("ALPHA123").isEmpty && !current.contentMatches("BRAVO456").isEmpty))
        for child in try! fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { try! fm.removeItem(at: child) }
        _ = Indexer.run(full: false, namesOnly: true)
        out.append(("empty readable root removes all former descendant records", Index.load().entries.allSatisfy { !$0.path.hasPrefix(root.path + "/") }))
        return out
    }
}
