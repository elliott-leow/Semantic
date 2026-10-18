import Foundation
import IOKit.ps

// Progress for the bar: the plain "progress" string, plus "progress.json"
// ({"stage","done","total","eta"}, eta in seconds or null) for a ring with an ETA.
final class IndexProgress {
    private let store: Store
    private var stage = ""
    private var total = 0
    private var started = Date()
    private var written = Date.distantPast

    init(_ store: Store) { self.store = store }

    func begin(_ stage: String, total: Int) {
        self.stage = stage
        self.total = total
        started = Date()
        written = .distantPast
    }

    // `label` is the legacy progress string; nil keeps "<stage> done/total"
    func tick(_ done: Int, label: String? = nil, force: Bool = false) {
        guard force || done >= total || Date().timeIntervalSince(written) >= 1 else { return }
        written = Date()
        store.setMeta("progress", string: label ?? "\(stage) \(done)/\(total)")
        let elapsed = Date().timeIntervalSince(started)
        let eta: Any = done > 0 ? Int((elapsed / Double(done) * Double(max(0, total - done))).rounded()) : NSNull()
        let j: [String: Any] = ["stage": stage, "done": done, "total": total, "eta": eta]
        store.setMeta("progress.json", try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]))
    }

    func clear() {
        store.setMeta("progress", nil)
        store.setMeta("progress.json", nil)
    }
}

enum IndexPower {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    // Image/audio/video model work waits for AC power and a cool machine; names and text never wait.
    static var deferMedia: Bool {
        guard config.reduceIndexingOnBattery != false else { return false }
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue || onBattery
    }
}
