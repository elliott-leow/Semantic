import AppKit

// When the indexer child process runs, and how the bar learns about its progress.
extension AppDelegate {
    func startIndexer() {
        guard indexer == nil, let exe = Bundle.main.executablePath else { pendingIndex = indexer != nil; return }
        lastIndexRun = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--index"]
        p.qualityOfService = .utility
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexer = nil
                self.progressTimer?.invalidate()
                self.bar.status = ""
                Engine.shared.reloadIndex()
                if self.pendingIndex { self.pendingIndex = false; self.startIndexer() }
            }
        }
        guard (try? p.run()) != nil else { return }
        indexer = p
        ticks = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let s = Store(readonly: true)?.metaString("progress") else { return }
            self.bar.status = "Indexing \(s)"
            self.ticks += 1
            if self.ticks == 1 || self.ticks % 8 == 0 { Engine.shared.reloadIndex() } // surface new results while indexing
        }
    }

    func watchFiles() {
        let roots = Indexer.roots() as CFArray
        let cb: FSEventStreamCallback = { _, _, _, _, _, _ in
            DispatchQueue.main.async {
                guard let d = AppDelegate.shared else { return }
                let wait = max(0, 60 - Date().timeIntervalSince(d.lastIndexRun))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    if Date().timeIntervalSince(d.lastIndexRun) >= 60 { d.startIndexer() }
                }
            }
        }
        guard let s = FSEventStreamCreate(nil, cb, nil, roots, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 15,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
}
