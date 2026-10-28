import Darwin
import Foundation

enum MemoryFormat {
    static func badge(bytes: Int64, kind: TabMemory.Kind) -> String {
        switch kind {
        case .suspended: return "asleep"
        case .empty: return ""
        case .unknown: return "…"
        case .measured: return megabytes(bytes)
        case .estimate: return "~\(megabytes(bytes))"
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(max(bytes, 0)) / 1_048_576
        if mb < 10 { return String(format: "%.1fM", mb) }
        return String(format: "%.0fM", mb)
    }
}

struct TabMemory: Equatable {
    enum Kind: Equatable { case empty, unknown, suspended, estimate, measured }
    var bytes: Int64
    var kind: Kind

    static let empty = TabMemory(bytes: 0, kind: .empty)
    static let unknown = TabMemory(bytes: 0, kind: .unknown)
    static let suspended = TabMemory(bytes: 0, kind: .suspended)
}

/// Proxy when WebKit will not tell us which process belongs to which tab.
/// TODO: Replace the heuristic with a public per-tab footprint API if WebKit adds one.
/// Do not call private WKWebView memory SPI.
enum MemoryEstimate {
    static let floorBytes: Int64 = 8 * 1_048_576

    static func bytes(transfer: Int64, nodes: Int) -> Int64 {
        let dom = Int64(max(nodes, 0)) * 256
        return floorBytes + max(transfer, 0) * 2 + dom
    }
}

struct WebKitFootprint {
    var webContentBytes: Int64
    var webContentProcesses: Int
    var helperBytes: Int64
}

struct TabLoadInput: Equatable {
    var id: UUID
    var title: String
    var estimate: Int64
    var asleep: Bool
}

struct ProcessLoad: Equatable {
    var pid: Int32
    var bytes: Int64
    var cpu: Double
}

struct TabLoadRow: Identifiable, Equatable {
    var id: UUID
    var title: String
    var bytes: Int64
    var measured: Bool
    var cpu: Double
    var asleep: Bool
}

enum EnergyEstimate {
    /// CPU seconds used divided by wall seconds. 1.0 is one full core.
    static func fraction(previous: UInt64, current: UInt64, seconds: Double) -> Double {
        guard seconds > 0.05, current >= previous else { return 0 }
        let delta = Double(current - previous) / 1_000_000_000
        return min(8, delta / seconds)
    }

    static func label(_ fraction: Double) -> String {
        if fraction < 0.05 { return "idle" }
        if fraction < 0.25 { return "low" }
        if fraction < 0.70 { return "med" }
        return "high"
    }
}

/// Pairs live tabs with WebContent processes only when the counts match.
/// Otherwise the row keeps the tab's own estimate and `measured` stays false.
enum TabLoadAssign {
    static func rows(tabs: [TabLoadInput], processes: [ProcessLoad]) -> [TabLoadRow] {
        let live = tabs.filter { !$0.asleep }
        let asleep = tabs.filter(\.asleep)
        var assigned: [TabLoadRow] = []
        if !live.isEmpty, live.count == processes.count {
            let orderedTabs = live.sorted { $0.estimate == $1.estimate ? $0.title < $1.title : $0.estimate > $1.estimate }
            let orderedProcesses = processes.sorted { $0.bytes == $1.bytes ? $0.pid < $1.pid : $0.bytes > $1.bytes }
            for pair in zip(orderedTabs, orderedProcesses) {
                assigned.append(TabLoadRow(
                    id: pair.0.id,
                    title: pair.0.title,
                    bytes: pair.1.bytes,
                    measured: true,
                    cpu: pair.1.cpu,
                    asleep: false
                ))
            }
        } else {
            for tab in live {
                assigned.append(TabLoadRow(id: tab.id, title: tab.title, bytes: tab.estimate, measured: false, cpu: 0, asleep: false))
            }
        }
        for tab in asleep {
            assigned.append(TabLoadRow(id: tab.id, title: tab.title, bytes: 0, measured: false, cpu: 0, asleep: true))
        }
        return assigned.sorted { lhs, rhs in
            if lhs.asleep != rhs.asleep { return !lhs.asleep && rhs.asleep }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.title < rhs.title
        }
    }
}

enum ProcessFootprint {
    private static let procPIDTaskInfo: Int32 = 4

    struct ProcTaskInfo {
        var virtualSize: UInt64 = 0
        var residentSize: UInt64 = 0
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var threadsUser: UInt64 = 0
        var threadsSystem: UInt64 = 0
        var policy: Int32 = 0
        var faults: Int32 = 0
        var pageins: Int32 = 0
        var cowFaults: Int32 = 0
        var messagesSent: Int32 = 0
        var messagesReceived: Int32 = 0
        var syscallsMach: Int32 = 0
        var syscallsUnix: Int32 = 0
        var csw: Int32 = 0
        var threadNum: Int32 = 0
        var numRunning: Int32 = 0
        var priority: Int32 = 0
    }

    static func sample() -> WebKitFootprint? {
        let root = ProcessInfo.processInfo.processIdentifier
        let descendants = childPIDs(of: root, depth: 4)
        guard !descendants.isEmpty else { return nil }
        var web: Int64 = 0
        var webCount = 0
        var helper: Int64 = 0
        var any = false
        for pid in descendants {
            guard let name = processName(pid), let rss = residentBytes(pid) else { continue }
            any = true
            let lower = name.lowercased()
            if lower.contains("webcontent") {
                web += rss
                webCount += 1
            } else if lower.contains("webkit") || lower.contains("networking") || lower.contains("gpu") {
                helper += rss
            }
        }
        guard any else { return nil }
        return WebKitFootprint(webContentBytes: web, webContentProcesses: webCount, helperBytes: helper)
    }

    struct WebContentProcess {
        var pid: Int32
        var bytes: Int64
        var cpuNanoseconds: UInt64
    }

    static func webContentProcesses() -> [WebContentProcess] {
        let root = ProcessInfo.processInfo.processIdentifier
        return childPIDs(of: root, depth: 4).compactMap { pid in
            guard let name = processName(pid)?.lowercased(), name.contains("webcontent"),
                  let info = taskInfo(pid) else { return nil }
            return WebContentProcess(pid: pid, bytes: Int64(info.residentSize), cpuNanoseconds: info.totalUser &+ info.totalSystem)
        }
    }

    private static func taskInfo(_ pid: Int32) -> ProcTaskInfo? {
        var info = ProcTaskInfo()
        let size = Int32(MemoryLayout<ProcTaskInfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                proc_pidinfo(pid, procPIDTaskInfo, 0, raw, size)
            }
        }
        guard result > 0 else { return nil }
        return info
    }

    private static func childPIDs(of root: Int32, depth: Int) -> [Int32] {
        var pending = [root]
        var seen = Set<Int32>([root])
        var found: [Int32] = []
        var level = 0
        while level < depth && !pending.isEmpty {
            var next: [Int32] = []
            for parent in pending {
                for child in directChildren(of: parent) where seen.insert(child).inserted {
                    found.append(child)
                    next.append(child)
                }
            }
            pending = next
            level += 1
        }
        return found
    }

    private static func directChildren(of pid: Int32) -> [Int32] {
        let needed = proc_listchildpids(pid, nil, 0)
        guard needed > 0 else { return [] }
        let count = Int(needed) / MemoryLayout<Int32>.size
        var buffer = [Int32](repeating: 0, count: max(count, 1))
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(pid, raw.baseAddress, needed)
        }
        guard written > 0 else { return [] }
        let n = min(count, Int(written) / MemoryLayout<Int32>.size)
        return Array(buffer.prefix(n)).filter { $0 > 0 }
    }

    private static func residentBytes(_ pid: Int32) -> Int64? {
        taskInfo(pid).map { Int64($0.residentSize) }
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = copyProcessName(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }
}

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_listchildpids")
private func proc_listchildpids(_ ppid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func copyProcessName(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ buffersize: UInt32) -> Int32

final class MemoryPressureCenter {
    static let shared = MemoryPressureCenter()
    private var source: DispatchSourceMemoryPressure?
    private(set) var warning = false
    private(set) var critical = false
    var isUnderPressure: Bool { warning || critical }
    var onPressure: ((Bool) -> Void)?

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let event = source.data
            if event.contains(.normal) {
                self.warning = false
                self.critical = false
            }
            if event.contains(.warning) { self.warning = true }
            if event.contains(.critical) {
                self.warning = true
                self.critical = true
            }
            self.onPressure?(self.critical)
        }
        source.resume()
        self.source = source
    }
}
