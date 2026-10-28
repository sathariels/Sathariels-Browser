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
        var info = ProcTaskInfo()
        let size = Int32(MemoryLayout<ProcTaskInfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                proc_pidinfo(pid, procPIDTaskInfo, 0, raw, size)
            }
        }
        guard result > 0 else { return nil }
        return Int64(info.residentSize)
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
    var onPressure: ((Bool) -> Void)?

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let event = source.data
            let critical = event.contains(.critical)
            self.onPressure?(critical)
        }
        source.resume()
        self.source = source
    }
}
