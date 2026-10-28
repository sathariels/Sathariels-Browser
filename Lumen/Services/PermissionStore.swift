import Foundation

final class PermissionStore: ObservableObject {
    static let shared = PermissionStore(persistent: true)

    @Published private(set) var sites: [SitePermissions] = []
    let persistent: Bool

    init(persistent: Bool) {
        self.persistent = persistent
        if persistent {
            sites = JSONStore.load("permissions.json", as: [SitePermissions].self) ?? []
        }
    }

    func site(for host: String) -> SitePermissions {
        let key = host.lowercased()
        return sites.first { $0.host == key } ?? .fresh(host: key)
    }

    func choice(host: String, kind: PermissionKind) -> PermissionChoice {
        site(for: host).choice(for: kind)
    }

    func set(host: String, kind: PermissionKind, choice: PermissionChoice) {
        let key = host.lowercased()
        var site = site(for: key)
        site.set(choice, for: kind)
        if let index = sites.firstIndex(where: { $0.host == key }) {
            sites[index] = site
        } else {
            sites.append(site)
        }
        persist()
    }

    func replace(_ site: SitePermissions) {
        var copy = site
        copy.host = site.host.lowercased()
        if let index = sites.firstIndex(where: { $0.host == copy.host }) {
            sites[index] = copy
        } else {
            sites.append(copy)
        }
        persist()
    }

    func remove(host: String) {
        sites.removeAll { $0.host == host.lowercased() }
        persist()
    }

    func removeAll() {
        sites = []
        persist()
    }

    private func persist() {
        guard persistent else { return }
        JSONStore.save(sites, as: "permissions.json")
    }
}
