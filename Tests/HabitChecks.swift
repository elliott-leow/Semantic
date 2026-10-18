import Foundation

// App-first ranking and learning from what is picked. Runs last: it teaches Habits.shared.
enum HabitChecks {
    static func run(root: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { results.append((label, passed)) }
        let db = Store(path: ":memory:")!
        let base = root.appendingPathComponent("habits").path
        // real paths: suggestions leave out anything no longer on disk
        func add(_ fixture: String, kind: Kind = .doc, time: Double = 100) {
            let path = base + fixture
            if kind == .app || kind == .folder { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            else {
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data("fixture".utf8))
            }
            db.run("INSERT INTO files(path,name,kind,mtime,size,state,snippet) VALUES(?,?,?,?,?,3,'')",
                   [path, kind == .app ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : (path as NSString).lastPathComponent,
                    kind.rawValue, time, 100])
        }
        add("/fixtures/Apps/Google Chrome.app", kind: .app)
        add("/fixtures/Apps/Safari.app", kind: .app)
        add("/fixtures/Apps/Slack.app", kind: .app)
        add("/fixtures/Apps/Spotify.app", kind: .app)
        add("/fixtures/Code/Chrome.tsx", kind: .other, time: 300)
        add("/fixtures/Code/spotify", kind: .folder)
        add("/fixtures/Work/s.txt")
        add("/fixtures/Work/budget 2025.pdf", time: 400)
        add("/fixtures/Work/budget 2026.pdf", time: 200)
        add("/fixtures/Work/Spotify invoice.pdf")
        add("/fixtures/Work/plan a.pdf")
        add("/fixtures/Work/plan b.pdf")
        let ix = Index.load(store: db)
        let e = Engine(index: ix, quickIndex: ix.metadataSnapshot())
        func titles(_ q: String) -> [String] { e.build(q).hits.filter { $0.path != nil }.map(\.title) }

        check("an app named by a whole word beats a file with that name", titles("chrome").first == "Google Chrome")
        check("an app prefix beats a folder of the same word", titles("spot").first == "Spotify")
        check("one typed letter offers apps first", titles("s").prefix(3).allSatisfy { ["Safari", "Slack", "Spotify"].contains($0) })
        check("app launches do not offer to ask ChatGPT", !e.build("chrome").hits.contains { $0.tag == "ChatGPT" })
        check("an exact filename still beats documents that merely share a word", titles("budget 2026").first == "budget 2026.pdf")

        // learning: the older budget is what this user means by "budget"
        check("newer file leads before anything is learned", titles("budget").first == "budget 2025.pdf")
        e.recordPick("budget", base + "/fixtures/Work/budget 2026.pdf")
        check("one pick reorders that exact query", titles("budget").first == "budget 2026.pdf")
        check("the learned pick also leads for a shorter prefix", titles("bud").first == "budget 2026.pdf")
        e.recordPick("s", base + "/fixtures/Apps/Spotify.app")
        e.recordPick("s", base + "/fixtures/Apps/Spotify.app")
        check("a repeated pick for one letter makes it the first suggestion", titles("s").first == "Spotify")
        e.recordPick("zebra", base + "/fixtures/Work/budget 2025.pdf")
        check("learning cannot admit an unrelated result from a single pick", !titles("zebra").contains("budget 2025.pdf"))
        e.recordPick("zebra", base + "/fixtures/Work/budget 2025.pdf")
        check("a choice repeated for the same words is what those words mean", titles("zebra").first == "budget 2025.pdf")

        check("alphabetical order decides between equal files before learning", titles("plan").first == "plan a.pdf")
        e.recordPick("plan", base + "/fixtures/Old/plan b.pdf")
        check("what was learned follows a file that has since moved", titles("plan").first == "plan b.pdf")

        var quick: [SearchResult] = []
        e.search("s") { quick.append($0) }
        let deadline = Date().addingTimeInterval(2)
        while quick.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check("the first, fast result already reflects what was learned", quick.first?.hits.first?.title == "Spotify")

        // nothing typed: habit suggests, and the app already in front is left out
        var empty: [SearchResult] = []
        e.search("") { empty.append($0) }
        let until = Date().addingTimeInterval(2)
        while empty.isEmpty, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check("an empty bar suggests what is picked most", empty.first?.hits.first?.title == "Spotify" && empty.first?.note == "Suggested")
        Habits.shared.setContext(base + "/fixtures/Apps/Spotify.app")
        check("the app in front is never suggested", !Habits.shared.predictions(limit: 6).contains { $0.0 == base + "/fixtures/Apps/Spotify.app" })
        Habits.shared.setContext(nil)

        // the model on its own: decay, time of day and what follows what
        let model = Habits(path: root.appendingPathComponent("habits-only.sqlite").path)
        let day = 86400.0, now = 1_800_000_000.0
        for k in 0..<6 { model.recordPick("", "/a/Old.app", now: now - 120 * day + Double(k)) }
        model.recordPick("", "/a/New.app", now: now - day)
        let p = model.prior(now: now)
        check("a recent pick outweighs older, more frequent ones", (p["/a/New.app"] ?? 0) > (p["/a/Old.app"] ?? 0))
        let hour = Habits.hour(now)
        // the other app was even used more recently, just never at this hour
        for k in 0..<3 { model.recordPick("", "/a/Morning.app", now: now - Double(k + 1) * day) }
        for k in 0..<3 { model.recordPick("", "/a/Evening.app", now: now - 8 * 3600 - Double(k) * day) }
        let q = model.prior(now: now)
        check("an app used at this hour outranks one used as often at another hour (hour \(hour))", (q["/a/Morning.app"] ?? 0) > (q["/a/Evening.app"] ?? 0))
        model.setContext("/a/Mail.app")
        for _ in 0..<3 { model.recordPick("", "/a/Calendar.app", now: now - day) }
        model.setContext("/a/Code.app")
        for _ in 0..<3 { model.recordPick("", "/a/Terminal.app", now: now - day) }
        let fromCode = model.prior(now: now)
        check("what usually follows the app in front ranks higher", (fromCode["/a/Terminal.app"] ?? 0) > (fromCode["/a/Calendar.app"] ?? 0))
        model.recordActivation("/a/Browser.app", from: "/a/Code.app", now: now)
        check("a single app switch is weaker evidence than a pick", (model.prior(now: now)["/a/Browser.app"] ?? 0) < (fromCode["/a/Terminal.app"] ?? 0))
        for q in ["screensharing", "screen sharing"] { model.recordPick(q, "/a/Screen Sharing.app", now: now) }
        model.recordPick("spot", "/a/Spotify.app", now: now)
        let one = model.boosts("s", now: now)
        check("several loosely related queries do not outvote the closest one", (one["/a/Spotify.app"] ?? 0) > (one["/a/Screen Sharing.app"] ?? 0))
        model.flush()
        let reloaded = Habits(path: root.appendingPathComponent("habits-only.sqlite").path)
        reloaded.setContext("/a/Code.app")
        check("learned habits survive a restart", abs((reloaded.prior(now: now)["/a/Terminal.app"] ?? 0) - (model.prior(now: now)["/a/Terminal.app"] ?? 0)) < 0.01)
        return results
    }
}
