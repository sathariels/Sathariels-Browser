import Foundation
import Network

enum LocalhostScanner {
    static let ports: [UInt16] = [3000, 3001, 4000, 4173, 4200, 4321, 5000, 5173, 5174, 5500, 8000, 8080, 8081, 8888, 9000, 9229]

    static func scan() async -> [UInt16] {
        var open: [UInt16] = []
        await withTaskGroup(of: UInt16?.self) { group in
            var next = 0
            let limit = 4
            func add() {
                guard next < ports.count else { return }
                let port = ports[next]
                next += 1
                group.addTask { await probe(port) ? port : nil }
            }
            for _ in 0..<min(limit, ports.count) { add() }
            for await port in group {
                if let port { open.append(port) }
                add()
            }
        }
        return open.sorted()
    }

    static func probe(_ port: UInt16) async -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        return await withCheckedContinuation { continuation in
            let gate = ProbeGate(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(true)
                case .failed, .cancelled: gate.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.28) {
                gate.finish(false)
            }
        }
    }
}

private final class ProbeGate {
    let connection: NWConnection
    let continuation: CheckedContinuation<Bool, Never>
    private var done = false
    private let lock = NSLock()

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}

final class LocalhostModel: ObservableObject {
    @Published private(set) var ports: [UInt16] = []
    @Published private(set) var scanning = false
    @Published var status = "Scan when you need a port."

    func scan() {
        guard !scanning else { return }
        scanning = true
        status = "Scanning…"
        Task {
            let found = await LocalhostScanner.scan()
            await MainActor.run {
                self.ports = found
                self.scanning = false
                self.status = found.isEmpty ? "Nothing listening on the usual ports." : "\(found.count) open"
            }
        }
    }
}
