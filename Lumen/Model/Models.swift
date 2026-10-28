import Foundation

enum Pane: String, Codable {
    case primary
    case secondary
}

enum UpperPane: String, Codable {
    case tabs
    case bookmarks
    case history
}

enum PermissionKind: String, Codable, CaseIterable, Identifiable {
    case camera
    case microphone
    case notifications
    case location
    case popups
    case autoplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .notifications: return "Notifications"
        case .location: return "Location"
        case .popups: return "Popups"
        case .autoplay: return "Autoplay"
        }
    }
}

enum PermissionChoice: String, Codable {
    case ask
    case allow
    case deny
}

struct SitePermissions: Codable, Equatable, Identifiable {
    var host: String
    var camera: PermissionChoice
    var microphone: PermissionChoice
    var notifications: PermissionChoice
    var location: PermissionChoice
    var popups: PermissionChoice
    var autoplay: PermissionChoice

    var id: String { host }

    static func fresh(host: String) -> SitePermissions {
        SitePermissions(
            host: host,
            camera: .ask,
            microphone: .ask,
            notifications: .ask,
            location: .ask,
            popups: .ask,
            autoplay: .deny
        )
    }

    func choice(for kind: PermissionKind) -> PermissionChoice {
        switch kind {
        case .camera: return camera
        case .microphone: return microphone
        case .notifications: return notifications
        case .location: return location
        case .popups: return popups
        case .autoplay: return autoplay
        }
    }

    mutating func set(_ choice: PermissionChoice, for kind: PermissionKind) {
        switch kind {
        case .camera: camera = choice
        case .microphone: microphone = choice
        case .notifications: notifications = choice
        case .location: location = choice
        case .popups: popups = choice
        case .autoplay: autoplay = choice
        }
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    var title: String
    var host: String
    var created: Date
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    var title: String
    var host: String
    var visitCount: Int
    var lastVisit: Date
}

struct TabSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var url: String?
    var title: String
    var colorIndex: Int
}

struct WindowSnapshot: Codable, Equatable {
    var index: Int
    var tabs: [TabSnapshot]
    var primaryTabID: UUID?
    var secondaryTabID: UUID?
    var focusedPane: Pane
    var splitFraction: Double
    var sidebarWidth: Double
}

struct SessionFile: Codable, Equatable {
    var version: Int
    var windows: [WindowSnapshot]
}

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, url, image }
    var id: UUID
    var kind: Kind
    var text: String?
    var created: Date
    var pinned: Bool
    var thumbFile: String?
}

struct AIMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case system, user, assistant }
    var id: UUID
    var role: Role
    var content: String
}

enum DownloadState: String, Codable {
    case active
    case finished
    case failed
    case cancelled
}

struct DownloadRow: Identifiable, Equatable {
    var id: UUID
    var filename: String
    var destination: URL?
    var bytesWritten: Int64
    var bytesExpected: Int64
    var fraction: Double?
    var state: DownloadState
    var detail: String?
    var tabID: UUID?
}

struct WindowLaunch: Codable, Hashable {
    var index: Int
    var isPrivate: Bool
}
