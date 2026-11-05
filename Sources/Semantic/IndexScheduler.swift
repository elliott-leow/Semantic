import AppKit

// Scheduler state; AppDelegate is an extension here, so it lives beside it (main thread only).
private enum Watch {
    static var dirs = Set<String>()   // folders with changed entries since the last run started
    static var rescan = false         // FSEvents lost track (dropped events, root moved): walk everything
    static var timer: Timer?          // the one pending debounce
    static var roots: [String] = []
    static var home: DispatchSourceFileSystemObject?
    static var store: Store?          // one read-only connection for progress polling
    static let maxDirs = 400          // beyond this a full walk is cheaper than listing each folder
    static var generation: String??   // meta "generation" as of the last reload; nil before one
    static var dirty = false          // a reload was skipped because the bar was hidden
    static var packages: [String: Bool] = [:] // folder -> is a package, for the file watcher

    // The outermost package that `path` lies strictly inside, if any. Only names with an extension are
    // looked at: that is how packages are recognised, and it keeps the check to a few cached lookups.
    static func package(containing path: String) -> String? {
        guard let base = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return nil }
        var p = base
        for comp in path.dropFirst(base.count + 1).split(separator: "/").dropLast() {
            p += "/" + comp
            guard comp.contains(".") else { continue }
            if let known = packages[p] { if known { return p } else { continue } }
            guard let isPackage = Indexer.isPackage(p) else { continue } // gone: its parent's event covers it
            if packages.count > 10_000 { packages.removeAll() }
            packages[p] = isPackage
            if isPackage { return p }
        }
        return nil
    }
}

// When the indexer child process runs, and how the bar learns about its progress.
extension AppDelegate {
    // nil paths: full walk of every root (launch, hourly). Paths: rescan only those folders.
    func startIndexer(paths: [String]? = nil) {
        guard !indexingPaused, let exe = Bundle.main.executablePath else { return }
        guard indexer == nil else {
            // a full request waits for the current run; changed folders are still in Watch.dirs
            if paths == nil { pendingIndex = true }
            return
        }
        var args = ["--index"]
        if let paths {
            let list = Paths.tmp + "/changed-folders.txt"
            guard (try? paths.joined(separator: "\n").write(toFile: list, atomically: true, encoding: .utf8)) != nil else {
                startIndexer()
                return
            }
            args += ["--paths", list]
        }
        Watch.dirs.removeAll()
        Watch.rescan = false
        lastIndexRun = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.qualityOfService = .utility
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexer = nil
                self.progressTimer?.invalidate()
                self.bar.status = ""
                // a run cut short may have written rows without bumping the generation
                self.reloadIndex(ifChanged: p.terminationReason == .exit && p.terminationStatus == 0, deferIfHidden: true)
                if self.pendingIndex { self.pendingIndex = false; self.startIndexer() }
                else if Watch.rescan || !Watch.dirs.isEmpty { self.scheduleChangedRun() }
            }
        }
        guard (try? p.run()) != nil else { return }
        indexer = p
        ticks = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if Watch.store == nil { Watch.store = Store(readonly: true) }
            guard let self, let s = Watch.store?.metaString("progress") else { return }
            self.bar.status = "Indexing \(s)"
            self.ticks += 1
            // surface new results while indexing; a hidden bar catches up when it is shown
            if self.ticks == 1 || self.ticks % 8 == 0 {
                self.reloadIndex(ifChanged: true, deferIfHidden: true)
            }
        }
    }

    // The indexer and the clipboard history write meta "generation" after changing rows, so an unchanged
    // value means the loaded index is current. It is read before reloading: a later write changes it again.
    // `deferIfHidden`: loading every row and vector is the costliest thing the idle bar does, so a hidden
    // bar only marks the index stale and reloads it when it is next shown.
    func reloadIndex(ifChanged: Bool = false, deferIfHidden: Bool = false) {
        if Watch.store == nil { Watch.store = Store(readonly: true) }
        let gen = Watch.store.map { $0.metaString("generation") }
        if ifChanged, let gen, let last = Watch.generation, gen == last { Watch.dirty = false; return }
        if deferIfHidden, !bar.isVisible { Watch.dirty = true; return }
        Watch.generation = gen
        Watch.dirty = false
        Engine.shared.reloadIndex()
    }

    func reloadIfDirty() {
        if Watch.dirty { reloadIndex() }
    }

    // One debounce for every batch of events: at least 5 s, and runs start at most once a minute.
    private func scheduleChangedRun() {
        guard Watch.timer == nil else { return }
        let wait = max(5, 60 - Date().timeIntervalSince(lastIndexRun))
        Watch.timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Watch.timer = nil
            guard let self, self.indexer == nil else { return } // the termination handler reschedules
            if Watch.rescan || Watch.dirs.count > Watch.maxDirs { self.startIndexer() }
            else if !Watch.dirs.isEmpty { self.startIndexer(paths: Watch.dirs.sorted()) }
        }
    }

    fileprivate func filesChanged(_ dirs: [String], rescan: Bool) {
        if rescan { Watch.rescan = true }
        Watch.dirs.formUnion(dirs)
        if Watch.rescan || !Watch.dirs.isEmpty { scheduleChangedRun() }
    }

    func watchFiles() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        let roots = Indexer.roots()
        Watch.roots = roots
        watchHome()
        let cb: FSEventStreamCallback = { _, _, n, paths, flags, _ in
            // kFSEventStreamCreateFlagUseCFTypes: the paths are a CFArray of CFString
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                                               kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            var dirs: [String] = [], rescan = false
            for i in 0..<min(n, list.count) {
                if flags[i] & lost != 0 { rescan = true; continue }
                let p = list[i]
                // a file event names the item; its folder is what gets listed again
                guard !Indexer.ignorable(p, roots: Watch.roots) else { continue }
                let dir = (p as NSString).deletingLastPathComponent
                if let pkg = Watch.package(containing: p) {
                    // a package is indexed as one file, and only its direct entries change its date; churn deeper
                    // inside (a Photos library's databases, an app's caches) would otherwise start a run every minute
                    if dir == pkg { dirs.append((pkg as NSString).deletingLastPathComponent) }
                    continue
                }
                dirs.append(Watch.roots.contains(p) ? p : dir)
            }
            AppDelegate.shared?.filesChanged(dirs, rescan: rescan)
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        guard let s = FSEventStreamCreate(nil, cb, nil, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                          FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    // Default roots are the visible folders in ~: a new or removed one re-creates the stream and walks everything.
    private func watchHome() {
        guard config.roots == nil, Watch.home == nil else { return }
        let fd = open(Paths.home, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, Indexer.roots() != Watch.roots else { return }
            self.watchFiles()
            self.startIndexer()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        Watch.home = src
    }
}
