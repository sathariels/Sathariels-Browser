import CoreGraphics
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

struct TabGroup: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var colorIndex: Int
    var collapsed: Bool
}

struct TabSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var url: String?
    var title: String
    var colorIndex: Int
    var pinned: Bool
    var groupID: UUID?
    var scrollX: Double?
    var scrollY: Double?
    var stateFile: String?

    init(id: UUID, url: String?, title: String, colorIndex: Int, pinned: Bool = false, groupID: UUID? = nil, scrollX: Double? = nil, scrollY: Double? = nil, stateFile: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.colorIndex = colorIndex
        self.pinned = pinned
        self.groupID = groupID
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.stateFile = stateFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        scrollX = try container.decodeIfPresent(Double.self, forKey: .scrollX)
        scrollY = try container.decodeIfPresent(Double.self, forKey: .scrollY)
        stateFile = try container.decodeIfPresent(String.self, forKey: .stateFile)
    }
}

struct WindowSnapshot: Codable, Equatable {
    var index: Int
    var tabs: [TabSnapshot]
    var groups: [TabGroup]
    var primaryTabID: UUID?
    var secondaryTabID: UUID?
    var focusedPane: Pane
    var splitFraction: Double
    var sidebarWidth: Double

    init(index: Int, tabs: [TabSnapshot], groups: [TabGroup] = [], primaryTabID: UUID?, secondaryTabID: UUID?, focusedPane: Pane, splitFraction: Double, sidebarWidth: Double) {
        self.index = index
        self.tabs = tabs
        self.groups = groups
        self.primaryTabID = primaryTabID
        self.secondaryTabID = secondaryTabID
        self.focusedPane = focusedPane
        self.splitFraction = splitFraction
        self.sidebarWidth = sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        tabs = try container.decode([TabSnapshot].self, forKey: .tabs)
        groups = try container.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
        primaryTabID = try container.decodeIfPresent(UUID.self, forKey: .primaryTabID)
        secondaryTabID = try container.decodeIfPresent(UUID.self, forKey: .secondaryTabID)
        focusedPane = try container.decode(Pane.self, forKey: .focusedPane)
        splitFraction = try container.decode(Double.self, forKey: .splitFraction)
        sidebarWidth = try container.decode(Double.self, forKey: .sidebarWidth)
    }
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
    var imageFile: String? = nil
}

struct AIMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case system, user, assistant, step }
    var id: UUID
    var role: Role
    var content: String
}

enum DownloadState: String, Codable {
    case active
    case paused
    case finished
    case failed
    case cancelled
}

struct DownloadRow: Identifiable, Equatable {
    var id: UUID
    var filename: String
    var destination: URL?
    var source: String?
    var bytesWritten: Int64
    var bytesExpected: Int64
    var fraction: Double?
    var bytesPerSecond: Double
    var state: DownloadState
    var detail: String?
    var tabID: UUID?
}

struct ViewportMode: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case full
        case iPhone
        case iPad
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .full: return "Full"
            case .iPhone: return "iPhone"
            case .iPad: return "iPad"
            case .custom: return "Custom"
            }
        }
    }

    var preset: Preset = .full
    var mobileUserAgent = false
    var customWidth = 390.0
    var customHeight = 844.0

    var size: CGSize? {
        switch preset {
        case .full: return nil
        case .iPhone: return CGSize(width: 390, height: 844)
        case .iPad: return CGSize(width: 820, height: 1180)
        case .custom: return CGSize(width: customWidth, height: customHeight)
        }
    }
}

struct WindowLaunch: Codable, Hashable {
    var index: Int
    var isPrivate: Bool
}
