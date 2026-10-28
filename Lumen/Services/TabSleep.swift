import Foundation

enum TabSleepMode: String, CaseIterable, Identifiable {
    case off
    case smart
    case aggressive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .smart: return "Smart"
        case .aggressive: return "Aggressive"
        }
    }
}

struct TabSleepInput: Equatable {
    var id: UUID
    var pinned: Bool
    var visible: Bool
    var neighbor: Bool
    var lastFocused: Date
    var focusCount: Int
    var loading: Bool
    var downloading: Bool
    var capturing: Bool
    var hasWebView: Bool
}

/// Decides which background tabs may be discarded. Media playback and unsaved
/// fields are checked in the page after this list is chosen.
enum TabSleepPolicy {
    static let smartBase: TimeInterval = 30 * 60
    static let smartCap: TimeInterval = 3 * 60 * 60
    static let pressureFloor: TimeInterval = 2 * 60

    static func idleLimit(mode: TabSleepMode, aggressiveMinutes: Int, focusCount: Int) -> TimeInterval {
        switch mode {
        case .off:
            return .infinity
        case .aggressive:
            return TimeInterval(max(1, aggressiveMinutes) * 60)
        case .smart:
            let uses = max(1, focusCount)
            let steps = min(3, log2(Double(uses)))
            return min(smartCap, smartBase * (1 + steps))
        }
    }

    static func candidates(
        tabs: [TabSleepInput],
        mode: TabSleepMode,
        aggressiveMinutes: Int,
        pressure: Bool,
        critical: Bool,
        now: Date
    ) -> [UUID] {
        if mode == .off && !critical { return [] }
        let live = tabs.filter(\.hasWebView)
        let eligible = live.filter { tab in
            !tab.pinned && !tab.visible && !tab.neighbor && !tab.loading && !tab.downloading && !tab.capturing
        }
        let oldest = eligible.sorted { lhs, rhs in
            if lhs.lastFocused != rhs.lastFocused { return lhs.lastFocused < rhs.lastFocused }
            return lhs.focusCount < rhs.focusCount
        }
        if pressure || critical {
            let idle = oldest.filter { now.timeIntervalSince($0.lastFocused) >= (critical ? 0 : pressureFloor) }
            return critical ? idle.map(\.id) : Array(idle.prefix(2).map(\.id))
        }
        if mode == .smart {
            return oldest.filter { tab in
                now.timeIntervalSince(tab.lastFocused) >= idleLimit(mode: mode, aggressiveMinutes: aggressiveMinutes, focusCount: tab.focusCount)
            }.map(\.id)
        }
        var chosen: [UUID] = []
        let timed = oldest.filter { tab in
            now.timeIntervalSince(tab.lastFocused) >= idleLimit(mode: .aggressive, aggressiveMinutes: aggressiveMinutes, focusCount: tab.focusCount)
        }
        chosen.append(contentsOf: timed.map(\.id))
        let protected = live.filter { $0.pinned || $0.visible || $0.neighbor || $0.loading || $0.downloading || $0.capturing }.count
        let budget = max(4, protected)
        let overflow = max(0, live.count - budget - chosen.count)
        if overflow > 0 {
            for tab in oldest where !chosen.contains(tab.id) && chosen.count < timed.count + overflow {
                chosen.append(tab.id)
            }
        }
        return chosen
    }
}
