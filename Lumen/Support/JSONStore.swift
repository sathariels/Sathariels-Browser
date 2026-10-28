import Foundation

/// Atomic JSON files under Application Support/Lumen. No secrets belong here.
enum JSONStore {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ name: String) throws -> URL {
        try directory().appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        do {
            let file = try url(name)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        do {
            let file = try url(name)
            let data = try JSONEncoder().encode(value)
            try data.write(to: file, options: .atomic)
        } catch {
            // Persistence failures should not take down the browser.
        }
    }

    static func remove(_ name: String) {
        guard let file = try? url(name) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
