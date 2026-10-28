import Foundation

/// Samples WebContent RSS and CPU only while the memory panel is open.
final class TabLoadCenter: ObservableObject {
    static let shared = TabLoadCenter()

    @Published private(set) var rows: [TabLoadRow] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var processCount = 0
    private var timer: Timer?
    private var lastCPU: [Int32: UInt64] = [:]
    private var lastTime: Date?
    private weak var session: BrowserSession?

    func row(_ id: UUID) -> TabLoadRow? {
        rows.first { $0.id == id }
    }

    func start(_ session: BrowserSession) {
        self.session = session
        session.tabs.forEach { $0.refreshHeuristic() }
        sample()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastCPU = [:]
        lastTime = nil
    }

    private func sample() {
        guard let session else { return }
        let now = Date()
        let processes = ProcessFootprint.webContentProcesses()
        let seconds = lastTime.map { now.timeIntervalSince($0) } ?? 0
        let loads = processes.map { process -> ProcessLoad in
            let previous = lastCPU[process.pid] ?? process.cpuNanoseconds
            let cpu = EnergyEstimate.fraction(previous: previous, current: process.cpuNanoseconds, seconds: seconds)
            return ProcessLoad(pid: process.pid, bytes: process.bytes, cpu: cpu)
        }
        lastCPU = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.cpuNanoseconds) })
        lastTime = now
        totalBytes = processes.reduce(0) { $0 + $1.bytes }
        processCount = processes.count
        let inputs = session.tabs.map { tab in
            TabLoadInput(
                id: tab.id,
                title: tab.title.isEmpty ? "New Tab" : tab.title,
                estimate: tab.memory.bytes,
                asleep: tab.webView == nil
            )
        }
        rows = TabLoadAssign.rows(tabs: inputs, processes: loads)
        for row in rows where row.measured {
            session.tab(row.id)?.memory = TabMemory(bytes: row.bytes, kind: .measured)
        }
    }
}
